from __future__ import annotations

import hashlib
import json
import re
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, replace
from typing import Any

from connector.runtime_protocol import (
    AgentCallToolContent,
    CommandToolContent,
    ErrorSystemContent,
    FileChangeToolContent,
    GenericSystemContent,
    InputRequestToolContent,
    MarkdownMessageContent,
    McpToolContent,
    MessageTimelineItem,
    ReasoningSystemContent,
    RuntimeTimelineItem,
    SystemTimelineItem,
    TimelineSource,
    ToolCallContent,
    ToolResultContent,
    ToolTimelineContent,
    ToolTimelineItem,
    UnknownSystemContent,
    WebSearchToolContent,
    complete_tool_content,
)
from connector.runtimes.claude.domain.context_report import (
    ClaudeContextProbe,
    is_context_report_text,
)
from connector.runtimes.claude.domain.models import claude_context_window
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import is_task_notification_text
from connector.runtimes.claude.sdk.title_tool import is_title_tool_name
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
    ClaudeAgentCallCard,
    ClaudeAgentTaskOverlay,
    agent_task_terminal_status,
    claude_agent_call_content,
    closure_rank,
    complete_claude_agent_call_content,
    has_running_agent_tasks,
    is_async_agent_receipt,
    open_agent_task_ids,
    resolve_agent_card_status,
    resolve_resume_alias,
    send_message_target,
)

CLAUDE_INTERRUPTED_REQUEST_MARKERS = frozenset(
    {
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    }
)
CLAUDE_NO_RESPONSE_MARKER = "No response requested."
# Claude restarts the chain from a summary after /compact or an automatic
# compaction and persists that summary as a plain user message. `SessionMessage`
# carries no isCompactSummary flag, so these exact CLI sentences (captured by
# the 2026-10-02 probe) are the only marker we have. Both are matched: the
# longer the guard, the narrower the chance it eats a message the user wrote.
CLAUDE_COMPACT_SUMMARY_PREFIX = (
    "This session is being continued from a previous conversation that ran out of "
    "context. The summary below covers the earlier portion of the conversation."
)
# CLI chrome around a native slash command typed in the CLI's own input, which
# the wire replays as ordinary user messages (real session 84275e9e, 2026-10-02:
# 93b03c34 stdout echo, 767c8e9a command-name echo, prefixed by a caveat). None
# of it is conversation content: the CLI's own caveat says the command "was run
# directly in Claude Code, not sent to you as a request, and its output goes to
# the CLI, not to the model", the command name is the CLI dispatching its own
# input line, and the stdout/stderr echo is that CLI-bound output coming back.
# The tags live here, in the layer every other reader already depends on, so the
# compaction path (`markers.is_local_command_echo`) and the synthetic-control
# path cannot drift apart on what counts as chrome.
#
# Scope note: only zero-argument commands have been observed on the wire
# (`/compact`). Suppressing stdout/stderr echoes wholesale is therefore an
# evidence-backed guess about commands with arguments too; if such a command ever
# emits output a user must see, that case is reassessed here rather than the
# suppression being widened further.
CLAUDE_CAVEAT_PREFIX = "<local-command-caveat>"
CLAUDE_COMMAND_NAME_TAG = "<command-name>"
CLAUDE_LOCAL_COMMAND_ECHO_TAGS = (
    "<local-command-stdout>",
    "<local-command-stderr>",
)
CLAUDE_LOCAL_COMMAND_CHROME_PREFIXES = (
    CLAUDE_CAVEAT_PREFIX,
    CLAUDE_COMMAND_NAME_TAG,
    *CLAUDE_LOCAL_COMMAND_ECHO_TAGS,
)
# The wire's reasoning shapes. One set for the extraction, the revision rule
# and the display gate, so the three can never drift apart on what counts as
# reasoning.
REASONING_BLOCK_TYPES = frozenset({"thinking", "reasoning", "redacted_thinking"})


@dataclass(frozen=True, slots=True)
class ClaudeToolBlock:
    block_type: str
    tool_use_id: str
    tool_name: str | None = None
    tool_input: Any = None
    tool_result: Any = None
    is_error: bool = False
    is_synthetic: bool = False
    parent_tool_use_id: str | None = None
    tool_result_metadata: Mapping[str, Any] | None = None
    # The per-call usage of the assistant frame this `tool_use` arrived on,
    # already enriched with the model/window keys (`enrich_usage`). Carried on
    # the block (not just the item) so the pending call keeps it: the later
    # `tool_result` write rebuilds the item from this block, and without the
    # carry that rewrite would strip the only usage a tool-only call left on
    # the timeline.
    usage: Mapping[str, Any] | None = None


@dataclass(frozen=True, slots=True)
class ClaudePendingToolCall:
    block: ClaudeToolBlock
    turn_id: str
    # History lookup only: the public SDK SessionMessage carries the original
    # tool_result body but drops transcript-level toolUseResult metadata.
    # Keeping the matched result lets a later incremental window rebuild the
    # same recoverable receipt shape before applying its task overlay.
    result_block: ClaudeToolBlock | None = None


@dataclass(frozen=True, slots=True)
class ClaudeSystemBlock:
    block_type: str
    block_index: int
    text: str | None = None
    metadata: Mapping[str, Any] | None = None


