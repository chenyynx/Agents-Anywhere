"""Mid-turn steering for the Claude runtime (2026-11-17).

The message goes out with `priority: "next"` and is read by Claude inside the
running turn (verified against the bundled CLI 2.1.319 with the real SDK).
These tests pin the CONNECTOR half:

- the prompt still goes out as `later`; the steer as `next`;
- the steer user row is published under the RUNNING turn, with its own uuid
  and `itemType: steeringUserMessage`, and carries the client message id so
  the sender's optimistic bubble upgrades in place;
- the SDK's echo of that message is consumed as a confirmation, never
  republished as a second row (and never mistaken for the prompt replay);
- the turn still settles once, on the prompt's turn id;
- a steer with no running turn is refused instead of minting a turn.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

from claude_agent_sdk import AssistantMessage, UserMessage

from test_claude_runtime import _RecordingHost, _runtime

STEER = "STEER: say BANANA-42"


class _SteerClaudeClient:
    """Scripted SDK client: tool frame -> wait for steer -> steer reply."""

    def __init__(self) -> None:
        self.options = None
        self.connected = False
        self.disconnected = False
        self.queries: list[str] = []
        self.priorities: list[str | None] = []
        self.first_query = asyncio.Event()
        self.tool_running = asyncio.Event()
        self.steer_received = asyncio.Event()
        self.steer_uuid: str | None = None

    async def connect(self) -> None:
        self.connected = True

    async def disconnect(self) -> None:
        self.disconnected = True

    async def query(self, prompt) -> None:
        if isinstance(prompt, str):
            self.queries.append(prompt)
            self.priorities.append(None)
            self.first_query.set()
            return
        first = [message async for message in prompt][0]
        content = first["message"]["content"]
        priority = first.get("priority")
        self.queries.append(content)
        self.priorities.append(priority)
        if priority == "next":
            self.steer_uuid = first.get("uuid")
            self.steer_received.set()
        else:
            self.first_query.set()

    def receive_response(self):
        async def frames():
            await self.first_query.wait()
            yield AssistantMessage(
                uuid="assistant_tool",
                session_id="claude_session_1",
                model="claude-test",
                content=[
                    {
                        "type": "tool_use",
                        "id": "toolu_sleep",
                        "name": "Bash",
                        "input": {"command": "sleep 12"},
                    }
                ],
            )
            self.tool_running.set()
            # The turn is parked on a running tool: the window a steering
            # message is supposed to reach Claude in.
            await self.steer_received.wait()
            # With `replay-user-messages` (AA's CLI args) the steer message
            # comes back with its own uuid, inside the same turn.
            yield UserMessage(content=STEER, uuid=self.steer_uuid)
            yield AssistantMessage(
                uuid="assistant_steer",
                session_id="claude_session_1",
                model="claude-test",
                content=[{"type": "text", "text": "BANANA-42"}],
            )
            yield SimpleNamespace(
                type="result",
                session_id="claude_session_1",
                is_error=False,
            )

        return frames()


def test_claude_steer_stays_in_the_running_turn() -> None:
    asyncio.run(_test_claude_steer_stays_in_the_running_turn())


async def _test_claude_steer_stays_in_the_running_turn() -> None:
    host = _RecordingHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_steer",
        "claude_session_0",
        "hello",
        client_message_id="client_msg_1",
    )
    assert started.ok is True
    session = runtime._sessions["sess_steer"]
    task = session.active_task
    assert task is not None

    await asyncio.wait_for(client.tool_running.wait(), 5)

    steered = await runtime.steer_turn(
        "sess_steer",
        "claude_session_0",
        STEER,
        client_message_id="client_steer_1",
    )
    assert steered.ok is True
    assert steered.result["steered"] is True
    assert steered.result["turnId"] == started.result["turnId"]

    await asyncio.wait_for(task, 10)

    # The steer went out as `next`; the prompt went out as `later`.
    assert client.queries == ["hello", STEER]
    assert client.priorities == ["later", "next"]

    turn_id = started.result["turnId"]
    items = host.timeline_item_upserts
    steer_rows = [
        item
        for item in items
        if item.role == "user" and item.content.get("text") == STEER
    ]
    prompt_rows = [
        item
        for item in items
        if item.role == "user" and item.content.get("text") == "hello"
    ]
    reply_rows = [
        item
        for item in items
        if item.role == "assistant" and item.content.get("text") == "BANANA-42"
    ]
    # One row only: the submit-time publish, not a second one on the echo.
    assert len(steer_rows) == 1
    assert len(prompt_rows) == 1
    assert reply_rows, "the steer reply must be published"
    assert steer_rows[0].source.get("itemType") == "steeringUserMessage"
    assert steer_rows[0].source.get("clientMessageId") == "client_steer_1"
    # Everything the turn published shares the prompt turn id: no second turn.
    assert all(
        item.turn_id == turn_id for item in items if item.turn_id is not None
    )
    assert steer_rows[0].turn_id == turn_id

    assert len(host.session_turn_ends) == 1
    assert host.session_turn_ends[0]["turn_id"] == turn_id
    assert host.session_state_updates[-1]["status"] == "idle"
    assert session.execution is None


def test_claude_steer_without_active_turn_is_refused() -> None:
    asyncio.run(_test_claude_steer_without_active_turn_is_refused())


async def _test_claude_steer_without_active_turn_is_refused() -> None:
    host = _RecordingHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    result = await runtime.steer_turn(
        "sess_missing",
        "claude_session_0",
        "late steer",
        client_message_id="client_steer_late",
    )
    assert result.ok is False
    assert result.code == "claude_no_active_turn"
    assert client.queries == []
