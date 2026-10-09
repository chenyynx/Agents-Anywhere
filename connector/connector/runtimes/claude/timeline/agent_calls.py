from __future__ import annotations

from collections.abc import Mapping
from collections.abc import Set as AbstractSet
from dataclasses import dataclass, field, replace
from typing import Any

from connector.runtime_protocol import (
    AgentCallToolContent,
    RuntimeAgentCall,
    complete_agent_call_content,
)
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent

# L2 subagent progress (.local-dev/claude-subagent-progress-tasks.md §3.4).
# The wire's terminal task statuses map onto timeline item statuses; stopped
# and killed mean the CLI cut the agent short rather than the agent failing,
# so they surface as "interrupted". Any other status string is not a
# closure — it leaves the card running.
AGENT_TASK_TERMINAL_STATUSES: Mapping[str, str] = {
    "completed": "done",
    "failed": "failed",
    "stopped": "interrupted",
    "killed": "interrupted",
}
# Timeline item statuses that are final for an Agent card.
AGENT_CARD_TERMINAL_STATUSES = frozenset(
    {"done", "failed", "interrupted", "cancelled"}
)
#: The CLI's tool_use name for an Agent dispatch call. This is the in-process
#: lineage gate's exact criterion — ``messages._tool_call_content`` mints an
#: Agent card only under ``if tool_name == "Agent"``, and the history folds
#: gate dispatch roots on ``call.block.tool_name == "Agent"`` (reader's
#: ``_agent_task_notification_folds``). The raw-transcript scanner must judge
#: dispatch receipts by the same name, or the persisted surface and the live
#: surface disagree about what a dispatch is (red team F1: any tool result
#: quoting ``agentId: <task>`` inside its body read as a dispatch receipt).
DISPATCH_TOOL_NAME = "Agent"
#: The CLI's tool_use name for a SendMessage resume call, mirroring
#: ``send_message_target``'s own gate. The resume receipt's ``resumedAgentId``
#: is only evidence when the call it acknowledges is this tool.
SEND_MESSAGE_TOOL_NAME = "SendMessage"
# The CLI's async launch receipt for an Agent dispatch (run1 L491,
# 2026-10-03): metadata only — the real result arrives later through task
# events. It is not an outcome, so an Agent card must not land "done" on it.
ASYNC_AGENT_RECEIPT_STATUS = "async_launched"
# The same receipt, recognisable from the body alone. A dispatch made inside a
# subagent's own sidechain arrives with no `toolUseResult` at all (2026-10-05
# findings §A), so the metadata above is empty and the text is the only signal
# left that this call launched instead of finished.
ASYNC_AGENT_RECEIPT_PREFIX = "Async agent launched"
# Per-agent statuses that still mean the subagent is alive: the receipt's own
# marker, plus "running" from the task events. An entry with no status key is
# deliberately not in here — a task event without a status leaves `{}` behind,
# and counting that as live would pin every closed card open.
AGENT_TASK_LIVE_STATUSES = frozenset({"running", ASYNC_AGENT_RECEIPT_STATUS})


def claude_agent_call_content(
    *,
    tool_use_id: str,
    tool_input: Mapping[str, Any],
    parent_item_id: str | None,
) -> AgentCallToolContent:
    return RuntimeAgentCall(
        action="invoke",
        title=_string(tool_input.get("description")) or "Agent",
        description=_string(tool_input.get("description")),
        agent_type=_string(
            tool_input.get("subagent_type") or tool_input.get("agent_type")
        ),
        prompt=_string(tool_input.get("prompt")),
        run_in_background=(
            tool_input.get("run_in_background")
            if isinstance(tool_input.get("run_in_background"), bool)
            else None
        ),
        parent_item_id=parent_item_id,
        input=dict(tool_input),
        metadata={"toolUseId": tool_use_id, "toolName": "Agent"},
    ).to_timeline_content()


def complete_claude_agent_call_content(
    call: AgentCallToolContent,
    *,
    output: str,
    result: Any,
    is_error: bool,
    result_details: Mapping[str, Any],
    metadata: Mapping[str, Any],
) -> AgentCallToolContent:
    agent_id = _string(result_details.get("agentId") or result_details.get("agent_id"))
    agent_type = _string(
        result_details.get("agentType") or result_details.get("agent_type")
    )
    model = _string(result_details.get("resolvedModel") or result_details.get("model"))
    status = _string(result_details.get("status"))
    return complete_agent_call_content(
        call,
        output=output,
        result=result,
        is_error=is_error,
        agent_id=agent_id,
        agent_type=agent_type,
        model=model,
        target_ids=(agent_id,) if agent_id is not None else None,
        agents=(
            {agent_id: {"status": status or "completed"}}
            if agent_id is not None
            else None
        ),
        usage=_agent_call_usage(result_details),
        metadata=metadata,
    )


