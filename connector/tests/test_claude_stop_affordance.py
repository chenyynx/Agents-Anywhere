"""Per-task stop affordance and the selection-change drain (pp 2026-10-05 §8).

Four layers, each pinned here:

* the declaration that makes a CLI interrupt spare background agents
  (``install_per_task_stop_declaration`` — narrow, idempotent, kill-switchable,
  fail-soft);
* the interrupt's two flavors (``preserve_background``): sparing, and the
  historical all-stop implemented as an explicit ``stop_task`` fan-out;
* the drain signal (``ClaudeBackgroundTasks.drained``) and the settle window
  (``ClaudeConnection.wait_settled``) that keep a rebuild from cutting off the
  wake turn;
* the wall itself: a selection change now waits for the transport's background
  work instead of failing the next turn with ``RuntimeError``.
"""

from __future__ import annotations

import asyncio
import time
from types import SimpleNamespace
from typing import Any

from test_claude_compact_ghost import _runtime_with
from test_claude_runtime import (
    SystemMessage,
    _default_sdk,
    _FakeHookMatcher,
    _RecordingHost,
    _ScheduledClaudeClient,
)
from test_claude_stale_frame_turn import (
    _runtime_with_values,
    _single_client_factory,
)
from test_claude_subagent_progress import (
    DISPATCH_TUID,
    TASK_ID,
    WIRE_DISPATCH_RECEIPT,
    WIRE_TASK_STARTED,
    _card_agents,
    _card_items,
    _DispatchClient,
    _FakeClaudeClient,
    _parse,
    _start_dispatch,
)

from connector.runtime_protocol import RuntimeConfig
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk import stop_affordance
from connector.runtimes.claude.sdk.background import ClaudeBackgroundTasks
from connector.runtimes.claude.sdk.connection import ClaudeConnection, ClaudeResponse
from connector.runtimes.claude.sdk.stop_affordance import (
    install_per_task_stop_declaration,
    stop_background_tasks,
)
from connector.runtimes.claude.timeline.messages import stable_tool_item_id
from connector.runtimes.claude.turns.lifecycle import ClaudeTurnRunner


async def _wait_until(predicate: Any, timeout: float = 5.0) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.01)


async def _never(*_args: Any) -> None:
    return None


async def _model_selections(runtime: ClaudeRuntime) -> tuple[str, str]:
    catalog = await runtime.list_model_catalog()
    models = catalog.models
    assert len(models) >= 2
    return models[0].selection_id, models[1].selection_id


class _Query:
    def __init__(self) -> None:
        self.sent: list[Any] = []

    async def _send_control_request(self, request: Any, *_args: Any, **_kwargs: Any) -> Any:
        self.sent.append(request)
        return {"ok": True}


class _Sdk:
    class _internal:
        class query:
            Query = _Query


class _NoSenderQuery:
    pass


class _SdkWithoutSender:
    class _internal:
        class query:
            Query = _NoSenderQuery


class _StoppingClient(_ScheduledClaudeClient):
    """A client that records per-task stops."""

    def __init__(self) -> None:
        super().__init__()
        self.stopped: list[str] = []

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)


def _reset_declaration() -> None:
    stop_affordance._declared = False


# --- the declaration ---------------------------------------------------------


def test_declaration_lands_on_initialize_requests_only() -> None:
    async def run() -> None:
        sdk = _Sdk()
        assert install_per_task_stop_declaration(sdk, declare=True) is True
        query = sdk._internal.query.Query()
        await query._send_control_request({"subtype": "initialize", "hooks": None})
        await query._send_control_request({"subtype": "interrupt"})
        await query._send_control_request("not-a-dict")
        assert query.sent[0]["perTaskStopAffordance"] is True
        assert query.sent[0]["hooks"] is None  # the rest of the request is untouched
        assert "perTaskStopAffordance" not in query.sent[1]
        assert query.sent[2] == "not-a-dict"

    try:
        asyncio.run(run())
    finally:
        _reset_declaration()


