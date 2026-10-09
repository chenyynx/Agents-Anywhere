"""Small-library rotation: page 1's own coverage verdict (T1b).

Task sheet `.local-dev/stale-residue-selfheal-tasks.md` §3 T1b. A library whose
whole session list fits inside the first page (history shorter than `limit`, so
every rotation window past the seam is legitimately empty) can never prove its
end the way the ladder does — an empty window is not proof (R1 P1-2/P1-3) — so
from c1 on the sweep read one empty window per cycle forever (60-cycle probe:
`~/aa-test/probe_small_library.py`, never disarmed). Page 1 now reports the
coverage verdict itself (`SessionListPage.page_one_complete`), `read_failed`
rides the page-1 result so a failed read is not mistaken for displacement, and
the ladder starts at 0 when a seam-0 page really did leave readable history
behind.

These tests are the non-hollow half of the fix. Against the unfixed tree
(3ed7db73) the behavioral ones go red — the sweep keeps scanning windows — and
the reader-level ones raise on the missing verdict; here they all pass.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import _HistorySdk, _RecordingHost, _runtime
from test_session_rotation import (
    ROTATION_STATE_KEY,
    PagedRuntime,
    StatefulRecordingHost,
    _meta,
    _runner,
)

from connector.logging import logger
from connector.runtime_protocol.instance_binding import RuntimeInstance
from connector.runtime_protocol.instance_models import RuntimeInstanceSpec
from connector.runtimes.claude.sessions.reader import SessionListPage
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
    _first_rotation_offset,
    session_rotation_state_from_mapping,
)


def _spec() -> RuntimeInstanceSpec:
    return RuntimeInstanceSpec(
        runtime_id="claude", runtime_type="claude", name="Claude"
    )


def _sdk_sessions(count: int, *, prefix: str = "claude_small") -> list[Any]:
    return [
        SimpleNamespace(
            session_id=f"{prefix}_{index:03d}",
            summary=f"Small {index}",
            last_modified=1_789_000_000_000 - index,
            file_size=100 + index,
            cwd="/repo",
        )
        for index in range(count)
    ]


def _no_catalogs(monkeypatch: Any, runner: Any) -> None:
    async def no_catalogs(_runtime_: Any) -> None:
        return None

    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)


def _window_reads(sdk: _HistorySdk) -> list[dict[str, Any]]:
    """The SDK calls that were rotation windows (page 1 always reads offset 0)."""

    return [call for call in sdk.list_calls if call["offset"] != 0]


def _timeline_external_ids(notifications: list[dict[str, Any]]) -> set[str]:
    return {
        str(notification["params"].get("externalSessionId"))
        for notification in notifications
        if notification["method"] == "timeline.sync"
    }


# --- The probe shape: the whole library fits in page 1. ---------------------


def test_a_small_library_never_reads_a_rotation_window(monkeypatch) -> None:
    """Probe shape (T<一页、无 local): activation happens (page 1 has an
    outdated session) and the sweep closes at once — zero window reads, and
    no armed state — instead of one whole-library scan per cycle forever."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=_sdk_sessions(5))
    runtime = _runtime(host=host, sdk=sdk)
    runner, _notifications = _runner(runtime, host)
    _no_catalogs(monkeypatch, runner)

    async def drive() -> None:
        for _cycle in range(6):
            await runner.sync_existing_once()

    asyncio.run(drive())

    assert _window_reads(sdk) == []
    state = host.sync_states.get(ROTATION_STATE_KEY) or {}
    # Not armed — and, with the verdict, never armed in the first place.
    assert state.get("active", False) is False, state


