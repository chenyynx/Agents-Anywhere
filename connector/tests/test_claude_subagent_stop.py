"""Per-task stop: the RPC, the capability bit, and the ghost-card sweep.

A3 batch, station A (2026-10-05). Three layers:

* ``session.stopSubagent`` — the per-task stop control. A task id in the
  live snapshot is stopped through the SDK's ``stop_task``; an unknown id is
  a factual ``stopped=false``, never an error, and never a thrown failure.
* ``session.subagent_control`` — the capability bit. ``supported`` is the
  SDK's ``stop_task`` presence; ``available`` is the session's live
  connection, deliberately not the turn (background subagents run while the
  session is idle).
* the ghost-card sweep (``ghost-card-findings.md``, narrowed by red team
  F-D/F-E) — a stop judges every open Agent card it leaves without a
  *started* task (I-G1), and a task that starts after that judgment
  re-opens the card (I-G2).
* the fan-out's fold honesty (red team F-A): a declared connection reports
  exactly the stops the CLI accepted — a refused or timed-out stop is not a
  kill, and the fallback arm below is only for an *undeclared* connection.

The ghost arms are the P0 probe's S1/S3 scenarios turned into red->green
tests: before this batch they leave the card ``running`` forever.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import (
    _default_sdk,
    _FakeClaudeClient,
    _FakeHookMatcher,
    _RecordingHost,
)
from test_claude_stop_affordance import (
    _PartialStopDispatchClient,
    _StoppingDispatchClient,
)
from test_claude_subagent_progress import (
    DISPATCH_TUID,
    SESSION,
    TASK_ID,
    WIRE_DISPATCH_RECEIPT,
    WIRE_DISPATCH_TOOL_USE,
    WIRE_MAIN_RESULT,
    WIRE_TASK_NOTIFICATION,
    WIRE_TASK_STARTED,
    WIRE_TASK_UPDATED,
    _card_agents,
    _card_items,
    _parse,
    _start_dispatch,
)

from connector.runtime_protocol import AgentCallToolContent, RuntimeConfig
from connector.runtime_protocol.models import CAPABILITY_SESSION_SUBAGENT_CONTROL
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.timeline.agent_calls import has_running_agent_tasks
from connector.runtimes.claude.timeline.messages import stable_tool_item_id
from connector.server.runtime_rpc import RuntimeRpcHandler
from connector.server.runtime_turn_rpc import dispatch_session_stop_subagent

#: A second background subagent, dispatched after the first: the F-A partial
#: refusal arm needs two bound tasks whose stops land differently.
SECOND_TUID = "call_00_SecondDispatch000000000001"
SECOND_TASK_ID = "b1c2d3e4f5a6b7c8d"

WIRE_SECOND_DISPATCH_TOOL_USE = {
    **WIRE_DISPATCH_TOOL_USE,
    "uuid": "second-dispatch-1",
    "message": {
        **WIRE_DISPATCH_TOOL_USE["message"],
        "content": [
            {
                "type": "tool_use",
                "id": SECOND_TUID,
                "name": "Agent",
                "input": {
                    "description": "Second audit",
                    "run_in_background": True,
                    "prompt": "Second task prompt (elided)",
                },
            }
        ],
    },
}

WIRE_SECOND_DISPATCH_RECEIPT = {
    **WIRE_DISPATCH_RECEIPT,
    "uuid": "second-receipt-1",
    "message": {
        **WIRE_DISPATCH_RECEIPT["message"],
        "content": [
            {
                "tool_use_id": SECOND_TUID,
                "type": "tool_result",
                "content": WIRE_DISPATCH_RECEIPT["message"]["content"][0]["content"],
            }
        ],
    },
    "tool_use_result": {
        **WIRE_DISPATCH_RECEIPT["tool_use_result"],
        "agentId": SECOND_TASK_ID,
    },
}

WIRE_SECOND_TASK_STARTED = {
    **WIRE_TASK_STARTED,
    "uuid": "second-task-started-1",
    "task_id": SECOND_TASK_ID,
    "tool_use_id": SECOND_TUID,
    "description": "Second audit",
}

# --- harness -----------------------------------------------------------------


class _StopTaskSdkClient:
    """Stands in for the SDK's ``ClaudeSDKClient``: it carries stop_task."""

    async def stop_task(self, task_id: str) -> None:  # pragma: no cover
        raise AssertionError("only the class attribute is probed")