def test_declaration_is_idempotent_and_kill_switchable() -> None:
    async def run() -> None:
        sdk = _Sdk()
        assert install_per_task_stop_declaration(sdk, declare=True) is True
        sender = sdk._internal.query.Query._send_control_request
        assert install_per_task_stop_declaration(sdk, declare=True) is True
        assert sdk._internal.query.Query._send_control_request is sender  # patched once
        # The kill-switch flips the behavior without re-patching.
        assert install_per_task_stop_declaration(sdk, declare=False) is False
        query = sdk._internal.query.Query()
        await query._send_control_request({"subtype": "initialize"})
        assert "perTaskStopAffordance" not in query.sent[0]

    try:
        asyncio.run(run())
    finally:
        _reset_declaration()


def test_declaration_fails_soft_without_the_sdk_seam() -> None:
    try:
        assert install_per_task_stop_declaration(_SdkWithoutSender(), declare=True) is False
    finally:
        _reset_declaration()


def test_stop_background_tasks_stops_each_named_task() -> None:
    class _Client:
        def __init__(self) -> None:
            self.stopped: list[str] = []

        async def stop_task(self, task_id: str) -> None:
            self.stopped.append(task_id)

    async def run() -> None:
        client = _Client()
        assert await stop_background_tasks(client, ["a", "b"]) == ("a", "b")
        assert client.stopped == ["a", "b"]
        # No per-task control at all: nothing to do, nothing to fail.
        assert await stop_background_tasks(object(), ["a"]) == ()

    asyncio.run(run())


def test_stop_background_tasks_tolerates_refusal_and_silence() -> None:
    class _Client:
        async def stop_task(self, task_id: str) -> None:
            if task_id == "boom":
                raise RuntimeError("the CLI refused")
            if task_id == "hang":
                await asyncio.Event().wait()

    async def run() -> None:
        # Only the accepted stops are reported back: the refusal and the
        # silence are not kills.
        assert await stop_background_tasks(_Client(), ["boom", "hang"], timeout=0.05) == ()

    asyncio.run(run())


