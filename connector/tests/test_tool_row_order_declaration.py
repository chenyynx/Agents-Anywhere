"""Tool rows declare their in-message position (tool-order-inversion P1).

A group of tool calls inside one assistant message can land on the timeline in
completion order rather than model order, and the server freezes that arrival
order into ``order_seq`` (see ``.local-dev/tool-order-inversion-tasks.md``).
The root fix needs the connector to declare, on every tool row, which assistant
message the call belongs to and which position it holds inside that message,
so the server can order the group by truth.

**The index is the per-message tool_use count, not the block's offset in
``content``.** The engine streams one content block per frame, so a frame's
``message.content`` holds a single ``tool_use`` and its index there is always 0
(measured: of the rows sharing a ``message.id`` in a real transcript, the
overwhelming majority are "one block per frame"; only a handful are "one frame,
many blocks"). ``enumerate(content)`` therefore degenerates to a constant 0 for
every tool and the whole declaration carries no order — the exact inversion the
fix means to remove. The engine *does* emit a message's ``tool_use`` blocks in
model order, one frame each, so the running count of ``tool_use`` blocks seen
for a message id *is* the model order, and that count is what the projector
assigns (``ClaudeMessageProjector._assign_block_index``).

Every runtime route that mints a tool row shares
``ClaudeMessageProjector.tool_items_for_message`` — the live stream, the history
rebuild (``reader.py::_history_items_from_messages``) and the subagent frames
(``lifecycle.py::project_background_frame``) — so the declaration is pinned on
each of the three, plus the two facts the fix depends on:

* the index is the count of tool_use blocks for the message id (0-based,
  independent of any intervening text/thinking frames);
* a row first materialised by its ``tool_result`` frame — the running frame
  never persisted — still carries both, recovered from the pending call
  (``messages.py`` ``_tool_calls.pop`` -> ``call.block``).

The final test pins the connector->server wire shape
(``runtime_host._timeline_source_payload``), which whitelists source fields: a
field missing there never leaves the connector.
"""

from __future__ import annotations

from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import task_event_from_message
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.timeline.agent_calls import (
    agent_task_overlay_for_event,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
)
from connector.server.runtime_host import _timeline_source_payload

SESSION = "tool-order-declaration"


def _session() -> ClaudeSession:
    return ClaudeSession(session_id=SESSION, external_session_id=SESSION)


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _assistant(message_id: str, content: list[dict[str, Any]]) -> Any:
    return _parse(
        {
            "type": "assistant",
            "message": {
                "id": message_id,
                "role": "assistant",
                "model": "deepseek-v4.1-flash",
                "content": content,
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": f"assistant-{message_id}",
        }
    )


def _tool_use_frame(message_id: str, call_id: str, name: str = "Bash") -> Any:
    """One assistant frame carrying a single ``tool_use`` — the wire shape the
    engine actually emits (one content block per frame)."""

    return _assistant(
        message_id, [{"type": "tool_use", "id": call_id, "name": name, "input": {}}]
    )


def _text_frame(message_id: str, text: str) -> Any:
    return _assistant(message_id, [{"type": "text", "text": text}])


def _thinking_frame(message_id: str, text: str) -> Any:
    return _assistant(
        message_id, [{"type": "thinking", "thinking": text, "signature": "s"}]
    )


def _project(
    projector: ClaudeMessageProjector, *frames: Any
) -> list[Any]:
    """Project each frame in order (the projector is the shared live instance),
    flattening the rows it mints for all of them."""

    rows: list[Any] = []
    for frame in frames:
        rows.extend(
            projector.tool_items_for_message(
                session=_session(), turn_id="turn-1", message=frame
            )
        )
    return rows


def _tool_result(tool_use_id: str, text: str = "ok") -> Any:
    return _parse(
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": tool_use_id,
                        "content": [{"type": "text", "text": text}],
                    }
                ],
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": f"result-{tool_use_id}",
        }
    )


def _declaration(item: Any) -> tuple[Any, Any]:
    return item.source.get("nativeMessageId"), item.source.get("blockIndex")


