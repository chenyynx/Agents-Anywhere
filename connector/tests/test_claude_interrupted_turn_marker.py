"""The durable "this turn was interrupted" fact (pp 2026-11-14).

Why this file exists
--------------------
A user stop has no faithful row-level status to leave behind: the CLI's aborted
tool results land ``failed``, an interrupted thinking block lands ``done``, and
the connector's turn-end notification describes only the process that saw the
stop. So the official 「Claude 的回复已中断。」 notice had nothing durable to read
on a cold open, another device, or after a relaunch — the client had to have
been the one that pressed stop.

The CLI itself persists the cause as its own user row,
``[Request interrupted by user]`` / ``[Request interrupted by user for tool
use]``. This projection turns that marker into one turn-level content flag on
the turn's last main-agent row (``content.turnInterrupted``): content, not item
metadata, because the server's change detection hashes
``type/status/role/content`` only. The live settle stamps the same key from the
cause it already knows, so the fact reaches clients before the transcript sync
does; a history rebuild re-derives it from the marker and cannot lose it.

The flag rides the notice's anchor row by construction — the client shows the
card under the unit that draws that row — so no extra timeline row is added.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import (
    _BlockingClaudeClient,
    _RecordingHost,
    _gateway_config,
    _runtime,
    _wait_until,
)

from connector.runtime_protocol import (
    TURN_INTERRUPTED_CONTENT_KEY,
    RuntimeTimelineItem,
    timeline_content_hash,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    _history_turn_id,
)
from connector.runtimes.claude.timeline.messages import (
    stable_message_item_id,
    stable_tool_item_id,
)

SESSION_ID = "sess_interrupt_marker"
EXTERNAL_SESSION_ID = "native-interrupt-marker"
TOOL_USE_ID = "call_00_interrupt_probe_000000000001"
PROMPT_UUID = "11111111-2222-3333-4444-555555555555"
INTERRUPT_TEXT = "[Request interrupted by user]"
INTERRUPT_TOOL_TEXT = "[Request interrupted by user for tool use]"


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
    )


def _user(uuid: str, text: str) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        message={"role": "user", "content": text},
    )


def _assistant_text(uuid: str, text: str, *, message_id: str = "msg_text") -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        message={"role": "assistant", "id": message_id, "content": text},
    )


def _assistant_tool(uuid: str, *, message_id: str = "msg_tool") -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        message={
            "role": "assistant",
            "id": message_id,
            "content": [
                {
                    "type": "tool_use",
                    "id": TOOL_USE_ID,
                    "name": "Bash",
                    "input": {"command": "sleep 30"},
                }
            ],
        },
    )


def _assistant_text_and_tool(
    uuid: str,
    text: str,
    *,
    message_id: str = "msg_tool",
) -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        message={
            "role": "assistant",
            "id": message_id,
            "content": [
                {"type": "text", "text": text},
                {
                    "type": "tool_use",
                    "id": TOOL_USE_ID,
                    "name": "Bash",
                    "input": {"command": "sleep 30"},
                },
            ],
        },
    )


def _aborted_tool_result(uuid: str) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        message={
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": TOOL_USE_ID,
                    "content": "The user doesn't want to proceed with this tool use.",
                    "is_error": True,
                }
            ],
        },
    )


def _interrupt_marker(text: str = INTERRUPT_TEXT, uuid: str = "interrupt-marker") -> Any:
    return _user(uuid, text)


def _flagged(items: tuple[Any, ...]) -> list[Any]:
    return [
        item
        for item in items
        if item.content.get(TURN_INTERRUPTED_CONTENT_KEY) is True
    ]


def test_history_projection_marks_the_stopped_turns_last_main_row() -> None:
    session = _session()
    messages = (
        _user(PROMPT_UUID, "run it"),
        _assistant_tool("assistant-tool"),
        _aborted_tool_result("tool-result"),
        _interrupt_marker(),
    )
    items = _history_items_from_messages(session, messages)

    flagged = _flagged(items)
    assert len(flagged) == 1, [item.id for item in flagged]
    anchor = flagged[0]
    assert anchor.id == stable_tool_item_id(session, TOOL_USE_ID)
    assert anchor.turn_id == _history_turn_id(SESSION_ID, PROMPT_UUID)
    # The flag is part of the hashed content, not free metadata, so the
    # server sees the row as changed and publishes it.
    assert anchor.content_hash == timeline_content_hash(
        item_type=anchor.type,
        status=anchor.status,
        role=anchor.role,
        content=anchor.content,
    )
    # The aborted result keeps its own truthful status; the turn-level fact is
    # the only thing added.
    assert anchor.status == "failed"


def test_history_projection_closes_a_tool_without_a_result() -> None:
    """A stop discards the aborted tool_result; the row must not stay running.

    Device 2026-11-14: after an interrupt, a later resync republished the
    failed tool row as `running` (the transcript holds the tool_use with no
    result), so the settled step row came back to life while a queued message
    was being sent.
    """

    session = _session()
    messages = (
        _user(PROMPT_UUID, "run it"),
        _assistant_tool("assistant-tool"),
        _interrupt_marker(INTERRUPT_TOOL_TEXT),
    )
    items = _history_items_from_messages(session, messages)

    flagged = _flagged(items)
    assert len(flagged) == 1, [item.id for item in flagged]
    assert flagged[0].id == stable_tool_item_id(session, TOOL_USE_ID)
    assert flagged[0].status == "failed"
    assert not any(item.status == "running" for item in items)


def test_history_projection_anchors_a_text_plus_tool_turn_on_the_tool_row() -> None:
    """The card must follow the step group, not sit between text and tool.

    Device 2026-11-14: a message with text + a Bash call, stopped while the
    command ran, showed 「Claude 的回复已中断。」 above the running-command
    row because the stamp had landed on the message text row. The client
    draws the text block first and the tool block after it, so the tool row
    is the turn's last drawn row.
    """

    session = _session()
    messages = (
        _user(PROMPT_UUID, "run it"),
        _assistant_text_and_tool("assistant-tool", "I'll run it"),
        _aborted_tool_result("tool-result"),
        _interrupt_marker(INTERRUPT_TOOL_TEXT),
    )
    items = _history_items_from_messages(session, messages)

    flagged = _flagged(items)
    assert len(flagged) == 1, [item.id for item in flagged]
    assert flagged[0].id == stable_tool_item_id(session, TOOL_USE_ID)
    assert flagged[0].turn_id == _history_turn_id(SESSION_ID, PROMPT_UUID)


def test_history_projection_marks_a_text_only_turn_on_its_last_message() -> None:
    session = _session()
    messages = (
        _user(PROMPT_UUID, "talk to me"),
        _assistant_text("assistant-text", "partial answer"),
        _interrupt_marker(INTERRUPT_TOOL_TEXT),
    )
    items = _history_items_from_messages(session, messages)

    flagged = _flagged(items)
    assert len(flagged) == 1
    assert flagged[0].id == stable_message_item_id(session, "msg_text")
    assert flagged[0].status == "done"


def test_a_window_without_the_marker_uses_the_session_fact() -> None:
    """An incremental window can hold the rows but not the marker."""

    session = _session()
    turn_id = _history_turn_id(SESSION_ID, PROMPT_UUID)
    messages = (
        _user(PROMPT_UUID, "run it"),
        _assistant_tool("assistant-tool"),
        _aborted_tool_result("tool-result"),
    )
    items = _history_items_from_messages(
        session,
        messages,
        interrupted_turns={turn_id},
    )

    flagged = _flagged(items)
    assert len(flagged) == 1
    assert flagged[0].id == stable_tool_item_id(session, TOOL_USE_ID)
    assert flagged[0].turn_id == turn_id


def test_history_projection_leaves_a_turn_without_the_marker_unmarked() -> None:
    session = _session()
    messages = (
        _user(PROMPT_UUID, "run it"),
        _assistant_tool("assistant-tool"),
        _aborted_tool_result("tool-result"),
    )
    items = _history_items_from_messages(session, messages)
    assert _flagged(items) == []


def test_history_projection_marks_only_the_interrupted_turn() -> None:
    session = _session()
    second_uuid = "99999999-8888-7777-6666-555555555555"
    messages = (
        _user(PROMPT_UUID, "first"),
        _assistant_text("assistant-one", "first answer", message_id="msg_one"),
        _user(second_uuid, "second"),
        _assistant_text("assistant-two", "second answer", message_id="msg_two"),
        _interrupt_marker(),
    )
    items = _history_items_from_messages(session, messages)

    flagged = _flagged(items)
    assert len(flagged) == 1
    assert flagged[0].id == stable_message_item_id(session, "msg_two")
    assert flagged[0].turn_id == _history_turn_id(SESSION_ID, second_uuid)
    assert flagged[0].turn_id != _history_turn_id(SESSION_ID, PROMPT_UUID)


def test_live_user_stop_stamps_the_turn_before_the_history_sync() -> None:
    """A stop reaches clients in the turn's own push, not only on a cold read."""

    async def run() -> None:
        host = _RecordingHost()
        release = asyncio.Event()
        client = _BlockingClaudeClient(release)
        runtime = _runtime(host=host, client=client, config=_gateway_config())
        try:
            result = await runtime.start_turn(
                "sess_interrupt", "native_interrupt", "wait"
            )
            turn_id = result.result["turnId"]
            await _wait_until(lambda: bool(client.queries))

            task = runtime._sessions["sess_interrupt"].active_task
            await runtime.interrupt_session("sess_interrupt", reason="user")
            await asyncio.gather(task, return_exceptions=True)

            stamped = [
                item
                for item in host.timeline_item_upserts
                if item.content.get(TURN_INTERRUPTED_CONTENT_KEY) is True
            ]
            assert len(stamped) == 1, [item.id for item in stamped]
            assert stamped[0].turn_id == turn_id
            assert stamped[0].role == "user"
            # The turn really ended by the user's stop.
            assert [
                end["outcome"]
                for end in host.session_turn_ends
                if end["turn_id"] == turn_id
            ] == ["interrupted"]
        finally:
            release.set()
            await runtime.stop()

    asyncio.run(run())


