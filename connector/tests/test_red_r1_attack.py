"""R1 red-team attack tests — T1 rotation + T2 age ceiling (stale-residue-selfheal).

Adversarial suite written against the integration baseline `fix/residue-integration`
@ d73ac494 (T1 = 0c230f23, T2 = aa92c335). Product code is NOT modified here:
every test drives the shipped functions and asserts on their real behaviour.
Where a finding proposes a fix, the fix is *simulated* by calling the same
function with the corrected input, so the repair is proven without editing
`connector/`.
"""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from typing import Any

from test_session_rotation import (
    ROTATION_STATE_KEY,
    MarkedPagedRuntime,
    PagedRuntime,
    StatefulRecordingHost,
    _all_session_ids,
    _meta,
    _runner,
)
from test_task_closure import (
    T_AGE_BOUND,
    TASK_ID,
    _async_card,
    _dispatch_message,
    _fresh_file,
    _old_receipt_raw_lines,
    _oracle,
    _receipt_message,
    _session,
)

from connector.runtimes.claude.sessions.reader import (
    _apply_oracle_closures,
    _history_items_from_messages,
    _raw_history_notices,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    participation_times_ms,
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_IDLE_FREE_READS,
    SESSION_ROTATION_IDLE_SLEEP_MAX,
    SESSION_ROTATION_PAGE_SIZE,
    SESSION_ROTATION_REBUILD_BUDGET,
    SESSION_ROTATION_STALL_CIRCLES,
    SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT,
)

NOW = 1_791_457_800.0
OLD_RECEIPT_MS = int((NOW - (T_AGE_BOUND + 3_600.0)) * 1000)  # 25h old dispatch
FRESH_RESUME_MS = int((NOW - 300.0) * 1000)  # resumed 5 minutes ago


def _iso_ms(value: int) -> str:
    return (
        datetime.fromtimestamp(value / 1000, tz=UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _resume_raw_line(resume_ms: int) -> str:
    """An assistant row's SendMessage call that resumed TASK_ID.

    This is the shape `subagent_oracle._extract_transcript_lineage` records as
    `send_resume_times_ms` — the P9 "newest survival evidence" anchor.
    """

    return json.dumps(
        {
            "type": "assistant",
            "uuid": "resume-native",
            "timestamp": _iso_ms(resume_ms),
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "call_resume_1",
                        "name": "SendMessage",
                        "input": {"to": TASK_ID, "message": "continue"},
                    }
                ],
            },
        }
    )


def _resumed_transcript() -> tuple[str, ...]:
    return (*_old_receipt_raw_lines(OLD_RECEIPT_MS), _resume_raw_line(FRESH_RESUME_MS))


def _card(items: tuple[Any, ...]) -> Any:
    return next(i for i in items if i.content.get("kind") == "agent_call")


# ---------------------------------------------------------------------------
# T2 attack 1 — the history side anchors the age on the dispatch receipt only
# ---------------------------------------------------------------------------


def test_R1_T2_the_scan_really_carries_the_resume_evidence() -> None:
    """Precondition: the resume row is real, parsed, and recent."""

    scan = scan_raw_transcript(_resumed_transcript())
    assert scan.receipt_times_ms[TASK_ID] == OLD_RECEIPT_MS
    assert scan.send_resume_times_ms[TASK_ID] == FRESH_RESUME_MS
    # The helper the LIVE side uses already computes the right anchor.
    assert participation_times_ms(scan)[TASK_ID] == FRESH_RESUME_MS


