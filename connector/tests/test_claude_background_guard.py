"""Background subagents must outlive their dispatch reply (2026-10-02 incident).

Why this file exists
--------------------
On 2026-10-02 an AA session (native ``1e1c3706``) dispatched three background
audit subagents. The dispatch turn settled normally, and then the subagents'
own wire frames — thinking, tool_use, tool_result and text frames parented to
the dispatch tool call — leaked into the parent stream while the reader sat at
silence. Every such frame minted a scheduled turn that could never reach a
terminal; 30 seconds later the stuck-turn circuit breaker retired the
transport, the CLI process died, and all three subagents died with it. The
death certificates replayed on the next session, minted a fresh ghost, and the
cycle repeated (16:45:07 → 16:50:54).

Two defense layers are pinned here:

* the reader never mints a scheduled reply from a parented frame — the main
  agent's own wake-and-report frames carry ``parent_tool_use_id=None``, so the
  parented ones are safe to absorb;
* the breaker still releases the lock and fails the ghost turn, but never
  retires a healthy transport that hosts live background work, and it drops
  the ghost response so the reader can route again.

The reproduction payloads below are verbatim wire frames captured from the
reproduction sessions (three independent sessions reproduced the mint; a
control run without the breaker saw every subagent finish), parsed through the
SDK's own ``parse_message``, never hand-built — the fixture lesson from the
/compact ghost. The wake-turn and failed-result frames are synthetic
SDK-parsed shapes that model the CLI's own wake behaviour, and are labelled as
such at their definitions.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.sdk.background import (
    ClaudeBackgroundTasks,
    is_background_activity,
)
from connector.runtimes.claude.turns import lifecycle
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _turn_ends,
    _wait_until,
)
from test_claude_runtime import (
    _FakeClaudeClient,
    _RecordingHost,
    _ScheduledClaudeClient,
)

SESSION = "bd5cb60b-f01f-48e3-9061-46ec52ba11ad"

# --------------------------------------------------------------------------
# Verbatim wire payloads (shape untouched) from .local-dev/recon/raw
# --------------------------------------------------------------------------

# A subagent's Bash tool_result leaking into the parent stream, parented to
# its Agent dispatch call (session-20261002-2323 L556, +24.9s after the reply).
WIRE_DANGER_USER_TOOL_RESULT = {
    "type": "user",
    "message": {
        "role": "user",
        "content": [
            {
                "tool_use_id": "call_00_6tFC5WwgqGk8bj1RwQ9t1891",
                "type": "tool_result",
                "content": "(Bash completed with no output)",
                "is_error": False,
            }
        ],
    },
    "parent_tool_use_id": "call_01_0nlz6gJGgoVqb7lfwu8u8686",
    "session_id": SESSION,
    "uuid": "45617d75-057c-404e-9226-5527791061ab",
    "timestamp": "2026-10-02T23:23:58.076Z",
    "subagent_type": "general-purpose",
    "task_description": "Sleep 25 then reply DONE-B",
}

# A subagent's thinking frame landing 47 ms after the dispatch reply — the
# "+4s ghost" family (session-20261002-2330-short L371).
WIRE_DANGER_ASSISTANT_THINKING = {
    "type": "assistant",
    "message": {
        "id": "3d3d6703-bc1e-420e-ad6f-298fe25bd67e",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "stop_sequence": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "thinking",
                "thinking": (
                    "The task is simple: run `sleep 8` via Bash, then reply "
                    "with exactly 'DONE-C'."
                ),
                "signature": "3d3d6703-bc1e-420e-ad6f-298fe25bd67e",
            }
        ],
        "usage": {
            "input_tokens": 7350,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 27520,
        },
        "context_management": None,
    },
    "parent_tool_use_id": "call_00_PTnOCB9vAH4D2Vdmq6TA1784",
    "session_id": "7d0b9fb6-c6d0-41a1-9a19-78fd76e0b753",
    "uuid": "c46b4a41-3923-4430-9594-6227bb1e01b4",
    "timestamp": "2026-10-02T23:30:50.687Z",
    "subagent_type": "general-purpose",
    "task_description": "Sleep 8 then reply DONE-C",
}

# The matched lifecycle pair for one background subagent (task ad379dfd…,
# "Sleep 25 then reply DONE-B"), both verbatim from the same dump.
WIRE_TASK_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": "ad379dfda276d8f8d",
    "tool_use_id": "call_01_0nlz6gJGgoVqb7lfwu8u8686",
    "description": "Sleep 25 then reply DONE-B",
    "subagent_type": "general-purpose",
    "is_backgrounded": True,
    "spawn_depth": 1,
    "task_type": "local_agent",
    "prompt": (
        "Run this exact Bash command: sleep 25\n\nAfter the command "
        "completes, reply with exactly: DONE-B\n\nDo not do anything else."
    ),
    "uuid": "4b6fcf80-25c0-4b65-a4be-f0dd2e7fae43",
    "session_id": SESSION,
}

WIRE_TASK_NOTIFICATION_COMPLETED = {
    "type": "system",
    "subtype": "task_notification",
    "task_id": "ad379dfda276d8f8d",
    "tool_use_id": "call_01_0nlz6gJGgoVqb7lfwu8u8686",
    "status": "completed",
    "output_file": (
        "/tmp/claude-1001/-home-ubuntu-aa-test-bg-guard-recon/"
        "bd5cb60b-f01f-48e3-9061-46ec52ba11ad/tasks/ad379dfda276d8f8d.output"
    ),
    "summary": "DONE-B",
    "usage": {"total_tokens": 30938, "tool_uses": 1, "duration_ms": 31214},
    "uuid": "86d4e414-baf1-40cb-8256-cec8d6d249e0",
    "session_id": SESSION,
}

WIRE_BACKGROUND_TASKS_CHANGED = {
    "type": "system",
    "subtype": "background_tasks_changed",
    "tasks": [
        {
            "task_id": "aebf59759706f3446",
            "task_type": "local_agent",
            "description": "Sleep 100 then reply DONE-A",
        }
    ],
    "uuid": "d2e30119-14ba-417c-b0af-a1c9ec314560",
    "session_id": SESSION,
}

# The wake turn: after a subagent completes the CLI wakes the main agent, and
# its reply frames carry parent_tool_use_id=None — these must still mint a
# scheduled reply and surface to the client. (Synthetic SDK-parsed shapes, not
# wire captures; the wake path produces no captureable fixture of its own.)
WIRE_WAKE_ASSISTANT = {
    "type": "assistant",
    "message": {
        "role": "assistant",
        "model": "claude-opus-5",
        "content": [{"type": "text", "text": "Subagent finished: all green."}],
    },
    "uuid": "wake-assistant-1",
    "session_id": SESSION,
}

WIRE_WAKE_RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "num_turns": 1,
    "session_id": SESSION,
    "result": "",
    "duration_ms": 12,
    "duration_api_ms": 10,
    "total_cost_usd": 0.0,
}

WIRE_FAILED_RESULT = {
    "type": "result",
    "subtype": "error_during_execution",
    "is_error": True,
    "num_turns": 1,
    "session_id": SESSION,
    "result": "",
    "duration_ms": 12,
    "duration_api_ms": 10,
    "total_cost_usd": 0.0,
}


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


@pytest.fixture(autouse=True)
def _short_breaker_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    """Compress the 30s product budget so the breaker is observable in a test."""

    monkeypatch.setattr(lifecycle, "POLLED_TURN_WATCHDOG_SECONDS", 0.2)


# --------------------------------------------------------------------------
# 1. The reader predicate: parented frames are background activity
# --------------------------------------------------------------------------


def test_parented_frames_are_background_activity() -> None:
    assert is_background_activity(_parse(WIRE_DANGER_USER_TOOL_RESULT)) is True
    assert is_background_activity(_parse(WIRE_DANGER_ASSISTANT_THINKING)) is True


def test_wake_and_human_frames_are_not_background_activity() -> None:
    assert is_background_activity(_parse(WIRE_WAKE_ASSISTANT)) is False
    assert is_background_activity(_parse(WIRE_WAKE_RESULT)) is False
    human = _parse(
        {
            "type": "user",
            "message": {"role": "user", "content": "please fix the flaky test"},
            "uuid": "human-1",
            "session_id": SESSION,
        }
    )
    assert is_background_activity(human) is False


def test_background_tasks_changed_marks_work_active() -> None:
    tasks = ClaudeBackgroundTasks()
    assert tasks.observe(_parse(WIRE_BACKGROUND_TASKS_CHANGED)) is True
    assert tasks.active_ids == {"aebf59759706f3446"}

    # An empty snapshot releases nothing on its own — only terminal task
    # events do, because an unconfirmed task is never assumed complete.
    empty = _parse(
        {
            "type": "system",
            "subtype": "background_tasks_changed",
            "tasks": [],
            "uuid": "changed-empty",
            "session_id": SESSION,
        }
    )
    assert tasks.observe(empty) is True
    assert tasks.active_ids == {"aebf59759706f3446"}


# --------------------------------------------------------------------------
# 2. The mint: parented frames at silence mint nothing (修前红)
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "frame",
    [WIRE_DANGER_USER_TOOL_RESULT, WIRE_DANGER_ASSISTANT_THINKING],
    ids=["subagent-tool-result", "subagent-thinking"],
)
def test_parented_frames_never_mint_a_scheduled_turn(frame: dict[str, Any]) -> None:
    """修前红 / 修后绿: without the guard this frame mints a ghost turn."""

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("guard", None, "hello")
            session = runtime._sessions["guard"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.execution is None
            assert len(host.session_turn_ends) == 1
            items_before = len(host.timeline_item_upserts)

            await client.incoming.put(_parse(frame))
            await asyncio.sleep(0.05)

            assert session.execution is None, "a parented frame must not mint"
            assert session.queued_execution is None
            assert len(host.session_turn_ends) == 1
            assert len(host.timeline_item_upserts) == items_before
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 3. The invariant: a stuck turn with live background work is failed, not
#    retired — the subagent keeps its process (修前红)
# --------------------------------------------------------------------------


def test_stuck_turn_with_live_background_work_is_not_retired() -> None:
    """The incident replayed under the fix: fail the ghost, keep the process."""

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        built: list[int] = []

        def factory(sdk: Any, options: Any) -> Any:
            built.append(1)
            client.options = options
            return client

        runtime = _runtime_with(host, factory)
        try:
            await runtime.start_turn("shield", None, "hello")
            session = runtime._sessions["shield"]
            await asyncio.wait_for(session.active_task, 5)

            # A background subagent goes live...
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await _wait_until(
                lambda: bool(
                    runtime._turns.runner.connections["shield"]
                    .background.active_ids
                )
            )

            # ...and an unrecognized frame mints a ghost. The invariant must
            # hold for ANY wire shape, so this deliberately uses a bare reply
            # frame rather than a parented one.
            await client.incoming.put(_parse(WIRE_WAKE_ASSISTANT))
            await _wait_until(lambda: session.execution is not None)
            ghost_turn_id = session.execution.turn_id

            await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
            ended = _turn_ends(host, ghost_turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            assert session.execution is None

            # The breaker released the lock but did NOT retire the transport:
            # the live subagent keeps the CLI process it runs in.
            connection = runtime._turns.runner.connections.get("shield")
            assert connection is not None
            assert client.disconnected is False
            assert connection.background.active_ids

            # The subagent completes; the same transport serves the next turn.
            await client.incoming.put(_parse(WIRE_TASK_NOTIFICATION_COMPLETED))
            await _wait_until(lambda: not connection.background.active_ids)
            assert client.disconnected is False

            await runtime.start_turn("shield", "native_timer", "after")
            await asyncio.wait_for(runtime._sessions["shield"].active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert client.queries == ["hello", "after"]
            assert len(built) == 1, "the transport must be reused, not rebuilt"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4. The wake reply still mints and surfaces (D4: the guard stays narrow)
# --------------------------------------------------------------------------


def test_wake_reply_after_subagent_completion_still_mints() -> None:
    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("wake", None, "hello")
            await asyncio.wait_for(runtime._sessions["wake"].active_task, 5)
            assert len(host.session_turn_ends) == 1

            await client.incoming.put(_parse(WIRE_WAKE_ASSISTANT))
            await client.incoming.put(_parse(WIRE_WAKE_RESULT))

            await _wait_until(lambda: len(host.session_turn_ends) == 2)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert any(
                item.role == "assistant"
                and item.content.get("text") == "Subagent finished: all green."
                for item in host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 5. A failed human turn no longer kills a live background worker
# --------------------------------------------------------------------------


class _FailingTurnClient(_ScheduledClaudeClient):
    """The first ``hello`` turn fails while a background subagent runs."""

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        await self.incoming.put(_parse(WIRE_TASK_STARTED))
        await self.incoming.put(_parse(WIRE_FAILED_RESULT))


def test_failed_turn_with_live_background_keeps_transport() -> None:
    async def run() -> None:
        client = _FailingTurnClient()
        host = _RecordingHost()
        built: list[int] = []

        def factory(sdk: Any, options: Any) -> Any:
            built.append(1)
            client.options = options
            return client

        runtime = _runtime_with(host, factory)
        try:
            await runtime.start_turn("failguard", None, "hello")
            session = runtime._sessions["failguard"]
            await asyncio.wait_for(session.active_task, 5)

            assert host.session_turn_ends[-1]["outcome"] == "failed"
            connection = runtime._turns.runner.connections.get("failguard")
            assert connection is not None
            assert client.disconnected is False
            assert connection.background.active_ids

            await client.incoming.put(_parse(WIRE_TASK_NOTIFICATION_COMPLETED))
            await _wait_until(lambda: not connection.background.active_ids)

            await runtime.start_turn("failguard", "native_timer", "after")
            await asyncio.wait_for(runtime._sessions["failguard"].active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert client.queries == ["hello", "after"]
            assert len(built) == 1, "the transport must be reused, not rebuilt"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 6. The limiter: repeat stuck turns yield one client-visible failure (D2)
# --------------------------------------------------------------------------


def test_repeat_stuck_turns_report_at_most_one_failure_per_connection() -> None:
    """修前红: without the limiter every repeat ghost lands a failed turn."""

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("cap", None, "hello")
            session = runtime._sessions["cap"]
            await asyncio.wait_for(session.active_task, 5)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            connection = runtime._turns.runner.connections["cap"]
            await _wait_until(lambda: bool(connection.background.active_ids))

            for index in range(3):
                unknown = {**WIRE_WAKE_ASSISTANT, "uuid": f"cap-{index}"}
                await client.incoming.put(_parse(unknown))
                await _wait_until(lambda: session.execution is not None)
                # Every ghost still fails out and releases the lock...
                await _wait_until(lambda: session.execution is None)
                assert session.queued_execution is None

            failures = [
                end for end in host.session_turn_ends if end["outcome"] == "failed"
            ]
            assert len(failures) == 1, (
                "one connection window must surface at most one visible "
                f"failure, saw {len(failures)}"
            )
            # ...and the transport with its live background work never died.
            assert client.disconnected is False
            assert connection.background.active_ids
            # Repeat timeouts still drive the session state off "running".
            assert host.session_state_updates[-1]["status"] == "error"
        finally:
            await runtime.stop()

    asyncio.run(run())