def test_live_user_stop_closes_a_running_tool_in_the_same_push() -> None:
    """The failure mark must not wait for the post-stop history sync.

    Device 2026-11-14: the notice appeared at the stop, but the step-row
    triangle only after the sync re-read the transcript (~3 s later). The
    stop discards the CLI's aborted `tool_result` frame, so the live push has
    to carry the terminal status itself.
    """

    async def run() -> None:
        host = _RecordingHost()
        release = asyncio.Event()
        client = _BlockingClaudeClient(release)
        runtime = _runtime(host=host, client=client, config=_gateway_config())
        try:
            result = await runtime.start_turn(
                "sess_interrupt", "native_interrupt", "wait"
            )
            turn_id = result.result["turnId"]
            await _wait_until(lambda: bool(client.queries))
            session = runtime._sessions["sess_interrupt"]
            tool = RuntimeTimelineItem(
                id="tool_running",
                session_id="sess_interrupt",
                type="tool",
                status="running",
                role="tool",
                turn_id=turn_id,
                order_seq=2,
                content={"command": "sleep 30"},
                content_hash="sha256:running",
            )
            session.timeline_items[tool.id] = tool

            task = session.active_task
            await runtime.interrupt_session("sess_interrupt", reason="user")
            await asyncio.gather(task, return_exceptions=True)

            published = {item.id: item for item in host.timeline_item_upserts}
            closed = published["tool_running"]
            assert closed.status == "failed"
            assert closed.content.get(TURN_INTERRUPTED_CONTENT_KEY) is True
            # Closed first, then stamped: both changes ride one push.
            assert closed.revision == tool.revision + 2
        finally:
            release.set()
            await runtime.stop()

    asyncio.run(run())


def test_runtime_stop_does_not_stamp_a_turn_as_user_interrupted() -> None:
    """A connector shutdown is not the official user-stop notice."""

    async def run() -> None:
        host = _RecordingHost()
        release = asyncio.Event()
        client = _BlockingClaudeClient(release)
        runtime = _runtime(host=host, client=client, config=_gateway_config())
        try:
            await runtime.start_turn("sess_interrupt", "native_interrupt", "wait")
            await _wait_until(lambda: bool(client.queries))
            await asyncio.wait_for(runtime.stop(), 2)
            assert [
                item
                for item in host.timeline_item_upserts
                if item.content.get(TURN_INTERRUPTED_CONTENT_KEY) is True
            ] == []
        finally:
            release.set()
            await runtime.stop()

    asyncio.run(run())