# --------------------------------------------------------------------------
# 1. the live route: real wire shape — one tool_use per frame, same message id
# --------------------------------------------------------------------------


def test_real_wire_form_declares_tool_count_not_zero() -> None:
    """The regression the fix closes (P0): two tool_use blocks of one message
    arrive as two frames, one block each. Before the fix each frame's
    ``content`` index was 0, so both rows declared ``blockIndex == 0`` and the
    server's sort degenerated to arrival order — the bug the fix removes. Now
    the rows declare the emission order, 0 then 1."""

    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1", name="Read"),
    )

    assert [item.source["itemId"] for item in rows] == ["call_0", "call_1"]
    assert [_declaration(item) for item in rows] == [
        ("msg_A", 0),
        ("msg_A", 1),
    ]


def test_interleaved_text_and_thinking_frames_do_not_shift_the_index() -> None:
    """The index counts tool_use blocks only. Text/thinking frames of the same
    message sit between the two calls in real transcripts; they must not push
    the second tool to a larger number — the tools' relative order is all the
    server needs, and a middle text block changes no such order."""

    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _text_frame("msg_A", "running two reads next"),
        _thinking_frame("msg_A", "which files"),
        _tool_use_frame("msg_A", "call_1", name="Read"),
    )

    assert [_declaration(item) for item in rows] == [
        ("msg_A", 0),
        ("msg_A", 1),
    ]


def test_emission_order_is_stable_across_projectors() -> None:
    """Two projectors see the same frame sequence: the declaration is stable."""

    frames = (
        _tool_use_frame("msg_A", "call_0"),
        _text_frame("msg_A", "…"),
        _tool_use_frame("msg_A", "call_1"),
    )
    first = _project(ClaudeMessageProjector(), *frames)
    second = _project(ClaudeMessageProjector(), *frames)
    assert [_declaration(item) for item in first] == [
        _declaration(item) for item in second
    ]


def test_three_tools_in_one_message_count_up() -> None:
    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1"),
        _tool_use_frame("msg_A", "call_2"),
    )
    assert [item.source["blockIndex"] for item in rows] == [0, 1, 2]


def test_separate_messages_count_independently() -> None:
    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1"),
        _tool_use_frame("msg_B", "call_2"),
    )
    assert [_declaration(item) for item in rows] == [
        ("msg_A", 0),
        ("msg_A", 1),
        ("msg_B", 0),
    ]


def test_repeated_tool_frame_keeps_its_index() -> None:
    """Idempotency: re-projecting the same tool_use frame (the same call
    published again, e.g. live then history) must not take a fresh number —
    otherwise a re-published row's index drifts and the group mis-sorts."""

    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_0"),  # same call, projected again
        _tool_use_frame("msg_A", "call_1"),
    )
    assert [_declaration(item) for item in rows] == [
        ("msg_A", 0),
        ("msg_A", 0),
        ("msg_A", 1),
    ]


def test_frame_without_message_id_declares_no_index() -> None:
    """A tool_use frame that names no assistant message id cannot be ordered
    against siblings, so it declares no index (宁缺勿假) — the server then
    leaves its group untouched rather than guess."""

    projector = ClaudeMessageProjector()
    frame = _parse(
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "deepseek-v4.1-flash",
                "content": [{"type": "tool_use", "id": "call_0", "name": "Bash", "input": {}}],
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
        }
    )
    rows = projector.tool_items_for_message(
        session=_session(), turn_id="turn-1", message=frame
    )
    assert _declaration(rows[0]) == (None, None)


# --------------------------------------------------------------------------


def test_result_created_row_still_declares_position() -> None:
    """The whole fix rests on this: the running frame did not persist, so the
    row is first materialised by the result frame — and it must still carry the
    message id and index, recovered from the pending call."""

    projector = ClaudeMessageProjector()
    # Two tools of msg_A; the second (call_1) is the one whose result lands.
    _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1", name="Read"),
    )

    rows = projector.tool_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_tool_result("call_1"),
    )
    assert len(rows) == 1
    assert rows[0].source["itemId"] == "call_1"
    assert rows[0].source["itemType"] == "tool_result"
    assert _declaration(rows[0]) == ("msg_A", 1)