def test_background_drain_signal_tracks_the_live_set() -> None:
    tasks = ClaudeBackgroundTasks()
    tasks.observed(
        SystemMessage(subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"})
    )
    assert not tasks.drained.is_set()
    tasks.observed(
        SystemMessage(
            subtype="task_updated",
            task_id="bg_1",
            patch={"status": "completed"},
            data={"task_id": "bg_1"},
        )
    )
    assert tasks.drained.is_set()


def test_wait_settled_holds_the_wake_window_and_stops_at_the_ceiling() -> None:
    async def run() -> None:
        connection = ClaudeConnection(
            client=SimpleNamespace(),
            on_activity=_never,
            on_idle=_never,
            on_background_done=_never,
            cleanup=lambda: None,
        )
        # Already quiet: settles once the grace window has passed.
        started = time.monotonic()
        assert await connection.wait_settled(grace=0.05, ceiling=5.0) is True
        assert time.monotonic() - started >= 0.05
        # A turn starting inside the window restarts it …
        connection.pending = ClaudeResponse(connection)
        pending_task = asyncio.create_task(
            connection.wait_settled(grace=0.05, ceiling=5.0)
        )
        await asyncio.sleep(0.15)
        assert not pending_task.done()
        connection.pending = None
        connection._notify_turn_changed()
        assert await asyncio.wait_for(pending_task, 1) is True
        # … and a turn that never ends fails the wait at the ceiling.
        connection.current = ClaudeResponse(connection)
        assert await connection.wait_settled(grace=0.01, ceiling=0.05) is False

    asyncio.run(run())


# --- the two interrupt flavors ----------------------------------------------


async def _bind_subagent(host: Any, runtime: Any, client: Any) -> str:
    """Bind one background agent to its Agent card and open a live turn.

    Returns the card id, with a running turn whose connection hosts the bound
    subagent — the state an interrupt actually sees (the fan-out only owns
    tasks that have a card binding; see `_bound_subagent_ids`).
    """

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


def test_preserving_interrupt_spares_background_tasks() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(
            host, _single_client_factory(client), {"perTaskStopAffordance": True}
        )
        try:
            await _bind_subagent(host, runtime, client)
            connection = runtime._turns.runner.connections["sub_progress"]
            assert TASK_ID in connection.background.active_ids

            result = await runtime.interrupt_session(
                "sub_progress", reason="switch", preserve_background=True
            )

            assert result.ok is True
            assert result.result["interrupted"] is True
            assert client.stopped == []
            assert TASK_ID in connection.background.active_ids
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_default_interrupt_stops_background_tasks_explicitly() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(
            host, _single_client_factory(client), {"perTaskStopAffordance": True}
        )
        try:
            await _bind_subagent(host, runtime, client)

            result = await runtime.interrupt_session("sub_progress", reason="user")

            assert result.ok is True
            assert result.result["interrupted"] is True
            assert client.stopped == [TASK_ID]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_default_interrupt_without_the_declaration_does_not_fan_out() -> None:
    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        # The kill-switch, end to end: no declaration, so the CLI interrupt
        # already ends the tasks and the fan-out must not double-fire.
        runtime = _runtime_with_values(
            host, _single_client_factory(client), {"perTaskStopAffordance": False}
        )
        try:
            await _bind_subagent(host, runtime, client)

            await runtime.interrupt_session("sub_progress", reason="user")

            assert client.stopped == []
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --- the wall: wait instead of refusing -------------------------------------


class _CountingFactory:
    def __init__(self, client: Any) -> None:
        self.client = client
        self.calls = 0

    def __call__(self, sdk: Any, options: Any) -> Any:
        _ = sdk
        self.calls += 1
        self.client.options = options
        return self.client


def _switch_runtime(
    host: _RecordingHost,
    factory: Any,
    **value_overrides: float,
) -> ClaudeRuntime:
    sdk = _default_sdk()
    sdk.HookMatcher = _FakeHookMatcher
    values: dict[str, Any] = {
        "environment": {},
        "selectionChangeSettleSeconds": 0.05,
        "selectionChangeDrainCeilingSeconds": 5.0,
    }
    values.update(value_overrides)
    return ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values=values),
        host=host,
        sdk_loader=lambda: sdk,
        client_factory=factory,
    )