def _stop_capable_sdk() -> Any:
    sdk = _default_sdk()
    sdk.HookMatcher = _FakeHookMatcher
    sdk.ClaudeSDKClient = _StopTaskSdkClient
    return sdk


def _stop_capable_runtime(host: Any, client_factory: Any) -> ClaudeRuntime:
    """A runtime whose loaded SDK offers the per-task stop control."""

    sdk = _stop_capable_sdk()
    return ClaudeRuntime(
        config=RuntimeConfig(
            runtime="claude", revision=1, values={"environment": {}}
        ),
        host=host,
        sdk_loader=lambda: sdk,
        client_factory=client_factory,
    )


async def _find_capability(
    runtime: ClaudeRuntime,
    session_id: str,
    capability_id: str = CAPABILITY_SESSION_SUBAGENT_CONTROL,
) -> Any:
    capabilities = await runtime.get_session_capabilities(session_id)
    capability = next(
        (
            item
            for item in capabilities.capabilities
            if item.capability_id == capability_id
        ),
        None,
    )
    assert capability is not None, f"{capability_id} missing from the session set"
    return capability


async def _bind_subagent(host: Any, runtime: Any, client: Any) -> str:
    """Bind one background agent to its card and open a live turn (the stop's
    shape: an execution whose connection hosts the bound subagent)."""

    session = await _start_dispatch(runtime)
    card_id = stable_tool_item_id(session, DISPATCH_TUID)
    await client.incoming.put(_parse(WIRE_TASK_STARTED))
    await _wait_until(
        lambda: _card_agents(host, card_id).get(TASK_ID, {}).get("status") == "running"
    )
    await runtime.start_turn("sub_progress", None, "wait")
    await _wait_until(
        lambda: getattr(runtime._sessions["sub_progress"].execution, "client", None)
        is not None
    )
    return card_id


class _SessionScopedInterrupt:
    """An interrupt whose abort tail carries the real session id.

    `_ScheduledClaudeClient.interrupt` hardcodes `native_timer`; a stop whose
    tail re-scopes the session would re-key every later fold's card id — an
    artefact of the fake, not the product (a real abort's result carries the
    session's own id), so the tests that assert per-card after a stop pin
    the production shape here.
    """

    async def interrupt(self) -> None:
        await _FakeClaudeClient.interrupt(self)
        await self.incoming.put(
            SimpleNamespace(
                type="result", session_id=SESSION, terminal_reason="aborted_streaming"
            )
        )


