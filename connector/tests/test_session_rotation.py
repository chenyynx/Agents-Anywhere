"""Session-list rotation across the whole library (T1, stale-residue-selfheal).

`.local-dev/stale-residue-selfheal-tasks.md` §3 T1: a runtime without a complete
session inventory lists one bounded first page per cycle, so sessions past it
were never compared and their stale rows were never rebuilt (residue cause ③).
The rotation fetches one further window per cycle — on demand, budgeted, and
switchable — and runs it through the existing marker-comparison flow.

These tests drive the real `RuntimeSyncRunner` against a paged runtime that
records every discovery call, so the ladder (offset order, wrap, sleep), the
rebuild budget, the report mode's no-side-effect promise and the kill-switch
are all pinned to observable behavior rather than internal attributes.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_connector_runtime import (
    FakeAgentRuntime,
    FakeRuntimeSupervisor,
    RecordingRuntimeHost,
    unused_notification_sender,
)

from connector.core.config import ConnectorConfig
from connector.runtime_protocol import SessionMeta
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
    SESSION_ROTATION_REBUILD_BUDGET,
    RuntimeSyncRunner,
    _session_rotation_state_key,
)

ROTATION_STATE_KEY = _session_rotation_state_key("claude", "claude")


def _meta(
    index: int,
    *,
    requires_sync: bool = False,
    projection_outdated: bool | None = None,
) -> SessionMeta:
    sync: dict[str, Any] = {
        "marker": f"marker-{index}",
        "changed": requires_sync,
        "requires_timeline_sync": requires_sync,
    }
    if projection_outdated is not None:
        sync["projection_outdated"] = projection_outdated
    return SessionMeta(
        session_id=f"sess_{index:03d}",
        external_session_id=f"ext_{index:03d}",
        runtime="claude",
        title=f"Session {index}",
        cwd="/repo",
        ordering_time="2026-08-01T00:00:00Z",
        metadata={"source": "claude.session/list", "sync": sync},
    )


class StatefulRecordingHost(RecordingRuntimeHost):
    """Recording host with a dict-backed sync state store."""

    def __init__(self) -> None:
        super().__init__()
        self.state: dict[str, dict[str, Any]] = {}

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.state.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        await super().sync_state_write(key, value)
        self.state[key] = dict(value)


class PagedRuntime(FakeAgentRuntime):
    """A runtime whose session list is served window by window, like the SDK's."""

    def __init__(self, *, runtime_id: str = "claude") -> None:
        super().__init__(runtime_id)
        self.page_one: tuple[SessionMeta, ...] = ()
        self.rotation_pages: dict[int, tuple[SessionMeta, ...]] = {}
        self.cursors: list[str | None] = []
        self.snapshot_failures: set[str] = set()

    async def list_sessions(
        self,
        limit: int = 100,
        cursor: str | None = None,
        force: bool = False,
    ) -> tuple[SessionMeta, ...]:
        self.calls.append(
            ("session.discover", {"limit": limit, "cursor": cursor, "force": force})
        )
        self.cursors.append(cursor)
        if cursor is None:
            return self.page_one[:limit]
        return self.rotation_pages.get(int(cursor), ())[:limit]

    async def get_session_snapshot(
        self,
        session_id: str,
        external_session_id: str | None = None,
        limit: int | None = None,
    ):
        if session_id in self.snapshot_failures:
            raise RuntimeError("snapshot read failed")
        return await super().get_session_snapshot(
            session_id, external_session_id, limit
        )


def _runner(
    runtime: Any,
    host: Any,
) -> tuple[RuntimeSyncRunner, list[dict[str, Any]]]:
    notifications: list[dict[str, Any]] = []

    async def ingest(batch: list[dict[str, Any]]) -> None:
        notifications.extend(batch)

    runner = RuntimeSyncRunner(
        config=ConnectorConfig(
            server_url="http://127.0.0.1:8000",
            connector_id="conn_1",
            connector_token="token",
        ),
        supervisor=FakeRuntimeSupervisor(runtime),  # type: ignore[arg-type]
        host=host,
        preferences_reader=dict,
        send_notification=unused_notification_sender,
        ingest_notifications=ingest,
    )
    return runner, notifications


def _timeline_session_ids(notifications: list[dict[str, Any]]) -> list[str]:
    return [
        notification["params"]["sessionId"]
        for notification in notifications
        if notification["method"] == "timeline.sync"
    ]


def _all_session_ids(notifications: list[dict[str, Any]]) -> set[str]:
    ids: set[str] = set()
    for notification in notifications:
        session_id = notification["params"].get("sessionId")
        if isinstance(session_id, str):
            ids.add(session_id)
    return ids


def test_rotation_off_by_default_is_the_old_behavior(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_off_by_default(monkeypatch))