def test_selection_change_runs_next_turn_immediately_and_lands_after_drain() -> None:
    """Reversed 2026-10-15 (model-switch-in-process-tasks.md §3.1b): a turn is
    never held behind a selection change.

    This used to assert the queued turn WAITED for the transport's background
    work (the "wall"). `_StoppingClient` has no `set_model` seam, so the change
    cannot be applied in place: the next turn now runs IMMEDIATELY on the live
    transport (old selection, AC2), and the deferred landing rebuilds once the
    background work drains.
    """

    async def run() -> None:
        client = _StoppingClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        stop_affordance._declared = True
        try:
            first_choice, second_choice = await _model_selections(runtime)
            await runtime.start_turn("switch", None, "wait", selections={"model": first_choice})
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"})
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            update = await runtime.update_session_selections(
                "switch", None, {"model": second_choice}
            )
            assert update.ok is True
            assert (await runtime.start_turn("switch", None, "next")).ok is True

            # The next turn runs to completion RIGHT AWAY: it is not held
            # behind the live background work, and nothing is rebuilt under it.
            next_task = runtime._sessions["switch"].active_task
            assert next_task is not None
            await asyncio.wait_for(next_task, 10)
            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted",
                "completed",
            ]
            assert factory.calls == 1  # no rebuild while the worker is live
            assert "bg_1" in connection.background.active_ids  # and nothing killed it

            # The last background task reports terminal: the deferred landing
            # rebuilds the transport on the new selection.
            await client.incoming.put(
                SystemMessage(
                    subtype="task_updated",
                    task_id="bg_1",
                    patch={"status": "completed"},
                    data={"task_id": "bg_1"},
                )
            )
            await _wait_until(lambda: factory.calls == 2)
            connection_now = runtime._turns.runner.connections["switch"]
            assert connection_now.selections["model"] == second_choice
            # Honest states only: no fabricated idle anywhere in the switch,
            # and the completed turn still settles to idle.
            statuses = [
                update["status"]
                for update in host.session_state_updates
                if update["session_id"] == "switch"
            ]
            assert statuses[-1] == "idle"
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_selection_change_never_blocks_a_stop_or_kills_background_work() -> None:
    """Reversed 2026-10-15: there is no message-side "wait" left to cancel.

    This used to assert a stop cancelled the queued turn's wait in the wall.
    The turn no longer waits (AC2), so the shape pinned here is the one that
    still matters: the follow-up message runs immediately on the live
    transport, a stop interrupts that running turn like any other, and the
    background worker keeps its process (no rebuild under live work).

    The discriminator is that the follow-up turn's prompt actually REACHES the
    CLI (a second "wait" query) inside a window well under the drain ceiling —
    under the old wall the turn would be parked in `connection_for` and the
    prompt would never leave (red team Q-5: `not task.done()` alone was true
    under the wall too, so it could not tell the two apart).
    """

    async def run() -> None:
        client = _StoppingClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        # A drain ceiling far above the observation window: if the turn were
        # still waiting in the wall, the prompt could not reach the CLI.
        runtime = _switch_runtime(host, factory)
        stop_affordance._declared = True
        try:
            first_choice, second_choice = await _model_selections(runtime)
            await runtime.start_turn("switch", None, "wait", selections={"model": first_choice})
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"})
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            await runtime.update_session_selections("switch", None, {"model": second_choice})
            # A follow-up that stays open ("wait"). It must reach the CLI
            # promptly — the live transport serves it without waiting for the
            # background work.
            await runtime.start_turn("switch", None, "wait")
            queued_task = runtime._sessions["switch"].active_task
            assert queued_task is not None
            # Event-driven, bounded well under the drain ceiling (5 s): the
            # second "wait" prompt reaching the client proves the turn was not
            # parked. The 3 s window is generous under load yet still discriminates
            # — under the wall the prompt could not arrive until the ceiling.
            await _wait_until(
                lambda: client.queries.count("wait") >= 2,
                timeout=3.0,
            )
            assert factory.calls == 1  # no rebuild under the live worker
            assert not queued_task.done()  # the turn is open (awaiting a reply)

            # A stop interrupts the running turn.
            await runtime.interrupt_session("switch", reason="user")
            await asyncio.wait_for(queued_task, 10)

            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted",
                "interrupted",
            ]
            assert factory.calls == 1  # never rebuilt: nothing was pinned
            assert "bg_1" in connection.background.active_ids  # and nothing killed it
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_selection_change_reuses_the_transport_when_the_switch_is_reverted() -> None:
    async def run() -> None:
        client = _StoppingClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        stop_affordance._declared = True
        try:
            first_choice, second_choice = await _model_selections(runtime)
            await runtime.start_turn("switch", None, "wait", selections={"model": first_choice})
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"})
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            # No in-place seam, so the switch to second is deferred (not waited).
            await runtime.update_session_selections("switch", None, {"model": second_choice})
            await runtime.start_turn("switch", None, "next")
            next_task = runtime._sessions["switch"].active_task
            assert next_task is not None
            await asyncio.wait_for(next_task, 10)
            # The user switches back before the deferral lands.
            await runtime.update_session_selections("switch", None, {"model": first_choice})
            await client.incoming.put(
                SystemMessage(
                    subtype="task_updated",
                    task_id="bg_1",
                    patch={"status": "completed"},
                    data={"task_id": "bg_1"},
                )
            )
            await _wait_until(lambda: not connection.background.active_ids)
            await asyncio.sleep(0.1)

            # No rebuild: the switch back to the transport's current selection
            # cancels the deferral outright.
            assert factory.calls == 1
            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted",
                "completed",
            ]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --- F-B: the drain phase is bounded too -------------------------------------