def test_an_armed_sweep_sleeps_when_page_one_covers_the_library(monkeypatch) -> None:
    """The already-active path: an armed sweep whose page 1 proves coverage is
    closed with its own log line, keeps the extent it learned, and reads no
    window."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=_sdk_sessions(5))
    runtime = _runtime(host=host, sdk=sdk)
    runner, _notifications = _runner(runtime, host)
    _no_catalogs(monkeypatch, runner)
    host.sync_states[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": 5000,
        "circleCandidates": 3,
        "libraryExtent": 5100,
        "circles": 4,
    }

    messages: list[str] = []
    sink = logger.add(lambda message: messages.append(message.record["message"]))
    try:
        asyncio.run(runner.sync_existing_once())
    finally:
        logger.remove(sink)

    state = host.sync_states[ROTATION_STATE_KEY]
    assert state["active"] is False
    assert state["libraryExtent"] == 5100
    assert _window_reads(sdk) == []
    assert any(
        "sweep completed; page one covers the library" in message
        for message in messages
    ), messages


# --- The displacement shape: harness reads the displaced rows. --------------


def test_the_seam_zero_ladder_reaches_the_sessions_page_one_displaced(
    monkeypatch,
) -> None:
    """位移形（T<一页 + 本地顶出全部历史，seam=0）.

    Every exposed history row is pushed off page 1 by newer local-only
    sessions, while one library session survives on the page merged under its
    local identity (that is what carries the outdated signal that activates
    the sweep). The reader reports seam 0 and no coverage; the ladder starts
    at 0, reads the displaced range, rebuilds it, and converges to sleep —
    where the fixed page boundary would have stepped over it forever.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=_sdk_sessions(5))
    runtime = _runtime(host=host, sdk=sdk)
    store = runtime._session_reader.session_store
    for index in range(100):
        store.ensure(
            f"local_only_{index:03d}", cwd="/repo", title=f"Local {index}"
        )
    store.ensure(
        "local_dup_00",
        external_session_id="claude_small_000",
        cwd="/repo",
        title="Dup 000",
    )
    runner, notifications = _runner(runtime, host)
    _no_catalogs(monkeypatch, runner)

    page_one = asyncio.run(runtime.list_sessions(limit=100))
    assert len(page_one) == 100
    assert page_one.history_scanned == 0
    assert page_one.read_failed is False
    assert page_one.page_one_complete is False
    assert _first_rotation_offset(page_one) == 0

    async def drive() -> None:
        for _cycle in range(6):
            await runner.sync_existing_once()

    asyncio.run(drive())

    rebuilt = _timeline_external_ids(notifications)
    assert {"claude_small_001", "claude_small_002", "claude_small_003", "claude_small_004"} <= rebuilt
    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active", False) is False


# --- Reader-level: the verdict itself, its refusals, its travels. -----------


def test_the_reader_reports_a_library_that_fits_inside_page_one() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, sdk=_HistorySdk(sessions=_sdk_sessions(5)))

    page = asyncio.run(runtime.list_sessions(limit=100))

    assert len(page) == 5
    assert page.history_scanned == 5
    assert page.read_failed is False
    assert page.page_one_complete is True


def test_the_reader_does_not_report_a_full_window_as_the_whole_library() -> None:
    """A page the SDK filled to its size is a page boundary, not the end of
    the list — the T==limit residual stays unproven and the ladder keeps
    walking (pinned in `test_a_library_exactly_one_page_long_keeps_walking`)."""

    host = _RecordingHost()
    runtime = _runtime(
        host=host, sdk=_HistorySdk(sessions=_sdk_sessions(SESSION_ROTATION_PAGE_SIZE))
    )

    page = asyncio.run(runtime.list_sessions(limit=100))

    assert len(page) == SESSION_ROTATION_PAGE_SIZE
    assert page.page_one_complete is False
    assert _first_rotation_offset(page) == SESSION_ROTATION_PAGE_SIZE


def test_the_reader_does_not_report_coverage_one_displaced_row_was_left_behind() -> None:
    """Reverse guard: the list is short (95 < limit) but local-only sessions
    pushed five history rows off the page. Those five are in no window when
    the ladder starts at the seam... and the verdict must NOT claim the page
    covered them."""

    host = _RecordingHost()
    runtime = _runtime(host=host, sdk=_HistorySdk(sessions=_sdk_sessions(95)))
    store = runtime._session_reader.session_store
    for index in range(10):
        store.ensure(
            f"local_only_{index:03d}", cwd="/repo", title=f"Local {index}"
        )

    page = asyncio.run(runtime.list_sessions(limit=100))

    assert len(page) == 100
    assert page.history_scanned == 90
    assert page.page_one_complete is False
    # The ladder starts at the seam, so the five displaced rows (90..94) are
    # inside its first window rather than behind it.
    assert _first_rotation_offset(page) == 90


def test_a_library_merged_under_local_identities_is_still_covered() -> None:
    """Every history row is represented on page 1 — merged under its local
    identity — so seam 0 is not displacement here and coverage holds."""

    host = _RecordingHost()
    runtime = _runtime(host=host, sdk=_HistorySdk(sessions=_sdk_sessions(5)))
    store = runtime._session_reader.session_store
    for index in range(5):
        store.ensure(
            f"local_dup_{index:03d}",
            external_session_id=f"claude_small_{index:03d}",
            cwd="/repo",
            title=f"Dup {index}",
        )

    page = asyncio.run(runtime.list_sessions(limit=100))

    assert len(page) == 5
    assert page.history_scanned == 0
    assert page.page_one_complete is True


