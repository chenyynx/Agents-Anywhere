"""Project Claude's compaction events as one tri-state timeline marker.

Claude reports compaction through system messages rather than through a native
item. One compaction keeps the running, completed and failed states on a single
item id and lets the client flip the separator in place instead of stacking
duplicates; a later compaction opens the next generation rather than reopening
the closed one.

Ownership belongs to the session, not to the turn that dispatched the command.
The CLI streams `status:"compacting"`, `compact_result` and `compact_boundary`
*after* the command turn's own result message, by which time that turn's message
loop has ended and a scheduled reader turn holds the stream — with a turn id of
its own. Keying markers by turn therefore stranded the dispatched separator and
let the reader mint a second one. The session now holds at most one open marker:
every turn that reads a compaction frame reports it against that marker, and
only the turn that opened it may settle it.

The SDK hands the turn loop whole message objects whose compaction fields sit in
`.data`, so every read here looks at both levels — see `_attr`.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any, Literal

from connector.runtime_protocol import (
    CompactMarkerContent,
    MarkerTimelineItem,
    RuntimeTimelineItem,
    TimelineSource,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import (
    message_id,
    message_role,
    message_text,
)

ClaudeCompactState = Literal["started", "completed", "failed"]

# The CLI wraps a native slash command's own output in this tag and replays it
# as a user message (2026-10-02 probe:
# `<local-command-stdout>Compacted </local-command-stdout>`). It is CLI chrome,
# never conversation content.
CLAUDE_LOCAL_COMMAND_ECHO_TAGS = (
    "<local-command-stdout>",
    "<local-command-stderr>",
)
CLAUDE_COMPACTING_STATUS = "compacting"
CLAUDE_COMPACT_RESULT_FIELD = "compact_result"

_COMPACT_STARTED_EVENT = "claude.compact.started"
_COMPACT_RESULT_EVENT = "claude.compact.result"
_COMPACT_BOUNDARY_EVENT = "claude.compact.boundary"
_COMPACT_DISPATCHED_EVENT = "claude.compact.dispatched"
_COMPACT_SETTLED_EVENT = "claude.compact.settled"

_MARKER_LABELS: dict[ClaudeCompactState, str] = {
    "started": "正在压缩上下文",
    "completed": "对话已压缩",
    "failed": "上下文压缩未完成",
}
# `content.state` is what the client's CompactMarker reads first; the item
# status is the fallback it checks second, so both always agree.
_MARKER_STATUS: dict[ClaudeCompactState, str] = {
    "started": "running",
    "completed": "done",
    "failed": "failed",
}


@dataclass(frozen=True, slots=True)
class ClaudeCompactEvent:
    """One compaction observation taken from a Claude SDK message."""

    state: ClaudeCompactState
    event: str
    native_message_id: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class _ActiveMarker:
    item_id: str
    turn_id: str
    generation: int
    state: ClaudeCompactState
    native_message_id: str | None
    metadata: dict[str, Any]
    # Whether this separator was failed for want of evidence when its own turn
    # ended, as opposed to a verdict the CLI reported. Only the former may be
    # corrected by trailing evidence — see `item_for_event`.
    settled_by_turn_end: bool = False


class ClaudeTimelineMarkers:
    """Track the one compaction marker each session has open.

    `order_allocator` is the timeline projector's own counter. Sharing it keeps
    every item's `order_seq` unique: a separator can no longer land on a slot a
    message already claimed and leave the client to guess their relative order.
    """

    def __init__(self, order_allocator: Callable[[str], int]) -> None:
        self._order_seq_for = order_allocator
        self._markers: dict[str, _ActiveMarker] = {}
        # The last generation each session spent, so the next separator never
        # reuses the id of one that is already closed.
        self._generations: dict[str, int] = {}

    def open_command_marker(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Open the running marker a command turn owes before dispatch.

        The user asked for this compaction, so the separator must exist before
        the prompt leaves; whichever turn reads the CLI's events then advances
        or settles it.

        A separator this turn already opened is republished as it stands. One an
        interrupted predecessor left running is settled first: it is the only
        way a session holds two open markers, and the line the user is waiting
        for must not queue behind a dead one.
        """

        existing = self._markers.get(session.session_id)
        if existing is not None and existing.state == "started":
            if existing.turn_id == turn_id:
                return (
                    self._item(
                        session=session,
                        marker=existing,
                        event=_COMPACT_DISPATCHED_EVENT,
                    ),
                )
            self._fail(existing)
            stale = self._item(
                session=session,
                marker=existing,
                event=_COMPACT_SETTLED_EVENT,
            )
            opened = self._item(
                session=session,
                marker=self._open_marker(
                    session=session,
                    turn_id=turn_id,
                    state="started",
                ),
                event=_COMPACT_DISPATCHED_EVENT,
            )
            return (stale, opened)
        return (
            self._item(
                session=session,
                marker=self._open_marker(
                    session=session,
                    turn_id=turn_id,
                    state="started",
                ),
                event=_COMPACT_DISPATCHED_EVENT,
            ),
        )

    def item_for_event(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        event: ClaudeCompactEvent,
    ) -> RuntimeTimelineItem:
        """Upsert the session's current marker for one compaction observation.

        The turn that reads the frame is recorded but does not decide: the CLI
        streams its verdict after the dispatching turn has ended, so the frames
        usually belong to a turn that never opened anything.
        """

        marker = self._markers.get(session.session_id)
        if marker is None or (marker.state != "started" and event.state == "started"):
            # A compaction that already reported an outcome owns its separator.
            # Another start is the CLI compacting again, so the session opens the
            # next generation instead of reopening the closed one.
            marker = self._open_marker(
                session=session,
                turn_id=turn_id,
                state=event.state,
                native_message_id=event.native_message_id,
                metadata=event.metadata,
            )
        else:
            marker.native_message_id = event.native_message_id or marker.native_message_id
            marker.metadata.update(event.metadata)
            if marker.state == "started":
                marker.state = event.state
                marker.settled_by_turn_end = False
            elif marker.settled_by_turn_end and event.state == "completed":
                # The verdict arrived after the turn that dispatched it ended, so
                # this separator was failed for exactly the evidence now in hand.
                # Its own trailing evidence in this session corrects it; a failure
                # the CLI reported itself stays final.
                marker.state = "completed"
                marker.settled_by_turn_end = False
            # Anything else only adds evidence: a settled separator never slides
            # back to running, so the boundary after `compact_result` merges its
            # metadata into the finished compaction.
        return self._item(session=session, marker=marker, event=event.event)

    def settle_turn(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Close a compaction marker its own turn never proved complete.

        A turn can end without the CLI reporting a result — a native error or
        an interrupt never emits one — and a command turn that resolved without
        compacting is not a success either. Both settle as unsuccessful so the
        client never leaves a running separator behind.

        Only the turn that opened the separator may settle it. A turn that merely
        read the CLI's compaction frames is reporting on someone else's marker,
        and ending it must not invent a failure the user never had. The settled
        marker stays registered so the evidence that arrives late can still
        correct it.
        """

        marker = self._markers.get(session.session_id)
        if marker is None or marker.turn_id != turn_id or marker.state != "started":
            return ()
        self._fail(marker)
        return (
            self._item(
                session=session,
                marker=marker,
                event=_COMPACT_SETTLED_EVENT,
            ),
        )

    def _open_marker(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        state: ClaudeCompactState,
        native_message_id: str | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> _ActiveMarker:
        generation = self._generations.get(session.session_id)
        generation = 0 if generation is None else generation + 1
        self._generations[session.session_id] = generation
        marker = _ActiveMarker(
            item_id=stable_compact_item_id(session, turn_id, generation),
            turn_id=turn_id,
            generation=generation,
            state=state,
            native_message_id=native_message_id,
            metadata=dict(metadata or {}),
        )
        self._markers[session.session_id] = marker
        return marker

    @staticmethod
    def _fail(marker: _ActiveMarker) -> None:
        marker.state = "failed"
        marker.settled_by_turn_end = True

    def _item(
        self,
        *,
        session: ClaudeSession,
        marker: _ActiveMarker,
        event: str,
    ) -> RuntimeTimelineItem:
        return MarkerTimelineItem(
            id=marker.item_id,
            type="marker",
            status=_MARKER_STATUS[marker.state],  # type: ignore[arg-type]
            role="system",
            turn_id=marker.turn_id,
            content=CompactMarkerContent(
                label=_MARKER_LABELS[marker.state],
                metadata={"state": marker.state, **marker.metadata},
            ),
            source=TimelineSource(
                runtime="claude",
                external_session_id=session.external_session_id,
                turn_id=marker.turn_id,
                native_item_id=marker.native_message_id,
                native_item_type="compact",
                event=event,
                derived_key="compact",
            ),
        ).to_platform_item(
            session_id=session.session_id,
            order_seq=self._order_seq_for(marker.item_id),
        )


def claude_compact_event(message: Any) -> ClaudeCompactEvent | None:
    """Read one compaction observation from a message, or None.

    A manual `/compact` and an automatic compaction emit the same events, so
    this mapping belongs on the shared live path rather than in a command-only
    branch.
    """

    subtype = _string(_attr(message, "subtype"))
    if subtype == "compact_boundary":
        return ClaudeCompactEvent(
            state="completed",
            event=_COMPACT_BOUNDARY_EVENT,
            native_message_id=message_id(message),
            metadata=_compact_metadata(message),
        )
    if subtype != "status":
        return None
    if _string(_attr(message, "status")) == CLAUDE_COMPACTING_STATUS:
        return ClaudeCompactEvent(
            state="started",
            event=_COMPACT_STARTED_EVENT,
            native_message_id=message_id(message),
        )
    result = _string(_attr(message, CLAUDE_COMPACT_RESULT_FIELD, "compactResult"))
    if result is None:
        return None
    return ClaudeCompactEvent(
        state="completed" if result == "success" else "failed",
        event=_COMPACT_RESULT_EVENT,
        native_message_id=message_id(message),
        metadata={"compactResult": result},
    )


def is_claude_init_message(message: Any) -> bool:
    """Match the SDK session handshake the CLI replays after compaction."""

    return _string(_attr(message, "subtype")) == "init"


def is_local_command_echo(message: Any) -> bool:
    """Match the CLI's own echo of a native slash command's output."""

    if message_role(message) != "user":
        return False
    text = message_text(message)
    return bool(text) and text.strip().startswith(CLAUDE_LOCAL_COMMAND_ECHO_TAGS)


def is_compaction_control_message(message: Any) -> bool:
    """Report messages the compaction path owns and must not project."""

    return (
        claude_compact_event(message) is not None
        or is_claude_init_message(message)
        or is_local_command_echo(message)
    )


def stable_compact_item_id(
    session: ClaudeSession,
    turn_id: str,
    generation: int = 0,
) -> str:
    """Name one compaction separator inside its session and opening turn.

    `turn_id` is the turn that opened the separator, whoever ends up reporting
    the CLI's frames for it. `generation` only enters the hash from the second
    compaction on, so the first separator of every turn keeps the id clients
    already stored. The scope stays the native session id, so the same turn id
    in another session can never resolve to the same row.
    """

    scope = session.external_session_id or session.session_id
    parts = ("compact", scope, turn_id)
    if generation:
        parts = (*parts, generation)
    return "claude_compact_" + _short(*parts)


def _compact_metadata(message: Any) -> Mapping[str, Any]:
    raw = _attr(message, "compact_metadata", "compactMetadata")
    if not isinstance(raw, Mapping):
        return {}
    return {
        _camel_case(key): value for key, value in raw.items() if isinstance(key, str)
    }


def _camel_case(key: str) -> str:
    head, *rest = key.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _attr(value: Any, *names: str) -> Any:
    """Read one field from a message, a raw frame, or the SDK's `.data`.

    `SystemMessage` exposes exactly `subtype` and `data`: the CLI's `status`,
    `compact_result` and `compactMetadata` never become attributes, so a
    top-level-only read misses every compaction signal the CLI actually sends.
    """

    if isinstance(value, Mapping):
        for name in names:
            if value.get(name) is not None:
                return value[name]
        return _data_attr(value.get("data"), names)
    for name in names:
        candidate = getattr(value, name, None)
        if candidate is not None:
            return candidate
    return _data_attr(getattr(value, "data", None), names)


def _data_attr(data: Any, names: tuple[str, ...]) -> Any:
    if not isinstance(data, Mapping):
        return None
    for name in names:
        candidate = data.get(name)
        if candidate is not None:
            return candidate
    return None


def _short(*parts: Any) -> str:
    payload = json.dumps(
        parts,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]