def test_drain_wait_is_false_at_the_ceiling_and_true_when_drained() -> None:
    """The bounded drain API, at the connection itself (red team F-B)."""

    async def run() -> None:
        connection = ClaudeConnection(
            client=SimpleNamespace(),
            on_activity=_never,
            on_idle=_never,
            on_background_done=_never,
            cleanup=lambda: None,
        )
        # An id whose terminal frame never lands: the ceiling is the only exit.
        connection.background.active_ids.add("bg_stale")
        started = time.monotonic()
        assert await connection.wait_background_drained(ceiling=0.1) is False
        assert time.monotonic() - started >= 0.1

        # A real terminal drains it well inside the ceiling, and the wait
        # really waits until then.
        connection.background.active_ids.discard("bg_stale")
        connection.background.active_ids.add("bg_real")
        waiter = asyncio.create_task(
            connection.wait_background_drained(ceiling=5.0)
        )
        await asyncio.sleep(0.05)
        assert not waiter.done()
        connection.background.observed(
            SystemMessage(
                subtype="task_updated",
                task_id="bg_real",
                patch={"status": "completed"},
                data={"task_id": "bg_real"},
            )
        )
        assert await asyncio.wait_for(waiter, 1) is True

        # A transport already gone has nothing to drain.
        connection.background.active_ids.add("bg_after_close")
        connection.closing = True
        assert await connection.wait_background_drained(ceiling=5.0) is True
        connection.closing = False

    asyncio.run(run())


def test_stale_drain_id_cannot_block_the_message_or_hang_the_landing() -> None:
    """The red-team F-B probe, carried forward onto the new semantics.

    A stale background id whose terminal frame never arrives must not pin the
    user's message (it no longer waits at all — AC2), and it must not hang the
    deferred landing: the landing wait shares the settle ceiling, returns on
    it, and simply cannot rebuild while the id is still (falsely) live.
    """

    async def run() -> None:
        client = _StoppingClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(
            host, factory, selectionChangeDrainCeilingSeconds=0.3
        )
        stop_affordance._declared = True
        try:
            first_choice, second_choice = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first_choice}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            # A background task whose terminal frame never arrives.
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started",
                    task_id="bg_no_terminal",
                    data={"task_id": "bg_no_terminal"},
                )
            )
            await _wait_until(
                lambda: "bg_no_terminal" in connection.background.active_ids
            )

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            update = await runtime.update_session_selections(
                "switch", None, {"model": second_choice}
            )
            assert update.ok is True
            assert (await runtime.start_turn("switch", None, "next")).ok is True
            queued_task = runtime._sessions["switch"].active_task
            assert queued_task is not None

            # The message is NOT held behind the stale id: the turn completes
            # right away on the live transport (AC2).
            await asyncio.wait_for(queued_task, 10)
            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted",
                "completed",
            ]
            # The stale id is (falsely) still live, so the deferred landing
            # cannot rebuild under it: the transport is kept, not killed.
            await asyncio.sleep(0.4)  # past the drain ceiling
            assert factory.calls == 1
            assert "bg_no_terminal" in connection.background.active_ids
            assert not [
                update
                for update in host.session_state_updates
                if (update.get("error") or {})
            ]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --- what the stop reports as killed (the fold set) --------------------------


class _StoppingDispatchClient(_DispatchClient):
    """The subagent-progress dispatch client plus a per-task stop.

    "wait" is the no-reply prompt: the follow-up turn has to stay open, so the
    interrupt has a live execution whose connection snapshot it reads.
    """

    def __init__(self) -> None:
        super().__init__()
        # Same native session id as the wire frames: an interrupt's own
        # terminal frame carries it, and a mismatch would re-scope the card
        # mid-test (the card id derives from the adopted native id).
        self.native_id = str(WIRE_DISPATCH_RECEIPT["session_id"])
        self.stopped: list[str] = []

    async def _complete_query(self, prompt: str) -> None:
        if prompt == "wait":
            await _FakeClaudeClient.query(self, prompt)
            return
        await super()._complete_query(prompt)

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)