def _agent_call_usage(result: Mapping[str, Any]) -> Mapping[str, int]:
    fields = {
        "durationMs": result.get("totalDurationMs"),
        "tokens": result.get("totalTokens"),
        "toolCalls": result.get("totalToolUseCount"),
    }
    return {
        key: value
        for key, value in fields.items()
        if isinstance(value, int) and not isinstance(value, bool)
    }


def is_async_agent_receipt(
    result_details: Mapping[str, Any] | None,
    output: str | None = None,
) -> bool:
    """Whether an Agent tool_result is the CLI's async launch receipt.

    An explicit status in the frame's metadata decides on its own: a sync
    call's receipt *is* its outcome, even when its body carries the launch
    boilerplate. Only when the metadata names no status does the body speak —
    which is the sidechain case, where `toolUseResult` never exists and the
    text is all the frame offers.
    """

    details = result_details if isinstance(result_details, Mapping) else {}
    status = details.get("status")
    if isinstance(status, str) and status:
        return status == ASYNC_AGENT_RECEIPT_STATUS
    return isinstance(output, str) and output.lstrip().startswith(
        ASYNC_AGENT_RECEIPT_PREFIX
    )


def has_live_agent_tasks(content: AgentCallToolContent) -> bool:
    """Whether any agent on this card is still alive.

    Read off the content rather than the card, so it sees the task overlay the
    fold just merged in. An entry whose status is missing is not live — that
    is a status-less task event, not an agent in flight.
    """

    return any(
        _string(entry.get("status")) in AGENT_TASK_LIVE_STATUSES
        for entry in content.agents.values()
        if isinstance(entry, Mapping)
    )


def has_running_agent_tasks(content: AgentCallToolContent) -> bool:
    """Whether a *started* task backs this card (a ``running`` entry).

    The narrower form for the stop path's two judgments (red team F-D,
    2026-10-06): the ghost sweep's exemption and the fold clamp. The
    ``async_launched`` receipt is metadata about a launch, not proof a task
    exists — a card holding only that marker is still the dispatch-window
    ghost the sweep exists to close. ``running`` comes from task lifecycle
    frames, so it is the entry that genuinely vouches for a live task; a
    spared call that starts after the sweep re-opens the card through it.
    """

    return any(
        _string(entry.get("status")) == "running"
        for entry in content.agents.values()
        if isinstance(entry, Mapping)
    )


def resolve_agent_card_status(previous: str | None, incoming: str | None) -> str:
    """Pick the card status when projections and task events meet.

    The dispatch/receipt frames and the task events reach one card through two
    consumers of the same stream (the reader's observe point and the turn
    projection), so either can land first. Terminal statuses win over running
    ones so a late frame can still finish a card; once terminal, the status
    sticks — the CLI's terminal burst (task_updated → task_notification,
    findings §8.6) must fold into a single closure, never a second one.
    That stickiness is also what makes a misclassification irreversible, so a
    wrong "done" is unsticky with the A3 batch's single card-opening rule:
    ``has_running_agent_tasks`` unwinds it on the wire path
    (``messages.tool_item``), on the task-event fold (``messages.
    fold_agent_task_event``) and at the stop sweep
    (``messages.close_open_agent_cards``).
    """

    if incoming is None:
        return previous or "running"
    if previous is None or previous == incoming:
        return incoming
    previous_terminal = previous in AGENT_CARD_TERMINAL_STATUSES
    incoming_terminal = incoming in AGENT_CARD_TERMINAL_STATUSES
    if incoming_terminal and not previous_terminal:
        return incoming
    if previous_terminal:
        return previous
    return incoming


def agent_task_terminal_status(status: str | None) -> str | None:
    """Map a wire task status onto the timeline item status it closes with."""

    if status is None:
        return None
    return AGENT_TASK_TERMINAL_STATUSES.get(status)


def send_message_target(tool_name: str | None, tool_input: Any) -> str | None:
    """The background task a SendMessage tool call resumes (``input.to``).

    The live resume path (R4): a SendMessage call carries the task id it
    addresses in ``input.to`` (the CLI also mirrors it as ``recipient``). That
    id is the join key back to the original Agent dispatch, and reading it is
    the only thing this does — SendMessage visibility is untouched.
    """

    if tool_name != "SendMessage" or not isinstance(tool_input, Mapping):
        return None
    target = tool_input.get("to")
    return target if isinstance(target, str) and target else None


