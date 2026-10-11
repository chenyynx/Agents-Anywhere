"""Reasoning rows close at the message boundary (2026-10-11).

Root cause of the "thinking forever" report: the anthropic->openai bridge
(LiteLLM) emits a thinking block's ``content_block_start`` but never its
``content_block_stop``, and the CLI toggles TextBlock/ToolUseBlock blocks
around it. The accumulator flipped a block running->done only on its own
``content_block_stop``, so a block whose stop never arrived stayed "running".
Two paths then *silently dropped* it instead of finishing it:

  * ``reset()`` — called by the runner right after the aggregated assistant
    frame, which the captured wire shows arriving BEFORE ``message_stop``;
  * a new ``message_start`` id — the tool loop's next call.

The fix routes every boundary through one close primitive
(``_close_open_thinking``): the block's accumulated text is republished
``done`` under the same stable id, so the row converges. These tests drive the
accumulator with the EXACT frame shape captured live from LiteLLM plus the two
boundaries, and pin the invariants that make the fix safe for the ccr wire
(which already sends the stop) and for degenerate streams.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator


class StreamEvent(SimpleNamespace):
    """The SDK's stream frame; the accumulator keys on the class name."""


_SESSION = ClaudeSession(session_id="sess_b", external_session_id="ext_b")
_TURN = "turn_b"


def _evt(event: dict[str, Any], parent_tool_use_id: str | None = None) -> StreamEvent:
    kwargs: dict[str, Any] = {"uuid": "u", "session_id": "ext_b", "event": event}
    if parent_tool_use_id is not None:
        kwargs["parent_tool_use_id"] = parent_tool_use_id
    return StreamEvent(**kwargs)


def _msg_start(mid: str) -> dict[str, Any]:
    return {
        "type": "message_start",
        "message": {
            "id": mid,
            "model": "wb/deepseek-v4.1-flash",
            "usage": {"input_tokens": 10, "output_tokens": 0},
        },
    }


def _thinking_start(index: int, text: str = "") -> dict[str, Any]:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "thinking", "thinking": text, "signature": ""},
    }


def _thinking_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": index,
        "delta": {"type": "thinking_delta", "thinking": text},
    }


def _text_start(index: int, text: str = "") -> dict[str, Any]:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "text", "text": text},
    }


def _text_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": index,
        "delta": {"type": "text_delta", "text": text},
    }


def _block_stop(index: int) -> dict[str, Any]:
    return {"type": "content_block_stop", "index": index}


_MSG_STOP: dict[str, Any] = {"type": "message_stop"}


def _drive(events: list[dict[str, Any]]) -> tuple[ClaudeStreamAccumulator, list[Any]]:
    """Feed a frame sequence, collecting yielded items and drained rows."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    emitted: list[Any] = []
    for event in events:
        item = acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(event), projector=proj
        )
        if item is not None:
            emitted.append(item)
        # Mirror the caller: peek, publish, then confirm. The failure path
        # (publish raises, confirm never runs) is covered separately.
        boundary = acc.peek_pending_items()
        emitted.extend(boundary)
        acc.confirm_pending_items(len(boundary))
    return acc, emitted


def _reasoning(items: list[Any]) -> list[Any]:
    return [
        i
        for i in items
        if i.type == "system" and (i.content or {}).get("blockType") == "thinking"
    ]


def _by_id(items: list[Any]) -> dict[str, list[Any]]:
    out: dict[str, list[Any]] = {}
    for i in items:
        out.setdefault(i.id, []).append(i)
    return out


# ---------------------------------------------------------------------------
# A. The exact LiteLLM frame shape (thinking stop never arrives)
# ---------------------------------------------------------------------------


def test_message_stop_closes_a_thinking_block_whose_stop_never_arrived() -> None:
    """LiteLLM shape: message_stop must close the thinking block done."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _text_start(0),
            _thinking_start(1),
            _thinking_delta(1, "We"),
            _thinking_delta(1, " need 2+2"),
            _text_delta(0, "2 + 2 = 4"),
            _block_stop(0),  # ONLY the text block is stopped
            _MSG_STOP,  # the thinking block has no stop of its own
        ]
    )
    reasoning = _reasoning(emitted)
    finals = [r for r in reasoning if r.status == "done"]
    assert finals, "the thinking block must be closed done at message_stop"
    assert finals[-1].content.get("text") == "We need 2+2"
    # Streaming publishes intermediate running rows (that log is expected); the
    # invariant is that the LAST row per id is done, i.e. nothing is stranded.
    for rows in _by_id(reasoning).values():
        assert rows[-1].status == "done"


