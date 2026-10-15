"""In-process selection switch (model-switch-in-process-tasks.md, 2026-10-15).

The incident: a user changed a session's model / permission while a background
subagent was running, and every later message was held inside
`wait_for_selection_change` (up to 600 s) — never delivered, never published —
until the ceiling rebuilt the process and killed the subagent. The fix applies
a selection change to the LIVE transport in place (the SDK's `set_model` /
`set_permission_mode`), so the next turn runs on the new selection with no
process rebuild and no message held.

Pinned here:

* a model switch is applied in place, the transport is NOT rebuilt, and the
  connection's selections are updated;
* with live background work, a model switch still applies in place, the user's
  next message is published immediately, and the background work is untouched;
* `bypassPermissions` is the exception (§3.2): it is never applied in place,
  the running process is not rebuilt while background work exists, and the
  deferral is disclosed through a notice;
* a switch that cannot be applied in place (no SDK seam / an upstream refusal)
  degrades to the existing rebuild path and never holds the message;
* a deferred switch lands by rebuilding once the background work drains.
"""

from __future__ import annotations

import asyncio
from typing import Any

from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.turns import lifecycle
from tests.test_claude_runtime import (
    SystemMessage,
    _RecordingHost,
    _ScheduledClaudeClient,
)
from tests.test_claude_stop_affordance import (
    _CountingFactory,
    _model_selections,
    _StoppingClient,
    _switch_runtime,
    _wait_until,
)


class _SwitchableClient(_StoppingClient):
    """A client that accepts the in-process model / permission controls.

    Records what the connector asked it to switch to, so a test can tell the
    in-place path (a `set_model` call, no rebuild) from the rebuild path (a new
    client, no `set_model`).
    """

    def __init__(self) -> None:
        super().__init__()
        self.set_models: list[str | None] = []
        self.set_modes: list[str] = []

    async def set_model(self, model: str | None) -> None:
        self.set_models.append(model)

    async def set_permission_mode(self, mode: str) -> None:
        self.set_modes.append(mode)


async def _bypass_permission(runtime: ClaudeRuntime) -> Any:
    permissions = (await runtime.list_permission_catalog()).permissions
    return next(item for item in permissions if item.id == "bypassPermissions")


async def _plan_permission(runtime: ClaudeRuntime) -> Any:
    permissions = (await runtime.list_permission_catalog(query="plan")).permissions
    return permissions[0]


def _user_items(host: _RecordingHost, text: str) -> list[Any]:
    return [
        item
        for item in host.timeline_item_upserts
        if item.role == "user" and item.content.get("text") == text
    ]


# --- the main path: in-process model switch --------------------------------


def test_in_process_model_switch_applies_to_live_transport_without_rebuild() -> None:
    async def run() -> None:
        client = _SwitchableClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "hello", selections={"model": first}
            )
            task = runtime._sessions["switch"].active_task
            assert task is not None
            await asyncio.wait_for(task, 5)
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]

            update = await runtime.update_session_selections(
                "switch", None, {"model": second}
            )

            assert update.ok is True
            # Applied in place: the CLI was told the new model on the SAME
            # process, and the factory never ran a second time.
            assert client.set_models == ["claude-opus-5"]
            assert factory.calls == 1
            assert connection.selections["model"] == second
            assert runtime._turns.runner.connections["switch"] is connection
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_model_and_permission_halves_apply_concurrently() -> None:
    """A PATCH changing BOTH halves runs them concurrently, not in sequence.

    Each control request is bounded by the 20 s seam timeout; run in sequence
    they would stack to ~40 s and blow the server's 30 s RPC budget
    (`server/agent_server/services/session_run.py`). The two halves are
    gathered, so both enter their control call within one window. The barrier
    proves it: it only releases when BOTH calls are in flight at once — under a
    sequential implementation the first call blocks on the barrier and the
    request times out (red team P2-1).
    """

    class _BarrierClient(_SwitchableClient):
        def __init__(self) -> None:
            super().__init__()
            self.barrier = asyncio.Barrier(parties=2)

        async def set_model(self, model: str | None) -> None:
            self.set_models.append(model)
            # A short, generous window: concurrent calls meet at the barrier;
            # a sequential caller would hit the caller-side timeout instead.
            await asyncio.wait_for(self.barrier.wait(), timeout=2.0)

        async def set_permission_mode(self, mode: str) -> None:
            self.set_modes.append(mode)
            await asyncio.wait_for(self.barrier.wait(), timeout=2.0)

    async def run() -> None:
        client = _BarrierClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            plan = await _plan_permission(runtime)
            await runtime.start_turn(
                "switch", None, "hello", selections={"model": first}
            )
            task = runtime._sessions["switch"].active_task
            assert task is not None
            await asyncio.wait_for(task, 5)

            update = await runtime.update_session_selections(
                "switch",
                None,
                {"model": second, "permission": plan.selection_id},
            )
            assert update.ok is True
            # Both halves ran and met at the barrier (no timeout, so no partial
            # failure), and the change is fully applied in place.
            assert client.set_models == ["claude-opus-5"]
            assert client.set_modes == ["plan"]
            assert factory.calls == 1
            connection = runtime._turns.runner.connections["switch"]
            assert connection.selections["model"] == second
            assert connection.selections["permission"] == plan.selection_id
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_active_background_model_switch_publishes_next_message_without_stopping_work() -> None:
    """The incident, replayed: background live + model switch + a new message.

    The message must reach the timeline immediately (AC2) and the background
    subagent must keep its process (AC4). The model change rides the same
    process in place (AC1).
    """

    async def run() -> None:
        client = _SwitchableClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            update = await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            assert update.ok is True

            # Applied in place even with live background work: no rebuild and
            # nothing killed.
            assert client.set_models == ["claude-opus-5"]
            assert factory.calls == 1
            assert connection.selections["model"] == second
            assert client.stopped == []
            assert "bg_1" in connection.background.active_ids

            # The next message is published immediately — never held behind
            # the background work.
            assert (await runtime.start_turn("switch", None, "next")).ok is True
            await _wait_until(lambda: bool(_user_items(host, "next")))
            assert factory.calls == 1
            assert "bg_1" in connection.background.active_ids
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- the exception: bypassPermissions (§3.2 A) -----------------------------