def resolve_resume_alias(
    tool_use_id: str,
    *,
    send_to_task: Mapping[str, str],
    task_roots: Mapping[str, set[str]],
) -> str | None:
    """Resolve a SendMessage tool_use id to the Agent card it belongs to.

    R4 (``.local-dev/subagent-status-truth-tasks.md``): a task resumed through
    SendMessage has its lifecycle frames and terminal notification keyed by the
    *SendMessage* tool_use id, so the live fold would mint a second card and
    the original dispatch card would never receive the terminal state. This
    folds the alias back onto the original card.

    The join is intentionally strict and fail-closed — an unresolved id is
    returned as ``None`` and the caller keeps the id it came with:

    * the id must be a recorded SendMessage alias (``send_to_task``);
    * its task must resolve to exactly one dispatch root (``task_roots``) — a
      task with no root (dispatch not seen) or several roots (ambiguity) is
      not touchable;
    * the resolved root must not be the alias itself, so the two mappings can
      never loop.
    """

    task_id = send_to_task.get(tool_use_id)
    if task_id is None:
        return None
    roots = task_roots.get(task_id)
    if roots is None or len(roots) != 1:
        return None
    root = next(iter(roots))
    return root if root != tool_use_id else None


def resolve_resume_alias_from_scan(
    tool_use_id: str,
    *,
    send_aliases: Mapping[str, str] | None,
    dispatch_roots: Mapping[str, frozenset[str]] | None,
    verified_dispatch_ids: AbstractSet[str],
) -> tuple[str, str] | None:
    """Step 2 of the persistence fallback chain (T1 A-2): the scan's own join.

    ``send_aliases`` / ``dispatch_roots`` are the raw transcript's persisted
    copies of the two in-process maps ``resolve_resume_alias`` reads. This
    applies the exact same constraints — the id must be a recorded alias, its
    task must have exactly one dispatch root, and the root must not be the
    alias itself — so the fallback can only ever reproduce a resolution the
    in-process maps would have made had the process seen every frame. Anything
    less certain returns ``None`` and the caller keeps its fail-closed
    behaviour.

    ``verified_dispatch_ids`` is the scan's provenance set: the tool_use ids
    it verified as **dispatch calls** (assistant rows whose tool_use name is
    ``DISPATCH_TOOL_NAME``). A root outside it is not a dispatch however the
    mapping was built, and is refused (red team F3: a quoting tool result's id
    as the task's only root must never be folded onto, and must never be
    backfilled into the in-process maps). This is checkable-at-the-consumer by
    design — the producer's mapping alone is a convention, the provenance set
    makes it an invariant.

    Returns ``(task_id, root)`` on a hit so the caller can warm its own maps.
    """

    if not send_aliases:
        return None
    task_id = send_aliases.get(tool_use_id)
    if task_id is None:
        return None
    roots = dispatch_roots.get(task_id) if dispatch_roots else None
    if roots is None or len(roots) != 1:
        return None
    root = next(iter(roots))
    if root == tool_use_id:
        return None
    if root not in verified_dispatch_ids:
        return None
    return task_id, root


def resolve_task_card_from_timeline(
    *,
    task_id: str,
    timeline_items: Mapping[str, Any],
    alias_keys: AbstractSet[str],
    exclude: str,
) -> str | None:
    """Step 3 of the persistence fallback chain (T1 A-2): ask the projected timeline.

    When the scan knows the alias's task but not a usable dispatch root (its
    receipt rows are missing, or name several), the already-projected timeline
    can still say which card carries the task. A card qualifies when it is an
    Agent call whose ``agents`` map names the task and whose native tool_use id
    is **not** a known alias key — an alias-keyed twin is a resume card, not
    the dispatch root this is looking for.

    Exactly one qualifying card must exist; zero (nothing known) or several
    (ambiguity) returns ``None`` and leaves the caller fail-closed. The
    ``exclude`` id (the alias being folded) never qualifies, so the result can
    never loop back onto the incoming id.
    """

    candidates: set[str] = set()
    for item in timeline_items.values():
        if getattr(item, "type", None) != "tool":
            continue
        content = getattr(item, "content", None)
        if not isinstance(content, Mapping) or content.get("kind") != "agent_call":
            continue
        agents = content.get("agents")
        if not isinstance(agents, Mapping) or task_id not in agents:
            continue
        source = getattr(item, "source", None)
        native = source.get("itemId") if isinstance(source, Mapping) else None
        if not isinstance(native, str) or not native:
            continue
        if native == exclude or native in alias_keys:
            continue
        candidates.add(native)
    if len(candidates) != 1:
        return None
    return next(iter(candidates))