def test_a_failed_page_one_read_is_reported_and_is_not_a_coverage_verdict() -> None:
    class _FailingListSdk(_HistorySdk):
        def list_sessions(
            self, limit: int | None = None, offset: int = 0
        ) -> list[Any]:
            raise OSError("sdk session list blew up")

    host = _RecordingHost()
    runtime = _runtime(host=host, sdk=_FailingListSdk())

    page = asyncio.run(runtime.list_sessions(limit=100))

    # The page-1 result carries the failed read (without it, seam 0 here is
    # indistinguishable from "the whole exposed history was displaced").
    assert page.read_failed is True
    assert page.page_one_complete is False
    # A failed read keeps the fixed boundary: nothing about displacement was
    # proved.
    assert _first_rotation_offset(page) == SESSION_ROTATION_FIRST_OFFSET


def test_the_coverage_verdict_survives_rescanned_and_the_bound_instance() -> None:
    """The re-pager (`RuntimeInstance`) and `rescanned` are the production
    call path: a verdict lost there is a verdict that never reaches the
    sweep (the R1b P0 shape)."""

    meta = _meta(0)
    page = SessionListPage(
        (meta,), history_scanned=5, read_failed=True, page_one_complete=True
    )
    rewrapped = page.rescanned((meta,))

    assert isinstance(rewrapped, SessionListPage)
    assert rewrapped.page_one_complete is True
    assert rewrapped.read_failed is True
    assert rewrapped.history_scanned == 5

    host = _RecordingHost()
    native = _runtime(host=host, sdk=_HistorySdk(sessions=_sdk_sessions(5)))
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    native_page = asyncio.run(native.list_sessions(limit=100))
    bound_page = asyncio.run(bound.list_sessions(limit=100))

    assert native_page.page_one_complete is True
    assert type(bound_page) is not tuple
    assert bound_page.page_one_complete is True


# --- The residual, the seam-0 rule table, and the no-verdict fallback. ------


def test_a_library_exactly_one_page_long_keeps_walking(monkeypatch) -> None:
    """Known residual (documented in `_page_one_covers_library`): a library of
    exactly `limit` sessions returns a full window, so "the list ends here"
    is unprovable — there is no count in the SDK listing and a second probe
    read would cost a whole extra scan per cycle. The ladder keeps walking
    until the library grows past the page (or the page-1 signal is consumed),
    exactly as it did before the verdict existed. Pinned, not fixed."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=_sdk_sessions(SESSION_ROTATION_PAGE_SIZE))
    runtime = _runtime(host=host, sdk=sdk)
    runner, _notifications = _runner(runtime, host)
    _no_catalogs(monkeypatch, runner)

    async def drive() -> None:
        for _cycle in range(3):
            await runner.sync_existing_once()

    asyncio.run(drive())

    assert _window_reads(sdk), sdk.list_calls
    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active") is True


def test_the_seam_zero_rule_and_the_persisted_zero_position() -> None:
    """`_first_rotation_offset`/state-restore table: 0 is a real position for
    a readable seam-0 page, everything a failed or silent reader says keeps
    the fixed boundary, and a persisted 0 survives a restart."""

    readable_seam_zero = SessionListPage(
        (_meta(0),), history_scanned=0, page_one_complete=False
    )
    failed_read = SessionListPage(
        (), history_scanned=0, read_failed=True, page_one_complete=False
    )
    silent_runtime_page = (_meta(0),)

    assert _first_rotation_offset(readable_seam_zero) == 0
    assert _first_rotation_offset(failed_read) == SESSION_ROTATION_FIRST_OFFSET
    assert _first_rotation_offset(silent_runtime_page) == SESSION_ROTATION_FIRST_OFFSET

    restored = session_rotation_state_from_mapping(
        {"version": 1, "active": True, "offset": 0, "circles": 3}
    )
    assert restored.active is True
    assert restored.offset == 0
    assert restored.circles == 3

    corrupted = session_rotation_state_from_mapping(
        {"version": 1, "active": True, "offset": -5}
    )
    assert corrupted.offset == SESSION_ROTATION_FIRST_OFFSET


def test_a_runtime_without_the_verdict_keeps_walking_windows(monkeypatch) -> None:
    """Reverse guard: a runtime whose page is a plain tuple gets no inference
    from the shape — even a one-session page with empty windows keeps the old
    behavior (the sweep walks; it is not "small" until a reader says so)."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {}
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    async def drive() -> None:
        for _cycle in range(3):
            await runner.sync_existing_once()

    asyncio.run(drive())

    assert [cursor for cursor in runtime.cursors if cursor is not None]
    assert host.state[ROTATION_STATE_KEY]["active"] is True