async def _exercise_rotation_off_by_default(monkeypatch) -> None:
    monkeypatch.delenv(SESSION_ROTATION_ENV, raising=False)
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    await runner.sync_existing_once()

    # Page 1 behaves exactly as before: fetched, compared, rebuilt. The
    # rotation is never consulted — not even its state is read or written.
    assert runtime.cursors == [None]
    assert _timeline_session_ids(notifications) == ["sess_000"]
    assert ROTATION_STATE_KEY not in host.state


def test_rotation_kill_switch_off_matches_default(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_kill_switch_off(monkeypatch))


async def _exercise_rotation_kill_switch_off(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "off")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    await runner.sync_existing_once()

    assert runtime.cursors == [None]
    assert _timeline_session_ids(notifications) == ["sess_000"]
    assert ROTATION_STATE_KEY not in host.state


def test_rotation_stays_asleep_without_a_projection_signal(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_stays_asleep(monkeypatch))


async def _exercise_rotation_stays_asleep(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    # Page 1 is busy (freshness) but nothing says its projection is outdated:
    # a plain marker change must not open a library sweep.
    runtime.page_one = (_meta(0, requires_sync=True),)
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    await runner.sync_existing_once()

    assert runtime.cursors == [None]
    assert ROTATION_STATE_KEY not in host.state


def test_rotation_report_mode_quantifies_without_session_side_effects(
    monkeypatch,
) -> None:
    asyncio.run(_exercise_rotation_report_mode(monkeypatch))


async def _exercise_rotation_report_mode(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "report")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        100: (_meta(101, requires_sync=True), _meta(102, requires_sync=True))
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    await runner.sync_existing_once()

    # The window was walked and counted...
    assert runtime.cursors == [None, str(SESSION_ROTATION_FIRST_OFFSET)]
    state = host.state[ROTATION_STATE_KEY]
    assert state["active"] is True
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE
    assert state["circleCandidates"] == 2
    assert state["circleRebuilt"] == 0
    # ...and nothing about those sessions reached the platform.
    assert notifications == []
    assert _all_session_ids(notifications) == set()

    # The rest of the circle: an empty window ends it and puts the sweep to
    # sleep. Report mode walks exactly one circle per activation.
    await runner.sync_existing_once()
    assert runtime.cursors == [
        None,
        str(SESSION_ROTATION_FIRST_OFFSET),
        None,
        str(SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE),
    ]
    assert notifications == []
    assert host.state[ROTATION_STATE_KEY]["active"] is False


def test_rotation_rebuilds_sessions_past_the_first_page(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_rebuilds_page_two(monkeypatch))


async def _exercise_rotation_rebuilds_page_two(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True), _meta(102))}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    await runner.sync_existing_once()

    # Page 1 keeps its freshness rebuild; the rotation reached the second
    # window and rebuilt the session whose marker demanded it — and only it.
    assert runtime.cursors == [None, str(SESSION_ROTATION_FIRST_OFFSET)]
    assert _timeline_session_ids(notifications) == ["sess_000", "sess_101"]
    state = host.state[ROTATION_STATE_KEY]
    assert state["active"] is True
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE
    assert state["circleCandidates"] == 1
    assert state["circleRebuilt"] == 1


def test_rotation_wraps_after_a_clean_circle_then_sleeps(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_wrap_and_sleep(monkeypatch))