def closure_rank(status: str | None) -> tuple[int, int]:
    """Order two candidate closures so the most final, most honest one wins.

    Terminal beats running; among equals ``interrupted`` beats ``done`` because
    a card the engine cut short must never be shown as completed. Shared by the
    live sweep and the history rebuild so both pick the same verdict when a card
    names more than one task.
    """

    return (
        0 if status in AGENT_CARD_TERMINAL_STATUSES else -1,
        1 if status == "interrupted" else 0,
    )


def open_agent_task_ids(agents: Mapping[str, Any]) -> frozenset[str]:
    """The tasks on a card that still claim to be alive.

    A task counts as open when its agents-map entry carries a live status
    (``running`` or ``async_launched``). A card can name several tasks — a
    dispatch plus its SendMessage resumes, or a fan-out — and a closure may
    only be published when *every* open task has been judged, so a sibling
    that is still running is never hidden by the closure of another (red team
    F6). Entries already terminal, or with no status at all, are not open:
    they neither vouch for liveness nor block a judgement.
    """

    return frozenset(
        agent_id
        for agent_id, entry in agents.items()
        if isinstance(agent_id, str)
        and agent_id
        and isinstance(entry, Mapping)
        and _string(entry.get("status")) in AGENT_TASK_LIVE_STATUSES
    )


def task_usage(raw: Mapping[str, Any] | None) -> dict[str, Any]:
    """Map task usage onto the keys the receipt path already publishes.

    task_progress/task_notification name the same counters differently
    (``total_tokens``/``tool_uses``/``duration_ms``); reusing
    ``_agent_call_usage``'s key names keeps one usage shape per Agent card no
    matter which frame wrote it last.
    """

    fields = {
        "durationMs": None if raw is None else raw.get("duration_ms"),
        "tokens": None if raw is None else raw.get("total_tokens"),
        "toolCalls": None if raw is None else raw.get("tool_uses"),
    }
    return {
        key: value
        for key, value in fields.items()
        if isinstance(value, int) and not isinstance(value, bool)
    }


@dataclass(slots=True)
class ClaudeAgentTaskOverlay:
    """Cumulative task-event state folded onto one Agent call card.

    Kept apart from the wire-projected card content so the two writers — the
    dispatch/receipt frames and the task events — can arrive in either order
    (the SDK reader and the turn projection consume the stream through
    separate queues) without one clobbering the other: every publication is
    the latest wire content plus this overlay.
    """

    agents: dict[str, dict[str, Any]] = field(default_factory=dict)
    usage: dict[str, Any] = field(default_factory=dict)
    description: str | None = None
    agent_type: str | None = None
    prompt: str | None = None
    summary: str | None = None
    end_time: int | None = None

    def merge(self, other: ClaudeAgentTaskOverlay) -> None:
        for agent_id, entry in other.agents.items():
            existing = self.agents.get(agent_id)
            self.agents[agent_id] = (
                {**existing, **entry} if isinstance(existing, Mapping) else dict(entry)
            )
        self.usage.update(other.usage)
        if other.description:
            self.description = other.description
        if other.agent_type:
            self.agent_type = other.agent_type
        if other.prompt:
            self.prompt = other.prompt
        if other.summary is not None:
            self.summary = other.summary
        if other.end_time is not None:
            self.end_time = other.end_time

    def apply(self, content: AgentCallToolContent) -> AgentCallToolContent:
        metadata = dict(content.metadata)
        if self.summary is not None:
            # The subagent's verbatim final reply (findings §3.3), carried as
            # a flat content key (metadata serializes beside the typed fields)
            # so the panel's final-output section renders the result instead
            # of the launch receipt's internal-metadata boilerplate.
            metadata["summary"] = self.summary
        if self.end_time is not None:
            metadata["endTime"] = self.end_time
        agents: dict[str, Any] = {
            agent_id: dict(entry) if isinstance(entry, Mapping) else entry
            for agent_id, entry in content.agents.items()
        }
        for agent_id, entry in self.agents.items():
            existing = agents.get(agent_id)
            agents[agent_id] = (
                {**existing, **entry} if isinstance(existing, Mapping) else dict(entry)
            )
        return replace(
            content,
            # The dispatch input is authoritative when it named the agent or
            # wrote the prompt; the task data backfills what the call omitted
            # (the CLI resolves an omitted subagent_type to general-purpose).
            agent_type=content.agent_type or self.agent_type,
            prompt=content.prompt or self.prompt,
            agents=agents,
            usage={**dict(content.usage), **self.usage},
            metadata=metadata,
        )

    def synthesized_call(self, tool_use_id: str) -> AgentCallToolContent:
        """Base card for events that arrived before the dispatch frame.

        The dispatch projection replaces this shape moments later — with this
        same overlay applied — so the early card only needs what the events
        know: the task name, its prompt and the agent type.
        """

        tool_input: dict[str, Any] = {}
        if self.description:
            tool_input["description"] = self.description
        if self.prompt:
            tool_input["prompt"] = self.prompt
        if self.agent_type:
            tool_input["subagent_type"] = self.agent_type
        return claude_agent_call_content(
            tool_use_id=tool_use_id,
            tool_input=tool_input,
            parent_item_id=None,
        )