def test_new_message_start_closes_the_previous_blocks() -> None:
    """A tool-loop call's next message_start closes what the last one left."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _thinking_start(1),
            _thinking_delta(1, "step one"),
            # no message_stop for m1; the next call's message_start is the boundary
            _msg_start("m2"),
        ]
    )
    finals = [r for r in _reasoning(emitted) if r.status == "done"]
    assert finals, "a new message_start must close the previous block"
    assert finals[-1].content.get("text") == "step one"
    assert finals[-1].source["itemId"] == "m1"


def test_ccr_shape_does_not_double_publish() -> None:
    """ccr sends every block's stop: the boundary close must be a no-op."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _thinking_start(0),
            _thinking_delta(0, "reasoning"),
            _block_stop(0),  # ccr closes the thinking block itself
            _text_start(1, "hi"),
            _text_delta(1, "!"),
            _block_stop(1),
            _MSG_STOP,
        ]
    )
    by_id = _by_id(_reasoning(emitted))
    assert len(by_id) == 1, f"one thinking block -> one row, got {list(by_id)}"
    rows = next(iter(by_id.values()))
    assert [r.status for r in rows][-1] == "done"


# ---------------------------------------------------------------------------
# B. reset() is a message boundary (the frame order that stranded the row)
# ---------------------------------------------------------------------------


def test_reset_closes_open_thinking_and_returns_rows() -> None:
    """The captured order: aggregated frame -> reset() BEFORE message_stop."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for ev in (_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "deep")):
        acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(ev), projector=proj
        )
    # the aggregated assistant text frame arrives here and the runner resets
    settled = acc.reset(_SESSION, _TURN, proj)
    assert settled, "reset must close (not drop) the still-open thinking block"
    assert settled[-1].status == "done"
    assert settled[-1].content.get("text") == "deep"
    # and the later message_stop finds nothing left to close
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, message=_evt(_MSG_STOP), projector=proj
    )
    assert acc.peek_pending_items() == ()


def test_reset_without_session_only_clears() -> None:
    """A bare reset (no session to project against) still clears, returns ()."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for ev in (_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "x")):
        acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(ev), projector=proj
        )
    assert acc.reset() == ()
    assert acc.partial_thinking_blocks == {}


def test_reset_then_settle_flush_publishes_nothing_new() -> None:
    """The settle-time backstop after a reset must not republish."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for ev in (_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "x")):
        acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(ev), projector=proj
        )
    acc.reset(_SESSION, _TURN, proj)
    assert acc.finalize_pending_thinking(_SESSION, _TURN, proj) == ()


# ---------------------------------------------------------------------------
# C. Whitespace-only blocks (the 65 " " rows)
# ---------------------------------------------------------------------------


def test_whitespace_only_thinking_block_is_never_published() -> None:
    """A " " block renders as nothing; the stream must not mint a row for it."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _thinking_start(1, " "),  # a lone space — truthy, but blank
            _MSG_STOP,
        ]
    )
    assert _reasoning(emitted) == [], "a whitespace-only block must never publish"