def test_bypass_permission_is_deferred_and_never_rebuilds_under_background_work() -> None:
    async def run() -> None:
        client = _SwitchableClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            await runtime.start_turn("switch", None, "wait")
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            bypass = await _bypass_permission(runtime)
            update = await runtime.update_session_selections(
                "switch", None, {"permission": bypass.selection_id}
            )
            assert update.ok is True

            # The in-place permission path is NOT taken, and the process is
            # not rebuilt under the live background worker.
            assert client.set_modes == []
            assert factory.calls == 1
            assert connection.closing is False
            assert connection.selections.get("permission") != bypass.selection_id
            assert "bg_1" in connection.background.active_ids

            # The deferral is disclosed, not silent.
            assert any(
                notice.source.get("kind") == "selection_deferred"
                for notice in host.notice_upserts
            )

            # The user's next message is published immediately all the same.
            assert (await runtime.start_turn("switch", None, "next")).ok is True
            await _wait_until(lambda: bool(_user_items(host, "next")))
            assert factory.calls == 1  # still not rebuilt
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- the fallback: no seam / refusal ---------------------------------------


def test_switch_without_sdk_seam_degrades_to_rebuild_and_never_holds_message() -> None:
    async def run() -> None:
        # A plain scheduled client carries no `set_model` seam at all.
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "hello", selections={"model": first}
            )
            await asyncio.wait_for(runtime._sessions["switch"].active_task, 5)

            update = await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            assert update.ok is True

            # No in-place path: the idle refresh rebuilds the transport, which
            # carries the new selection.
            assert factory.calls == 2
            connection = runtime._turns.runner.connections["switch"]
            assert connection.selections["model"] == second

            assert (await runtime.start_turn("switch", None, "again")).ok is True
            await _wait_until(lambda: bool(_user_items(host, "again")))
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_transient_refusal_retries_without_rebuild_and_never_holds_the_message() -> None:
    """The real-CLI probe's hard fact (2026-10-15): a refusal is retryable.

    `set_model` is answered only after the CLI's 1-token model-validation probe
    against the API; when that probe stalls the CLI refuses with
    `retryable: true`. That must NOT be answered by rebuilding the process —
    which would kill the live background worker — so the connector keeps the
    session on the old selection, retries with a bounded count, and never holds
    the user's message. The clause under test: **no rebuild** + **message runs**
    + **a retry actually happens**.
    """

    class _FlakyClient(_SwitchableClient):
        """Refuses the first N in-place attempts, then accepts."""

        def __init__(self, refusals: int) -> None:
            super().__init__()
            self._refusals_left = refusals

        async def set_model(self, model: str | None) -> None:
            self.set_models.append(model)
            if self._refusals_left > 0:
                self._refusals_left -= 1
                raise RuntimeError("Couldn't confirm model with the API")

    async def run() -> None:
        client = _FlakyClient(refusals=1)
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(
            host, factory, selectionInProcessRetryDelaySeconds=0.05
        )
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            update = await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            assert update.ok is True
            # First attempt refused: NOT a rebuild, still on the old selection,
            # and the worker is untouched.
            assert factory.calls == 1
            assert connection.selections["model"] == first
            assert "bg_1" in connection.background.active_ids
            # An honest "not yet in effect" state is published.
            assert any(
                update["metadata"] and update["metadata"].get("selectionPending")
                for update in host.session_state_updates
                if update["session_id"] == "switch"
            )

            # The user's message is published immediately all the same (AC2).
            assert (await runtime.start_turn("switch", None, "next")).ok is True
            await _wait_until(lambda: bool(_user_items(host, "next")))
            assert factory.calls == 1  # still no rebuild

            # The bounded retry lands the change IN PLACE — a second attempt,
            # no rebuild, and the worker keeps its process.
            await _wait_until(lambda: len(client.set_models) >= 2)
            await _wait_until(lambda: connection.selections["model"] == second)
            assert factory.calls == 1
            assert "bg_1" in connection.background.active_ids
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_giving_up_clears_the_pending_state_and_discloses() -> None:
    """An exhausted retry must not go silent, and must not leave stale state
    (red team P2-2).

    When every bounded attempt is refused, `selectionPending` / `selectionTarget`
    / `statusReason` would otherwise ride every later update (sticky metadata),
    and the client — already told the new selection at PATCH time — would show
    "new model, old behaviour" with no explanation. Both obligations: the keys
    are cleared AND a deferral notice is published.
    """

    class _AlwaysRefusingClient(_SwitchableClient):
        async def set_model(self, model: str | None) -> None:
            self.set_models.append(model)
            raise RuntimeError("Couldn't confirm model with the API")

    async def run() -> None:
        client = _AlwaysRefusingClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(
            host, factory, selectionInProcessRetryDelaySeconds=0.02
        )
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            # Runs to the attempt ceiling: the pending state is dropped and the
            # deferral is disclosed rather than going silent.
            await _wait_until(
                lambda: "switch" not in runtime._turns.runner._pending_selections,
                timeout=5.0,
            )
            assert len(client.set_models) >= 4  # the retries really happened
            assert factory.calls == 1  # never rebuilt under the live worker

            # The deferral notice exists (not silent).
            assert any(
                notice.source.get("kind") == "selection_deferred"
                for notice in host.notice_upserts
            )
            # The sticky pending keys are cleared (the last published state no
            # longer carries them as truthy).
            assert host.session_state_updates[-1]["metadata"].get(
                "selectionPending"
            ) is False
            assert host.session_state_updates[-1]["metadata"].get(
                "selectionTarget"
            ) is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_give_up_when_background_drained_states_no_false_reason() -> None:
    """The give-up disclosure must not claim a reason that stopped holding.

    The retry loop sleeps for `SELECTION_IN_PROCESS_RETRY_DELAY_SECONDS` between
    checking `background.active_ids` and the give-up, so background work can
    drain inside that gap. Reusing the "有后台任务在跑" text there would assert a
    fact that is no longer true (red team). This drives exactly that: the
    background drains DURING a retry sleep, the retry reaches the ceiling, and
    the emitted notice must be the neutral one — content read from the live
    state, not assumed.
    """

    completed = SystemMessage(
        subtype="task_updated",
        task_id="bg_1",
        patch={"status": "completed"},
        data={"task_id": "bg_1"},
    )
    max_attempts = lifecycle.SELECTION_IN_PROCESS_MAX_ATTEMPTS

    class _RefusingDrainsClient(_SwitchableClient):
        """Refuses every in-place attempt; drains the background mid-retry.

        On the final ceiling attempt the callback is scheduled to complete the
        background task a moment later — i.e. inside the retry loop's next
        sleep — so the give-up path reads an empty `active_ids`.
        """

        def __init__(self) -> None:
            super().__init__()
            self.drained_once = False

        async def set_model(self, model: str | None) -> None:
            self.set_models.append(model)
            # The ceiling give-up fires on the call AFTER the MAX-th refusal, so
            # arm the drain on the MAX-th attempt (1 PATCH-time + retries).
            if not self.drained_once and len(self.set_models) == max_attempts + 1:
                self.drained_once = True
                asyncio.get_running_loop().call_later(
                    0.03, self.incoming.put_nowait, completed
                )
            raise RuntimeError("Couldn't confirm model with the API")

    async def run() -> None:
        client = _RefusingDrainsClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(
            host, factory, selectionInProcessRetryDelaySeconds=0.2
        )
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            await _wait_until(
                lambda: "switch" not in runtime._turns.runner._pending_selections,
                timeout=10.0,
            )
            assert client.drained_once  # the mid-retry drain really happened

            deferred = [
                notice
                for notice in host.notice_upserts
                if notice.source.get("kind") == "selection_deferred"
            ]
            assert deferred  # a disclosure always happens on give-up
            messages = [notice.message for notice in deferred]
            # The neutral text was used; the false-cause text was NOT.
            assert any(
                m == lifecycle.SELECTION_UNLANDED_MESSAGE for m in messages
            )
            assert all("有后台任务在跑" not in m for m in messages)
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_notice_resolves_when_the_next_turn_rebuilds() -> None:
    """An open deferral notice is retired wherever the change lands.

    Red team Q-4: the capability deferral is disclosed in `_defer_selection_change`,
    but if the change only lands later — via the next turn's `connection_for`
    rebuild once the background work is gone — an unresolve there would leave a
    `status=open` row hanging forever. This drives that exact path.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()  # no in-place seam: forces the deferral
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            # A deferral notice is open, and no rebuild yet.
            assert any(
                notice.source.get("kind") == "selection_deferred"
                and notice.status == "open"
                for notice in host.notice_upserts
            )

            # The background work finishes, then the next turn rebuilds.
            await client.incoming.put(
                SystemMessage(
                    subtype="task_updated",
                    task_id="bg_1",
                    patch={"status": "completed"},
                    data={"task_id": "bg_1"},
                )
            )
            await _wait_until(lambda: not connection.background.active_ids)
            await runtime.start_turn("switch", None, "next")
            await _wait_until(lambda: factory.calls == 2)
            await _wait_until(
                lambda: any(
                    notice.source.get("kind") == "selection_deferred"
                    and notice.status == "resolved"
                    for notice in host.notice_upserts
                )
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --- the deferral lands once the background work drains --------------------


def test_effort_only_change_rebuilds_and_does_not_call_set_model() -> None:
    """A reasoning-effort change needs the launch argument, not `set_model`.

    `set_model` carries the model id only; the SDK exposes no seam for effort.
    So switching effort on the SAME model must NOT be applied in place — it
    falls to the rebuild, which is what actually carries `options.effort`. The
    guard is load-bearing (red team Q-6: removing it left 32 tests green while
    silently leaving the user on the wrong effort, un-rebuilt). The clause
    under test: **no `set_model` call** + **a rebuild** + **the new effort**.
    """

    async def run() -> None:
        client = _SwitchableClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            catalog = await runtime.list_model_catalog()
            model = next(
                item for item in catalog.models if len(item.reasoning_items) >= 2
            )
            low = next(e for e in model.reasoning_items if e.id == "low")
            high = next(e for e in model.reasoning_items if e.id == "high")

            await runtime.start_turn(
                "switch", None, "hello", selections={"model": low.selection_id}
            )
            task = runtime._sessions["switch"].active_task
            assert task is not None
            await asyncio.wait_for(task, 5)
            assert client.options.kwargs["effort"] == "low"

            update = await runtime.update_session_selections(
                "switch", None, {"model": high.selection_id}
            )
            assert update.ok is True
            # Not applicable in place: the model id is unchanged, so the model
            # half needs nothing, and the effort half has no seam.
            assert client.set_models == []
            # The idle rebuild lands it, carrying the new effort.
            assert factory.calls == 2
            assert client.options.kwargs["effort"] == "high"
            connection = runtime._turns.runner.connections["switch"]
            assert connection.selections["model"] == high.selection_id
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_deferred_switch_lands_after_background_drains() -> None:
    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        factory = _CountingFactory(client)
        runtime = _switch_runtime(host, factory)
        try:
            first, second = await _model_selections(runtime)
            await runtime.start_turn(
                "switch", None, "wait", selections={"model": first}
            )
            await _wait_until(lambda: "switch" in runtime._turns.runner.connections)
            connection = runtime._turns.runner.connections["switch"]
            await client.incoming.put(
                SystemMessage(
                    subtype="task_started", task_id="bg_1", data={"task_id": "bg_1"}
                )
            )
            await _wait_until(lambda: "bg_1" in connection.background.active_ids)

            await runtime.interrupt_session(
                "switch", reason="switch", preserve_background=True
            )
            update = await runtime.update_session_selections(
                "switch", None, {"model": second}
            )
            assert update.ok is True
            assert factory.calls == 1  # deferred, not rebuilt

            # The background worker finishes: the landing task rebuilds the
            # transport on the new selection.
            await client.incoming.put(
                SystemMessage(
                    subtype="task_updated",
                    task_id="bg_1",
                    patch={"status": "completed"},
                    data={"task_id": "bg_1"},
                )
            )
            await _wait_until(lambda: factory.calls == 2)
            landed = runtime._turns.runner.connections["switch"]
            assert landed.selections["model"] == second
        finally:
            await runtime.stop()

    asyncio.run(run())