@dataclass(slots=True)
class ClaudeAgentCallCard:
    """Live L2 state for one Agent call card, keyed by its stable item id."""

    turn_id: str | None = None
    content: AgentCallToolContent | None = None
    overlay: ClaudeAgentTaskOverlay = field(default_factory=ClaudeAgentTaskOverlay)
    status: str | None = None
    #: The dispatch tool_use id and the owning platform session. One projector
    #: serves every session of the runtime, so the stop-path sweep
    #: (`messages.close_open_agent_cards`) must know which cards are this
    #: session's, and a card minted by task events before its dispatch frame
    #: (content None) needs the raw id to synthesize a base.
    tool_use_id: str | None = None
    session_id: str | None = None
    #: Wall-clock seconds when this card was first seen (its dispatch frame
    #: landed). The wire frames carry no timestamps, so this is the live path's
    #: only launch time — the input the never-started grace needs when a task
    #: has no subagent transcript at all (red team F5).
    #:
    #: It is a *card* stamp, not a task one: a card naming several tasks (a
    #: fan-out, or a dispatch plus a resume) dates them all from the first
    #: frame, so a later task's age is over-estimated. The bias only makes the
    #: never-started closure more willing, and the subagent file — when it
    #: exists — overrides it entirely; recorded rather than fixed (N5a).
    launched_at: float | None = None


def agent_task_overlay_for_event(
    event: ClaudeTaskEvent,
) -> tuple[ClaudeAgentTaskOverlay, str | None]:
    """Translate one normalized task event into (card overlay, card status).

    task_progress fires once per tool start, 1-15 ms behind the tool_use frame
    (findings §3.1) — never as a heartbeat — so its ``last_tool_name`` is the
    agent's most recent tool, recorded inside its agents-map entry.
    """

    if event.kind == "started":
        agent: dict[str, Any] = {"status": "running"}
        if event.subagent_type:
            agent["subagentType"] = event.subagent_type
        if event.is_backgrounded is not None:
            agent["isBackgrounded"] = event.is_backgrounded
        if event.spawn_depth is not None:
            agent["spawnDepth"] = event.spawn_depth
        return (
            ClaudeAgentTaskOverlay(
                agents={event.task_id: agent},
                description=event.description,
                agent_type=event.subagent_type,
                prompt=event.prompt,
            ),
            "running",
        )
    if event.kind == "progress":
        agent = {"status": "running"}
        if event.last_tool_name:
            agent["lastToolName"] = event.last_tool_name
        return (
            ClaudeAgentTaskOverlay(
                agents={event.task_id: agent},
                usage=task_usage(event.usage),
            ),
            "running",
        )
    if event.kind == "updated":
        return (
            ClaudeAgentTaskOverlay(
                agents={event.task_id: _terminal_agent_entry(event.status)},
                end_time=event.end_time,
            ),
            agent_task_terminal_status(event.status) or "running",
        )
    # notification: the terminal frame carrying the agent's verbatim final
    # reply (summary) plus the final usage snapshot. The live wire carries no
    # end time on this frame (only task_updated's patch has one), so for the
    # live path ``event.end_time`` is None and nothing changes; an import fold
    # that read one from the transcript message passes it through here.
    return (
        ClaudeAgentTaskOverlay(
            agents={event.task_id: _terminal_agent_entry(event.status)},
            usage=task_usage(event.usage),
            summary=event.summary,
            end_time=event.end_time,
        ),
        agent_task_terminal_status(event.status) or "running",
    )


def _terminal_agent_entry(status: str | None) -> dict[str, Any]:
    return {"status": status} if status else {}


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None