def test_R1_T2_history_no_longer_closes_a_task_resumed_five_minutes_ago() -> None:
    """ATTACK (R1 P1-1), now closed: a task dispatched 25h ago and resumed 5
    minutes ago used to be closed `interrupted`/`ageBounded` by the history
    rebuild, although its newest survival evidence is 300s old and its
    transcript was written 0s ago.

    The history side anchored the ceiling on `raw_scan.receipt_times_ms`,
    which drops the SendMessage resume row; the live sweep folds participation
    in (messages.py) and always spared the same task. Same engine facts, two
    verdicts — and the rebuild is the side that owns the residue this whole
    exercise is about, so it is the side that must be right.

    The fix reuses the live side's own `participation_times_ms`, so the anchor
    only ever moves NEWER — the conservative direction for a ceiling.
    """

    messages = (_dispatch_message(), _receipt_message())
    oracle = _oracle(
        now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(), messages, raw_lines=_resumed_transcript(), oracle=oracle
    )
    card = _card(items)
    assert card.status == "running"
    assert "closedByEvidence" not in card.content
    # The two anchors are genuinely different values — this is a real
    # asymmetry, not a coincidence the test happens to pass on.
    scan = scan_raw_transcript(_resumed_transcript())
    assert scan.receipt_times_ms[TASK_ID] == OLD_RECEIPT_MS
    assert participation_times_ms(scan)[TASK_ID] == FRESH_RESUME_MS


def test_R1_T2_history_still_closes_a_task_whose_newest_evidence_is_old() -> None:
    """The other side of P1-1, so the repair cannot be a blanket "never close".

    No resume row: the newest survival evidence really is the 25h-old
    dispatch, the file is fresh (the scenario the ceiling exists for), and the
    history rebuild must close it exactly as before.
    """

    raw_lines = _old_receipt_raw_lines(OLD_RECEIPT_MS)
    messages = (_dispatch_message(), _receipt_message())
    oracle = _oracle(
        now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(), messages, raw_lines=raw_lines, oracle=oracle
    )
    card = _card(items)
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"
    assert card.content["endTime"] == OLD_RECEIPT_MS


def test_R1_T2_control_the_live_sweep_spares_the_same_task() -> None:
    """Control: the same transcript through the LIVE sweep stays open.

    `ClaudeMessageProjector.close_open_agent_cards` folds participation into the
    age (messages.py:1546-1558), so the ceiling cannot fire. This is the
    asymmetry: identical engine facts, two different verdicts.
    """

    scan = scan_raw_transcript(_resumed_transcript())
    projector = ClaudeMessageProjector()
    projector._raw_scan_provider = lambda _s: scan
    _async_card(projector)
    assert (
        projector.close_open_agent_cards(
            _session(),
            oracle=_oracle(
                now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
            ),
            # What production hands in: the dispatch-derived age.
            receipt_ages={TASK_ID: T_AGE_BOUND + 3_600.0},
            now_ms=int(NOW * 1000),
        )
        == ()
    )


def test_R1_T2_minimal_fix_participation_anchor_spares_the_task() -> None:
    """ATTACK VALIDATED FIX: feeding `participation_times_ms` where
    reader.py:539 passes `raw_scan.receipt_times_ms` spares the task.

    One-line change, reuses the live side's helper, moves the anchor in the
    documented conservative direction (newer = smaller age).
    """

    raw_lines = _resumed_transcript()
    messages = (_dispatch_message(), _receipt_message())
    scan = scan_raw_transcript(raw_lines)
    oracle = _oracle(
        now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(), messages, raw_lines=raw_lines, oracle=None
    )
    fixed = _apply_oracle_closures(
        _session(),
        items,
        messages=messages,
        raw_notices=_raw_history_notices(messages, scan),
        raw_receipt_times=participation_times_ms(scan),  # <-- the fix
        oracle=oracle,
    )
    card = _card(fixed)
    assert card.status == "running"
    assert "closedByEvidence" not in card.content


def test_R1_T2_live_task_ids_still_spare_it_on_the_history_side() -> None:
    """The only thing that saves this card today is a transport signal the
    history rebuild structurally never has (`live_task_ids` defaults empty)."""

    oracle = _oracle(
        now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=_resumed_transcript(),
        oracle=oracle,
        live_task_ids=frozenset({TASK_ID}),
    )
    card = _card(items)
    assert card.status == "running"
    assert "closedByEvidence" not in card.content


# ---------------------------------------------------------------------------
# T1 attack 2 — an empty window is read as "end of the library"
# ---------------------------------------------------------------------------