def test_whitespace_block_does_not_leak_a_running_row() -> None:
    """The projection suppresses " "; the stream must agree, or it can't close."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _text_start(0),
            _thinking_start(1, " "),
            _text_delta(0, "answer"),
            _block_stop(0),
            _MSG_STOP,
        ]
    )
    assert not [r for r in _reasoning(emitted) if r.status == "running"]


# ---------------------------------------------------------------------------
# D. Idempotency / degenerate streams
# ---------------------------------------------------------------------------


def test_double_boundary_does_not_double_publish() -> None:
    """message_stop then an explicit close: one done row, no duplicate."""

    acc, emitted = _drive(
        [
            _msg_start("m1"),
            _thinking_start(1),
            _thinking_delta(1, "x"),
            _MSG_STOP,
        ]
    )
    proj = ClaudeMessageProjector()
    again = acc.finalize_pending_thinking(_SESSION, _TURN, proj)
    assert again == (), "a second close must publish nothing"
    done = [r for r in _reasoning(emitted) if r.status == "done"]
    assert len(done) == 1


def test_closed_sidechain_block_carries_no_main_usage() -> None:
    """A subagent block closed at a main-chain boundary must not take usage.

    The close runs on a later frame than the block's own, so it cannot ask the
    live frame "is this a sidechain"; the index mark carries that. Regression
    guard: the boundary close must never stamp the main chain's usage onto a
    subagent row (red-team finding).
    """

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_msg_start("m1")),
    )
    # a sidechain thinking block, opened under a parent tool use id
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_thinking_start(1, "sub"), parent_tool_use_id="tool_X"),
    )
    # a main-chain message_start closes it
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_msg_start("m2")),
    )
    closed = acc.peek_pending_items()
    assert closed, "the sidechain block must still be closed"
    assert "usage" not in (closed[0].content or {}), "sidechain row took main usage"


def test_closed_main_block_keeps_its_usage() -> None:
    """The mirror: a main-chain block closed at the boundary keeps its usage."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_msg_start("m1")),
    )
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_thinking_start(1, "main")),
    )
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, projector=proj,
        message=_evt(_msg_start("m2")),
    )
    closed = acc.peek_pending_items()
    assert closed
    assert (closed[0].content or {}).get("usage"), "main chain lost its usage"


def test_two_thinking_blocks_close_with_their_own_text() -> None:
    """Two open indices at the boundary: each row keeps only its own text."""

    _, emitted = _drive(
        [
            _msg_start("m1"),
            _thinking_start(0, "A"),
            _thinking_start(1, "B"),
            _thinking_delta(0, "0"),
            _thinking_delta(1, "1"),
            _MSG_STOP,
        ]
    )
    texts = sorted(
        r.content.get("text", "") for r in _reasoning(emitted) if r.status == "done"
    )
    assert any("A0" in t for t in texts), texts
    assert any("B1" in t for t in texts), texts


def test_stop_before_any_start_does_not_crash() -> None:
    """message_stop as the first frame: nothing to close, no error."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    item = acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, message=_evt(_MSG_STOP), projector=proj
    )
    assert item is None
    assert acc.peek_pending_items() == ()


def test_confirm_pending_items_is_destructive_and_idempotent() -> None:
    """confirm drops the published rows; a second peek returns ()."""

    acc, _ = _drive(
        [_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "x"), _MSG_STOP]
    )
    assert acc.peek_pending_items() == (), "already confirmed by _drive"


def test_unconfirmed_boundary_rows_recover_via_settle_flush() -> None:
    """A boundary whose publish never confirmed must not lose its row.

    Models the new failure path: the caller peeks, the publish raises, so
    `confirm_pending_items` never runs. The block is already gone from
    `partial_thinking_blocks`, so ONLY the still-buffered row can save it — the
    settle-time `finalize_pending_thinking` must carry it out (report Finding 4).
    """

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for ev in (_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "why so")):
        acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(ev), projector=proj
        )
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, message=_evt(_MSG_STOP), projector=proj
    )
    # peek the boundary rows, then simulate the publish failing: do NOT confirm
    pending = acc.peek_pending_items()
    assert pending and pending[-1].status == "done"
    # and the block map is empty, so the flush can only rely on the buffer
    assert acc.partial_thinking_blocks == {}
    recovered = acc.finalize_pending_thinking(_SESSION, _TURN, proj)
    assert recovered, "the unconfirmed boundary row must be recovered by the flush"
    assert recovered[-1].status == "done"
    assert recovered[-1].content.get("text") == "why so"
    # and a second flush republishes nothing
    assert acc.finalize_pending_thinking(_SESSION, _TURN, proj) == ()


def test_reset_recovers_unconfirmed_boundary_rows() -> None:
    """reset() also carries out any unconfirmed boundary rows."""

    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for ev in (_msg_start("m1"), _thinking_start(1), _thinking_delta(1, "x")):
        acc.item_from_stream_event(
            session=_SESSION, turn_id=_TURN, message=_evt(ev), projector=proj
        )
    acc.item_from_stream_event(
        session=_SESSION, turn_id=_TURN, message=_evt(_MSG_STOP), projector=proj
    )
    acc.peek_pending_items()  # not confirmed — as if the publish raised
    carried = acc.reset(_SESSION, _TURN, proj)
    assert carried, "reset must carry out the unconfirmed boundary rows"
    assert carried[-1].status == "done"
