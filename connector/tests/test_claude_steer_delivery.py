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

from connector.runtimes.claude.domain.capabilities import (
    ClaudeCapabilityContext,
    claude_session_capabilities,
)
from test_claude_runtime import _RecordingHost, _runtime

STEER = "STEER: say BANANA-42"


class _SteerClaudeClient:
    """Scripted SDK client: tool frame -> wait for steer -> steer reply."""

    def __init__(self, *, echo_prompt: bool = False) -> None:
        self.options = None
        self.connected = False
        self.disconnected = False
        self.queries: list[str] = []
        self.priorities: list[str | None] = []
        self.first_query = asyncio.Event()
        self.tool_running = asyncio.Event()
        self.steer_received = asyncio.Event()
        self.steer_echo_allowed = asyncio.Event()
        self.steer_uuid: str | None = None
        self.steer_text: str | None = None
        self.prompt_uuid: str | None = None
        self.prompt_text: str | None = None
        self.echo_prompt = echo_prompt

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
            self.steer_text = content
            self.steer_received.set()
        else:
            self.prompt_uuid = first.get("uuid")
            self.prompt_text = content
            self.first_query.set()

    def receive_response(self):
        async def frames():
            await self.first_query.wait()
            if self.echo_prompt and self.prompt_uuid and self.prompt_text:
                # AA runs the CLI with `replay-user-messages`; the prompt comes
                # back before the tool frame.
                yield UserMessage(content=self.prompt_text, uuid=self.prompt_uuid)
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
            # The test decides when the runtime "reads" the steer, so it can
            # assert nothing was published before the echo.
            await self.steer_echo_allowed.wait()
            # With `replay-user-messages` (AA's CLI args) the steer message
            # comes back with its own uuid, inside the same turn.
            yield UserMessage(content=self.steer_text or STEER, uuid=self.steer_uuid)
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
    execution = session.execution
    assert execution is not None

    steered = await runtime.steer_turn(
        "sess_steer",
        "claude_session_0",
        STEER,
        client_message_id="client_steer_1",
    )
    assert steered.ok is True
    assert steered.result["steered"] is True
    assert steered.result["turnId"] == started.result["turnId"]
    # Nothing reached the transcript yet: the row is published only when the
    # runtime echoes the message back (i.e. when it read it).
    assert not [
        item for item in host.timeline_item_upserts
        if item.source.get("itemType") == "steeringUserMessage"
    ]
    assert session.pending_steers[client.steer_uuid] == (
        STEER, "client_steer_1",
    )

    client.steer_echo_allowed.set()
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
    # One row only: published on the echo, under the turn that read it.
    assert len(steer_rows) == 1
    assert len(prompt_rows) == 1
    assert reply_rows, "the steer reply must be published"
    # The row's native id is the uuid actually sent to the SDK: the echo only
    # confirms when those two stay in lockstep.
    assert steer_rows[0].source.get("itemId") == client.steer_uuid
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
    # The same-turn echo consumed the pending registration.
    assert session.pending_steers == {}


def test_claude_steer_stopped_before_echo_leaves_no_row() -> None:
    asyncio.run(_test_claude_steer_stopped_before_echo_leaves_no_row())


async def _test_claude_steer_stopped_before_echo_leaves_no_row() -> None:
    host = _RecordingHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_stop", "claude_session_0", "hello",
        client_message_id="client_msg_stop",
    )
    assert started.ok is True
    session = runtime._sessions["sess_stop"]
    task = session.active_task
    assert task is not None
    await asyncio.wait_for(client.tool_running.wait(), 5)

    steered = await runtime.steer_turn(
        "sess_stop", "claude_session_0", "never read",
        client_message_id="client_steer_stop",
    )
    assert steered.ok is True
    assert session.pending_steers

    await runtime.interrupt_session("sess_stop", reason="manual")
    try:
        await asyncio.wait_for(task, 8)
    except asyncio.CancelledError:
        pass

    # The stopped turn must not carry a steer row: the row only exists once
    # the runtime echoes the message back.
    assert not [
        item for item in host.timeline_item_upserts
        if item.source.get("itemType") == "steeringUserMessage"
    ]
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