def test_R1_T1_a_failed_window_no_longer_ends_the_library_sweep(
    monkeypatch,
) -> None:
    """ATTACK (R1 P1-2), now closed: one swallowed window read used to complete
    the circle and put the sweep to sleep, so the window that actually held the
    residue was never read.

    reader.py turned ANY failure inside the SDK session list into `()`, and
    `run_session_rotation` had no way to tell that from a genuine end of
    library — it believed the first empty window, disarmed, and never came
    back. The residue then sat there for the life of the process, which is
    the exact failure this whole feature exists to remove.

    Fixed at the source (the reader reports `read_failed`) and at the ladder
    (an unvouched-for window never concludes a circle).
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime(failed=(SESSION_ROTATION_FIRST_OFFSET,))
    # Page 1 carries the activation signal; it is rebuilt in the same cycle.
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    # Window 100's read raised; window 200 holds residue.
    runtime.rotation_pages = {200: (_meta(201, requires_sync=True),)}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    assert runtime.cursors == [None, str(SESSION_ROTATION_FIRST_OFFSET)]
    assert host.state[ROTATION_STATE_KEY]["active"] is True, (
        "sweep disarmed after one failed window"
    )

    # And the next cycle walks on to the window the failed read was hiding.
    asyncio.run(runner.sync_existing_once())

    assert "200" in runtime.cursors
    assert "sess_201" in _all_session_ids(notifications)


def test_R1_T1_a_failed_window_midway_still_does_not_end_a_proved_circle(
    monkeypatch,
) -> None:
    """The same signal, deeper in a circle that HAS proved itself.

    The first window of a circle can be empty for reasons unrelated to the end
    of the library, but a mid-circle read that raises is unambiguous: the
    library is still there, we just did not get to see it. Neither may
    conclude a circle.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime(failed=(SESSION_ROTATION_FIRST_OFFSET + 100,))
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101),),
        SESSION_ROTATION_FIRST_OFFSET + 100: (_meta(201),),
        SESSION_ROTATION_FIRST_OFFSET + 200: (_meta(301),),
        SESSION_ROTATION_FIRST_OFFSET + 300: (_meta(401, requires_sync=True),),
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(4):
        asyncio.run(runner.sync_existing_once())

    assert host.state[ROTATION_STATE_KEY]["active"] is True
    assert str(SESSION_ROTATION_FIRST_OFFSET + 300) in runtime.cursors
    assert "sess_401" in _all_session_ids(notifications)


def test_R1_T1_the_disarm_recovers_after_page_one_is_consumed(
    monkeypatch,
) -> None:
    """ATTACK (R1 P1-3), now closed: the activation signal is a page-1 EDGE
    that only a page-1 rebuild consumes, and page 1 is rebuilt earlier in the
    very same cycle. So the first rotation window came back empty, the sweep
    concluded "end of library", disarmed — and with the signal already spent
    there was nothing left to re-arm it. The tail went unread for the life of
    the process.

    Fixed by refusing to believe an empty window that no non-empty window has
    yet backed: the sweep steps over it and stays armed.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    runtime.rotation_pages = {200: (_meta(201, requires_sync=True),)}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())
    # The signal is consumed: page 1 is now current.
    runtime.page_one = (_meta(0, requires_sync=False, projection_outdated=False),)

    for _ in range(5):
        asyncio.run(runner.sync_existing_once())

    assert "200" in runtime.cursors, "residue window never compared"
    assert "sess_201" in _all_session_ids(notifications)


def test_R1_T1_an_all_filtered_window_no_longer_ends_the_library_sweep(
    monkeypatch,
) -> None:
    """ATTACK (R1 P1-2), now closed: a window whose sessions were ALL dropped
    by the reader's live/active filters also arrived as `()`, so the circle
    ended early even though the library continued past it — and this one is
    not even a failure, it is a window the filters own.

    The reader now reports how many sessions the read actually saw
    (`history_scanned`), which is larger than the page length exactly when
    filtering emptied it, so the ladder steps over it.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime(filtered=(SESSION_ROTATION_FIRST_OFFSET,))
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        # window 100 is empty after filtering; 200 is real.
        200: (_meta(201, requires_sync=True),),
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())
    assert host.state[ROTATION_STATE_KEY]["active"] is True

    asyncio.run(runner.sync_existing_once())

    assert "sess_201" in _all_session_ids(notifications)


