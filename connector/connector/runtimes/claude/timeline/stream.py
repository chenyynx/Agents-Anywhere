from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from connector.logging import logger
from connector.runtime_protocol import RuntimeTimelineItem
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_message_item_id,
    usage_counts,
)


@dataclass(slots=True)
class ClaudeStreamAccumulator:
    partial_message_id: str | None = None
    partial_text_blocks: dict[int, str] = field(default_factory=dict)
    partial_revision: int = 0
    partial_thinking_blocks: dict[int, str] = field(default_factory=dict)
    partial_thinking_revision: int = 0
    # Rows a message boundary closed but could not return from
    # `item_from_stream_event` (which yields at most one item). A `message_stop`
    # can close several blocks at once, so the done rows ride here and the
    # caller drains them right after the frame. `finalize_pending_thinking`
    # keeps working independently of this buffer: they close disjoint sets
    # (this one closes at the boundary, that one closes whatever a boundary
    # never reached), and closing is idempotent.
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
                # backend dropped its `content_block_stop` (the LiteLLM
                # bridge omits the thinking block's stop) or the stream simply
                # moved on. A retransmitted message_start for the SAME message
                # must not reset counters, so streamed revisions stay monotonic
                # per item — the boundary close only runs on a genuine new id.
                self._close_open_blocks(session, turn_id, projector)
                self.partial_text_blocks.clear()
                self.partial_revision = 0
                self.partial_thinking_blocks.clear()
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
            # The message is complete: every block it opened is done, whether or
            # not its own `content_block_stop` ever arrived (the LiteLLM bridge
            # omits the thinking block's; other backends may omit others). The
            # rows are buffered — a stop can close several blocks and this event
            # returns at most one — and the caller drains them right after.
            self._close_open_blocks(session, turn_id, projector, message)
            return None
        if event_type == "message_delta":
            self._absorb_delta_usage(message, event)
            return self._partial_item(session, turn_id, message, projector)
        return None

    def reset(self) -> None:
        self.partial_message_id = None
        self.partial_text_blocks.clear()
        self.partial_revision = 0
        self.partial_thinking_blocks.clear()
        self.partial_thinking_revision = 0
        self.partial_usage = None
        self.partial_model = None
        # A boundary's buffered rows are the caller's to drain; if the caller
        # moved on without draining (the final assistant frame resets before
        # asking, and a subsequent boundary would have published them), drop
        # them here so they can never leak into the next message.
        self.pending_items.clear()

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
        *,
        status: str = "running",
        usage: Mapping[str, int] | None = None,
        usage_model: str | None = None,
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
        # A streaming frame carries the live seed; a settle-time close (a
        # message boundary, or `finalize_pending_thinking`) republishes a row
        # the message frame already wrote, so it passes the same usage in from
        # `_stream_frame_usage` rather than stripping it.
        if usage is None and status == "running":
            usage = None if _is_sidechain(message) else self.partial_usage
            usage_model = None if _is_sidechain(message) else self.partial_model
        return projector.message_item(
            session=session,
            turn_id=turn_id,
            role="assistant",
            text=text,
            event="claude.turn.assistant.partial",
            status=status,
            native_item_id=message_id,
            item_id=item_id,
            revision=self.partial_revision,
            usage=usage,
            usage_model=usage_model,
        )

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
        if not text:
            return None
        self.partial_thinking_revision += 1
        return projector.reasoning_item(
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

    def finalize_pending_thinking(
        self,
        session: ClaudeSession,
        turn_id: str,
        projector: ClaudeMessageProjector,
    ) -> tuple[RuntimeTimelineItem, ...]:
        """Close whatever a turn left open when it ends without a boundary.

        The turn-settle backstop. A message boundary (`message_stop`, or a new
        `message_start` id) closes the rows it can as they stream; this catches
        a turn that ends without ever seeing its message's boundary — a
        truncated stream, a kill mid-call. It closes every still-open block,
        not just thinking: a text partial stranded open by the same truncation
        is the same bug, so it is settled the same way. The two paths close
        disjoint sets — a row the boundary already published is gone from the
        open maps, so nothing is double-published.
        """

        self._close_open_blocks(session, turn_id, projector)
        return self.drain_pending_items()

    def drain_pending_items(self) -> tuple[RuntimeTimelineItem, ...]:
        """Take the rows a message boundary closed but could not return.

        `item_from_stream_event` yields at most one item, but a `message_stop`
        or a new `message_start` can close several blocks at once (thinking
        blocks of more than one index), so the boundary rows are buffered here
        and the caller drains them right after feeding the frame. Draining is
        destructive and idempotent: a second call returns nothing.
        """

        items = tuple(self.pending_items)
        self.pending_items.clear()
        return items

    def _close_open_blocks(
        self,
        session: ClaudeSession,
        turn_id: str,
        projector: ClaudeMessageProjector,
        message: Any = None,
    ) -> None:
        """Close every block still open, buffering the done rows.

        Called at a message boundary — `message_stop`, or a `message_start`
        that has moved on to a new id. The wire guarantees no more deltas for
        the message being closed, so any block still open will never receive
        its own `content_block_stop` (the LiteLLM anthropic→openai bridge drops
        the thinking block's; another backend could drop any of them). Each is
        published as done rather than stranded in `running`.

        Blocks are keyed by index and closed independently, so an interleaved
        stream (text and thinking open at once, deltas alternating between
        indices) closes each correctly with its own content — nothing is
        concatenated across indices and nothing leaks between them.

        Rows ride `pending_items` because this can close several at once;
        `drain_pending_items` returns them to the caller for publication.
        """

        usage = self._stream_frame_usage(message)
        for index in sorted(self.partial_thinking_blocks):
            text = self.partial_thinking_blocks[index]
            if not text:
                continue
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
                self.pending_items.append(item)
        self.partial_thinking_blocks.clear()
        if self.partial_text_blocks:
            item = self._partial_item(
                session,
                turn_id,
                message,
                projector,
                status="done",
                usage=usage,
                usage_model=self.partial_model,
            )
            if item is not None:
                self.pending_items.append(item)
            self.partial_text_blocks.clear()


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
