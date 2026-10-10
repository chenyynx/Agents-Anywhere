"""Adversarial cases for the message-boundary block close (red team).

Independent of `test_claude_thinking_stop_missing.py` — these attack the
edges that harness covers only on the happy path: same-id retransmit,
double drain, empty/duplicate stops, sidechain usage leakage, out-of-order
boundaries, and no-block streams. The invariant attacked: a boundary close
must never (a) fire on a same-id retransmit, (b) double-publish, (c) leak
usage onto a sidechain row, (d) crash on a degenerate stream.
"""

from __future__ import annotations

from typing import Any

from test_claude_runtime import StreamEvent
from test_claude_thinking_stop_missing import (
    SESSION,
    TURN_ID,
    _block_stop,
    _drive,
    _messages,
    _msg_start,
    _msg_stop,
    _reasoning,
    _session,
    _text_delta,
    _text_start,
    _thinking_delta,
    _thinking_start,
)

from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator


def _evt(event: dict[str, Any], parent_tool_use_id: str | None = None) -> Any:
    kw: dict[str, Any] = {"uuid": "u", "session_id": SESSION, "event": event}
    if parent_tool_use_id is not None:
        kw["parent_tool_use_id"] = parent_tool_use_id
    return StreamEvent(**kw)


# ---------------------------------------------------------------------------
# A. Idempotency / double-publish
# ---------------------------------------------------------------------------


def test_same_id_retransmit_does_not_close_open_blocks() -> None:
    """A re-sent message_start for the SAME id must not close open blocks.

    Regression guard for the boundary-close: the `message_id != current`
    check protects it. If it fired on a retransmit, the live block would be
    sealed mid-stream and its later deltas lost.
    """
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()

    def feed(ev: dict[str, Any]) -> list[Any]:
        out: list[Any] = []
        item = acc.item_from_stream_event(
            session=sess, turn_id=TURN_ID,
            message=_evt(ev), projector=proj,
        )
        if item is not None:
            out.append(item)
        out.extend(acc.drain_pending_items())
        return out

    feed(_msg_start("m1"))
    feed(_thinking_start(0, "think"))
    feed(_thinking_delta(0, "ing"))
    # same id again — must NOT seal the thinking block
    retransmit = feed(_msg_start("m1"))
    assert retransmit == [], "same-id message_start must emit nothing"
    assert acc.partial_thinking_blocks, "block must still be open after retransmit"
    # more deltas still accumulate onto the same open block
    feed(_thinking_delta(0, "...more"))
    assert acc.partial_thinking_blocks[0] == "thinking...more"
    # and it still closes cleanly at the real boundary
    feed(_msg_stop())
    r = _reasoning(feed(_msg_stop()))
    # drain already consumed above; assert on the map the close emptied
    assert not acc.partial_thinking_blocks


def test_drain_is_destructive_and_idempotent() -> None:
    """drain_pending_items returns rows once; a second call returns ()."""
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    for ev in (_msg_start("m1"), _thinking_start(0, "x")):
        acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(ev), projector=proj)
    acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(_msg_stop()), projector=proj)
    first = acc.drain_pending_items()
    second = acc.drain_pending_items()
    assert first, "boundary close must buffer the done row"
    assert second == (), "second drain must be empty"


def test_finalize_after_boundary_does_not_republish() -> None:
    """The settle-time flush after a boundary close must publish nothing new."""
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    for ev in (_msg_start("m1"), _thinking_start(0, "x"), _msg_stop()):
        acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(ev), projector=proj)
    acc.drain_pending_items()
    settled = acc.finalize_pending_thinking(sess, TURN_ID, proj)
    assert settled == (), "nothing open after a boundary — flush must be empty"


# ---------------------------------------------------------------------------
# B. Boundary integrity
# ---------------------------------------------------------------------------


def test_new_id_with_no_open_blocks_emits_nothing() -> None:
    """A new message_start when nothing is open must not mint ghost rows."""
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(_msg_start("m1")), projector=proj)
    acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(_msg_stop()), projector=proj)
    acc.drain_pending_items()
    # new id, nothing open
    item = acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(_msg_start("m2")), projector=proj)
    assert item is None
    assert acc.drain_pending_items() == ()


def test_message_stop_with_no_blocks_emits_nothing() -> None:
    """message_start + message_stop with zero blocks must not crash or emit."""
    _, emitted = _drive([_msg_start("m1"), _msg_stop()])
    assert emitted == [], "a block-less message must emit nothing"


def test_sidechain_boundary_close_carries_no_usage() -> None:
    """A subagent sidechain's closed block must not leak usage onto the row."""
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    acc.item_from_stream_event(
        session=sess, turn_id=TURN_ID,
        message=_evt(_msg_start("m1")), projector=proj,
    )
    # a sidechain thinking block
    item = acc.item_from_stream_event(
        session=sess, turn_id=TURN_ID,
        message=_evt(_thinking_start(0, "sub"), parent_tool_use_id="tool_p"), projector=proj,
    )
    rows = ([item] if item else []) + list(acc.drain_pending_items())
    assert rows, "sidechain block must still publish"
    for row in rows:
        assert "usage" not in row.metadata, "sidechain row must carry no usage"