def test_R1_T1_an_empty_window_after_a_real_one_still_ends_the_circle(
    monkeypatch,
) -> None:
    """The other side of P1-2/P1-3, so neither repair can become "never sleep".

    Once the circle has read a non-empty window, the next empty one is the end
    of the library, and the sweep must be allowed to say so and go to sleep.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101),),
    }
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())
    assert host.state[ROTATION_STATE_KEY]["active"] is True
    asyncio.run(runner.sync_existing_once())

    assert host.state[ROTATION_STATE_KEY]["active"] is False


def test_R1_T1_a_raising_window_does_not_advance_the_ladder(monkeypatch) -> None:
    """CONTROL (does not land): an exception that escapes `list_sessions` is
    caught by the runner and the ladder stays put, unlike the empty case."""

    class RaisingRuntime(PagedRuntime):
        async def list_sessions(
            self,
            limit: int = 100,
            cursor: str | None = None,
            force: bool = False,
        ) -> tuple[Any, ...]:
            if cursor is not None:
                raise RuntimeError("sdk exploded")
            return await super().list_sessions(limit, cursor, force)

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = RaisingRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    assert host.state[ROTATION_STATE_KEY]["active"] is True
    assert host.state[ROTATION_STATE_KEY]["offset"] == SESSION_ROTATION_FIRST_OFFSET


# ---------------------------------------------------------------------------
# T1 attack 3 — durable offset state under corruption / rollback
# ---------------------------------------------------------------------------


def test_R1_T1_offset_state_corruption_is_contained(monkeypatch) -> None:
    """ATTACK: a corrupted durable state must never raise and must re-seek."""

    payloads: list[dict[str, Any]] = [
        {"version": 1, "active": True, "offset": -5},
        {"version": 1, "active": True, "offset": "not-an-int"},
        {"version": 1, "active": True, "offset": True},
        {"version": 1, "active": True, "offset": 10**9},
        {"version": 99, "active": True, "offset": 10**9},
        {"version": 1, "active": "yes", "offset": None},
    ]
    for payload in payloads:
        monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
        runtime = PagedRuntime()
        runtime.page_one = (_meta(0, projection_outdated=True),)
        runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
        host = StatefulRecordingHost()
        host.state[ROTATION_STATE_KEY] = payload
        runner, _notifications = _runner(runtime, host)

        asyncio.run(runner.sync_existing_once())

        state = host.state[ROTATION_STATE_KEY]
        # Never negative, never a string, and the sweep keeps working.
        assert isinstance(state["offset"], int)
        assert state["offset"] >= SESSION_ROTATION_FIRST_OFFSET
        assert state["version"] == 1


def test_R1_T1_a_corrupt_huge_offset_re_seeks_the_circle(monkeypatch) -> None:
    """ATTACK (R1, durable state), now contained: an absurd but well-formed
    offset is trusted; the reads past the end return empty, and the old code
    concluded "end of library" on the FIRST one and discarded the real
    position.

    It no longer does. A position that returns nothing is not proof, so the
    ladder steps over it — bounded by SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT,
    or a library that genuinely shrank under a persisted offset could never
    conclude at all and would read a window every cycle forever. After the
    bound it concludes, wraps to a real position, and the residue the bogus
    offset was hiding is actually compared.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {100: (_meta(101, requires_sync=True),)}
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": 10**9,
        "circleCandidates": 4,
        "circleRebuilt": 1,
    }
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    assert runtime.cursors == [None, "1000000000"]
    assert host.state[ROTATION_STATE_KEY]["active"] is True
    # Unproven empties advance the ladder instead of concluding the circle...
    assert host.state[ROTATION_STATE_KEY]["offset"] == 10**9 + 100
    # ...and the bound keeps that bounded: the third empty in a row is taken
    # as the end of the library and the circle wraps to a real position.
    for _cycle in range(SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT - 1):
        asyncio.run(runner.sync_existing_once())
    assert host.state[ROTATION_STATE_KEY]["offset"] == SESSION_ROTATION_FIRST_OFFSET
    assert host.state[ROTATION_STATE_KEY]["active"] is True

    # The window the bogus offset was hiding is reached, and its residue
    # rebuilt — which the old behaviour never did.
    asyncio.run(runner.sync_existing_once())
    assert "100" in runtime.cursors
    assert "sess_101" in _all_session_ids(notifications)


