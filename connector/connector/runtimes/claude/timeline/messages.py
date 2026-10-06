from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
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
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import is_task_notification_text
from connector.runtimes.claude.sdk.title_tool import is_title_tool_name
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
    ClaudeAgentCallCard,
    ClaudeAgentTaskOverlay,
    claude_agent_call_content,
    complete_claude_agent_call_content,
    has_live_agent_tasks,
    is_async_agent_receipt,
    resolve_agent_card_status,
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
    ) -> None:
        self._order_by_id: dict[str, int] = {}
        self._next_order_seq = 1
        self._tool_calls: dict[str, ClaudePendingToolCall] = {}
        self._tool_call_lookup = dict(tool_call_lookup or {})
        self._hidden_tool_use_ids: set[str] = set(hidden_tool_use_ids or ())
        # L2 subagent progress: live state of every Agent call card this
        # projector has minted, keyed by the card's stable item id. The card
        # carries the wire-projected content and the task-event overlay
        # separately so either writer can land first (see agent_calls.py).
        self._agent_cards: dict[str, ClaudeAgentCallCard] = {}

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
        return MessageTimelineItem(
            id=resolved_item_id,
            type="message",
            status=status,  # type: ignore[arg-type]
            role=role,  # type: ignore[arg-type]
            turn_id=turn_id,
            content=MarkdownMessageContent(
                text=text,
                metadata=(
                    {"attachments": [dict(attachment) for attachment in attachments]}
                    if attachments
                    else {}
                ),
            ),
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
        for block in message_tool_blocks(message):
            if block.block_type == "tool_use" and is_hidden_tool_name(block.tool_name):
                self._hidden_tool_use_ids.add(block.tool_use_id)
                continue
            if (
                block.block_type == "tool_result"
                and block.tool_use_id in self._hidden_tool_use_ids
            ):
                continue
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
            content = _system_content(block)
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
    ) -> RuntimeTimelineItem:
        """Project one streaming thinking block as a reasoning system item.

        Shares stable_system_item_id with the finished-message projection, so
        the live item, the turn-end item and history converge on one row.
        Callers must not pass empty text: an empty reasoning block is never
        published (the stream guard in `stream.py` answers the same question),
        and `system_items_for_message` drops the same shape on the other
        routes.
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
        return SystemTimelineItem(
            id=item_id,
            type="system",
            status=status,  # type: ignore[arg-type]
            role="system",
            turn_id=turn_id,
            content=ReasoningSystemContent(
                text=text,
                metadata={"blockType": "thinking"},
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
                item_id, item_turn_id, status, content
            )
            if status in AGENT_CARD_TERMINAL_STATUSES and has_live_agent_tasks(
                content
            ):
                # I1: agents still alive means the card is not finished. The
                # wire frames above can classify a launch as an outcome (the
                # sidechain receipt carries no metadata to tell them apart),
                # and `resolve_agent_card_status` keeps the first terminal
                # status — so unstick it here, on the item and on the card,
                # which also heals a status a wrong frame already pinned.
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
    ) -> tuple[str, AgentCallToolContent]:
        """Remember one wire-projected Agent card and merge live task state.

        The card's two writers — the dispatch/receipt frames projected here
        and the task events folded by ``fold_agent_task_event`` — consume the
        same stream through different queues, so either can land first.
        Keeping this wire content and the event overlay apart makes every
        publication convergent, and the resolved status keeps the most final
        one (the terminal closure is idempotent).
        """

        card = self._agent_cards.setdefault(item_id, ClaudeAgentCallCard())
        card.turn_id = turn_id
        card.content = content
        card.status = resolve_agent_card_status(card.status, status)
        return card.status, card.overlay.apply(content)

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
        """

        item_id = stable_tool_item_id(session, tool_use_id)
        order_seq = self.order_seq_for(item_id)
        card = self._agent_cards.setdefault(item_id, ClaudeAgentCallCard())
        if card.turn_id is None and turn_id is not None:
            card.turn_id = turn_id
        card.overlay.merge(overlay)
        card.status = resolve_agent_card_status(card.status, status)
        resolved_base = card.content or base or card.overlay.synthesized_call(
            tool_use_id
        )
        return ToolTimelineItem(
            id=item_id,
            type="tool",
            status=card.status,  # type: ignore[arg-type]
            role="tool",
            turn_id=card.turn_id,
            content=card.overlay.apply(resolved_base),
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=card.turn_id,
                native_item_id=tool_use_id,
                native_item_type="tool_use",
                event="claude.agent.task",
            ),
        ).to_platform_item(session_id=session.session_id, order_seq=order_seq)


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


def _system_content(block: ClaudeSystemBlock) -> Any:
    metadata = {
        "blockType": block.block_type,
        **dict(block.metadata or {}),
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
    if tool_name == "AskUserQuestion":
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