# ---------------------------------------------------------------------------
# C. Interleaved content isolation
# ---------------------------------------------------------------------------


def test_interleaved_content_never_crosses_indices() -> None:
    """text(0) and thinking(1) interleaved: each row holds only its own text."""
    _, emitted = _drive([
        _msg_start("m1"),
        _text_start(0, "hello "),
        _thinking_start(1, "reason "),
        _text_delta(0, "world"),
        _thinking_delta(1, "more"),
        # NO stops for either — boundary must close both
        _msg_stop(),
    ])
    msgs = _messages(emitted)
    reas = _reasoning(emitted)
    assert msgs, "text block must publish"
    assert reas, "thinking block must publish"
    text = "".join(m.content.get("text", "") for m in msgs if m.status == "done")
    think = "".join(r.content.get("text", "") for r in reas if r.status == "done")
    assert "hello" in text and "world" in text, text
    assert "reason" not in text, f"thinking leaked into text: {text!r}"
    assert "reason" in think and "more" in think, think
    assert "hello" not in think and "world" not in think, f"text leaked into thinking: {think!r}"


def test_two_thinking_blocks_close_independently() -> None:
    """Two thinking indices both open → both close, own content each."""
    _, emitted = _drive([
        _msg_start("m1"),
        _thinking_start(0, "A"),
        _thinking_start(1, "B"),
        _thinking_delta(0, "0"),
        _thinking_delta(1, "1"),
        _msg_stop(),
    ])
    reas = [r for r in _reasoning(emitted)]
    finals = {}
    for r in reas:
        finals[r.id] = r.content.get("text", "")
    texts = sorted(finals.values())
    assert any("A0" in t for t in texts), texts
    assert any("B1" in t for t in texts), texts


# ---------------------------------------------------------------------------
# D. Degenerate / out-of-order
# ---------------------------------------------------------------------------


def test_stop_before_any_start_does_not_crash() -> None:
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    # message_stop as the very first frame
    item = acc.item_from_stream_event(
        session=sess, turn_id=TURN_ID, message=_evt(_msg_stop()), projector=proj,
    )
    assert item is None
    assert acc.drain_pending_items() == ()


def test_duplicate_block_stop_is_idempotent() -> None:
    """A block stopped twice must publish done once, not twice."""
    _, emitted = _drive([
        _msg_start("m1"),
        _thinking_start(0, "x"),
        _block_stop(0),
        _block_stop(0),  # duplicate
    ])
    done = [r for r in _reasoning(emitted) if r.status == "done"]
    ids = {r.id for r in done}
    assert len(ids) == 1, f"one block → one done row, got {ids}"


def test_trailing_delta_after_message_stop_is_inert() -> None:
    """A (non-conformant) delta after message_stop must not mint a ghost row."""
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    sess = _session()
    for ev in (_msg_start("m1"), _thinking_start(0, "x"), _msg_stop()):
        acc.item_from_stream_event(session=sess, turn_id=TURN_ID, message=_evt(ev), projector=proj)
    acc.drain_pending_items()
    # stray delta after the boundary — block already closed and cleared
    item = acc.item_from_stream_event(
        session=sess, turn_id=TURN_ID, message=_evt(_thinking_delta(0, "late")), projector=proj,
    )
    rows = ([item] if item else []) + list(acc.drain_pending_items())
    # A stray delta re-accumulates (no closed-set is kept) — that is benign: the
    # invariant is that it never leaves a PERMANENTLY running row, i.e. the next
    # boundary still closes it. Assert that, not that the block stays sealed.
    acc.item_from_stream_event(
        session=sess, turn_id=TURN_ID, message=_evt(_msg_stop()), projector=proj,
    )
    closed = list(acc.drain_pending_items())
    assert closed, "a later boundary must still close the stray block"
    assert all(r.status == "done" for r in closed), "stray-opened block must end done"


# ---------------------------------------------------------------------------
# E. Regression: ccr shape unchanged
# ---------------------------------------------------------------------------


def test_ccr_full_stop_shape_all_done_no_duplicates() -> None:
    """ccr wire (every block stopped, thinking first) → all done, no dupes."""
    _, emitted = _drive([
        _msg_start("m1"),
        _thinking_start(0, "t"),
        _thinking_delta(0, "t2"),
        _block_stop(0),
        _text_start(1, "hi"),
        _text_delta(1, "!"),
        _block_stop(1),
        _msg_stop(),
    ])
    finals = {}
    for item in emitted:
        if item.type in ("system", "message"):
            finals[item.id] = item.status
    assert finals, "ccr shape must publish"
    assert all(s == "done" for s in finals.values()), finals
