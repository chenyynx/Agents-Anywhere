"""The ghost scheduled turn: repro, chrome governance and the circuit breaker.

Why this file exists
--------------------
The production ghost (AA session sess_FqgnOrefq2I8Cw / native session
84275e9e, 2026-10-02 05:52:43 UTC) ran a native ``/compact`` turn normally;
2ms after that turn completed, a second turn was minted out of silence, never
saw a terminal result, and held ``session.execution`` forever — the composer
stayed disabled and the session could not be recovered short of a connector
restart. The trigger chain (hook replays, caveat/command echoes, handshakes)
cannot be enumerated: user environments write any hook in any shape. The main
defense is therefore invariant-shaped (the circuit breaker); the chrome
predicate is only flak-reduction.

Every fixture is a REAL claude_agent_sdk message shape — parsed through
``parse_message`` or built from the SDK's own dataclasses. Hand-built
lookalikes produced the P0 the realwire file documents.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtime_protocol import RuntimeConfig
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk.connection import _is_wire_chrome
from connector.runtimes.claude.timeline.markers import (
    claude_compact_event,
    is_compaction_control_message,
)
from connector.runtimes.claude.timeline.messages import (
    is_local_command_chrome,
    is_synthetic_control_message,
)
from connector.runtimes.claude.turns import lifecycle
from test_claude_runtime import (
    _FakeHookMatcher,
    _RecordingHost,
    _ScheduledClaudeClient,
    _default_sdk,
)

INCIDENT_SESSION = "84275e9e-1baa-48b9-a6e8-17cf64b953e7"

STATUS_RUNNING = {
    "type": "system",
    "subtype": "status",
    "status": "running",
    "session_id": INCIDENT_SESSION,
}

HOOK_STARTED = {
    "type": "system",
    "subtype": "hook_started",
    "hook_event": "SessionStart",
    "hook_name": "SessionStart:compact",
    "session_id": INCIDENT_SESSION,
    "uuid": "767c8e9a-probe-hook-start",
}

HOOK_RESPONSE = {
    "type": "system",
    "subtype": "hook_response",
    "exit_code": 0,
    "outcome": "success",
    "stdout": "=== 当前分支: ? ===\n",
    "session_id": INCIDENT_SESSION,
    "uuid": "767c8e9a-probe-hook-response",
}

COMPACT_BOUNDARY = {
    "type": "system",
    "subtype": "compact_boundary",
    "compactMetadata": {},
    "session_id": INCIDENT_SESSION,
    "uuid": "767c8e9a-probe-compact-boundary",
}

# The two phantom user bubbles from pp's screenshot (verbatim transcript):
COMMAND_ECHO = {
    "type": "user",
    "message": {
        "role": "user",
        "content": (
            "<command-name>/compact</command-name>\n"
            "            <command-message>compact</command-message>\n"
            "            <command-args></command-args>"
        ),
    },
    "uuid": "93b03c34-echo-command-name",
    "session_id": INCIDENT_SESSION,
}

STDOUT_ECHO = {
    "type": "user",
    "message": {
        "role": "user",
        "content": "<local-command-stdout>Compacted </local-command-stdout>",
    },
    "uuid": "93b03c34-echo-stdout",
    "session_id": INCIDENT_SESSION,
}

CAVEAT = {
    "type": "user",
    "message": {
        "role": "user",
        "content": (
            "<local-command-caveat>The command below was run directly in "
            "Claude Code, not sent to you as a request, and its output goes "
            "to the CLI, not to the model.</local-command-caveat>"
        ),
    },
    "isMeta": True,
    "uuid": "93b03c34-echo-caveat",
    "session_id": INCIDENT_SESSION,
}

RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "num_turns": 0,
    "session_id": INCIDENT_SESSION,
    "result": "",
    "duration_ms": 14120,
    "duration_api_ms": 13997,
    "total_cost_usd": 0.0,
}

# A real assistant reply, built from the SDK's own dataclasses so it cannot
# drift from the shape the reader actually sees.
ASSISTANT_REPLY = {
    "type": "assistant",
    "message": {
        "role": "assistant",
        "model": "claude-opus-5",
        "content": [{"type": "text", "text": "half an answer"}],
    },
    "uuid": "assistant-hanging",
    "session_id": INCIDENT_SESSION,
}

# The frames the CLI replayed on the wire right after the /compact turn settled,
# in the order the connector's reader saw them.
INCIDENT_REPLAY = (STATUS_RUNNING, HOOK_STARTED, HOOK_RESPONSE, COMMAND_ECHO, STDOUT_ECHO)


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


# --------------------------------------------------------------------------
# 1. Reader-side governance: silence chrome never mints a turn
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "frame",
    [STATUS_RUNNING, HOOK_STARTED, HOOK_RESPONSE, COMMAND_ECHO, STDOUT_ECHO, CAVEAT],
    ids=lambda frame: f"{frame['type']}:{frame.get('subtype', 'user')}",
)
def test_replayed_chrome_never_looks_like_a_scheduled_wakeup(
    frame: dict[str, Any],
) -> None:
    """Post-command replay frames must not mint an execution from silence."""

    assert _is_wire_chrome(_parse(frame))


def test_wire_chrome_passes_a_real_reply_through() -> None:
    """The predicate must stay narrow: a reply is still a reply."""

    human = _parse(
        {
            "type": "user",
            "message": {"role": "user", "content": "please fix the flaky test"},
            "uuid": "human-1",
            "session_id": INCIDENT_SESSION,
        }
    )
    for message in (_parse(ASSISTANT_REPLY), human, _parse(RESULT)):
        assert not _is_wire_chrome(message)
    assert not is_synthetic_control_message(_parse(ASSISTANT_REPLY))


def test_compaction_owner_still_sees_governed_frames() -> None:
    """Governance drops nothing the compaction path still needs."""

    boundary = _parse(COMPACT_BOUNDARY)
    assert claude_compact_event(boundary) is not None
    assert is_compaction_control_message(boundary) is True
    # Governed at the reader, still owned by the compaction path once it is
    # buffered as preamble and handed to the turn that reports the marker.
    assert _is_wire_chrome(boundary)


# --------------------------------------------------------------------------
# 2. The phantom user bubbles never publish any item
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "frame",
    [COMMAND_ECHO, STDOUT_ECHO, CAVEAT],
    ids=lambda frame: frame["uuid"],
)
def test_user_echo_bubble_suppressed(frame: dict[str, Any]) -> None:
    """Neither echo produces a projected item — the ghost bubbles from pp's shot."""

    assert is_synthetic_control_message(_parse(frame))


