"""Project Claude's compaction events as one tri-state timeline marker.

Claude reports compaction through system messages rather than through a native
item, so the marker identity is derived from the AA turn that observed it. One
compaction keeps the running, completed and failed states on a single item id
and lets the client flip the separator in place instead of stacking duplicates;
a turn that compacts twice opens a second generation rather than reopening the
closed one.

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


class ClaudeTimelineMarkers:
    """Track the compaction markers each in-flight turn owns.

    `order_allocator` is the timeline projector's own counter. Sharing it keeps
    every item's `order_seq` unique: a separator can no longer land on a slot a
    message already claimed and leave the client to guess their relative order.
    """

    def __init__(self, order_allocator: Callable[[str], int]) -> None:
        self._order_seq_for = order_allocator
        self._markers: dict[tuple[str, str], _ActiveMarker] = {}
        self._generations: dict[tuple[str, str], int] = {}

    def open_command_marker(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
    ) -> RuntimeTimelineItem:
        """Open the running marker a command turn owes before dispatch.

        The user asked for this compaction, so the separator must exist before
        the prompt leaves; the CLI's own events then advance or settle it.
        """

        key = (session.session_id, turn_id)
        marker = self._markers.get(key)
        if marker is None:
            marker = self._open_marker(
                session=session,
                turn_id=turn_id,
                state="started",
            )
        return self._item(
            session=session,
            marker=marker,
            event=_COMPACT_DISPATCHED_EVENT,
        )

    def item_for_event(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        event: ClaudeCompactEvent,
    ) -> RuntimeTimelineItem:
        """Upsert the turn's current marker for one compaction observation."""

        key = (session.session_id, turn_id)
        marker = self._markers.get(key)
        if marker is None or (marker.state != "started" and event.state == "started"):
            # A compaction that already reported an outcome owns its separator.
            # Another start inside the same turn is the CLI compacting again, so
            # it opens the next generation instead of reopening a closed one.
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
            # A settled marker only absorbs later evidence. The boundary that
            # follows `compact_result` therefore adds its metadata without
            # reopening a finished compaction, and a failure is final.
            if marker.state == "started":
                marker.state = event.state
        return self._item(session=session, marker=marker, event=event.event)

    def settle_turn(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Close a turn's current marker that never produced compaction evidence.

        A turn can end without the CLI reporting a result — a native error or
        an interrupt never emits one — and a command turn that resolved without
        compacting is not a success either. Both settle as unsuccessful so the
        client never leaves a running separator behind.
        """

        key = (session.session_id, turn_id)
        marker = self._markers.pop(key, None)
        self._generations.pop(key, None)
        if marker is None or marker.state != "started":
            return ()
        marker.state = "failed"
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
        key = (session.session_id, turn_id)
        generation = self._generations.get(key, 0)
        if key in self._markers:
            generation += 1
        self._generations[key] = generation
        marker = _ActiveMarker(
            item_id=stable_compact_item_id(session, turn_id, generation),
            turn_id=turn_id,
            generation=generation,
            state=state,
            native_message_id=native_message_id,
            metadata=dict(metadata or {}),
        )
        self._markers[key] = marker
        return marker

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
    """Name one compaction separator inside its session and turn.

    `generation` only enters the hash from the second compaction on, so the
    first separator of every turn keeps the id clients already stored. The scope
    stays the native session id, so the same turn id in another session can
    never resolve to the same row.
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