# ---------------------------------------------------------------------------
# T1 attack 4 — budget, stall gate, ladder arithmetic
# ---------------------------------------------------------------------------


def test_R1_T1_budget_bounds_a_cycle_and_leaves_the_rest_alone(monkeypatch) -> None:
    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: tuple(
            _meta(200 + i, requires_sync=True) for i in range(20)
        )
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    synced = [
        n["params"]["sessionId"]
        for n in notifications
        if n["method"] == "timeline.sync"
    ]
    assert len(synced) == SESSION_ROTATION_REBUILD_BUDGET
    state = host.state[ROTATION_STATE_KEY]
    assert state["circleCandidates"] == 20
    assert state["circleRebuilt"] == SESSION_ROTATION_REBUILD_BUDGET


def test_R1_T1_the_stall_gate_sleeps_after_three_failed_circles(monkeypatch) -> None:
    """CONTROL: the SESSION_ROTATION_STALL_CIRCLES backstop does fire — the
    sweep disarms after three circles that rebuilt nothing."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101, requires_sync=True),),
    }
    runtime.snapshot_failures = {"sess_101"}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    disarmed_at = None
    for cycle in range(1, 2 * SESSION_ROTATION_STALL_CIRCLES + 3):
        asyncio.run(runner.sync_existing_once())
        if host.state[ROTATION_STATE_KEY]["active"] is False:
            disarmed_at = cycle
            break

    assert disarmed_at is not None, "stall gate never fired"
    assert "sess_101" not in _all_session_ids(notifications)


def _ladder_runtime(*, poison: bool) -> PagedRuntime:
    """A 550-session library: five contiguous windows, one candidate at 500."""

    runtime = PagedRuntime()
    # Page 1 stays permanently `projection_outdated` — its own rebuild never
    # lands, so the activation signal is never consumed.
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        offset: (_meta(offset // 100, requires_sync=False),)
        for offset in range(
            SESSION_ROTATION_FIRST_OFFSET,
            5 * SESSION_ROTATION_PAGE_SIZE,
            SESSION_ROTATION_PAGE_SIZE,
        )
    }
    # The one real residue, in the last window.
    runtime.rotation_pages[5 * SESSION_ROTATION_PAGE_SIZE] = (
        _meta(501, requires_sync=True),
    )
    if poison:
        runtime.rotation_pages[SESSION_ROTATION_FIRST_OFFSET] = (
            _meta(101, requires_sync=True),
        )
        runtime.snapshot_failures = {"sess_101"}
    return runtime


def test_R1_T1_control_a_clean_ladder_reaches_the_last_window(monkeypatch) -> None:
    """CONTROL: with no poison, the sweep walks all five windows and rebuilds
    the candidate in the last one. This is what T1 is supposed to do."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = _ladder_runtime(poison=False)
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(6):
        asyncio.run(runner.sync_existing_once())

    assert "sess_501" in _all_session_ids(notifications)