def test_result_without_pending_call_declares_nothing() -> None:
    """An orphaned result (no recoverable call) degrades to no declaration —
    never a guessed one (宁缺勿假)."""

    projector = ClaudeMessageProjector()
    rows = projector.tool_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_tool_result("call_orphan"),
    )
    assert len(rows) == 1
    assert _declaration(rows[0]) == (None, None)


def test_result_can_also_recover_through_the_history_lookup() -> None:
    """A window whose tool_use frame fell outside it rebuilds the row from the
    lookup, and the declaration comes with it (same block-carry as usage).

    The lookup is keyed by ``tool_use_id`` (reader.py builds it that way); a
    fresh projector with only that lookup, seeing just the result frame, must
    still declare the position the tool_use frame carried.
    """

    source = ClaudeMessageProjector()
    _project(
        source,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1", name="Read"),
    )
    lookup = {call.block.tool_use_id: call for call in source._tool_calls.values()}
    assert set(lookup) == {"call_0", "call_1"}

    rebased = ClaudeMessageProjector(tool_call_lookup=lookup)
    rows = rebased.tool_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_tool_result("call_0"),
    )
    assert _declaration(rows[0]) == ("msg_A", 0)


# --------------------------------------------------------------------------
# 3. the history route
# --------------------------------------------------------------------------


def test_history_tool_rows_declare_message_and_index() -> None:
    items = _history_items_from_messages(
        _session(),
        (
            _tool_use_frame("msg_H", "call_0"),
            _tool_use_frame("msg_H", "call_1", name="Read"),
            _tool_result("call_0"),
            _tool_result("call_1"),
        ),
    )
    tool_rows = [item for item in items if item.type == "tool"]
    assert [item.source["itemId"] for item in tool_rows] == ["call_0", "call_1"]
    # Both keep the emission-order index their tool_use frame recorded.
    assert [_declaration(item) for item in tool_rows] == [
        ("msg_H", 0),
        ("msg_H", 1),
    ]


def test_history_result_frames_keep_the_tool_use_index() -> None:
    """The production symptom lives in the *declaration*, and the history
    rebuild must carry it through the result frames: the tool_use frames are
    projected first (recording the pending calls and their indices), the
    results then rebuild those rows. Each row stays pinned to the emission
    order, so the server — which does the actual ordering — has the truth even
    when the stored/arrival order is inverted."""

    items = _history_items_from_messages(
        _session(),
        (
            _tool_use_frame("msg_H", "call_0"),
            _tool_use_frame("msg_H", "call_1", name="Read"),
            _tool_result("call_1"),  # completes first
            _tool_result("call_0"),
        ),
    )
    rows = {item.source["itemId"]: item for item in items if item.type == "tool"}
    assert rows["call_0"].source["blockIndex"] == 0
    assert rows["call_1"].source["blockIndex"] == 1
    assert rows["call_0"].source["nativeMessageId"] == "msg_H"
    assert rows["call_1"].source["nativeMessageId"] == "msg_H"


# --------------------------------------------------------------------------
# 3b. the Agent-card fold path: a rewritten tool row keeps its declaration
# --------------------------------------------------------------------------


def _task_started(tool_use_id: str, task_id: str) -> Any:
    return _parse(
        {
            "type": "system",
            "subtype": "task_started",
            "task_id": task_id,
            "tool_use_id": tool_use_id,
            "description": "Add ring state",
            "subagent_type": "general-purpose",
            "is_backgrounded": True,
            "spawn_depth": 1,
            "task_type": "local_agent",
            "prompt": "You are working ... (elided)",
            "uuid": f"started-uuid-{tool_use_id}",
            "session_id": SESSION,
        }
    )


