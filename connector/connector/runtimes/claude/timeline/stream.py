from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from typing import Any

from connector.logging import logger
from connector.runtime_protocol import RuntimeTimelineItem, timeline_content_hash
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_message_item_id,
    stable_tool_item_id,
    usage_counts,
)


@dataclass(slots=True)
class ClaudeStreamAccumulator:
    partial_message_id: str | None = None
    partial_text_blocks: dict[int, str] = field(default_factory=dict)
    partial_revision: int = 0
    partial_thinking_blocks: dict[int, str] = field(default_factory=dict)
    partial_thinking_revision: int = 0
    # Which open thinking blocks came from a subagent sidechain frame. Tracked
    # per index because a boundary close can run on a later, unrelated frame:
    # `_stream_frame_usage(None)` cannot tell a sidechain block from a
    # main-chain one once the originating frame is gone, and a sidechain row
    # must never carry the main chain's usage. Cleared with the block maps.
    partial_thinking_sidechain: set[int] = field(default_factory=set)
    # The dispatch tool use each open thinking block came from, keyed by
    # index, so the block's parentItemId follows the FRAME THAT OPENED IT.
    # A boundary close (and the settle-time flush) runs on a later frame —
    # real wire 2026-10-14: a background subagent's stream frame closed a
    # main-agent thinking block whose `content_block_stop` the bridge never
    # sent, and the row was stamped with the subagent's card (the closing
    # frame's parent), dropping a main-agent reasoning row into the SubAgent
    # capsule (pp session sess_3vglLn61-wPSSg, seq 1323/1424/1460). The
    # border must ride the block, never the frame that happens to close it.
    # `None` (main chain) is stored explicitly so the mark is authoritative
    # either way. Cleared with the block maps.
    partial_thinking_parent: dict[int, str | None] = field(default_factory=dict)
    # Rows a message boundary closed but could not return from
    # `item_from_stream_event` (which yields at most one item). A boundary can
    # close several blocks at once, so the done rows ride here and the caller
    # drains them right after the frame. `reset()` closes its own rows and
    # returns them instead — a caller that resets has already stopped yielding
    # frames, so it can publish the tuple directly.
    pending_items: list[RuntimeTimelineItem] = field(default_factory=list)
    # Per-call usage of the message being streamed: seeded by the API's
    # `message_start.message.usage`, kept current by `message_delta.usage`
    # (which carries the message's cumulative output count).
    partial_usage: dict[str, int] | None = None
    # The model the streamed message reports (`message_start.message.model` —
    # for a gateway this is the engine's real id, not the catalog entry's).
    # It rides the streamed rows as the usage block's model fallback.
    partial_model: str | None = None
    # The last per-call usage this turn saw from a final frame. Deliberately
    # survives `reset()`: the result-envelope fallback republishes the same
    # item id after a reset, and its own frame only carries turn-cumulative
    # totals, so this stash is the only per-call number left for it. The model
    # is stashed alongside for the same reason.
    last_usage: dict[str, int] | None = None
    last_model: str | None = None

    def item_from_stream_event(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
        projector: ClaudeMessageProjector,
    ) -> RuntimeTimelineItem | None:
        event = _stream_event(message)
        if event is None:
            return None
        event_type = _string(event.get("type"))
        if event_type == "message_start":
            payload = event.get("message")
            message_id = (
                _string(payload.get("id")) if isinstance(payload, Mapping) else None
            )
            if message_id != self.partial_message_id:
                # A new message begins: close whatever the previous message
                # left open before its counters reset. A `message_start` is a
                # completeness signal in its own right — a block still open
                # under the old id was never going to be closed, whether the
                # backend dropped its `content_block_stop` (the LiteLLM bridge
                # omits the thinking block's stop) or the stream simply moved
                # on. A retransmitted message_start for the SAME message must
                # not reset counters, so streamed revisions stay monotonic per
                # item — the boundary close only runs on a genuine new id.
                self.pending_items.extend(
                    self._close_open_thinking(session, turn_id, projector)
                )
                self.partial_text_blocks.clear()
                self.partial_revision = 0
                self.partial_thinking_blocks.clear()
                self.partial_thinking_sidechain.clear()
                self.partial_thinking_parent.clear()
                self.partial_thinking_revision = 0
            self.partial_message_id = message_id
            self.partial_usage = _message_start_usage(message, payload)
            self.partial_model = (
                None
                if self.partial_usage is None
                else _message_start_model(payload)
            )
            return None
        if event_type == "content_block_start":
            index = _int(event.get("index"))
            block = event.get("content_block")
            thinking = _thinking_text_from_stream_delta(block)
            if index is not None and thinking:
                self.partial_thinking_blocks[index] = thinking
                self._note_thinking_origin(index, message)
                return self._thinking_partial_item(
                    session,
                    turn_id,
                    projector,
                    index=index,
                    status="running",
                    usage=self._stream_frame_usage(message),
                )
            text = _text_from_stream_block(block)
            if index is not None and text is not None:
                self.partial_text_blocks[index] = text
                return self._partial_item(session, turn_id, message, projector)
            return None
        if event_type == "content_block_delta":
            index = _int(event.get("index"))
            delta = event.get("delta")
            thinking = _thinking_text_from_stream_delta(delta)
            if index is not None and thinking:
                self.partial_thinking_blocks[index] = (
                    f"{self.partial_thinking_blocks.get(index, '')}{thinking}"
                )
                self._note_thinking_origin(index, message)
                return self._thinking_partial_item(
                    session,
                    turn_id,
                    projector,
                    index=index,
                    status="running",
                    usage=self._stream_frame_usage(message),
                )
            text = _text_from_stream_block(delta)
            if index is not None and text:
                self.partial_text_blocks[index] = (
                    f"{self.partial_text_blocks.get(index, '')}{text}"
                )
                return self._partial_item(session, turn_id, message, projector)
            return None
        if event_type == "content_block_stop":
            index = _int(event.get("index"))
            if index is None:
                return None
            thinking = self.partial_thinking_blocks.pop(index, None)
            if not thinking:
                return None
            return self._thinking_partial_item(
                session,
                turn_id,
                projector,
                index=index,
                status="done",
                text=thinking,
                usage=self._stream_frame_usage(message),
            )
        if event_type == "message_stop":
            # The message is complete: every block it opened is done, whether
            # or not its own `content_block_stop` ever arrived (the LiteLLM
            # bridge omits the thinking block's; other backends may omit
            # others). The rows are buffered — a stop can close several blocks
            # and this event returns at most one — and the caller drains them
            # right after the frame.
            self.pending_items.extend(
                self._close_open_thinking(session, turn_id, projector)
            )
            return None
        if event_type == "message_delta":
            self._absorb_delta_usage(message, event)
            return self._partial_item(session, turn_id, message, projector)
        return None

    def peek_pending_items(self) -> tuple[RuntimeTimelineItem, ...]:
        """The rows a message boundary closed, WITHOUT clearing them.

        A caller publishes these and then confirms with `confirm_pending_items`.
        The two-step exists because publication can fail (`publish_items` awaits
        the host): if the rows were drained up front and the send raised, the
        closed rows would be lost AND their blocks already gone from
        `partial_thinking_blocks`, so the settle-time backstop could not recover
        them -- the very "stranded running" the boundary close exists to stop.
        Peek-then-confirm keeps them recoverable until the send succeeds.
        """

        return tuple(self.pending_items)

    def confirm_pending_items(self, count: int) -> None:
        """Drop the first `count` buffered rows a successful publish covered."""

        if count > 0:
            del self.pending_items[:count]

    def reset(
        self,
        session: ClaudeSession | None = None,
        turn_id: str | None = None,
        projector: ClaudeMessageProjector | None = None,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Close this message's open thinking blocks, then clear the accumulator.

        Resetting is a message boundary: the caller has stopped feeding frames
        for the message being streamed, so any thinking block still open (its
        `content_block_stop` never arrived) is closed `done` here rather than
        silently dropped. The closed rows are returned for the caller to
        publish; when the three boundary arguments are omitted the close is
        skipped (there is no session to project against) and only the clear
        happens. Any boundary rows a caller closed but never confirmed (their
        publish failed) are folded in too, so they are recoverable from the
        settle-time flush instead of being dropped here. Idempotent: a second
        call finds nothing open and returns ().
        """

        closed: list[RuntimeTimelineItem] = []
        if session is not None and turn_id is not None and projector is not None:
            closed.extend(self._close_open_thinking(session, turn_id, projector))
        # Boundary rows whose publish was never confirmed ride out with this
        # close so the settle-time flush can still recover them (see
        # `peek_pending_items`). Drain regardless of `session` so a bare reset
        # cannot silently swallow them.
        closed.extend(self.pending_items)
        self.pending_items = []
        self.partial_message_id = None
        self.partial_text_blocks.clear()
        self.partial_revision = 0
        self.partial_thinking_blocks.clear()
        self.partial_thinking_sidechain.clear()
        self.partial_thinking_parent.clear()
        self.partial_thinking_revision = 0
        self.partial_usage = None
        self.partial_model = None
        return tuple(closed)

    def remember_usage(
        self,
        usage: Mapping[str, int] | None,
        model: str | None = None,
    ) -> None:
        """Keep the last concrete per-call usage this turn saw.

        Called for every main-chain assistant frame, text or not: a
        tool-only frame's call is the per-call usage a later result-envelope
        fallback (whose own frame reports turn-cumulative totals) must carry.
        The frame's model is stashed beside it so the fallback's rows can name
        the model too.
        """

        if usage is not None:
            self.last_usage = dict(usage)
        if model:
            self.last_model = model

    def result_text_usage(self) -> dict[str, int] | None:
        """The per-call usage to stamp on a result-envelope fallback item.

        The fallback republishes the item id the streamed partial already
        used, so it must carry usage too or its later write would erase it
        (contentHash changes on content, so nothing else stops the clobber).
        The partial seed names that exact message and wins when present; the
        last remembered frame usage covers turns with no stream events.
        """

        return self._stream_frame_usage(None)

    def result_usage_model(self) -> str | None:
        """The model to stamp on a result-envelope fallback item.

        The envelope itself names no model, so the streamed message's own id is
        what the item can carry — the same stash the usage comes from.
        """

        return self.partial_model or self.last_model

    def _stream_frame_usage(self, message: Any | None) -> dict[str, int] | None:
        """The usage a streamed row can carry right now, if any.

        The live seed names the message being streamed and wins while the
        stream is open; the last remembered frame usage covers the settle-time
        flush of a thinking block whose stream never closed — that republishes
        a row the message frame already wrote, so it must carry the frame's
        usage rather than strip it. Subagent sidechain frames get None.

        An all-zero seed counts as absent: it measured nothing (the shape a
        `message_start` emits before any call has counted tokens), and treating
        it as a real seed would pin four zeros on the row instead of falling
        back to the last real measurement.
        """

        if message is not None and _is_sidechain(message):
            return None
        seed = self.partial_usage
        if seed is not None and not any(seed.values()):
            seed = None
        return seed or self.last_usage

    def _absorb_delta_usage(self, message: Any, event: Mapping[str, Any]) -> None:
        """Fold a message_delta's cumulative output count into the seed."""

        if self.partial_usage is None or _is_sidechain(message):
            return
        raw = event.get("usage")
        if not isinstance(raw, Mapping):
            return
        output = _int(_extract(raw, "output_tokens", "outputTokens"))
        if output is not None:
            self.partial_usage["outputTokens"] = output

    def final_item_id(
        self,
        session: ClaudeSession,
        turn_id: str,
    ) -> str | None:
        _ = turn_id
        if self.partial_message_id is None:
            return None
        return stable_message_item_id(session, self.partial_message_id)

    def next_final_revision(self) -> int:
        if self.partial_revision <= 0:
            return 1
        self.partial_revision += 1
        return self.partial_revision

    def next_thinking_final_revision(self) -> int:
        return self.partial_thinking_revision + 1

    def _partial_item(
        self,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
        projector: ClaudeMessageProjector,
    ) -> RuntimeTimelineItem | None:
        text = "".join(
            self.partial_text_blocks[index]
            for index in sorted(self.partial_text_blocks)
        )
        if not text:
            return None
        message_id = self.partial_message_id
        if message_id is None:
            logger.warning(
                "dropping Claude stream text without message_start id turn_id={}",
                turn_id,
            )
            return None
        self.partial_revision += 1
        item_id = stable_message_item_id(session, message_id)
        item = projector.message_item(
            session=session,
            turn_id=turn_id,
            role="assistant",
            text=text,
            event="claude.turn.assistant.partial",
            status="running",
            native_item_id=message_id,
            item_id=item_id,
            revision=self.partial_revision,
            usage=None if _is_sidechain(message) else self.partial_usage,
            usage_model=None if _is_sidechain(message) else self.partial_model,
        )
        # Like the reasoning row above, the streamed text partial carries the
        # parent of the frame that streamed it, not an ambient parent applied
        # later by the caller — a subagent frame can be the one being consumed
        # when this partial is published (stream.py's `content_block_stop`
        # route hands the row straight back to `drive_turn`).
        return _with_origin_parent(item, session, _parent_tool_use_id(message))

    def _note_thinking_origin(self, index: int, message: Any) -> None:
        """Remember which frame opened the thinking block under `index`.

        The index is authoritative for the block's lifetime: a boundary close
        runs after the originating frame is gone, so this is what lets it keep
        the main chain's usage off a subagent's row (and, for the ownership
        mark below, the parent off a main-chain row). A later delta for the
        same index overwrites the mark, so one index can never carry two.
        """

        parent = _parent_tool_use_id(message)
        self.partial_thinking_parent[index] = parent
        if parent is not None:
            self.partial_thinking_sidechain.add(index)
        else:
            self.partial_thinking_sidechain.discard(index)

    def _thinking_partial_item(
        self,
        session: ClaudeSession,
        turn_id: str,
        projector: ClaudeMessageProjector,
        *,
        index: int,
        status: str,
        text: str | None = None,
        usage: Mapping[str, int] | None = None,
    ) -> RuntimeTimelineItem | None:
        message_id = self.partial_message_id
        if message_id is None:
            logger.warning(
                "dropping Claude stream thinking without message_start id turn_id={}",
                turn_id,
            )
            return None
        if text is None:
            text = self.partial_thinking_blocks.get(index, "")
        # A whitespace-only block renders as nothing (the client trims it to the
        # bare marker), so it is never published — the same caliber
        # `messages.py::_reasoning_block_is_displayable` applies to the
        # full-message projection. The two must agree: a `" "` the stream
        # published but the projection suppressed could never be closed.
        if not text or not text.strip():
            return None
        self.partial_thinking_revision += 1
        item = projector.reasoning_item(
            session=session,
            turn_id=turn_id,
            native_message_id=message_id,
            block_index=index,
            text=text,
            status=status,
            revision=self.partial_thinking_revision,
            usage=usage,
            usage_model=self.partial_model,
        )
        # The row carries the parent of the FRAME THAT OPENED THIS BLOCK (its
        # own index's mark), never a caller-supplied ambient parent — a later
        # boundary close runs on a different, possibly subagent, frame.
        return _with_origin_parent(
            item, session, self.partial_thinking_parent.get(index)
        )

    def _close_open_thinking(
        self,
        session: ClaudeSession,
        turn_id: str,
        projector: ClaudeMessageProjector,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Close every still-open thinking block `done` and clear them.

        The single close primitive: a message boundary (`message_stop`, a new
        `message_start` id, or `reset()`) routes here so a block whose own
        `content_block_stop` never arrived is finished rather than dropped. The
        block's accumulated text is republished with `status="done"` under the
        same stable id the running row used, so the row converges instead of
        leaking. Idempotent: a second call finds nothing open and returns ().
        """

        items: list[RuntimeTimelineItem] = []
        for index in sorted(self.partial_thinking_blocks):
            text = self.partial_thinking_blocks[index]
            # A boundary runs on a later frame than the block's own, so the
            # live `_stream_frame_usage(message)` cannot answer "is this row a
            # subagent's": pass `None` for a sidechain block so the close never
            # stamps the main chain's usage onto it.
            usage = (
                None
                if index in self.partial_thinking_sidechain
                else self._stream_frame_usage(None)
            )
            item = self._thinking_partial_item(
                session,
                turn_id,
                projector,
                index=index,
                status="done",
                text=text,
                usage=usage,
            )
            if item is not None:
                items.append(item)
        self.partial_thinking_blocks.clear()
        self.partial_thinking_sidechain.clear()
        self.partial_thinking_parent.clear()
        return tuple(items)

    def finalize_pending_thinking(
        self,
        session: ClaudeSession,
        turn_id: str,
        projector: ClaudeMessageProjector,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Turn-settle backstop for blocks no earlier boundary closed.

        Also folds in any boundary rows a caller closed but never confirmed
        (their publish raised), so a failed send cannot strand them: the flush
        still carries them out. The buffer is cleared either way, so a second
        flush republishes nothing.
        """

        closed = list(self._close_open_thinking(session, turn_id, projector))
        closed.extend(self.pending_items)
        self.pending_items = []
        return tuple(closed)


def _stream_event(message: Any) -> Mapping[str, Any] | None:
    if not is_stream_event(message):
        return None
    event = _extract(message, "event")
    return event if isinstance(event, Mapping) else None


def _message_start_usage(message: Any, payload: Any) -> dict[str, int] | None:
    """The usage seed a message_start carries, output pinned to 0.

    The API seeds a message's usage at start; its produced-token count is
    filled in by `message_delta`, so the seed never counts as output already
    generated. Sidechain frames get no seed at all — a subagent call's usage
    is not the main chain's context.
    """

    if _is_sidechain(message) or not isinstance(payload, Mapping):
        return None
    usage = usage_counts(payload.get("usage"))
    if usage is None:
        return None
    usage["outputTokens"] = 0
    return usage


def _message_start_model(payload: Any) -> str | None:
    """The model a `message_start` reports for the message it opens."""

    if not isinstance(payload, Mapping):
        return None
    return _string(payload.get("model"))


def _is_sidechain(message: Any) -> bool:
    """Whether a frame belongs to a subagent sidechain (never gets usage)."""

    return _extract(message, "parent_tool_use_id", "parentToolUseId") is not None


def _parent_tool_use_id(message: Any) -> str | None:
    """The dispatch tool use a sidechain frame is parented to, else None.

    Read straight off the frame that opened a thinking block; a main-chain
    frame carries none, so this is `None` for it.
    """

    value = _extract(message, "parent_tool_use_id", "parentToolUseId")
    return value if isinstance(value, str) and value else None


def _with_origin_parent(
    item: RuntimeTimelineItem,
    session: ClaudeSession,
    parent_tool_use_id: str | None,
) -> RuntimeTimelineItem:
    """Stamp a reasoning row with its OWN frame's parentItemId (or leave it).

    Mirrors `lifecycle.py`'s `_with_parent_card`, but for a streaming
    reasoning row whose parent has to be read from the frame that opened the
    block, not from whatever frame is being processed when the row is
    published. A main-chain block (`parent_tool_use_id is None`) is returned
    byte-identical — no `parentItemId` — so it stays in the main timeline. A
    sidechain block gets the dispatch card id, so iOS folds it into the
    SubAgent capsule exactly as before.
    """

    if parent_tool_use_id is None or item.type not in {"system", "message"}:
        return item
    content = {
        **dict(item.content),
        "parentItemId": stable_tool_item_id(session, parent_tool_use_id),
    }
    return replace(
        item,
        content=content,
        content_hash=timeline_content_hash(
            item_type=item.type,  # type: ignore[arg-type]
            status=item.status,  # type: ignore[arg-type]
            role=item.role,  # type: ignore[arg-type]
            content=content,
        ),
    )


def is_stream_event(message: Any) -> bool:
    return message.__class__.__name__ == "StreamEvent"


def _text_from_stream_block(value: Any) -> str | None:
    if not isinstance(value, Mapping):
        return None
    block_type = _string(value.get("type"))
    if block_type in {"text", "text_delta"}:
        return _string(value.get("text"))
    if block_type == "input_json_delta":
        return None
    return _string(value.get("text"))


def _thinking_text_from_stream_delta(value: Any) -> str | None:
    if not isinstance(value, Mapping):
        return None
    if _string(value.get("type")) not in {"thinking_delta", "thinking"}:
        return None
    return _string(value.get("thinking"))


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


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None