async def _exercise_rotation_wrap_and_sleep(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    # Cycle 1: activated, window 100 walked and its candidate rebuilt.
    await runner.sync_existing_once()
    assert runtime.cursors[-2:] == [None, "100"]
    assert host.state[ROTATION_STATE_KEY]["circleRebuilt"] == 1

    # Cycle 2: window 200 is empty — the circle ends with rebuild progress, so
    # the ladder wraps to the start of the rotation range and keeps scanning.
    await runner.sync_existing_once()
    assert runtime.cursors[-2:] == [None, "200"]
    state = host.state[ROTATION_STATE_KEY]
    assert state["active"] is True
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET

    # Cycles 3-4: everything compares clean now (the rebuild landed, the
    # trigger cleared), so the sweep completes and sleeps.
    runtime.page_one = (_meta(0),)
    runtime.rotation_pages = {100: (_meta(101),)}
    await runner.sync_existing_once()
    assert runtime.cursors[-2:] == [None, "100"]
    await runner.sync_existing_once()
    assert runtime.cursors[-2:] == [None, "200"]
    assert host.state[ROTATION_STATE_KEY]["active"] is False

    # Awake cycles after that cost nothing: no further window is fetched.
    fetches_before = len(runtime.cursors)
    await runner.sync_existing_once()
    assert len(runtime.cursors) == fetches_before + 1
    assert runtime.cursors[-1] is None
    assert _timeline_session_ids(notifications) == ["sess_101"]


def test_rotation_budget_caps_rebuilds_per_cycle(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_budget(monkeypatch))


async def _exercise_rotation_budget(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        100: tuple(_meta(100 + index, requires_sync=True) for index in range(20))
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    await runner.sync_existing_once()
    assert len(_timeline_session_ids(notifications)) == SESSION_ROTATION_REBUILD_BUDGET
    assert host.state[ROTATION_STATE_KEY]["circleRebuilt"] == (
        SESSION_ROTATION_REBUILD_BUDGET
    )

    # Empty tail window: the circle ends, progress was made, so it wraps and
    # the still-outdated candidates wait for the next visit.
    await runner.sync_existing_once()
    assert host.state[ROTATION_STATE_KEY]["offset"] == SESSION_ROTATION_FIRST_OFFSET

    await runner.sync_existing_once()
    assert (
        len(_timeline_session_ids(notifications)) == 2 * SESSION_ROTATION_REBUILD_BUDGET
    )


def test_rotation_resumes_from_persisted_state_after_restart(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_restart(monkeypatch))


async def _exercise_rotation_restart(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    await runner.sync_existing_once()
    assert host.state[ROTATION_STATE_KEY]["offset"] == 200

    # A restart: a fresh runner with no in-memory state, the same state store,
    # and a page 1 that no longer carries the activation signal (its session
    # was rebuilt above). The sweep must resume where it stopped, not restart.
    runtime.page_one = (_meta(0),)
    restarted, _notifications = _runner(runtime, host)
    await restarted.sync_existing_once()

    assert runtime.cursors[-2:] == [None, "200"]


def test_rotation_stall_guard_gives_up_on_a_poison_session(monkeypatch) -> None:
    asyncio.run(_exercise_rotation_stall_guard(monkeypatch))


async def _exercise_rotation_stall_guard(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
    runtime.snapshot_failures = {"sess_101"}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    # Each circle visits the poison window once (its rebuild fails) and ends on
    # the empty tail, until the stall limit puts the sweep to sleep.
    for _ in range(6):
        await runner.sync_existing_once()

    state = host.state[ROTATION_STATE_KEY]
    assert state["active"] is False
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET
    assert _timeline_session_ids(notifications) == []

    # With the trigger gone as well, later cycles cost nothing.
    runtime.page_one = (_meta(0),)
    fetches_before = len(runtime.cursors)
    await runner.sync_existing_once()
    assert len(runtime.cursors) == fetches_before + 1


def test_rotation_reaches_claude_sessions_past_the_first_page(
    monkeypatch,
) -> None:
    asyncio.run(_exercise_rotation_reaches_claude_sessions(monkeypatch))


async def _exercise_rotation_reaches_claude_sessions(monkeypatch) -> None:
    """End to end through the real Claude reader and history syncer.

    The reader serves page 1 (offset 0) and the rotation window (offset 100)
    from the same SDK listing, and the runner rebuilds what the comparison
    flags — which is the whole point of T1: sessions the old single-page scan
    could never reach are compared, marked needs-sync, and rebuilt.
    """

    from test_claude_runtime import _HistorySdk, _RecordingHost, _runtime

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(
        sessions=[
            SimpleNamespace(
                session_id=f"claude_rot_{index:03d}",
                summary=f"Rotation {index}",
                last_modified=1_789_000_000_000 - index,
                file_size=123 + index,
                cwd="/repo",
            )
            for index in range(130)
        ]
    )
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        # Catalogs are their own subsystem with their own tests; the rotation
        # only needs the session-sync path.
        return None

    runner, notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    await runner.sync_existing_once()

    rotation_syncs = [
        notification
        for notification in notifications
        if notification["method"] == "timeline.sync"
        and str(notification["params"].get("externalSessionId", "")).startswith(
            ("claude_rot_1",)
        )
    ]
    page_one_syncs = [
        notification
        for notification in notifications
        if notification["method"] == "timeline.sync"
        and str(notification["params"].get("externalSessionId", "")).startswith(
            ("claude_rot_0",)
        )
    ]
    # Page 1 keeps its old behavior (everything compares changed on a fresh
    # store, so everything rebuilds)...
    assert len(page_one_syncs) == 100
    # ...and the rotation window reached the 30 sessions past it, rebuilding
    # up to the per-cycle budget of them.
    assert len(rotation_syncs) == SESSION_ROTATION_REBUILD_BUDGET
    state = host.sync_states[ROTATION_STATE_KEY]
    assert state["active"] is True
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE
    assert state["circleCandidates"] == 30
    assert state["circleRebuilt"] == SESSION_ROTATION_REBUILD_BUDGET