def _fold_agent(
    projector: ClaudeMessageProjector, session: ClaudeSession, frame: Any, tool_use_id: str
) -> Any:
    event = task_event_from_message(frame)
    assert event is not None
    overlay, status = agent_task_overlay_for_event(event)
    return projector.fold_agent_task_event(
        session, tool_use_id=tool_use_id, overlay=overlay, status=status
    )


def test_agent_card_fold_keeps_the_dispatch_position() -> None:
    """The regression this section pins: a task event rewrites the Agent tool
    row (``_fold_agent_task_card``), and the rewritten row must still declare
    the dispatch frame's in-message position — otherwise the row drops out of
    its message group and can render before the body, never self-healing
    (``_fold_agent_card`` records the position on the card; ``usage``'s role).

    The launch receipt is projected in between — a position-less frame — to
    prove a later fold cannot erase what the dispatch frame learned.
    """

    projector = ClaudeMessageProjector()
    session = _session()
    # The Agent call is the second tool of its message; a thinking frame came
    # first but does not affect the tool count, so the Agent sits at index 1.
    items = _project(
        projector,
        _thinking_frame("msg_agent", "spawn a subagent"),
        _tool_use_frame("msg_agent", "call_before"),
        _assistant(
            "msg_agent",
            [
                {
                    "type": "tool_use",
                    "id": "call_agent",
                    "name": "Agent",
                    "input": {"description": "x", "prompt": "y"},
                }
            ],
        ),
    )
    agent_item = next(i for i in items if i.source["itemId"] == "call_agent")
    assert _declaration(agent_item) == ("msg_agent", 1)

    # The launch receipt frame carries neither declaration; folding it must not
    # wipe the position the dispatch frame recorded on the card.
    projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_tool_result("call_agent"),
    )

    folded = _fold_agent(projector, session, _task_started("call_agent", "task_1"), "call_agent")
    assert folded.source["itemId"] == "call_agent"
    assert _declaration(folded) == ("msg_agent", 1)


def test_agent_and_plain_rows_still_group_by_index_after_fold() -> None:
    """End-to-end shape: one message holds an Agent row and a plain row. After
    the Agent row is folded by a task event, both rows still declare the same
    message and their true positions, so the server can group and order them by
    truth. The declarations come from the real wire shape (two frames)."""

    projector = ClaudeMessageProjector()
    session = _session()
    rows = _project(
        projector,
        _assistant(
            "msg_two",
            [
                {
                    "type": "tool_use",
                    "id": "call_agent",
                    "name": "Agent",
                    "input": {"description": "x", "prompt": "y"},
                }
            ],
        ),
        _tool_use_frame("msg_two", "call_bash"),
    )
    assert {item.source["itemId"]: _declaration(item) for item in rows} == {
        "call_agent": ("msg_two", 0),
        "call_bash": ("msg_two", 1),
    }

    folded = _fold_agent(projector, session, _task_started("call_agent", "task_2"), "call_agent")
    assert _declaration(folded) == ("msg_two", 0)
    # The Agent row and the plain row still share their message-group key.
    plain = next(i for i in rows if i.source["itemId"] == "call_bash")
    assert folded.source["nativeMessageId"] == plain.source["nativeMessageId"]


# --------------------------------------------------------------------------
# 4. the wire shape (source field whitelist)
# --------------------------------------------------------------------------


def test_source_payload_carries_the_declaration() -> None:
    projector = ClaudeMessageProjector()
    rows = _project(
        projector,
        _tool_use_frame("msg_A", "call_0"),
        _tool_use_frame("msg_A", "call_1", name="Read"),
    )
    payload = _timeline_source_payload(rows[1])
    assert payload["nativeMessageId"] == "msg_A"
    assert payload["blockIndex"] == 1


def test_source_payload_omits_absent_declaration() -> None:
    """A frame that declares neither must not leak ``None`` placeholders."""

    projector = ClaudeMessageProjector()
    rows = projector.tool_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_tool_result("call_orphan"),
    )
    payload = _timeline_source_payload(rows[0])
    assert "nativeMessageId" not in payload
    assert "blockIndex" not in payload