@pytest.mark.parametrize("frame", [STDOUT_ECHO], ids=lambda f: f["uuid"])
def test_command_output_echo_is_also_owned_by_the_compaction_path(
    frame: dict[str, Any],
) -> None:
    """Both predicates agree on the output echo, so no path can project it twice."""

    message = _parse(frame)
    assert is_synthetic_control_message(message)
    assert is_compaction_control_message(message)


def test_command_echo_with_arguments_is_still_cli_chrome() -> None:
    """Only zero-argument commands have been seen; the line itself never is one.

    `/compact` shipped no arguments, so stdout suppression is extrapolated one
    step (see the scope note on the tag constants). The `<command-name>` echo is
    different in kind: it is the CLI dispatching the user's own terminal input,
    so it stays chrome whatever arguments follow it.
    """

    frame = {
        **COMMAND_ECHO,
        "message": {
            "role": "user",
            "content": (
                "<command-name>/foo</command-name>\n"
                "<command-message>foo</command-message>\n"
                "<command-args>--now</command-args>"
            ),
        },
        "uuid": "93b03c34-echo-command-name-with-args",
    }
    assert is_local_command_chrome(_parse(frame).content)
    assert is_synthetic_control_message(_parse(frame))


def test_real_human_bubble_still_publishes() -> None:
    human = _parse(
        {
            "type": "user",
            "message": {"role": "user", "content": "please fix the flaky test"},
            "uuid": "human-1",
            "session_id": INCIDENT_SESSION,
        }
    )
    assert not is_local_command_chrome(human.content)
    assert not is_synthetic_control_message(human)


# --------------------------------------------------------------------------
# 3. The repro: replayed silence turned a settled run permanently running
# --------------------------------------------------------------------------


def _runtime_config() -> RuntimeConfig:
    return RuntimeConfig(runtime="claude", revision=1, values={"environment": {}})