def test_claude_session_capabilities_gate_steer_on_running() -> None:
    def steer(status: str, active: bool):
        caps = claude_session_capabilities(
            ClaudeCapabilityContext(
                connector_id="conn_test",
                revision=1,
                session_id="sess_caps",
                has_active_turn=active,
                status=status,
            )
        )
        return next(
            item
            for item in caps.capabilities
            if item.capability_id == "session.steer"
        )

    running = steer("running", True)
    assert running.supported is True
    assert running.available is True
    assert running.unavailable_reason is None

    # A pending permission prompt or question is still the same turn.
    for status in ("waiting", "waiting_approval"):
        pending = steer(status, True)
        assert pending.supported is True
        assert pending.available is True
        assert pending.unavailable_reason is None

    stopping = steer("stopping", True)
    assert stopping.available is False
    assert stopping.unavailable_reason == "turn_not_steerable"

    idle = steer("idle", False)
    assert idle.available is False
    assert idle.unavailable_reason == "no_active_turn"


def test_claude_steer_is_refused_once_the_response_settled() -> None:
    asyncio.run(_test_claude_steer_is_refused_once_the_response_settled())


async def _test_claude_steer_is_refused_once_the_response_settled() -> None:
    host = _RecordingHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_settled", "claude_session_0", "hello",
        client_message_id="client_msg_settled",
    )
    assert started.ok is True
    session = runtime._sessions["sess_settled"]
    task = session.active_task
    assert task is not None
    await asyncio.wait_for(client.tool_running.wait(), 5)

    response = session.execution.client
    # 1. A reconciler-owned response must not take a user message.
    response.maintenance = True
    refused = await runtime.steer_turn(
        "sess_settled", "claude_session_0", "late steer",
        client_message_id="client_steer_maint",
    )
    assert refused.ok is False
    assert refused.code == "claude_no_active_turn"
    response.maintenance = False

    # 2. A response that already released its turn must refuse too. Checked on
    # the pure guard so the scripted turn is not disturbed.
    from connector.runtimes.claude.turns.actions import ClaudeTurnActionHandler

    released = asyncio.Event()
    released.set()
    assert ClaudeTurnActionHandler._client_accepts_steer(
        SimpleNamespace(released=released)
    ) is False
    assert ClaudeTurnActionHandler._client_accepts_steer(
        SimpleNamespace(
            released=asyncio.Event(),
            maintenance=False,
            terminal_received=False,
            discard=False,
        )
    ) is True

    # Let the scripted turn finish so the test leaves nothing running.
    client.steer_received.set()
    client.steer_echo_allowed.set()
    await asyncio.wait_for(task, 10)


def test_claude_steer_echo_does_not_rebind_the_prompt_when_text_matches() -> None:
    asyncio.run(_test_claude_steer_echo_does_not_rebind_the_prompt_when_text_matches())