def test_R1_T1_coverage_survives_a_poison_candidate(monkeypatch) -> None:
    """ATTACK THAT FAILED (kept as a control): a poison candidate does NOT
    block the tail. The stall gate only fires when the ladder reaches the end
    of the library, and by then every window has been walked, so coverage is
    preserved. This is why T1's coverage claim survives the attack."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = _ladder_runtime(poison=True)
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(20):
        asyncio.run(runner.sync_existing_once())

    assert "sess_501" in _all_session_ids(notifications)


def test_R1_T1_a_never_consumed_page_one_signal_backs_the_sweep_off(
    monkeypatch,
) -> None:
    """ATTACK (R1 P2-5), now contained: while page 1 keeps reporting
    `projection_outdated`, the sweep is re-armed on the cycle after every
    stall, so it never really sleeps. The activation signal is consumed only
    by a page-1 *rebuild*; a page-1 session whose rebuild keeps failing leaves
    it lit forever.

    Cost per cycle is not free: `list_sdk_sessions` reads the whole library
    (every project dir, every session file head/tail) and only then applies
    offset/limit (`_apply_sort_limit_offset`), so every rotation window is a
    full-library scan — page 1's cost doubled, permanently.

    The repair is a backoff on the only evidence available: window reads that
    rebuilt nothing. Past the first circle (which always runs flat out — it is
    the one a version bump just paid for) each such read buys one more rest
    cycle, capped at SESSION_ROTATION_IDLE_SLEEP_MAX. A read that rebuilds
    something clears it, so a sweep with real work to do still walks at full
    speed.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = _ladder_runtime(poison=True)
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(20):
        asyncio.run(runner.sync_existing_once())

    window_reads = len([c for c in runtime.cursors if c is not None])
    # This library is only five windows wide and its last window rebuilds
    # every circle, so its idle runs stay short and the ramp only reaches
    # 1, 2, 4: 13 reads, of which 7 cycles are rests. The old behaviour read
    # a window in 19 of 20 cycles. (The saving scales with the idle run, and
    # an idle run is bounded by the window count — an eight-window library
    # holds the sweep to 16 reads in 40 cycles; see
    # test_rotation_backs_off_while_its_candidates_never_rebuild.)
    assert window_reads <= 14, f"sweep still scans every cycle: {window_reads} reads"
    assert 20 - window_reads >= 5, "the sweep never rested"
    # The counter is what bought those rests, and it is capped: a sweep that
    # stays idle forever still re-reads a window every few cycles and cannot
    # "back off" into never noticing a new residue.
    assert host.state[ROTATION_STATE_KEY]["idleReads"] <= (
        SESSION_ROTATION_IDLE_SLEEP_MAX + SESSION_ROTATION_IDLE_FREE_READS
    )

    # And the backoff never costs coverage: the residue in the last window is
    # still compared (and rebuilt) on the way.
    assert "sess_501" in _all_session_ids(notifications)


def test_R1_T1_windows_are_contiguous_no_overlap(monkeypatch) -> None:
    """The ladder advances by exactly one page; windows tile the library."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        offset: (_meta(1000 + offset // 100, requires_sync=True),)
        for offset in range(
            SESSION_ROTATION_FIRST_OFFSET,
            SESSION_ROTATION_FIRST_OFFSET + 3 * SESSION_ROTATION_PAGE_SIZE,
            SESSION_ROTATION_PAGE_SIZE,
        )
    }
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())
    await_state = host.state[ROTATION_STATE_KEY]
    assert await_state["offset"] == SESSION_ROTATION_FIRST_OFFSET + 100
    assert await_state["circleCandidates"] == 1

def test_R1_T1_a_rotation_rebuild_publishes_exactly_a_page_one_rebuild(
    monkeypatch,
) -> None:
    """The unread-ledger surface: a rotation rebuild must be indistinguishable
    from the page-1 rebuild that already ships, because it calls the same
    `sync_existing_session` with the same default arguments.

    Anything that would touch `last_read_seq` / `latest_turn_end_seq` /
    `mark_read` lives in the publish payload, so equal payloads mean the
    rotation wave adds no new ledger semantics — only more of the same.
    """

    def _payload(monkeypatch, *, rotation: bool) -> list[Any]:
        monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
        runtime = PagedRuntime()
        if rotation:
            runtime.page_one = (_meta(0, projection_outdated=True),)
            runtime.rotation_pages = {
                SESSION_ROTATION_FIRST_OFFSET: (_meta(1, requires_sync=True),)
            }
        else:
            runtime.page_one = (_meta(0, requires_sync=True),)
        host = StatefulRecordingHost()
        runner, notifications = _runner(runtime, host)
        asyncio.run(runner.sync_existing_once())
        # Compare the publish SHAPE, not the per-session values: methods, param
        # keys, and the sync-metadata key set. If the rotation wave ever grew a
        # new field (an unread/seq hint), it would show up here.
        return [
            (
                n["method"],
                tuple(sorted(n["params"])),
                tuple(sorted(n["params"].get("metadata", {}).get("sync", {}))),
                tuple(sorted(n["params"].get("metadata", {}))),
            )
            for n in notifications
        ]

    assert _payload(monkeypatch, rotation=True) == _payload(
        monkeypatch, rotation=False
    )