def _single_client_factory(client: Any) -> Any:
    def client_factory(sdk: Any, options: Any) -> Any:
        _ = sdk
        client.options = options
        return client

    return client_factory


def _new_client_per_connection(clients: list[Any]) -> Any:
    """Hand out one transport per connection, like the real client factory."""

    remaining = list(clients)

    def client_factory(sdk: Any, options: Any) -> Any:
        _ = sdk
        client = remaining.pop(0)
        client.options = options
        return client

    return client_factory


def _runtime_with(host: _RecordingHost, client_factory: Any) -> ClaudeRuntime:
    sdk = _default_sdk()
    sdk.HookMatcher = _FakeHookMatcher
    return ClaudeRuntime(
        config=_runtime_config(),
        host=host,
        sdk_loader=lambda: sdk,
        client_factory=client_factory,
    )


async def _wait_until(predicate: Any, timeout: float = 5.0) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.01)


def _turn_ends(host: _RecordingHost, turn_id: str) -> list[dict[str, Any]]:
    return [end for end in host.session_turn_ends if end["turn_id"] == turn_id]


def test_ghost_turn_repro_replayed_silence_mints_no_turn() -> None:
    """修前红 / 修后绿: the 2ms replay after a settled turn mints nothing.

    The incident timing is the whole point: the /compact turn completed
    normally, and only then — with the reader at silence and no prompt pending —
    did the CLI replay its SessionStart hook narration and the two command
    echoes. Feeding those frames while the turn is still running would hide the
    bug, because the running turn consumes them and never reaches the reader's
    mint branch at all.
    """

    class ReplayingClient(_ScheduledClaudeClient):
        async def replay_incident_frames(self) -> None:
            """Raw frames off the incident session file, in wire order."""

            for frame in INCIDENT_REPLAY:
                await self.incoming.put(_parse(frame))

    async def run() -> None:
        client = ReplayingClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("ghost", None, "hello")
            session = runtime._sessions["ghost"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.execution is None
            assert host.session_turn_ends[-1]["outcome"] == "completed"

            await client.replay_incident_frames()
            await asyncio.sleep(0.05)

            # No second execution, no second turn, no phantom bubbles: chrome at
            # silence is buffered, not answered.
            assert session.execution is None
            assert session.queued_execution is None
            assert len(host.session_turn_ends) == 1
            user_texts = [
                str(item.content.get("text", ""))
                for item in host.timeline_item_upserts
                if item.role == "user"
            ]
            assert user_texts.count("hello") == 1
            assert not any("compact" in text.lower() for text in user_texts)
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4. The circuit breaker: a stuck scheduled turn fails out inside the budget
# --------------------------------------------------------------------------


class _HangingScheduledClient(_ScheduledClaudeClient):
    """A cron task that starts answering and then never finishes.

    This is the invariant the breaker defends, stated without the trigger chain
    that produced the incident: the CLI emits an assistant frame out of silence,
    the reader dutifully mints a scheduled turn for it, and no result message
    ever follows. Any wire shape that lands here gets the same deadline.
    """

    async def start_hanging_reply(self) -> None:
        await self.incoming.put(_parse({**ASSISTANT_REPLY, "session_id": self.native_id}))


@pytest.fixture(autouse=True)
def _short_breaker_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    """Compress the 30s product budget so the breaker is observable in a test.

    The deadline itself is the contract (pp: align it with the reconcile timeout
    magnitude); nothing below depends on the number, so shrinking it here keeps
    the whole file fast without inventing a second code path.
    """

    monkeypatch.setattr(lifecycle, "POLLED_TURN_WATCHDOG_SECONDS", 0.2)


def test_watchdog_forces_failed_terminal_on_stuck_scheduled_turn() -> None:
    """scheduled 回合挂起 → 预算耗尽 → 强制 failed 终态 + 释放执行锁.

    Pinned on the real semantics: the watchdog arms only scheduled turns (a
    human turn that legitimately thinks for longer than the budget must not be
    killed), and it fires on silence, not on any particular wire shape.
    """

    async def run() -> None:
        client = _HangingScheduledClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("breaker", None, "schedule")
            await asyncio.wait_for(runtime._sessions["breaker"].active_task, 5)
            assert runtime._sessions["breaker"].execution is None

            # The CLI starts a scheduled reply and stops mid-sentence.
            await client.start_hanging_reply()
            session = runtime._sessions["breaker"]
            await _wait_until(lambda: session.execution is not None)
            ghost_turn_id = session.execution.turn_id

            await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
            ended = _turn_ends(host, ghost_turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            assert host.session_state_updates[-1]["status"] == "error"
            assert (
                host.session_state_updates[-1]["error"]["code"]
                == "claude_scheduled_turn_timeout"
            )
            assert session.execution is None
            assert session.queued_execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_watchdog_leaves_a_thinking_human_turn_alone() -> None:
    """Only scheduled turns are armed; a slow human turn keeps the lock."""

    async def run() -> None:
        client = _HangingScheduledClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("slow", None, "wait")
            session = runtime._sessions["slow"]
            await asyncio.sleep(lifecycle.POLLED_TURN_WATCHDOG_SECONDS * 5)
            assert session.execution is not None
            assert session.execution.watchdog_task is None
            assert not host.session_turn_ends
            await client.reply("done thinking")
            await asyncio.wait_for(session.active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_next_turn_completes_after_the_breaker_fires() -> None:
    """熔断后补发一条消息必须正常完成 — the P0 regression.

    修前红: the breaker only released `session.execution`. The zombie
    `drive_turn` kept draining the reader's queue, so the next human turn's
    reply was consumed by it; when that turn's result finally arrived, the
    zombie's `finish_execution` returned early on the flag the breaker had just
    set, `response.release()` never ran, and the reader parked on `released`
    forever. The session looked unlocked and was permanently unusable.

    修后绿: the breaker finishes what the turn could not — it cancels the
    zombie and retires the transport — so the next turn rebuilds the connection
    and completes normally.
    """

    async def run() -> None:
        hanging = _HangingScheduledClient()
        healthy = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _new_client_per_connection([hanging, healthy]))
        try:
            await runtime.start_turn("recover", None, "schedule")
            session = runtime._sessions["recover"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.execution is None
            assert runtime._turns.runner.connections["recover"].task_ids == {"timer_1"}

            await hanging.start_hanging_reply()
            await _wait_until(lambda: session.execution is not None)
            ghost_turn_id = session.execution.turn_id
            await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
            assert _turn_ends(host, ghost_turn_id)[-1]["outcome"] == "failed"

            # Connection-side clean-up: the poisoned transport is retired and
            # the reader is no longer routing into the ghost response.
            await _wait_until(lambda: "recover" not in runtime._turns.runner.connections)
            assert hanging.disconnected
            assert session.execution is None

            # ...and the very next message is answered normally.
            recovery = await runtime.start_turn("recover", "native_timer", "after")
            assert recovery.ok is True
            await asyncio.wait_for(runtime._sessions["recover"].active_task, 5)
            ended = _turn_ends(host, recovery.result["turnId"])[-1]
            assert ended["outcome"] == "completed"
            assert host.session_state_updates[-1]["status"] == "idle"
            assert healthy.queries == ["after"]
            assert any(
                item.role == "assistant"
                and item.content.get("text") == "reply:after"
                for item in host.timeline_item_upserts
            )
            # The Cron* bookkeeping survived the retired transport.
            assert runtime._turns.runner.connections["recover"].task_ids == {"timer_1"}
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_breaker_hands_over_scheduled_task_ids_to_the_rebuilt_connection() -> None:
    """The retired transport's Cron* ids reach its replacement."""

    async def run() -> None:
        hanging = _HangingScheduledClient()
        healthy = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _new_client_per_connection([hanging, healthy]))
        try:
            await runtime.start_turn("handover", None, "schedule")
            session = runtime._sessions["handover"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.execution is None

            await hanging.start_hanging_reply()
            await _wait_until(lambda: session.execution is not None)
            await _wait_until(
                lambda: "handover" not in runtime._turns.runner.connections
            )
            assert runtime._turns.runner.carried_task_ids == {
                "handover": {"timer_1"}
            }

            await runtime.start_turn("handover", "native_timer", "after")
            await asyncio.wait_for(runtime._sessions["handover"].active_task, 5)
            assert runtime._turns.runner.carried_task_ids == {}
            assert runtime._turns.runner.connections["handover"].task_ids == {"timer_1"}
        finally:
            await runtime.stop()

    asyncio.run(run())
