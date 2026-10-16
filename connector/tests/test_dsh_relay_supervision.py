from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

from connector.runtimes.dsh.bridge.sync import SyncRelay


def _batch(stream_id: str, seq: int, projection_version: int = 3) -> dict:
    op = {"kind": "notifications", "notifications": [{"method": "session.state.updated", "params": {"sessionId": "session", "status": "idle"}}]}
    return {"streamId": stream_id, "batchSeq": seq, "projectionVersion": projection_version, "operations": [op]}


def _client(subscriptions: list[str], acks: list[int], acknowledged: asyncio.Event):
    async def request(method, params=None):
        if method == "runtime.sync.subscribe":
            subscriptions.append(f"stream-{len(subscriptions) + 1}")
            return {"streamId": subscriptions[-1], "projectionVersion": 3}
        if method == "runtime.sync.ack":
            acks.append(params["batchSeq"])
            acknowledged.set()
        return {"ok": True}

    return SimpleNamespace(request=request, writer=Mock(), connected=True)


def test_health_reports_that_fail_never_stop_the_relay():
    # The backend socket may be down while the bridge is healthy: reporting
    # "syncing" / "interrupted" / "running" must not kill the sync loop (#293).
    async def exercise():
        subscriptions, acks, acknowledged = [], [], asyncio.Event()
        client = _client(subscriptions, acks, acknowledged)
        host = SimpleNamespace(
            session_state_update=AsyncMock(),
            runtime_health_update=AsyncMock(side_effect=RuntimeError("backend websocket is not connected")),
        )
        relay = SyncRelay(client, host, retry_delay=0.01)
        relay.start()
        try:
            await asyncio.sleep(0)
            relay.accept(_batch("stream-1", 1))
            await asyncio.wait_for(acknowledged.wait(), 1)
            assert acks == [1]
            assert relay.failures == 0
            # A broken batch interrupts the feed; the relay resubscribes instead of dying.
            relay.accept(_batch("stream-1", 2, projection_version=2))
            for _ in range(200):
                if len(subscriptions) >= 2:
                    break
                await asyncio.sleep(0.01)
            assert len(subscriptions) >= 2
            assert relay.failures == 1
            assert not relay.task.done()
            acknowledged.clear()
            relay.accept(_batch("stream-2", 1))
            await asyncio.wait_for(acknowledged.wait(), 1)
            assert acks == [1, 1]
            assert relay.failures == 0
        finally:
            await relay.close()
    asyncio.run(exercise())


def test_consecutive_failures_back_off_and_a_delivered_batch_resets_the_counter():
    async def exercise():
        subscriptions, acks, acknowledged = [], [], asyncio.Event()
        client = _client(subscriptions, acks, acknowledged)
        host = SimpleNamespace(session_state_update=AsyncMock(), runtime_health_update=AsyncMock())
        relay = SyncRelay(client, host, retry_delay=0.01)
        relay.start()
        try:
            await asyncio.sleep(0)
            for attempt in range(1, 4):
                relay.accept(_batch(f"stream-{attempt}", 1, projection_version=2))
                for _ in range(300):
                    if len(subscriptions) > attempt:
                        break
                    await asyncio.sleep(0.005)
                assert relay.failures == attempt
            relay.accept(_batch(f"stream-{len(subscriptions)}", 1))
            await asyncio.wait_for(acknowledged.wait(), 1)
            assert relay.failures == 0
        finally:
            await relay.close()
    asyncio.run(exercise())


def test_exit_hook_reports_unexpected_death_but_not_a_normal_close():
    async def exercise():
        exits = []
        relay = SyncRelay(Mock(), SimpleNamespace(runtime_health_update=AsyncMock()), on_exit=lambda r, error: exits.append((r, error)))

        async def crash():
            raise RuntimeError("relay bug")

        relay.run = crash  # type: ignore[method-assign]
        relay.start()
        await asyncio.gather(relay.task, return_exceptions=True)
        await asyncio.sleep(0)
        assert len(exits) == 1 and exits[0][0] is relay and isinstance(exits[0][1], RuntimeError)

        closed = SyncRelay(Mock(), SimpleNamespace(runtime_health_update=AsyncMock()), on_exit=lambda r, error: exits.append((r, error)))

        async def wait_forever():
            await asyncio.Event().wait()

        closed.run = wait_forever  # type: ignore[method-assign]
        closed.start()
        await asyncio.sleep(0)
        await closed.close()
        await asyncio.sleep(0)
        assert len(exits) == 1
    asyncio.run(exercise())


def test_runtime_rebuilds_a_relay_that_died_from_a_bug(monkeypatch):
    from connector.runtime_protocol.models import RuntimeConfig
    from connector.runtimes.dsh import runtime as runtime_module
    from connector.runtimes.dsh.runtime import DshRuntime

    monkeypatch.setattr(runtime_module, "RELAY_RESTART_DELAY_SECONDS", 0.01)

    async def exercise():
        host = SimpleNamespace(connector_id="test", runtime_health_update=AsyncMock())
        runtime = DshRuntime(RuntimeConfig("dsh", 2), host)
        subscriptions, acks, acknowledged = [], [], asyncio.Event()
        client = _client(subscriptions, acks, acknowledged)
        runtime._client = client
        dead = SyncRelay(client, host, on_exit=runtime._relay_exited)
        runtime._sync = dead

        async def crash():
            raise RuntimeError("relay bug")

        dead.run = crash  # type: ignore[method-assign]
        dead.start()
        await asyncio.gather(dead.task, return_exceptions=True)
        await asyncio.sleep(0)
        assert runtime._relay_restart_task is not None
        await asyncio.wait_for(runtime._relay_restart_task, 1)
        replacement = runtime._sync
        try:
            assert replacement is not None and replacement is not dead
            for _ in range(100):
                if subscriptions:
                    break
                await asyncio.sleep(0.01)
            assert subscriptions == ["stream-1"], "the replacement relay subscribes on its own"
            host.runtime_health_update.assert_awaited()

            # A relay that was closed on purpose, or a runtime that is stopping, is left alone.
            runtime._stopping = True
            runtime._relay_exited(replacement, RuntimeError("late"))
            assert runtime._relay_restart_task.done()
            runtime._stopping = False
            runtime._relay_exited(replacement, None)
            assert runtime._relay_restart_task.done()
        finally:
            if replacement is not None:
                await replacement.close()
    asyncio.run(exercise())
