"""Message-boundary close for thinking/text blocks a backend never stops.

The anthropic→openai bridge (LiteLLM) emits a thinking block's
``content_block_start`` but never its ``content_block_stop``, so the
accumulator's ``running → done`` flip — which keyed on that per-block stop —
never fired and the client showed "thinking" forever (until the whole-turn
settle flush). The close now also fires at the message boundary
(``message_stop``, or a ``message_start`` that has moved on to a new id), and
it does so **per index**, so an interleaved stream (text and thinking open at
once, deltas alternating between indices) closes each block with its own
content — nothing is concatenated across indices and nothing is stranded.

Verified shapes (all synthesized to mirror the wire, not a single backend):
  * LiteLLM: text(0) + thinking(1) interleaved, thinking's stop missing.
  * ccr: thinking(0) + text(1), every block stopped — must not double-close.
  * a new ``message_start`` id: the previous message's open blocks close.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import StreamEvent, _FakeClaudeClient, _RecordingHost, _runtime

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator

SESSION = "claude_thinking_stop"
TURN_ID = "turn_think"


def _session() -> ClaudeSession:
    return ClaudeSession(session_id="sess_think", external_session_id=SESSION)


# ---------------------------------------------------------------------------
# Event builders — the SSE shapes, verbatim
# ---------------------------------------------------------------------------


def _msg_start(message_id: str) -> dict[str, Any]:
    return {"type": "message_start", "message": {"id": message_id}}


def _msg_stop() -> dict[str, Any]:
    return {"type": "message_stop"}


def _text_start(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "text", "text": text},
    }


def _thinking_start(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "thinking", "thinking": text},
    }


def _tool_start(index: int, tool_id: str) -> dict[str, Any]:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "tool_use", "id": tool_id, "name": "Bash", "input": {}},
    }


def _thinking_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": index,
        "delta": {"type": "thinking_delta", "thinking": text},
    }


def _text_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": index,
        "delta": {"type": "text_delta", "text": text},
    }


def _block_stop(index: int) -> dict[str, Any]:
    return {"type": "content_block_stop", "index": index}


# ---------------------------------------------------------------------------
# Driving the accumulator
# ---------------------------------------------------------------------------


def _drive(
    events: list[dict[str, Any]],
) -> tuple[ClaudeStreamAccumulator, list[Any]]:
    """Feed a stream, collecting every item the accumulator emits.

    "Emits" is the returned item of each frame PLUS whatever a boundary frame
    buffered for the caller to drain — exactly the two channels `drive_turn`
    consumes, so the list here is what the user would have seen.
    """

    accumulator = ClaudeStreamAccumulator()
    projector = ClaudeMessageProjector()
    session = _session()
    emitted: list[Any] = []
    for event in events:
        item = accumulator.item_from_stream_event(
            session=session,
            turn_id=TURN_ID,
            message=StreamEvent(uuid="u", session_id=SESSION, event=event),
            projector=projector,
        )
        if item is not None:
            emitted.append(item)
        emitted.extend(accumulator.drain_pending_items())
    return accumulator, emitted


def _reasoning(items: list[Any]) -> list[Any]:
    return [
        item
        for item in items
        if item.type == "system" and item.content.get("kind") == "reasoning"
    ]


def _messages(items: list[Any]) -> list[Any]:
    return [
        item
        for item in items
        if item.type == "message" and item.role == "assistant"
    ]


def _final_status_by_id(items: list[Any]) -> dict[str, str]:
    """The last-seen status of every item id, in first-seen order.

    A streamed block publishes an intermediate partial (`running`) on each
    delta and a terminal row (`done`) as it closes; the row the user is left
    looking at is the LAST one per id. The invariant under test is that the
    final status of every id is `done` — never that every intermediate write
    is — so the assertions read the map, not the raw list.
    """

    final: dict[str, str] = {}
    for item in items:
        final[item.id] = item.status
    return final


# ---------------------------------------------------------------------------
# (a) LiteLLM shape: the thinking block's own stop never arrives
# ---------------------------------------------------------------------------


def test_missing_thinking_stop_closes_at_message_stop() -> None:
    accumulator, emitted = _drive(
        [
            _msg_start("msg_lit"),
            _text_start(0, "Hello"),
            _thinking_start(1, "why"),
            _thinking_delta(1, " so"),
            _tool_start(2, "tool_1"),
            _block_stop(2),  # the tool's stop: present
            _block_stop(0),  # the text's stop: present
            # STOP[1] (thinking) is deliberately MISSING — the LiteLLM shape.
            _msg_stop(),
        ]
    )

    reasoning = _reasoning(emitted)
    assert reasoning, "no reasoning row was ever emitted"
    assert reasoning[0].status == "running"
    assert reasoning[-1].status == "done"
    assert reasoning[-1].content["text"] == "why so"
    # The boundary leaves nothing open.
    assert accumulator.partial_thinking_blocks == {}
    assert accumulator.partial_text_blocks == {}


# ---------------------------------------------------------------------------
# (b) ccr shape: every block has its own stop — no double close
# ---------------------------------------------------------------------------


def test_ccr_shape_with_all_stops_does_not_double_close() -> None:
    accumulator, emitted = _drive(
        [
            _msg_start("msg_ccr"),
            _thinking_start(0, "reason"),
            _text_start(1, "answer"),
            _thinking_delta(0, "ing"),
            _text_delta(1, "!"),
            _block_stop(0),
            _block_stop(1),
            _msg_stop(),
        ]
    )

    reasoning = _reasoning(emitted)
    done = [item for item in reasoning if item.status == "done"]
    # The block's own stop closes it once; the later message boundary finds
    # nothing open and publishes nothing (idempotent — no second done row).
    assert len(done) == 1
    assert done[0].content["text"] == "reasoning"

    messages = _messages(emitted)
    assert messages, "no text row emitted"
    assert messages[-1].status == "done"
    assert messages[-1].content["text"] == "answer!"
    assert accumulator.partial_thinking_blocks == {}
    assert accumulator.partial_text_blocks == {}


def test_stops_arriving_out_of_order_close_each_index_correctly() -> None:
    """STOP[2] then STOP[0] — the stop order need not match the start order.

    Each stop closes exactly its own index; a later boundary finds the rest
    closed. No index is closed twice and none is stranded.
    """

    accumulator, emitted = _drive(
        [
            _msg_start("msg_ooo"),
            _text_start(0, "alpha"),
            _thinking_start(1, "beta"),
            _tool_start(2, "tool_ooo"),
            # Stops out of order: the tool (2) before the text (0).
            _block_stop(2),
            _block_stop(0),
            _msg_stop(),  # closes thinking(1)
        ]
    )

    reasoning = _reasoning(emitted)
    assert reasoning[-1].status == "done"
    assert reasoning[-1].content["text"] == "beta"

    messages = _messages(emitted)
    assert messages[-1].status == "done"
    assert messages[-1].content["text"] == "alpha"
    assert accumulator.partial_thinking_blocks == {}
    assert accumulator.partial_text_blocks == {}


def test_duplicate_stop_for_a_closed_index_is_idempotent() -> None:
    """A second `content_block_stop` for an index already closed is a no-op."""

    _accumulator, emitted = _drive(
        [
            _msg_start("msg_dup_stop"),
            _thinking_start(0, "once"),
            _block_stop(0),
            _block_stop(0),  # duplicate — must not re-publish done
            _msg_stop(),  # boundary — nothing left open either
        ]
    )

    done = [item for item in _reasoning(emitted) if item.status == "done"]
    assert len(done) == 1
    assert done[0].content["text"] == "once"


def test_stop_for_a_never_started_index_is_a_noop() -> None:
    """A stop whose index never opened anything closes nothing."""

    accumulator, emitted = _drive(
        [
            _msg_start("msg_lone_stop"),
            _block_stop(7),  # never opened
            _msg_stop(),
        ]
    )
    assert _reasoning(emitted) == []
    assert accumulator.partial_thinking_blocks == {}


# ---------------------------------------------------------------------------
# (4) The real LiteLLM interleave: text and thinking open together
# ---------------------------------------------------------------------------


def test_interleaved_litellm_stream_closes_each_block_independently() -> None:
    """start[0]:text → start[1]:thinking → thinking_delta[1] → text_delta[0]
    → start[2]:tool_use → STOP[2] → STOP[0] → (message_stop), STOP[1] missing.

    The two live blocks interleave; each must close with its OWN text and
    neither may leak into the other.
    """

    accumulator, emitted = _drive(
        [
            _msg_start("msg_inter"),
            _text_start(0, "Hel"),
            _thinking_start(1, "think"),
            _thinking_delta(1, "A"),
            _text_delta(0, "lo"),
            _tool_start(2, "tool_x"),
            _block_stop(2),
            _block_stop(0),  # closes text; thinking[1] still open
            _msg_stop(),  # closes thinking[1]
        ]
    )

    reasoning = _reasoning(emitted)
    assert reasoning, "no reasoning row emitted"
    assert reasoning[-1].status == "done"
    # No cross-contamination: the thinking text is the thinking deltas only.
    assert reasoning[-1].content["text"] == "thinkA"
    assert "Hel" not in reasoning[-1].content["text"]

    messages = _messages(emitted)
    assert messages, "no text row emitted"
    assert messages[-1].status == "done"
    assert messages[-1].content["text"] == "Hello"
    assert "think" not in messages[-1].content["text"]

    # No residual running state anywhere: the LAST write per item id is done.
    assert set(_final_status_by_id(reasoning + messages).values()) == {"done"}
    assert accumulator.partial_thinking_blocks == {}
    assert accumulator.partial_text_blocks == {}


def test_interleaved_without_message_stop_closes_on_next_message_start() -> None:
    """The same interleave, but the backend never sends ``message_stop`` either.

    The next ``message_start`` (a second call in a tool loop) is the boundary:
    it must close the previous message's still-open thinking block, not clear
    it silently.
    """

    accumulator, emitted = _drive(
        [
            _msg_start("msg_a"),
            _text_start(0, "first"),
            _thinking_start(1, "old-thought"),
            _thinking_delta(1, " more"),
            # No stop for either block — the stream just advances.
            _msg_start("msg_b"),
            _text_start(0, "second"),
            _thinking_start(1, "new-thought"),
            _thinking_delta(1, "!"),
            _block_stop(1),
            _block_stop(0),
            _msg_stop(),
        ]
    )

    reasoning = [item for item in _reasoning(emitted) if item.status == "done"]
    texts = {item.content["text"] for item in reasoning}
    # The first message's thinking closed at the boundary, the second's at its
    # own stop. Both are present as done, each with its own content.
    assert texts == {"old-thought more", "new-thought!"}

    messages = [item for item in _messages(emitted) if item.status == "done"]
    message_texts = [item.content["text"] for item in messages]
    assert "first" in message_texts
    assert "second" in message_texts
    assert accumulator.partial_thinking_blocks == {}
    assert accumulator.partial_text_blocks == {}


# ---------------------------------------------------------------------------
# (c) text + thinking + tool_use mixed: every block reaches its terminal state
# ---------------------------------------------------------------------------

def test_mixed_blocks_each_reach_terminal_state() -> None:
    _accumulator, emitted = _drive(
        [
            _msg_start("msg_mix"),
            _thinking_start(0, "plan"),
            _thinking_delta(0, "ning"),
            _block_stop(0),
            _text_start(1, "Answer: "),
            _text_delta(1, "42"),
            _tool_start(2, "tool_mix"),
            _block_stop(2),
            _block_stop(1),
            _msg_stop(),
        ]
    )

    reasoning = _reasoning(emitted)
    assert [item.status for item in reasoning] == ["running", "running", "done"]
    assert reasoning[-1].content["text"] == "planning"

    messages = _messages(emitted)
    assert messages[-1].status == "done"
    assert messages[-1].content["text"] == "Answer: 42"


# ---------------------------------------------------------------------------
# Wiring smoke test: the boundary rows publish through a real turn
# ---------------------------------------------------------------------------


def test_boundary_close_publishes_through_a_turn() -> None:
    asyncio.run(_test_boundary_close_publishes_through_a_turn())


async def _test_boundary_close_publishes_through_a_turn() -> None:
    """The lifecycle's drain call site runs and the turn settles clean.

    The discriminating coverage for the boundary close is at the accumulator
    level above; this proves the `drive_turn` wiring (`drain_pending_items`)
    executes without error and no reasoning row is left `running`.
    """

    def _stream(event: dict[str, Any]) -> StreamEvent:
        return StreamEvent(uuid="u", session_id="stream_sess", event=event)

    host = _RecordingHost()
    client = _FakeClaudeClient(
        messages=[
            _stream(_msg_start("msg_turn")),
            _stream(_text_start(0, "Hel")),
            _stream(_thinking_start(1, "why")),
            _stream(_thinking_delta(1, " so")),
            _stream(_text_delta(0, "lo")),
            # STOP[1] (thinking) missing; message_stop is the boundary.
            _stream(_block_stop(0)),
            _stream(_msg_stop()),
            SimpleNamespace(
                type="assistant",
                message_id="msg_turn",
                message={
                    "role": "assistant",
                    "content": [
                        {"type": "thinking", "thinking": "why so"},
                        {"type": "text", "text": "Hello"},
                    ],
                },
                session_id="stream_sess",
            ),
            SimpleNamespace(type="result", session_id="stream_sess"),
        ]
    )
    runtime = _runtime(host=host, client=client)
    result = await runtime.start_turn("sess_think", None, "hi")
    task = runtime._sessions["sess_think"].active_task
    assert result.ok is True
    assert task is not None
    await task

    reasoning = [
        item
        for item in host.timeline_item_upserts
        if item.type == "system" and item.content.get("kind") == "reasoning"
    ]
    assert reasoning, "no reasoning row published"
    # The final write for the reasoning id is `done` — it never lingers on the
    # "running" the streamed partial published, even though the thinking
    # block's own stop was missing.
    assert set(_final_status_by_id(reasoning).values()) == {"done"}
    assert reasoning[-1].content["text"] == "why so"