class ClaudeMessageProjector:
    def __init__(
        self,
        tool_call_lookup: Mapping[str, ClaudePendingToolCall] | None = None,
        hidden_tool_use_ids: frozenset[str] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._order_by_id: dict[str, int] = {}
        self._next_order_seq = 1
        self._tool_calls: dict[str, ClaudePendingToolCall] = {}
        self._tool_call_lookup = dict(tool_call_lookup or {})
        self._hidden_tool_use_ids: set[str] = set(hidden_tool_use_ids or ())
        # Wall-clock seam for the launch stamp on Agent cards (F5): the
        # never-started grace needs an age, and the wire frames carry none.
        # Injectable so tests can drive it; wall clock (not monotonic) because
        # it is compared against file mtimes, which are wall-clock.
        self._clock = clock if clock is not None else time.time
        # L2 subagent progress: live state of every Agent call card this
        # projector has minted, keyed by the card's stable item id. The card
        # carries the wire-projected content and the task-event overlay
        # separately so either writer can land first (see agent_calls.py).
        self._agent_cards: dict[str, ClaudeAgentCallCard] = {}
        # R4 resume-alias lineage (subagent-status-truth-tasks §3.3): a task
        # resumed through SendMessage keys its later frames on the SendMessage
        # tool_use id, so the live fold must route them back onto the original
        # dispatch card instead of minting a second one. The two maps are the
        # join: a task id learned from an Agent receipt (or an Agent call's own
        # agentId) -> the dispatch tool_use id(s) that produced it, and a
        # SendMessage tool_use id -> the task id it addresses. Both are read
        # only for lineage; SendMessage's own visibility is untouched.
        self._task_roots: dict[str, set[str]] = {}
        self._send_to_task: dict[str, str] = {}

    def message_item(
        self,
        session: ClaudeSession,
        turn_id: str,
        role: str,
        text: str,
        event: str,
        status: str = "done",
        client_message_id: str | None = None,
        native_item_id: str | None = None,
        item_id: str | None = None,
        revision: int = 1,
        attachments: tuple[Mapping[str, object], ...] = (),
        usage: Mapping[str, Any] | None = None,
        usage_model: str | None = None,
    ) -> RuntimeTimelineItem:
        stable_key = native_item_id or client_message_id or text
        resolved_item_id = item_id or (
            stable_message_item_id(session, native_item_id)
            if native_item_id
            else _stable_id(
                "message",
                session.session_id,
                session.external_session_id,
                turn_id,
                role,
                stable_key,
            )
        )
        order_seq = self.order_seq_for(resolved_item_id)
        metadata: dict[str, Any] = {}
        if attachments:
            metadata["attachments"] = [
                dict(attachment) for attachment in attachments
            ]
        if usage:
            # A message's per-call usage rides its content, the one channel
            # the server passes through, stores and replays verbatim. The
            # engine's own window declaration (the session probe) names the
            # model and the window the measurement belongs to.
            metadata["usage"] = enrich_usage(
                usage,
                model=usage_model,
                probe=session.context_probe,
            )
        return MessageTimelineItem(
            id=resolved_item_id,
            type="message",
            status=status,  # type: ignore[arg-type]
            role=role,  # type: ignore[arg-type]
            turn_id=turn_id,
            content=MarkdownMessageContent(text=text, metadata=metadata),
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=turn_id,
                native_item_id=native_item_id,
                native_item_type=role,
                event=event,
                client_message_id=client_message_id,
            ),
            revision=revision,
        ).to_platform_item(session_id=session.session_id, order_seq=order_seq)

    def order_seq_for(self, item_id: str) -> int:
        """Hand out one stable order slot per item id.

        This counter is the timeline's single allocator: compaction markers take
        their slot from it too, so a separator can never reuse a number a
        message already published and leave the two items in an arbitrary order.
        """

        order_seq = self._order_by_id.get(item_id)
        if order_seq is None:
            order_seq = self._next_order_seq
            self._next_order_seq += 1
            self._order_by_id[item_id] = order_seq
        return order_seq

    def move_reserved_order(self, reserved_item_id: str, item_id: str) -> None:
        """Move a live item's reserved order to its final SDK-backed ID."""

        if reserved_item_id == item_id:
            return
        order_seq = self._order_by_id.pop(reserved_item_id, None)
        if order_seq is not None:
            self._order_by_id.setdefault(item_id, order_seq)

    def tool_items_for_message(
        self,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
    ) -> tuple[RuntimeTimelineItem, ...]:
        items: list[RuntimeTimelineItem] = []
        # A tool-only API call produces no message or reasoning row, so the
        # call's per-call usage (a pure tool_use frame's own) is stamped on
        # the tool rows it minted — otherwise nothing on the timeline would
        # carry the newest measurement until the next call streams text.
        # `message_usage` returns None for user frames (tool results) and for
        # subagent sidechain frames.
        usage = enrich_usage(
            message_usage(message),
            model=message_model(message),
            probe=session.context_probe,
        )
        for block in message_tool_blocks(message):
            if block.block_type == "tool_use" and is_hidden_tool_name(block.tool_name):
                self._hidden_tool_use_ids.add(block.tool_use_id)
                continue
            if block.block_type == "tool_use":
                # The resume lineage is recorded before visibility is decided,
                # so a hidden SendMessage still contributes its alias while its
                # own row stays exactly as visible (or hidden) as before.
                self._record_send_message(block)
            if (
                block.block_type == "tool_result"
                and block.tool_use_id in self._hidden_tool_use_ids
            ):
                continue
            if block.block_type == "tool_use" and usage is not None:
                block = replace(block, usage=usage)
            items.append(self.tool_item(session=session, turn_id=turn_id, block=block))
        return tuple(items)

    def system_items_for_message(
        self,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
        event: str,
        reasoning_revision: int | None = None,
    ) -> tuple[RuntimeTimelineItem, ...]:
        items: list[RuntimeTimelineItem] = []
        native_message_id = message_id(message)
        # The frame's per-call usage for its reasoning rows: this projection
        # republishes the row the stream already wrote (same stable id), and
        # the later write must not strip the usage that row carries.
        reasoning_usage = enrich_usage(
            message_usage(message),
            model=message_model(message),
            probe=session.context_probe,
        )
        for block in message_system_blocks(message):
            if (
                block.block_type in REASONING_BLOCK_TYPES
                and not _reasoning_block_is_displayable(block)
            ):
                # The empty-reasoning shape the affected model channel emits:
                # a thinking block carrying only its signature (9 of 49 blocks
                # in the reported session, 2026-10-05), or a redacted_thinking
                # with nothing readable. Published, it renders as a bare,
                # un-expandable 「推理」 dead row with no body, so it is never
                # projected — the same invariant the streaming path keeps
                # (`stream.py::_thinking_partial_item` drops empty text before
                # `reasoning_item`). All three routes share this projector
                # (live subagent frames, the turn-end projection, the history
                # import), and the client gate additionally hides rows already
                # persisted by older connectors.
                continue
            item_id = stable_system_item_id(
                session=session,
                turn_id=turn_id,
                native_message_id=native_message_id,
                block=block,
            )
            order_seq = self._order_by_id.get(item_id)
            if order_seq is None:
                order_seq = self._next_order_seq
                self._next_order_seq += 1
                self._order_by_id[item_id] = order_seq
            content = _system_content(
                block,
                usage=(
                    reasoning_usage
                    if block.block_type in REASONING_BLOCK_TYPES
                    else None
                ),
            )
            revision = (
                reasoning_revision
                if reasoning_revision is not None
                and block.block_type in REASONING_BLOCK_TYPES
                else 1
            )
            items.append(
                SystemTimelineItem(
                    id=item_id,
                    type="system",
                    status="failed" if block.block_type == "error" else "done",
                    role="system",
                    turn_id=turn_id,
                    content=content,
                    source=TimelineSource(
                        runtime="claude",
                        external_session_id=session.external_session_id,
                        turn_id=turn_id,
                        native_item_id=native_message_id,
                        native_item_type=block.block_type,
                        event=event,
                        derived_key=block.block_type,
                    ),
                    revision=revision,
                ).to_platform_item(session_id=session.session_id, order_seq=order_seq)
            )
        return tuple(items)

    def reasoning_item(
        self,
        session: ClaudeSession,
        turn_id: str,
        *,
        native_message_id: str,
        block_index: int,
        text: str,
        status: str,
        revision: int,
        usage: Mapping[str, Any] | None = None,
        usage_model: str | None = None,
    ) -> RuntimeTimelineItem:
        """Project one streaming thinking block as a reasoning system item.

        Shares stable_system_item_id with the finished-message projection, so
        the live item, the turn-end item and history converge on one row.
        Callers must not pass empty text: an empty reasoning block is never
        published (the stream guard in `stream.py` answers the same question),
        and `system_items_for_message` drops the same shape on the other
        routes.

        `usage` stamps the per-call usage the row's message reported, so the
        first item a turn streams already carries the turn's measurement (a
        thinking block precedes any text on the wire).
        """

        block = ClaudeSystemBlock(
            block_type="thinking",
            block_index=block_index,
            text=text,
        )
        item_id = stable_system_item_id(
            session=session,
            turn_id=turn_id,
            native_message_id=native_message_id,
            block=block,
        )
        order_seq = self.order_seq_for(item_id)
        metadata: dict[str, Any] = {"blockType": "thinking"}
        if usage:
            metadata["usage"] = enrich_usage(
                usage,
                model=usage_model,
                probe=session.context_probe,
            )
        return SystemTimelineItem(
            id=item_id,
            type="system",
            status=status,  # type: ignore[arg-type]
            role="system",
            turn_id=turn_id,
            content=ReasoningSystemContent(
                text=text,
                metadata=metadata,
            ),
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=turn_id,
                native_item_id=native_message_id,
                native_item_type="thinking",
                event="claude.turn.system",
                derived_key="thinking",
            ),
            revision=revision,
        ).to_platform_item(session_id=session.session_id, order_seq=order_seq)

    def missing_history_tool_result_items(
        self,
        session: ClaudeSession,
    ) -> tuple[RuntimeTimelineItem, ...]:
        items: list[RuntimeTimelineItem] = []
        for pending in tuple(self._tool_calls.values()):
            items.append(
                self.tool_item(
                    session=session,
                    turn_id=pending.turn_id,
                    block=ClaudeToolBlock(
                        block_type="tool_result",
                        tool_use_id=pending.block.tool_use_id,
                        tool_result="No tool result was recorded in Claude history.",
                        is_synthetic=True,
                    ),
                )
            )
        return tuple(items)

    def open_tool_calls(self, turn_id: str) -> tuple[ClaudePendingToolCall, ...]:
        """The tool_use calls of one turn still waiting for their result.

        A read-only snapshot of the same registry the history rebuild reads
        (`missing_history_tool_result_items`); nothing is added to or removed
        from it by this call. B2 uses it to pause a scheduled turn's stall
        clock while ANY call of that turn is unanswered
        (`.local-dev/claude-watchdog-liveness-tasks.md` §3 D2): a long tool
        call — Bash, pytest, an Agent wait — is legal silence, and the CLI's
        own timeout is the backstop, so stillness behind an open call may not
        be judged as a ghost's stillness.

        Filtered by `turn_id` on purpose. An entry only leaves `_tool_calls`
        when its `tool_result` arrives, so anything a killed turn or a
        compaction dropped result for stays registered forever; without the
        filter it would read as "still pending" and hold every LATER turn's
        verdicts hostage. Turn ids are minted with `secrets.token_urlsafe`
        and never reused, so the filter cannot alias two turns.

        Two accepted imprecisions, both deliberately conservative (they can
        only keep a turn alive longer, never kill it early):

        * an entry whose `tool_result` matched under a different item-id
          scope (`stable_tool_item_id` keys on the external session id, which
          a session can claim after the call was projected) is never paired —
          that turn then reaches its hard cap instead of its stall budget.
          B5/F1 makes that promise hold for the question shape too: the
          watchdog's cap exemption comes only from live interaction notices,
          so a stale `AskUserQuestion` entry is an EXECUTION like any other;
        * sidechain (subagent) frames are projected under the main turn's id,
          so a subagent's open call pauses the main turn's stall clock too —
          D2's accepted reading: the main turn IS waiting on that call.
        """

        return tuple(
            pending
            for pending in self._tool_calls.values()
            if pending.turn_id == turn_id
        )

    def tool_item(
        self,
        session: ClaudeSession,
        turn_id: str,
        block: ClaudeToolBlock,
    ) -> RuntimeTimelineItem:
        item_id = stable_tool_item_id(session, block.tool_use_id)
        order_seq = self.order_seq_for(item_id)

        if block.block_type == "tool_result":
            pending = self._tool_calls.pop(item_id, None)
            if pending is None:
                pending = self._tool_call_lookup.get(block.tool_use_id)
            call = pending.block if pending is not None else None
            item_turn_id = pending.turn_id if pending is not None else turn_id
            # The pending call knows the parent; an orphaned result frame can
            # still name its own parent (subagent tool results at silence).
            parent_item_id = _parent_tool_item_id(session, call)
            if parent_item_id is None and call is None:
                parent_item_id = _parent_tool_item_id(session, block)
            content = _tool_result_content(block, call, parent_item_id)
            status = "failed" if block.is_error else "done"
            if (
                call is not None
                and call.tool_name == "Agent"
                and is_async_agent_receipt(
                    block.tool_result_metadata, _result_text(block.tool_result)
                )
            ):
                # L2: the async launch receipt is metadata, not an outcome —
                # the card keeps running until task_updated/task_notification
                # closes it. Foreground (sync) calls still land done here.
                # The body is passed alongside the metadata because a
                # dispatch made inside a subagent's sidechain carries no
                # toolUseResult at all (2026-10-05 findings §A).
                status = "running"
        else:
            self._tool_calls[item_id] = ClaudePendingToolCall(
                block=block, turn_id=turn_id
            )
            item_turn_id = turn_id
            content = _tool_call_content(
                block,
                parent_item_id=_parent_tool_item_id(session, block),
            )
            status = "running"

        if isinstance(content, AgentCallToolContent):
            status, content = self._fold_agent_card(
                item_id,
                item_turn_id,
                status,
                content,
                session_id=session.session_id,
                tool_use_id=block.tool_use_id,
            )
            self._learn_agent_lineage(content, tool_use_id=block.tool_use_id)
            if status in AGENT_CARD_TERMINAL_STATUSES and has_running_agent_tasks(
                content
            ):
                # I1: a *started* task means the card is not finished. The
                # wire frames above can classify a launch as an outcome (the
                # sidechain receipt carries no metadata to tell them apart),
                # and `resolve_agent_card_status` keeps the first terminal
                # status — so unstick it here, on the item and on the card,
                # which also heals a status a wrong frame already pinned.
                #
                # Narrowed to `running` with the A3 batch (red team F-D): the
                # `async_launched` receipt is a launch report, not proof a
                # task exists, and vouching for it here would reopen a card
                # the stop's sweep just judged (the late aborted receipt is
                # exactly the frame a stop races). A spared call that really
                # starts re-opens the card through the task_started fold
                # clamp; running is the one entry that vouches for a task.
                status = "running"
                self._agent_cards[item_id].status = "running"

        return ToolTimelineItem(
            id=item_id,
            type="tool",
            status=status,  # type: ignore[arg-type]
            role="tool",
            turn_id=item_turn_id,
            content=content,
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=item_turn_id,
                native_item_id=block.tool_use_id,
                native_item_type=block.block_type,
                event=f"claude.{block.block_type}",
            ),
        ).to_platform_item(session_id=session.session_id, order_seq=order_seq)

    def _fold_agent_card(
        self,
        item_id: str,
        turn_id: str,
        status: str,
        content: AgentCallToolContent,
        *,
        session_id: str,
        tool_use_id: str,
    ) -> tuple[str, AgentCallToolContent]:
        """Remember one wire-projected Agent card and merge live task state.

        The card's two writers — the dispatch/receipt frames projected here
        and the task events folded by ``fold_agent_task_event`` — consume the
        same stream through different queues, so either can land first.
        Keeping this wire content and the event overlay apart makes every
        publication convergent, and the resolved status keeps the most final
        one (the terminal closure is idempotent).
        """

        card = self._agent_card(item_id)
        card.turn_id = turn_id
        card.content = content
        card.session_id = session_id
        card.tool_use_id = tool_use_id
        card.status = resolve_agent_card_status(card.status, status)
        return card.status, card.overlay.apply(content)

    def _agent_card(self, item_id: str) -> ClaudeAgentCallCard:
        """The card for one item id, minted with its launch stamp when new.

        The stamp is the wall clock at first sight — the dispatch frame — and
        is only ever set once, so a later fold or projection cannot move a
        card's launch time (F5).
        """

        card = self._agent_cards.get(item_id)
        if card is None:
            card = ClaudeAgentCallCard(launched_at=self._clock())
            self._agent_cards[item_id] = card
        return card

    def _learn_agent_lineage(
        self,
        content: AgentCallToolContent,
        *,
        tool_use_id: str,
    ) -> None:
        """Record the task id(s) an Agent call card is bound to (R4 join).

        An Agent card learns its task ids two ways: from the dispatch input
        (nothing) and from whoever writes the receipt — the launch receipt
        stamps ``content.agentId`` and the terminal overlay carries the
        ``agents`` map keyed by task id. Learning them here, beside the one
        place the card is minted, means the alias resolver has the same map the
        card itself is keyed by, whichever event landed first.
        """

        if content.agent_id:
            self._task_roots.setdefault(content.agent_id, set()).add(tool_use_id)
        for agent_id in content.agents:
            if isinstance(agent_id, str) and agent_id:
                self._task_roots.setdefault(agent_id, set()).add(tool_use_id)

    def _record_send_message(self, block: ClaudeToolBlock) -> None:
        """Learn one SendMessage resume alias without minting a visible card.

        The SendMessage tool_use frame is bookkeeping for the resume lineage,
        not a card of its own: its ``input.to`` names the task it resumes, and
        the tool_use id is the alias later frames key on. The frame itself is
        returned to the caller to project (visibility unchanged) — this only
        keeps a note of the join, and never publishes anything.
        """

        target = send_message_target(block.tool_name, block.tool_input)
        if target is not None:
            self._send_to_task[block.tool_use_id] = target

    def fold_agent_task_event(
        self,
        session: ClaudeSession,
        *,
        tool_use_id: str,
        overlay: ClaudeAgentTaskOverlay,
        status: str | None,
        base: AgentCallToolContent | None = None,
        turn_id: str | None = None,
    ) -> RuntimeTimelineItem:
        """Fold one task event into its Agent card and return the item to publish.

        The item keeps the card's stable id and order slot, so every fold
        upserts the one card the dispatch minted, and a projection that
        arrives later republishes the same base with this same overlay.

        ``base``/``turn_id`` are the import path's additions: its sync window
        is a suffix of the transcript, so the dispatch frame can sit outside
        it. A card already minted in-window always wins; otherwise the fold
        publishes the dispatch shape its caller rebuilt from the history
        lookup, so a dispatch-less window still opens the right card.

        A ``tool_use_id`` that is a SendMessage resume alias is redirected to
        the task's original dispatch card (R4, subagent-status-truth-tasks
        §3.3): the resumed task's lifecycle frames and notification arrive
        keyed on the SendMessage call, and folding them onto the dispatch card
        keeps one card per task. The id only moves when the lineage resolves
        to a single root; otherwise it is left exactly as it came
        (fail-closed), so an unlearned alias behaves as it does today.
        """

        tool_use_id = (
            resolve_resume_alias(
                tool_use_id,
                send_to_task=self._send_to_task,
                task_roots=self._task_roots,
            )
            or tool_use_id
        )
        item_id = stable_tool_item_id(session, tool_use_id)
        order_seq = self.order_seq_for(item_id)
        card = self._agent_card(item_id)
        if card.turn_id is None and turn_id is not None:
            card.turn_id = turn_id
        card.overlay.merge(overlay)
        card.session_id = session.session_id
        card.tool_use_id = tool_use_id
        card.status = resolve_agent_card_status(card.status, status)
        resolved_base = card.content or base or card.overlay.synthesized_call(
            tool_use_id
        )
        content = card.overlay.apply(resolved_base)
        if card.status in AGENT_CARD_TERMINAL_STATUSES and has_running_agent_tasks(
            content
        ):
            # I-G2 (ghost-card-findings §5.1, narrowed by red team F-D): a
            # *started* task outranks a terminal fold. The stop-path sweep
            # judges open cards at a stop, and a spared dispatch can start
            # after that judgment (the preserve edge); this clamp is what
            # turns the card back to running instead of leaving "card says
            # interrupted, agent runs". The `async_launched` receipt does not
            # trigger it — a receipt proves a launch was reported, not that a
            # task exists, and vouching for it would strand the S3 ghost.
            card.status = "running"
        return ToolTimelineItem(
            id=item_id,
            type="tool",
            status=card.status,  # type: ignore[arg-type]
            role="tool",
            turn_id=card.turn_id,
            content=content,
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=card.turn_id,
                native_item_id=tool_use_id,
                native_item_type="tool_use",
                event="claude.agent.task",
            ),
        ).to_platform_item(session_id=session.session_id, order_seq=order_seq)

    def close_open_agent_cards(
        self,
        session: ClaudeSession,
        *,
        oracle: Any | None = None,
        terminal_events: Mapping[str, Sequence[tuple[int | None, Any]]] | None = None,
        receipt_ages: Mapping[str, float] | None = None,
        attached_task_ids: frozenset[str] | None = None,
        live_task_ids: frozenset[str] | None = None,
        now_ms: int | None = None,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Judge every open Agent card of this session against engine evidence.

        Two closures live here and they are deliberately different.

        The dispatch-window ghost (I-G1, `ghost-card-findings.md` §5.1): a
        dispatch aborted inside its dispatch window has no task to close it —
        the CLI never created one — and the single frame that could (the
        aborted call's tool_result) is discarded by the stop's own release.
        Nothing else ever re-projects that card, so the stop is the last moment
        that can judge it; open cards with no live task fold to ``interrupted``.

        The evidence closure (R1/R2, `subagent-status-truth-tasks.md`): a task
        whose terminal notice the SDK message view never carried (R1), or one
        the host process was killed under so the CLI emitted no terminal event
        at all (R2), has no wire frame left to close it. When an ``oracle`` is
        supplied it is asked for the task's true state from its subagent
        transcript (terminal notice + silent file, a never-started launch, or a
        stale file) and its verdict is folded in, marked with the closure's
        provenance on ``content.metadata``.

        Open cards backed by a *started* task (a ``running`` entry, or an id the
        caller vouches for in ``live_task_ids``) are left alone (I-G2), and a
        card whose task starts after this ran is re-opened by the fold clamp in
        ``fold_agent_task_event`` — the sweep cannot lie about a live agent, and
        cannot strand a dead card. ``attached_task_ids`` names the tasks of a
        session whose process this connector is actively driving; those are
        exempt from the file-staleness closure (a long tool call writes nothing
        for a while) though a terminal notice still closes them.
        """

        events = terminal_events or {}
        ages = receipt_ages or {}
        attached = attached_task_ids or frozenset()
        live = live_task_ids or frozenset()
        items: list[RuntimeTimelineItem] = []
        for item_id, card in tuple(self._agent_cards.items()):
            if card.session_id != session.session_id:
                # One projector serves every session of the runtime.
                continue
            if card.status in AGENT_CARD_TERMINAL_STATUSES:
                continue
            base = card.content
            if base is None:
                # A card minted by task events before its dispatch frame:
                # with no agents it has nothing to say, and it cannot be
                # re-based without its tool_use id.
                if not card.overlay.agents or card.tool_use_id is None:
                    continue
                base = card.overlay.synthesized_call(card.tool_use_id)
            content = card.overlay.apply(base)
            if oracle is None:
                # Stop-path ghost judgment (I-G1): the caller is a stop, and
                # every open card it left without a started task folds to
                # interrupted. Unchanged from the original sweep — including
                # its `has_running_agent_tasks` exemption.
                if has_running_agent_tasks(content):
                    continue
                card.status = resolve_agent_card_status(card.status, "interrupted")
                closed_content = replace(
                    content,
                    metadata={
                        **dict(content.metadata),
                        "stoppedWithoutTask": True,
                    },
                )
                event = "claude.agent.stopped"
            else:
                # Engine-evidence judgment (R1/R2): the caller is a process
                # exit, a restart, or a periodic pass, where a false close is
                # worse than a slow one. Every *open* task (a `running` or
                # `async_launched` entry) must be judged before the card may be
                # closed; a task the transport still lists in `live`, or one
                # the oracle cannot justify closing, keeps the whole card open
                # (red team F1/F6) — a running sibling must never be hidden by
                # the closure of another task on the same card.
                #
                # Known boundary (red team F7): no caller passes
                # `terminal_events` today, so this path only ever closes on
                # file evidence or a transcript notice already folded by the
                # live fold. A terminal notice that reached neither the live
                # frame nor the history rebuild is out of this sweep's reach
                # by design (it is not a file fact); the history post-pass is
                # the surface for those.
                #
                # Known boundary (red team F9): this runs without the
                # execution lock, so a live fold can land concurrently. Both
                # writers are idempotent upserts — `resolve_agent_card_status`
                # keeps a terminal status sticky — and the loser simply
                # republishes the same state, so the race is self-healing.
                open_task_ids = open_agent_task_ids(content.agents)
                if not open_task_ids:
                    # Every entry is status-less or unknown, yet the card is not
                    # terminal: nothing vouches for liveness, so fall back to
                    # judging the tasks nothing else would settle rather than
                    # stranding the card forever (N3).
                    open_task_ids = _fallback_task_ids(content.agents)
                if not open_task_ids or open_task_ids & live:
                    continue
                verdicts = self._card_evidence(
                    oracle,
                    card=card,
                    task_ids=open_task_ids,
                    session=session,
                    events=events,
                    ages=ages,
                    attached=attached,
                    now_ms=now_ms,
                )
                if len(verdicts) != len(open_task_ids):
                    continue
                _, best = max(
                    verdicts.items(),
                    key=lambda item: (
                        _closure_rank(
                            (
                                item[1].closure_status,
                                item[1].closed_by,
                                item[1].end_time_ms,
                                None,
                            )
                        )
                    ),
                )
                card.status = resolve_agent_card_status(
                    card.status, best.closure_status
                )
                if best.end_time_ms is not None:
                    card.overlay.end_time = best.end_time_ms
                closed_content = self._apply_evidence_closure(
                    content=content,
                    card=card,
                    agents=self._evidence_agents(content, verdicts),
                    closed_by=best.closed_by,
                    end_time_ms=best.end_time_ms,
                )
                event = "claude.agent.closed"
            items.append(
                ToolTimelineItem(
                    id=item_id,
                    type="tool",
                    status=card.status,  # type: ignore[arg-type]
                    role="tool",
                    turn_id=card.turn_id,
                    # The marker keeps the judgment observable in the
                    # timeline (free JSON), next to the terminal status the
                    # client renders from the status field alone.
                    content=closed_content,
                    source=TimelineSource(
                        runtime="claude",
                        external_session_id=session.external_session_id,
                        turn_id=card.turn_id,
                        native_item_id=card.tool_use_id,
                        native_item_type="tool_use",
                        event=event,
                    ),
                ).to_platform_item(
                    session_id=session.session_id,
                    order_seq=self.order_seq_for(item_id),
                )
            )
        return tuple(items)

    def _card_evidence(
        self,
        oracle: Any | None,
        *,
        card: ClaudeAgentCallCard,
        task_ids: frozenset[str],
        session: ClaudeSession,
        events: Mapping[str, Sequence[tuple[int | None, Any]]],
        ages: Mapping[str, float],
        attached: frozenset[str],
        now_ms: int | None,
    ) -> dict[str, Any]:
        """The per-task evidence verdicts for one card.

        Returns one entry per task the oracle could judge; a task it declined
        (a fresh file, an attached process, a launch inside the grace) is
        simply absent, and the caller must then leave the whole card open.
        Evidence is never guessed.

        The receipt age comes from an explicit ``ages`` entry when the caller
        derived one (the history path reads it from the raw transcript); on the
        live path there is none, so the card's own launch stamp supplies it
        (F5) — without that, a never-started task could never be judged.
        """

        verdicts: dict[str, Any] = {}
        if oracle is None:
            return verdicts
        # "Now" for the launch age comes from the explicit override, else the
        # oracle's own clock — the same time domain its file probe judges
        # mtimes in — and only then the projector's mint clock. Using the mint
        # clock here would freeze the age whenever a caller pins it.
        if now_ms is not None:
            now_seconds = now_ms / 1000.0
        else:
            oracle_clock = getattr(oracle, "clock", None)
            now_seconds = (
                oracle_clock() if callable(oracle_clock) else self._clock()
            )
        for task_id in sorted(task_ids):
            age = ages.get(task_id)
            if age is None and card.launched_at is not None:
                age = max(now_seconds - card.launched_at, 0.0)
            verdict = oracle.evidence(
                task_id=task_id,
                external_session_id=session.external_session_id,
                cwd=session.cwd,
                terminal_events=events.get(task_id, ()),
                receipt_age_seconds=age,
                attached_live=task_id in attached,
                now_ms=now_ms,
            )
            if verdict is not None:
                verdicts[task_id] = verdict
        return verdicts

    def _evidence_agents(
        self,
        content: AgentCallToolContent,
        verdicts: Mapping[str, Any],
    ) -> dict[str, Any]:
        """Per-task entries for the tasks an evidence closure judged.

        The agents map is what the panel reads for per-task state, so a judged
        task must not keep its old ``running``/``async_launched`` entry. Only
        the judged tasks are rewritten; every other entry — a sibling that was
        already terminal, say — rides through untouched (red team F6).
        """

        entries: dict[str, Any] = {}
        for task_id, verdict in verdicts.items():
            existing = content.agents.get(task_id)
            entry = dict(existing) if isinstance(existing, Mapping) else {}
            status = verdict.agent_status or verdict.closure_status
            if status is not None:
                entry["status"] = status
            entries[task_id] = entry
        return entries

    def _apply_evidence_closure(
        self,
        *,
        content: AgentCallToolContent,
        card: ClaudeAgentCallCard,
        agents: Mapping[str, Any],
        closed_by: str,
        end_time_ms: int | None,
    ) -> AgentCallToolContent:
        """Publish the evidence verdict onto the card's content.

        The agents map carries the terminal status per task, an ``endTime``
        rides the metadata (the panel's final-output timestamp), and the
        ``closedByEvidence`` provenance is stamped beside ``stoppedWithoutTask``
        with the same semantics — free JSON the client may surface.
        """

        merged_agents: dict[str, Any] = {
            agent_id: dict(entry) if isinstance(entry, Mapping) else entry
            for agent_id, entry in content.agents.items()
        }
        for agent_id, entry in agents.items():
            if not isinstance(entry, Mapping):
                continue
            existing = merged_agents.get(agent_id)
            merged_agents[agent_id] = (
                {**existing, **entry} if isinstance(existing, Mapping) else dict(entry)
            )
        metadata = {**dict(content.metadata), "closedByEvidence": closed_by}
        if end_time_ms is not None:
            metadata["endTime"] = end_time_ms
        updated = replace(content, agents=merged_agents, metadata=metadata)
        card.overlay.agents = {
            agent_id: (
                dict(entry) if isinstance(entry, Mapping) else entry
            )
            for agent_id, entry in merged_agents.items()
        }
        return updated


def _fallback_task_ids(agents: Mapping[str, Any]) -> frozenset[str]:
    """Named tasks with no terminal status of their own (N3 fallback).

    A card that is not terminal but has no open entry is judged on these: the
    status-less and unknown-status entries, which nothing else would ever
    settle. An entry that already names a terminal outcome is left alone — it
    is the card's own record of the task's end, and re-judging it from a file
    could only walk a finished task backwards.
    """

    return frozenset(
        agent_id
        for agent_id, entry in agents.items()
        if isinstance(agent_id, str)
        and agent_id
        and agent_task_terminal_status(
            _string(entry.get("status")) if isinstance(entry, Mapping) else None
        )
        is None
    )


def _closure_rank(candidate: tuple[str, str, int | None, str | None]) -> tuple[int, int]:
    return closure_rank(candidate[0])


def synthesized_agent_call_content(
    session: ClaudeSession,
    call: ClaudePendingToolCall,
) -> AgentCallToolContent:
    """Rebuild the dispatch plus recoverable receipt from the full lookup.

    The import sync window is a suffix of the transcript, so a background
    task's notification can arrive in a later pass than the dispatch and its
    launch receipt. The lookup keeps the dispatch's block, turn and matching
    result block; rebuilding both through the same content constructors makes
    an incremental terminal fold stable with a full-window projection.
    """

    block = call.block
    tool_input = block.tool_input if isinstance(block.tool_input, Mapping) else {}
    content = claude_agent_call_content(
        tool_use_id=block.tool_use_id,
        tool_input=tool_input,
        parent_item_id=_parent_tool_item_id(session, block),
    )
    receipt = call.result_block
    if receipt is None:
        return content

    output = _result_text(receipt.tool_result)
    details = dict(receipt.tool_result_metadata or {})

    result_metadata: dict[str, Any] = {
        "toolUseId": receipt.tool_use_id,
        "toolName": block.tool_name,
        "input": block.tool_input,
        "text": output,
        "outputText": output,
        "outputPreview": _preview_text(output),
        "outputLength": len(output),
        "isError": receipt.is_error,
        **({"synthetic": True, "missingResult": True} if receipt.is_synthetic else {}),
        **({"error": output} if receipt.is_error else {}),
    }
    return complete_claude_agent_call_content(
        content,
        output=output,
        result=receipt.tool_result,
        is_error=receipt.is_error,
        result_details=details,
        metadata=result_metadata,
    )


def message_role(message: Any) -> str | None:
    raw_role = _extract(message, "role")
    if isinstance(raw_role, str) and raw_role:
        return raw_role
    nested = _extract(message, "message")
    if isinstance(nested, Mapping):
        raw_nested_role = nested.get("role")
        if isinstance(raw_nested_role, str) and raw_nested_role:
            return raw_nested_role
    raw_type = _extract(message, "type")
    if isinstance(raw_type, str) and raw_type:
        return raw_type
    return {
        "UserMessage": "user",
        "AssistantMessage": "assistant",
        "SystemMessage": "system",
    }.get(message.__class__.__name__)


def message_text(message: Any) -> str | None:
    text = _content_text(_message_content(message))
    if text:
        return text
    result = _extract(message, "result")
    return result if isinstance(result, str) and result else None


# Per-API-call token usage, the shape clients read off an assistant message's
# `content.usage`. The API's usage dicts are snake_case; the published shape is
# camelCase with all four keys always present — a missing count is 0, never
# null (the server's `exclude_none` persistence would drop a null and make a
# replayed history item differ from the live one). `ResultMessage.usage` is
# turn-cumulative and is deliberately never read as a message's usage; only
# per-call values (live frames, stream events, transcript messages) are.
_USAGE_FIELDS: tuple[tuple[str, str], ...] = (
    ("input_tokens", "inputTokens"),
    ("output_tokens", "outputTokens"),
    ("cache_read_input_tokens", "cacheReadTokens"),
    ("cache_creation_input_tokens", "cacheCreationTokens"),
)


def usage_counts(source: Any) -> dict[str, int] | None:
    """Normalize one raw API usage mapping into the wire's four int keys.

    Returns None when there is no usage mapping at all, when it holds none of
    the token counts, or when every counter it holds is zero — an object that
    measured nothing is not a usage, whether it omitted the counts or filled
    them with zeros (publishing four zeros would read as "the context is
    empty" on clients, and an all-zero seed is exactly the shape a
    `message_start` emits before a call has measured anything). A mapping with
    at least one real count still yields all four keys, gaps as 0.
    """

    if not isinstance(source, Mapping):
        return None
    if not any(
        _extract(source, snake, wire) is not None for snake, wire in _USAGE_FIELDS
    ):
        return None
    counts = {wire: _usage_int(source, snake, wire) for snake, wire in _USAGE_FIELDS}
    if not any(counts.values()):
        return None
    return counts


def enrich_usage(
    usage: Mapping[str, int] | None,
    *,
    model: str | None = None,
    probe: ClaudeContextProbe | None = None,
) -> dict[str, Any] | None:
    """The published `content.usage` block for one per-call measurement.

    `usage_counts` stays a pure normalizer; this is the single enrichment step
    every stamping site goes through, adding what measured the call:

    * `model` — the engine's own report wins (it names what actually ran, which
      a gateway makes differ from the catalog's id); the frame's own
      `message.model` is the fallback.
    * `contextWindow` — the engine's reported window, or the id rules
      (`claude_context_window`) while no probe has landed. A model neither
      source can size omits the key; clients then hide their indicator instead
      of guessing.

    Never null: unknown keys are omitted, exactly like the counters' contract.
    """

    if not usage:
        return None
    probed_model = probe.model if probe is not None else None
    resolved_model = probed_model or model
    window = probe.window if probe is not None else None
    if window is None:
        window = claude_context_window(probed_model, model)
    enriched: dict[str, Any] = dict(usage)
    if resolved_model:
        enriched["model"] = resolved_model
    if window is not None:
        enriched["contextWindow"] = int(window)
    return enriched


def message_usage(message: Any) -> dict[str, int] | None:
    """The per-call token usage one assistant frame contributes to its item.

    Live SDK frames carry it top-level (``AssistantMessage.usage``); the
    historical ``SessionMessage`` nests the raw API message, so its usage is
    read from ``message.usage`` there. Subagent sidechain frames
    (``parent_tool_use_id`` set) are not the main conversation and get None —
    the clients only measure the main chain's context. None means "omit the
    key", not "zero".
    """

    parent = _extract(message, "parent_tool_use_id", "parentToolUseId")
    if parent is not None:
        return None
    raw = _extract(message, "usage")
    if not isinstance(raw, Mapping):
        nested = _extract(message, "message")
        raw = _extract(nested, "usage") if isinstance(nested, Mapping) else None
    return usage_counts(raw)


def _usage_int(source: Mapping[str, Any], *names: str) -> int:
    value = _extract(source, *names)
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


def is_local_command_chrome(text: str | None) -> bool:
    """Match the CLI's own chrome around a slash command typed into the CLI.

    Four shapes, all replayed as ordinary user messages on the SDK wire (real
    session 84275e9e, 2026-10-02): the caveat wrapper the CLI writes before its
    command echo, the `<command-name>` echo of the command line itself, and the
    `<local-command-stdout>` / `<local-command-stderr>` echoes of output the CLI
    keeps for itself. None is conversation content; projecting any of them
    publishes phantom user bubbles for a command the user typed into the CLI, not
    into the app.
    """

    if not text:
        return False
    return text.strip().startswith(CLAUDE_LOCAL_COMMAND_CHROME_PREFIXES)


def is_compact_summary_text(text: str | None) -> bool:
    """Match Claude's compaction summary by its fixed CLI opening sentence."""

    return bool(text) and text.strip().startswith(CLAUDE_COMPACT_SUMMARY_PREFIX)


def is_task_notification_message(message: Any) -> bool:
    """Whether a message is the CLI's persisted background-task notice.

    Two channels, same as the bubble suppression below: the SDK keeps
    ``origin.kind`` on some paths and strips it on others (the top-level
    transcript read drops it), so the text's own wrapper is the fallback
    that works on every surface. The terminal fold and the "no bubble" skip
    must agree on what counts as a notice, so both read this one answer.
    """

    origin = _extract(message, "origin")
    if _extract(origin, "kind") == "task-notification":
        return True
    return is_task_notification_text(message_text(message))


def is_synthetic_control_message(message: Any) -> bool:
    role = message_role(message)
    text = message_text(message)
    if is_task_notification_message(message):
        return True
    if message.__class__.__name__ == "HookEventMessage":
        # The CLI's own hook lifecycle narration (SessionStart:compact,
        # PreToolUse, …). It rides the same stream as conversation messages but
        # is chrome: no reply is owed for it, and in the ghost incident it
        # arrived right after the command turn had already settled, minting an
        # execution from silence that hung forever.
        return True
    if text is None:
        return False
    normalized = text.strip()
    if role == "user" and normalized in CLAUDE_INTERRUPTED_REQUEST_MARKERS:
        return True
    if role == "user" and is_compact_summary_text(normalized):
        return True
    if role == "user" and is_local_command_chrome(normalized):
        return True
    if role == "assistant" and is_context_report_text(normalized):
        # The connector's own `/context` calibration is a local command whose
        # assistant frame is CLI output, not an answer: if a probe's frames
        # outlive the probe (timeout, transport drop), the reader must buffer
        # them as chrome rather than mint a scheduled turn — and a turn that
        # inherits one must not publish it as a bubble.
        return True
    return (
        role == "assistant"
        and normalized == CLAUDE_NO_RESPONSE_MARKER
        and message_model(message) == "<synthetic>"
    )


def message_model(message: Any) -> str | None:
    nested = _extract(message, "message")
    if isinstance(nested, Mapping):
        value = _extract(nested, "model")
        if isinstance(value, str) and value:
            return value
    value = _extract(message, "model")
    return value if isinstance(value, str) and value else None


def receipt_agent_id(
    result_metadata: Mapping[str, Any] | None,
    output: str | None,
) -> str | None:
    """The background task id an async Agent launch receipt names.

    The SDK's historical ``SessionMessage`` drops the transcript's
    ``toolUseResult``, so the receipt body (``agentId: <id>``) is the only
    identity channel there; metadata covers raw-transcript readers.
    """

    details = result_metadata if isinstance(result_metadata, Mapping) else {}
    for key in ("agentId", "agent_id"):
        value = details.get(key)
        if isinstance(value, str) and value:
            return value
    if not output or "agentId:" not in output:
        return None
    match = re.search(r"(?m)^\s*agentId:\s*([A-Za-z0-9_-]+)", output)
    return match.group(1) if match is not None else None


def message_tool_blocks(message: Any) -> tuple[ClaudeToolBlock, ...]:
    content = _message_content(message)
    if not isinstance(content, list | tuple):
        return ()
    parent_tool_use_id = _string(
        _extract(message, "parent_tool_use_id", "parentToolUseId")
    )
    result_metadata = _mapping(_extract(message, "tool_use_result", "toolUseResult"))
    blocks: list[ClaudeToolBlock] = []
    for block in content:
        block_type = _block_type(block)
        if block_type == "tool_use":
            blocks.append(
                ClaudeToolBlock(
                    block_type="tool_use",
                    tool_use_id=_string(
                        _extract(block, "id", "tool_use_id", "toolUseId")
                    )
                    or _stable_id("tool", repr(block)),
                    tool_name=_string(_extract(block, "name", "tool_name", "toolName"))
                    or "tool",
                    tool_input=_extract(block, "input", "tool_input", "toolInput")
                    or {},
                    parent_tool_use_id=parent_tool_use_id,
                )
            )
        elif block_type == "tool_result":
            result = _extract(block, "content", "result", "toolResult")
            output = _content_text(result)
            metadata = result_metadata
            if is_async_agent_receipt(metadata, output):
                # The SDK's historical reader drops the transcript's
                # toolUseResult, so a launch receipt there keeps only its body.
                # Restore the identity/status the raw transcript carried so
                # every downstream consumer sees one receipt shape.
                merged = dict(metadata or {})
                agent_id = receipt_agent_id(metadata, output)
                if agent_id is not None and not (
                    merged.get("agentId") or merged.get("agent_id")
                ):
                    merged["agentId"] = agent_id
                merged.setdefault("status", "async_launched")
                metadata = merged
            blocks.append(
                ClaudeToolBlock(
                    block_type="tool_result",
                    tool_use_id=_string(_extract(block, "tool_use_id", "toolUseId"))
                    or _stable_id("tool", repr(block)),
                    tool_result=result,
                    is_error=_extract(block, "is_error", "isError") is True,
                    parent_tool_use_id=parent_tool_use_id,
                    tool_result_metadata=metadata,
                )
            )
    return tuple(blocks)


def message_system_blocks(message: Any) -> tuple[ClaudeSystemBlock, ...]:
    content = _message_content(message)
    if not isinstance(content, list | tuple):
        return ()
    blocks: list[ClaudeSystemBlock] = []
    for index, block in enumerate(content):
        block_type = _block_type(block)
        if block_type not in {
            "thinking",
            "reasoning",
            "redacted_thinking",
            "system",
            "error",
        }:
            continue
        blocks.append(
            ClaudeSystemBlock(
                block_type=block_type,
                block_index=index,
                text=_system_block_text(block),
                metadata=_system_block_metadata(block),
            )
        )
    return tuple(blocks)


def message_session_id(message: Any) -> str | None:
    value = _extract(message, "session_id", "sessionId")
    if isinstance(value, str) and value:
        return value
    data = _extract(message, "data")
    if not isinstance(data, Mapping):
        return None
    nested = _extract(data, "session_id", "sessionId")
    return nested if isinstance(nested, str) and nested else None


def message_id(message: Any) -> str | None:
    nested = _extract(message, "message")
    if isinstance(nested, Mapping):
        value = _extract(nested, "id")
        if isinstance(value, str) and value:
            return value
    value = _extract(message, "message_id", "messageId", "id", "uuid")
    if isinstance(value, str) and value:
        return value
    # `SystemMessage` carries only `subtype` plus the untouched payload, so a
    # compaction boundary's uuid lives in `.data` and nowhere else.
    data = _extract(message, "data")
    if not isinstance(data, Mapping):
        return None
    nested = _extract(data, "message_id", "messageId", "id", "uuid")
    return nested if isinstance(nested, str) and nested else None


def is_result_message(message: Any) -> bool:
    if message.__class__.__name__ == "ResultMessage":
        return True
    raw_type = _extract(message, "type")
    subtype = _extract(message, "subtype")
    return raw_type == "result" or (isinstance(subtype, str) and "result" in subtype)


def message_is_error(message: Any) -> bool:
    return _extract(message, "is_error", "isError") is True


def message_error_text(message: Any) -> str | None:
    errors = _extract(message, "errors")
    if isinstance(errors, list) and errors:
        return "; ".join(str(error) for error in errors)
    value = _extract(message, "error", "terminal_reason", "terminalReason")
    return value if isinstance(value, str) and value else None


def _content_text(content: Any) -> str | None:
    if isinstance(content, str):
        return content
    if not isinstance(content, list | tuple):
        return None
    parts: list[str] = []
    for block in content:
        text = _extract(block, "text")
        if isinstance(text, str) and text:
            parts.append(text)
    return "\n".join(parts) if parts else None


def _message_content(message: Any) -> Any:
    nested = _extract(message, "message")
    if isinstance(nested, Mapping):
        return nested.get("content")
    return _extract(message, "content")


def _block_type(block: Any) -> str | None:
    raw_type = _extract(block, "type")
    if isinstance(raw_type, str) and raw_type:
        return raw_type
    name = block.__class__.__name__.lower()
    if "tooluse" in name or "tool_use" in name:
        return "tool_use"
    if "toolresult" in name or "tool_result" in name:
        return "tool_result"
    if "thinking" in name or "reasoning" in name:
        return "thinking"
    if "error" in name:
        return "error"
    if "system" in name:
        return "system"
    return None


def _reasoning_block_is_displayable(block: ClaudeSystemBlock) -> bool:
    """Whether a reasoning block would render with visible text.

    Mirrors the client's caliber (`TimelineText.reasoning` in
    `TimelineEntryPresentation.swift`): the `summaries` win when the list has
    any non-empty text, otherwise the first non-empty of rawText/text/summary;
    the winner is trimmed, and an empty result draws only the bare marker.
    Read here too so the connector never publishes a row the client would
    have nothing to show for.
    """

    return bool(_reasoning_display_text(block).strip())


def _reasoning_display_text(block: ClaudeSystemBlock) -> str:
    metadata = block.metadata or {}
    summaries = _summary_texts(metadata.get("summaries"))
    if summaries:
        return "\n\n".join(summaries)
    raw_text = metadata.get("rawText")
    if isinstance(raw_text, str) and raw_text:
        return raw_text
    if block.text:
        return block.text
    summary = metadata.get("summary")
    return summary if isinstance(summary, str) else ""


def _summary_texts(value: Any) -> list[str]:
    """The client's summary entries: `{"text": ...}` mappings with real text."""

    if not isinstance(value, list | tuple):
        return []
    texts: list[str] = []
    for entry in value:
        text = entry.get("text") if isinstance(entry, Mapping) else None
        if isinstance(text, str) and text:
            texts.append(text)
    return texts


def _system_content(
    block: ClaudeSystemBlock,
    usage: Mapping[str, Any] | None = None,
) -> Any:
    metadata = {
        "blockType": block.block_type,
        **dict(block.metadata or {}),
        **({"usage": dict(usage)} if usage else {}),
    }
    if block.block_type in REASONING_BLOCK_TYPES:
        return ReasoningSystemContent(
            text=block.text,
            metadata=metadata,
        )
    if block.block_type == "system":
        return GenericSystemContent(
            text=block.text,
            metadata=metadata,
        )
    if block.block_type == "error":
        return ErrorSystemContent(
            text=block.text,
            metadata=metadata,
        )
    return UnknownSystemContent(
        text=block.text,
        metadata=metadata,
    )


def _system_block_text(block: Any) -> str | None:
    value = _extract(block, "thinking", "text", "content", "message")
    if isinstance(value, str) and value:
        return value
    if isinstance(value, list | tuple):
        return _content_text(value)
    return None


def _system_block_metadata(block: Any) -> Mapping[str, Any]:
    if not isinstance(block, Mapping):
        return {}
    return {
        key: value
        for key, value in block.items()
        if key not in {"type", "thinking", "text", "content", "message"}
    }


def _tool_call_content(
    block: ClaudeToolBlock,
    parent_item_id: str | None = None,
) -> ToolTimelineContent:
    tool_name = block.tool_name or "tool"
    tool_input = block.tool_input if isinstance(block.tool_input, Mapping) else {}
    common = {
        "toolUseId": block.tool_use_id,
        "toolName": tool_name,
        "input": block.tool_input,
        # The call's per-call usage, when the frame carried one. It rides the
        # metadata `complete_tool_content` merges forward, so the completed
        # row keeps it too. The Agent card is deliberately excluded: its
        # `usage` field already carries the subagent's own totals.
        **({"usage": dict(block.usage)} if block.usage else {}),
        # L2: a frame parented to a tool call belongs to that call's card.
        # AgentCallToolContent already publishes this convention for nested
        # Agent calls; ordinary tool rows minted from subagent frames now carry
        # it too so clients can fold them into the Agent card. Main-agent rows
        # (no parent) are untouched.
        **({"parentItemId": parent_item_id} if parent_item_id is not None else {}),
    }
    if tool_name == "Bash":
        command = _string(tool_input.get("command") or tool_input.get("cmd")) or ""
        return CommandToolContent(
            command=command,
            input=dict(tool_input),
            metadata={
                **common,
                "description": _string(tool_input.get("description")) or command,
                "cwd": _string(tool_input.get("cwd")),
                **(
                    {"runInBackground": tool_input.get("run_in_background")}
                    if isinstance(tool_input.get("run_in_background"), bool)
                    else {}
                ),
            },
        )
    if tool_name in {"Edit", "Write", "MultiEdit", "NotebookEdit"}:
        return FileChangeToolContent(
            input=dict(tool_input),
            metadata={
                **common,
                "changes": _file_changes(tool_name, tool_input),
            },
        )
    if tool_name in {"WebFetch", "WebSearch"}:
        return WebSearchToolContent(
            title=tool_name,
            input=dict(tool_input),
            metadata={
                **common,
                "query": _string(tool_input.get("query")),
                "url": _string(tool_input.get("url")),
                "action": dict(tool_input),
            },
        )
    if is_interactive_tool_name(tool_name):
        return InputRequestToolContent(
            title=tool_name,
            input=dict(tool_input),
            metadata={
                **common,
                "questions": tool_input.get("questions", []),
            },
        )
    if tool_name == "Agent":
        return claude_agent_call_content(
            tool_use_id=block.tool_use_id,
            tool_input=tool_input,
            parent_item_id=parent_item_id,
        )
    mcp_parts = _mcp_parts(tool_name)
    if mcp_parts is not None:
        server, tool = mcp_parts
        return McpToolContent(
            title=tool,
            input=dict(tool_input),
            metadata={
                **common,
                "server": server,
                "tool": tool,
                "arguments": dict(tool_input),
            },
        )
    return ToolCallContent(
        title=tool_name,
        input=block.tool_input,
        metadata={
            **common,
            "name": tool_name,
            "tool": tool_name,
            "arguments": tool_input
            if isinstance(tool_input, Mapping)
            else block.tool_input,
        },
    )


def _tool_result_content(
    block: ClaudeToolBlock,
    call: ClaudeToolBlock | None,
    parent_item_id: str | None = None,
) -> ToolTimelineContent:
    output = _result_text(block.tool_result)
    result_metadata: dict[str, Any] = {
        "toolUseId": block.tool_use_id,
        "toolName": call.tool_name if call else None,
        "input": call.tool_input if call else None,
        "text": output,
        "outputText": output,
        "outputPreview": _preview_text(output),
        "outputLength": len(output),
        "isError": block.is_error,
        **({"synthetic": True, "missingResult": True} if block.is_synthetic else {}),
        **({"error": output} if block.is_error else {}),
    }
    call_content = (
        _tool_call_content(call, parent_item_id=parent_item_id)
        if call is not None
        else None
    )
    if call_content is not None:
        if isinstance(call_content, AgentCallToolContent):
            details = dict(block.tool_result_metadata or {})
            return complete_claude_agent_call_content(
                call_content,
                output=output,
                result=block.tool_result,
                is_error=block.is_error,
                result_details=details,
                metadata=result_metadata,
            )
        return complete_tool_content(
            call_content,
            output=output,
            result=block.tool_result,
            is_error=block.is_error,
            exit_code=_tool_result_exit_code(block.tool_result),
            metadata=result_metadata,
        )
    return ToolResultContent(
        output=output,
        exit_code=_tool_result_exit_code(block.tool_result),
        metadata={
            **result_metadata,
            "result": block.tool_result,
            "orphan": True,
            # Same L2 convention as the call rows: a subagent's orphaned result
            # still names the card it belongs to.
            **({"parentItemId": parent_item_id} if parent_item_id is not None else {}),
        },
    )


def _tool_result_exit_code(result: Any) -> int | None:
    if not isinstance(result, Mapping):
        return None
    value = result.get("exit_code", result.get("exitCode"))
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _parent_tool_item_id(
    session: ClaudeSession,
    block: ClaudeToolBlock | None,
) -> str | None:
    if block is None or block.parent_tool_use_id is None:
        return None
    return stable_tool_item_id(session, block.parent_tool_use_id)


def _file_changes(
    tool_name: str,
    tool_input: Mapping[str, Any],
) -> tuple[Mapping[str, Any], ...]:
    path = _string(
        tool_input.get("file_path")
        or tool_input.get("notebook_path")
        or tool_input.get("path")
    )
    action = "add" if tool_name == "Write" else "update"
    diff = _file_diff(tool_name, path or "", tool_input)
    return (
        {
            "path": path,
            "action": action,
            "kind": {"type": action},
            "toolName": tool_name,
            **({"diff": diff} if diff else {}),
        },
    )


def _file_diff(
    tool_name: str,
    path: str,
    tool_input: Mapping[str, Any],
) -> str | None:
    if tool_name == "Write":
        return _string(tool_input.get("content"))
    if tool_name == "Edit":
        return _edit_diff(
            path,
            _string(tool_input.get("old_string")) or "",
            _string(tool_input.get("new_string")) or "",
        )
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits")
        if not isinstance(edits, list):
            return None
        parts: list[str] = []
        for edit in edits:
            if not isinstance(edit, Mapping):
                continue
            parts.append(
                _edit_diff(
                    path,
                    _string(edit.get("old_string")) or "",
                    _string(edit.get("new_string")) or "",
                    include_header=not parts,
                )
            )
        return "\n".join(part for part in parts if part) or None
    if tool_name == "NotebookEdit":
        return _edit_diff(path, "", _result_text(tool_input.get("new_source")))
    return None


def _edit_diff(
    path: str,
    old: str,
    new: str,
    *,
    include_header: bool = True,
) -> str:
    lines: list[str] = []
    if include_header:
        lines.extend([f"--- {path}", f"+++ {path}"])
    lines.append("@@")
    if old:
        lines.extend(f"-{line}" for line in old.splitlines())
    if new:
        lines.extend(f"+{line}" for line in new.splitlines())
    return "\n".join(lines)


def _result_text(result: Any) -> str:
    if isinstance(result, str):
        return result
    text = _content_text(result)
    if text:
        return text
    if result is None:
        return ""
    return json.dumps(result, ensure_ascii=False, sort_keys=True, default=str)


def _preview_text(value: str, limit: int = 4000) -> str:
    return value[-limit:]


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _mcp_parts(tool_name: str | None) -> tuple[str, str] | None:
    if not tool_name or not tool_name.startswith("mcp__"):
        return None
    parts = tool_name.split("__", 2)
    if len(parts) != 3 or not parts[1] or not parts[2]:
        return None
    return parts[1], parts[2]


def is_task_event_tool_name(tool_name: str | None) -> bool:
    return bool(
        tool_name
        and tool_name != "Task"
        and tool_name.startswith("Task")
        and len(tool_name) > 4
        and tool_name[4].isupper()
    )


def is_hidden_tool_name(tool_name: str | None) -> bool:
    """Bookkeeping tools that must never surface as timeline tool cards.

    Task-lifecycle plumbing (Cron*/Task*) and the agent session-title tool
    are connector/CLI bookkeeping, not user-visible work. Filtering by name
    at extraction time also drops the matching tool_result (via the id set),
    in both the live projector and the history rebuild, which shares this
    method.
    """

    return is_task_event_tool_name(tool_name) or is_title_tool_name(tool_name)


def is_interactive_tool_name(tool_name: str | None) -> bool:
    """The tool whose `can_use_tool` call is a QUESTION, not an approval.

    `AskUserQuestion` is the one tool the interaction controller routes to
    `request_user_input` rather than `request_tool_approval`
    (turns/interactions.py) and the one whose tool_use block projects as an
    input-request card here; both classification sites read this predicate so
    the name has a single home. `domain/input_requests.py` builds the
    user-visible notice under the same name but keeps its own literal — the
    domain layer must not import the timeline layer.

    The scheduled-turn watchdog deliberately does NOT read it (B5/F1,
    `.local-dev/watchdog-liveness-b4-report.md` §1): a bare open tool_use
    entry proves nothing about a live question, and classifying one by name
    turned OFF the hard cap while PAUSING the stall clock — a stale entry
    (lost result / scope-drift pop-miss) left the turn uncollectable at any
    age. The watchdog's INTERACTION exemption therefore comes only from live
    interaction notices
    (`ClaudeInteractionController.pending_for_session`). The name here serves
    routing and the card shape, never deadline classification.
    """

    return tool_name == "AskUserQuestion"


def _extract(value: Any, *names: str) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
        return None
    for name in names:
        candidate = getattr(value, name, None)
        if candidate is not None:
            return candidate
    return None


def _stable_id(*parts: Any) -> str:
    return "claude_" + _short(*parts)


def stable_message_item_id(
    session: ClaudeSession,
    native_message_id: str,
) -> str:
    scope = session.external_session_id or session.session_id
    return "claude_msg_" + _short("message", scope, native_message_id)


def stable_tool_item_id(session: ClaudeSession, tool_use_id: str) -> str:
    scope = session.external_session_id or session.session_id
    return "claude_tool_" + _short("tool", scope, tool_use_id)


def stable_system_item_id(
    *,
    session: ClaudeSession,
    turn_id: str,
    native_message_id: str | None,
    block: ClaudeSystemBlock,
) -> str:
    scope = session.external_session_id or session.session_id
    native_scope = native_message_id or turn_id
    return "claude_system_" + _short(
        "system",
        scope,
        native_scope,
        block.block_index,
        block.block_type,
    )


def _short(*parts: Any) -> str:
    payload = json.dumps(
        parts,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]