class _WindowGhostClient(_SessionScopedInterrupt, _StoppingDispatchClient):
    """The dispatch-window ghost: the Agent call goes out, no task starts.

    Only the dispatch tool_use frame and the turn's own result are replayed —
    the probe's S1 shape (2026-10-05 findings §3.1). "wait" opens the live
    turn the stop interrupts, exactly like `_StoppingDispatchClient`.
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        if prompt == "wait":
            return
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in (WIRE_DISPATCH_TOOL_USE, WIRE_MAIN_RESULT):
            await self.incoming.put(_parse(frame))


class _RefusingStopClient(_StoppingDispatchClient):
    """Accepts no per-task stop at all (the CLI refuses)."""

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)
        raise RuntimeError("the CLI refused")


class _StopSubagentSupervisor:
    def __init__(self, runtime: Any) -> None:
        self.runtime = runtime

    def resolve_runtime(self, runtime_id: str, runtime_type: str) -> Any:
        _ = runtime_id, runtime_type
        return self.runtime


class _StopSubagentHost:
    connector_id = "conn_test"
    session_namespace = "conn_test"


# --- session.stopSubagent ----------------------------------------------------


def test_stop_subagent_stops_a_bound_task_and_reports_true() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            card_id = await _bind_subagent(host, runtime, client)

            result = await dispatch_session_stop_subagent(
                runtime, {"sessionId": "sub_progress", "taskId": TASK_ID}
            )

            assert result == {"stopped": True}
            assert client.stopped == [TASK_ID]
            # The card is left to the CLI's own terminal frame: the stop only
            # sends the control request, it never rewrites card state.
            await client.incoming.put(
                _parse(
                    {**WIRE_TASK_NOTIFICATION, "status": "stopped", "uuid": "stop-1"}
                )
            )
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "interrupted"
            )
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "stopped"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_stop_subagent_unknown_task_is_a_fact_not_a_failure() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await _bind_subagent(host, runtime, client)

            # An id the live snapshot does not know: factual false, no call,
            # no exception, and the session keeps working.
            result = await dispatch_session_stop_subagent(
                runtime, {"sessionId": "sub_progress", "taskId": "t_unknown"}
            )
            assert result == {"stopped": False}
            assert client.stopped == []

            # A session this process never opened has no connection to stop
            # through: also a fact, not an error.
            absent = await dispatch_session_stop_subagent(
                runtime, {"sessionId": "never_seen", "taskId": TASK_ID}
            )
            assert absent == {"stopped": False}
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_stop_subagent_refusal_is_false_not_an_error() -> None:
    async def run() -> None:
        client = _RefusingStopClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await _bind_subagent(host, runtime, client)

            result = await dispatch_session_stop_subagent(
                runtime, {"sessionId": "sub_progress", "taskId": TASK_ID}
            )

            assert result == {"stopped": False}
            assert client.stopped == [TASK_ID]  # attempted, refused, reported
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_stop_subagent_timeout_is_false_not_an_error(monkeypatch: Any) -> None:
    """A known id whose stop never answers: factual false, no exception."""

    class _HangingStopClient(_StoppingDispatchClient):
        async def stop_task(self, task_id: str) -> None:
            self.stopped.append(task_id)
            await asyncio.Event().wait()

    from connector.runtimes.claude.turns import actions as claude_actions

    original = claude_actions.stop_background_tasks

    async def bounded_stop(client: Any, task_ids: Any) -> Any:
        # The stop path bounds each attempt; the test bounds it to ms so the
        # arm stays fast while the real default (5 s) is untouched.
        return await original(client, task_ids, timeout=0.05)

    monkeypatch.setattr(claude_actions, "stop_background_tasks", bounded_stop)

    async def run() -> None:
        client = _HangingStopClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await _bind_subagent(host, runtime, client)

            result = await dispatch_session_stop_subagent(
                runtime, {"sessionId": "sub_progress", "taskId": TASK_ID}
            )

            assert result == {"stopped": False}
            assert client.stopped == [TASK_ID]
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_stop_subagent_params_reject_a_missing_task_id() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            try:
                await dispatch_session_stop_subagent(
                    runtime, {"sessionId": "sub_progress"}
                )
            except ValueError as exc:
                assert "taskId" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a missing taskId must be rejected")
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_runtime_rpc_routes_stop_subagent() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        handler = RuntimeRpcHandler(
            _StopSubagentSupervisor(runtime), _StopSubagentHost()
        )
        try:
            await _bind_subagent(host, runtime, client)
            assert handler.supports("session.stopSubagent") is True

            result = await handler.dispatch(
                "session.stopSubagent",
                {
                    "sessionId": "sub_progress",
                    "runtime": "claude",
                    "runtimeId": "claude",
                    "taskId": TASK_ID,
                },
            )

            assert result["stopped"] is True
            assert result["runtime"] == "claude"
            assert result["runtimeId"] == "claude"
            assert client.stopped == [TASK_ID]
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- session.subagent_control (three states) ---------------------------------


def test_subagent_control_is_available_with_a_live_connection_no_turn() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _stop_capable_runtime(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            assert session.execution is None  # the session is idle

            capability = await _find_capability(runtime, "sub_progress")
            assert capability.supported is True
            # Availability does not track the turn: the connection hosts the
            # session's work, and background subagents exist while idle.
            assert capability.available is True
            assert capability.unavailable_reason is None
            assert capability.scope == "session"

            interrupt = await _find_capability(
                runtime, "sub_progress", "session.interrupt"
            )
            assert interrupt.available is False  # the turn-based contrast

            # No live connection for a session this process never opened.
            absent = await _find_capability(runtime, "never_seen")
            assert absent.supported is True
            assert absent.available is False
            assert absent.unavailable_reason == "session_disconnected"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_subagent_control_is_unsupported_without_stop_task() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        # The default fake SDK carries no ClaudeSDKClient at all — no
        # stop_task, so the capability cannot be supported.
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await _start_dispatch(runtime)

            capability = await _find_capability(runtime, "sub_progress")
            assert capability.supported is False
            assert capability.available is False
            assert capability.unavailable_reason == "not_implemented"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- the ghost card (I-G1) ---------------------------------------------------


def test_stop_before_task_start_closes_the_dispatch_card() -> None:
    """The production ghost: dispatch out, task never created, stop lands.

    The one frame that could close this card (the aborted call's tool_result)
    is discarded by the stop itself, and no task event exists to fold — so
    the stop's own sweep must judge it (I-G1).
    """

    async def run() -> None:
        client = _WindowGhostClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            # The ghost as the client sees it: running, no agents.
            assert _card_items(host, card_id)[-1].status == "running"
            assert _card_agents(host, card_id) == {}

            await runtime.start_turn("sub_progress", None, "wait")
            await _wait_until(
                lambda: getattr(
                    runtime._sessions["sub_progress"].execution, "client", None
                )
                is not None
            )
            result = await runtime.interrupt_session("sub_progress", reason="user")

            assert result.ok is True
            assert result.result["interrupted"] is True
            assert host.session_turn_ends[-1]["outcome"] == "interrupted"
            card = _card_items(host, card_id)[-1]
            assert card.status == "interrupted"
            assert card.content.get("stoppedWithoutTask") is True
            assert card.source["event"] == "claude.agent.stopped"
            assert _card_agents(host, card_id) == {}
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_an_aborted_receipt_cannot_reopen_the_swept_card() -> None:
    async def run() -> None:
        client = _WindowGhostClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await runtime.start_turn("sub_progress", None, "wait")
            await _wait_until(
                lambda: getattr(
                    runtime._sessions["sub_progress"].execution, "client", None
                )
                is not None
            )
            await runtime.interrupt_session("sub_progress", reason="user")
            assert _card_items(host, card_id)[-1].status == "interrupted"

            # Late frames from the aborted call: a receipt-shaped tool_result
            # (the CLI's reply the stop raced) plus terminal task frames for
            # a task that was never bound. None of them may move the card.
            await client.incoming.put(
                _parse({**WIRE_DISPATCH_RECEIPT, "uuid": "late-receipt-1"})
            )
            await client.incoming.put(
                _parse(
                    {
                        **WIRE_TASK_NOTIFICATION,
                        "status": "stopped",
                        "uuid": "late-stopped-1",
                    }
                )
            )
            await asyncio.sleep(0.05)

            assert _card_items(host, card_id)[-1].status == "interrupted"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_task_starting_after_the_sweep_reopens_the_card() -> None:
    """I-G2, the swept card's safety valve: a spared dispatch that starts
    after the stop re-opens the card instead of leaving "card says
    interrupted, agent runs"."""

    async def run() -> None:
        client = _WindowGhostClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await runtime.start_turn("sub_progress", None, "wait")
            await _wait_until(
                lambda: getattr(
                    runtime._sessions["sub_progress"].execution, "client", None
                )
                is not None
            )
            await runtime.interrupt_session("sub_progress", reason="user")
            assert _card_items(host, card_id)[-1].status == "interrupted"

            # The spared call starts after all: the task_started fold flips
            # the swept card back to running (the fold clamp).
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "running"
            )
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "running"

            # And its terminal frame still closes it, exactly once.
            await client.incoming.put(
                _parse(
                    {
                        **WIRE_TASK_UPDATED,
                        "patch": {"status": "killed", "end_time": 1},
                        "uuid": "killed-after-sweep-1",
                    }
                )
            )
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "interrupted"
            )
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "killed"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_receipt_window_ghost_is_swept_too() -> None:
    """The S3 ghost (red team F-D): a receipt is a launch report, not a task.

    The card holds only the ``async_launched`` marker — no task frame ever
    arrived — so nothing proved a task exists; the sweep judges it and the
    marker is left exactly as the receipt wrote it (the sweep invents no
    agent status of its own).
    """

    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            assert _card_items(host, card_id)[-1].status == "running"
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "async_launched"

            await runtime.start_turn("sub_progress", None, "wait")
            await _wait_until(
                lambda: getattr(
                    runtime._sessions["sub_progress"].execution, "client", None
                )
                is not None
            )
            await runtime.interrupt_session("sub_progress", reason="user")

            card = _card_items(host, card_id)[-1]
            assert card.status == "interrupted"
            assert card.content.get("stoppedWithoutTask") is True
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "async_launched"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_running_predicate_excludes_the_launch_receipt() -> None:
    """F-D's narrowed exemption, pinned at the predicate itself."""

    assert (
        has_running_agent_tasks(
            AgentCallToolContent(agents={"a": {"status": "async_launched"}})
        )
        is False
    )
    assert (
        has_running_agent_tasks(
            AgentCallToolContent(agents={"a": {"status": "running"}})
        )
        is True
    )
    assert has_running_agent_tasks(AgentCallToolContent(agents={"a": {}})) is False