class _PartialStopDispatchClient(_StoppingDispatchClient):
    """Accepts one per-task stop and refuses another."""

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)
        if task_id != TASK_ID:
            raise RuntimeError("the CLI refused")


def _fold_spy(monkeypatch: Any, folds: list[tuple[str, ...]]) -> None:
    original = ClaudeTurnRunner.publish_stopped_subagents

    async def spy(self: Any, session: Any, task_ids: Any, *, reason: Any = None) -> Any:
        folds.append(tuple(task_ids))
        return await original(self, session, task_ids, reason=reason)

    monkeypatch.setattr(ClaudeTurnRunner, "publish_stopped_subagents", spy)


def test_preserving_interrupt_folds_nothing_and_leaves_cards_alone(
    monkeypatch: Any,
) -> None:
    """A sparing stop killed no task: folding survivors as killed would both
    lie ("stopped N") and stick — an Agent card marked interrupted does not
    heal."""

    folds: list[tuple[str, ...]] = []
    _fold_spy(monkeypatch, folds)

    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        stop_affordance._declared = True
        try:
            card_id = await _bind_subagent(host, runtime, client)
            connection = runtime._turns.runner.connections["sub_progress"]
            assert TASK_ID in connection.background.active_ids

            result = await runtime.interrupt_session(
                "sub_progress", reason="switch", preserve_background=True
            )

            assert result.ok is True
            assert result.result["interrupted"] is True  # a real stop, not alreadyStopped
            assert folds == []
            assert client.stopped == []
            # The card is untouched: nothing on this path wrote a terminal
            # card, and the agent entry still reads running.
            assert all(item.status != "interrupted" for item in host.timeline_item_upserts)
            assert _card_items(host, card_id)[-1].status == "running"
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "running"
            assert TASK_ID in connection.background.active_ids
        finally:
            stop_affordance._declared = False
            await runtime.stop()

    asyncio.run(run())


def test_default_interrupt_folds_only_the_subagents_it_stopped(
    monkeypatch: Any,
) -> None:
    """The fan-out owns bound subagents only, and the fold reports exactly
    the ones it stopped: bash/workflow tasks have no Agent card, are left for
    the CLI to release, and are never folded as killed."""

    folds: list[tuple[str, ...]] = []
    _fold_spy(monkeypatch, folds)

    async def run() -> None:
        client = _StoppingDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        stop_affordance._declared = True
        try:
            await _bind_subagent(host, runtime, client)
            # A second background task that is *not* a subagent (no card
            # binding) — the bash/workflow shape.
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_bash",
                    data={"task_id": "bg_bash", "task_type": "local_bash"},
                )
            )
            connection = runtime._turns.runner.connections["sub_progress"]
            await _wait_until(lambda: "bg_bash" in connection.background.active_ids)

            result = await runtime.interrupt_session("sub_progress", reason="user")

            assert result.ok is True
            assert result.result["interrupted"] is True
            # Only the bound subagent is stopped …
            assert client.stopped == [TASK_ID]
            # … the non-agent task is left to the CLI's own releasing …
            assert "bg_bash" in connection.background.active_ids
            # … and the killed fold reports exactly the stopped subagent.
            assert folds == [(TASK_ID,)]
            interrupted = [
                item for item in host.timeline_item_upserts if item.status == "interrupted"
            ]
            assert len(interrupted) == 1
            assert (
                (interrupted[0].content.get("agents") or {}).get(TASK_ID, {}).get("status")
                == "killed"
            )
        finally:
            stop_affordance._declared = False
            await runtime.stop()

    asyncio.run(run())