async def _test_claude_steer_echo_does_not_rebind_the_prompt_when_text_matches() -> None:
    """Same text as the prompt: the echo must still be consumed as a steer.

    Without the uuid branch, the generic user-echo path mistakes the steer for
    the prompt's own replay and warns / rebinds the prompt's client message.
    """

    from loguru import logger

    warnings: list[str] = []
    sink = logger.add(lambda message: warnings.append(str(message)), level="WARNING")
    try:
        host = _RecordingHost()
        client = _SteerClaudeClient(echo_prompt=True)
        runtime = _runtime(host=host, client=client)

        started = await runtime.start_turn(
            "sess_same_text",
            "claude_session_0",
            "hello",
            client_message_id="client_same_prompt",
        )
        assert started.ok is True
        session = runtime._sessions["sess_same_text"]
        task = session.active_task
        assert task is not None
        await asyncio.wait_for(client.tool_running.wait(), 5)

        # The steer carries exactly the prompt's text.
        steered = await runtime.steer_turn(
            "sess_same_text",
            "claude_session_0",
            "hello",
            client_message_id="client_same_steer",
        )
        assert steered.ok is True
        client.steer_echo_allowed.set()

        await asyncio.wait_for(task, 10)
    finally:
        logger.remove(sink)

    rows = [item for item in host.timeline_item_upserts if item.role == "user"]
    by_client = {
        item.source.get("clientMessageId"): item for item in rows
    }
    assert set(by_client) == {"client_same_prompt", "client_same_steer"}
    assert (
        by_client["client_same_steer"].source.get("itemType")
        == "steeringUserMessage"
    )
    assert all(item.turn_id == started.result["turnId"] for item in rows)
    assert not [
        warning
        for warning in warnings
        if "prompt uuid was not adopted" in warning
    ]


class _FailSteerPublishHost(_RecordingHost):
    """Refuses the steer row's upsert (server/DB unavailable at that moment)."""

    async def timeline_item_upsert(self, item) -> None:
        if item.source.get("event") == "claude.turn.steer":
            raise RuntimeError("publish failed")
        await super().timeline_item_upsert(item)


def test_claude_steer_echo_publish_failure_keeps_the_turn_alive() -> None:
    asyncio.run(_test_claude_steer_echo_publish_failure_keeps_the_turn_alive())


async def _test_claude_steer_echo_publish_failure_keeps_the_turn_alive() -> None:
    host = _FailSteerPublishHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_publish_fail", "claude_session_0", "hello",
        client_message_id="client_msg_pf",
    )
    assert started.ok is True
    session = runtime._sessions["sess_publish_fail"]
    task = session.active_task
    assert task is not None
    await asyncio.wait_for(client.tool_running.wait(), 5)

    steered = await runtime.steer_turn(
        "sess_publish_fail", "claude_session_0", "echoed but not recorded",
        client_message_id="client_steer_pf",
    )
    assert steered.ok is True
    client.steer_echo_allowed.set()

    # The row write fails at echo time; the turn must still settle normally.
    await asyncio.wait_for(task, 10)
    assert len(host.session_turn_ends) == 1
    assert host.session_turn_ends[0]["turn_id"] == started.result["turnId"]
    assert not [
        item for item in host.timeline_item_upserts
        if item.source.get("event") == "claude.turn.steer"
    ]


def test_pending_steers_stay_bounded_and_are_consumed() -> None:
    from connector.runtimes.claude.domain.session import ClaudeSession

    session = ClaudeSession(session_id="sess_recent")
    for index in range(40):
        session.remember_steer(f"steer_{index}", f"text_{index}", f"client_{index}")
    assert len(session.pending_steers) == 32
    assert list(session.pending_steers)[0] == "steer_8"
    assert session.take_steer("steer_39") == ("text_39", "client_39")
    assert session.take_steer("steer_missing") is None


def test_claude_steer_rejects_attachments() -> None:
    asyncio.run(_test_claude_steer_rejects_attachments())


async def _test_claude_steer_rejects_attachments() -> None:
    host = _RecordingHost()
    client = _SteerClaudeClient()
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_attachments", "claude_session_0", "hello",
        client_message_id="client_msg_att",
    )
    assert started.ok is True
    session = runtime._sessions["sess_attachments"]
    task = session.active_task
    assert task is not None
    await asyncio.wait_for(client.tool_running.wait(), 5)

    refused = await runtime.steer_turn(
        "sess_attachments", "claude_session_0", "with a file",
        attachments=(object(),),  # type: ignore[arg-type]
        client_message_id="client_steer_att",
    )
    assert refused.ok is False
    assert refused.code == "claude_steer_attachments_unsupported"

    client.steer_received.set()
    client.steer_echo_allowed.set()
    await asyncio.wait_for(task, 10)