def test_sweep_leaves_a_live_task_card_untouched() -> None:
    """I-G2's exemption: an entry that is alive keeps the card open — the
    preserving stop must not kill (or close) a surviving subagent's card."""

    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            card_id = await _bind_subagent(host, runtime, client)

            result = await runtime.interrupt_session(
                "sub_progress", reason="switch", preserve_background=True
            )

            assert result.result["interrupted"] is True
            assert client.stopped == []
            assert _card_items(host, card_id)[-1].status == "running"
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "running"
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.id == card_id and item.status == "interrupted"
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- the fan-out's fold honesty (red team F-A) -------------------------------


class _TwoAgentDispatchClient(_SessionScopedInterrupt, _PartialStopDispatchClient):
    """One turn dispatching two background Agents (the burst shape).

    The partial-refusal arm needs two bound tasks; dispatching both in the
    one turn keeps the card minting on the route every other test uses.
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        if prompt == "wait":
            return
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in (
            WIRE_DISPATCH_TOOL_USE,
            WIRE_DISPATCH_RECEIPT,
            WIRE_SECOND_DISPATCH_TOOL_USE,
            WIRE_SECOND_DISPATCH_RECEIPT,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


def test_declared_partial_refusal_folds_only_the_accepted_stops() -> None:
    """F-A: a declared connection reports exactly what the CLI accepted.

    The accepted task folds interrupted; the refused one is untouched and
    stays alive — reporting it would be the G4 lie that sticks (terminal
    cards do not heal).
    """

    async def run() -> None:
        client = _TwoAgentDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            first_card = stable_tool_item_id(session, DISPATCH_TUID)
            second_card = stable_tool_item_id(session, SECOND_TUID)
            # Both launches are on the cards; bind both tasks (the idle fold).
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_SECOND_TASK_STARTED))
            await _wait_until(
                lambda: (
                    _card_agents(host, first_card).get(TASK_ID, {}).get("status")
                    == "running"
                    and _card_agents(host, second_card)
                    .get(SECOND_TASK_ID, {})
                    .get("status")
                    == "running"
                )
            )
            await runtime.start_turn("sub_progress", None, "wait")
            await _wait_until(
                lambda: getattr(
                    runtime._sessions["sub_progress"].execution, "client", None
                )
                is not None
            )

            connection = runtime._turns.runner.connections["sub_progress"]
            # Precondition (F-C): the declaration is this connection's fact,
            # not a process-global switch another instance could have flipped.
            assert connection.per_task_stop_declared is True
            assert {TASK_ID, SECOND_TASK_ID} <= connection.background.active_ids

            result = await runtime.interrupt_session("sub_progress", reason="user")

            assert result.ok is True
            assert set(client.stopped) == {TASK_ID, SECOND_TASK_ID}
            assert _card_items(host, first_card)[-1].status == "interrupted"
            assert _card_items(host, second_card)[-1].status == "running"
            assert (
                _card_agents(host, second_card)[SECOND_TASK_ID]["status"] == "running"
            )
            assert SECOND_TASK_ID in connection.background.active_ids
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_declared_all_refused_folds_nothing() -> None:
    """F-A's red-team probe, converted: every stop refused => zero folds.

    The declared CLI interrupt spared the survivor, the fan-out accepted
    nothing, so nothing may be reported as killed — and the sweep must not
    close the survivor's card either (a started task backs it).
    """

    async def run() -> None:
        client = _RefusingStopClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            card_id = await _bind_subagent(host, runtime, client)
            connection = runtime._turns.runner.connections["sub_progress"]
            assert connection.per_task_stop_declared is True
            assert TASK_ID in connection.background.active_ids

            result = await runtime.interrupt_session("sub_progress", reason="user")

            assert result.ok is True
            assert client.stopped == [TASK_ID]  # attempted, refused
            assert TASK_ID in connection.background.active_ids  # survivor alive
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.status == "interrupted"
            ]
            assert _card_items(host, card_id)[-1].status == "running"
        finally:
            await runtime.stop()

    asyncio.run(run())
