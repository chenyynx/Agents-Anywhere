"""Progress arbitration: a contenting turn lives while its frames advance.

Why this file exists
--------------------
The scheduled-turn breaker used to end every contenting turn on a fixed age
(600s, then a 1800s stopgap). The 2026-10-09 autopsy showed every knife
landing on a live work cycle (`.local-dev/claude-watchdog-liveness-tasks.md`
§1: 8 host-process kills in a week, one knife 3 seconds behind the turn's
last productive frame). The verdict is now STALL-based (§2/§3): a contenting
turn is killed only when neither `published_items` nor `consumed_frames`
moves for `CONTENTING_TURN_STALL_SECONDS` while the turn is past
`CONTENTING_TURN_FLOOR_SECONDS`, with `CONTENTING_TURN_HARD_CAP_SECONDS` as
the one absolute bound left over it.

These tests pin the adjudication's two directions under real machinery
(reader, mint branch, `drive_turn`, watchdog, retirement) — everything is
the production path; only the budgets are compressed, via the longrun
file's `_budgets`:

* a progressing turn is never killed, at any age (I1);
* once progress truly stops it is killed — at the floor for early silence,
  at last-labour + STALL for late silence (I5);
* chrome-only frames move neither counter and buy no time (I4);
* the zero-content ghost reaps on the fast kill, untouched (I2);
* a never-stalling degenerate loop still ends, on the hard cap;
* a turn that settles while the watchdog is polling is never fired on.
"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any

import pytest
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _turn_ends,
    _wait_until,
)
from test_claude_runtime import _RecordingHost, _ScheduledClaudeClient
from test_claude_watchdog_longrun import (
    CHROME_PROBE_FRAME,
    FAST_KILL,
    FLOOR,
    GHOST_MINT_FRAME,
    HARD_CAP,
    POST_CAST_WORK_FRAME,
    STALL,
    TICK,
    _budgets,
    _CapturedWarnings,
    _cast_with_labour,
    _complete,
    _failed_ends,
    _settled_session,
    _with_session,
)

from connector.runtimes.claude.turns import lifecycle

# The fire line's three numbers, read back off the log the way the
# post-deploy observation window will read them.
_FIRE_NUMBERS = re.compile(
    r"age_seconds=(?P<age>[0-9.]+) stall_seconds=(?P<stall>[0-9.]+) "
    r"budget_seconds=(?P<budget>[0-9.]+)"
)


def _fire_line(captured: _CapturedWarnings) -> str:
    """The one watchdog fire line, or an assert naming what was captured."""

    fired = [
        line
        for line in captured.joined().splitlines()
        if "watchdog fired" in line
    ]
    assert len(fired) == 1, captured.joined()
    return fired[0]


def _fire_numbers(captured: _CapturedWarnings) -> tuple[float, float, float]:
    match = _FIRE_NUMBERS.search(_fire_line(captured))
    assert match is not None, _fire_line(captured)
    return (
        float(match["age"]),
        float(match["stall"]),
        float(match["budget"]),
    )


def _work_frame(index: int) -> dict[str, Any]:
    return {**POST_CAST_WORK_FRAME, "uuid": f"work-{index}"}


# --------------------------------------------------------------------------
# I1 — progress is life: any amount of frame movement outruns every timer
# --------------------------------------------------------------------------


def test_progressing_turn_is_never_killed(monkeypatch: pytest.MonkeyPatch) -> None:
    """I1: labour frames advancing ⇒ zero firings, however long it runs.

    修前红: with the absolute ceiling this turn dies at FLOOR regardless of
    how much work is still flowing — the exact production shape of §1. Here
    the turn runs past the floor AND past floor+stall with a fresh frame on
    every tick, holds its lock the whole way, and only dies once the test
    stops feeding it — which is the other half of the invariant: "never
    killed while working" must not become "never killed".
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("live", None, "hello")
            session = await _settled_session(runtime, "live")
            execution = await _cast_with_labour(client, session)

            deadline = time.monotonic() + FLOOR + STALL + 0.25
            index = 0
            with _CapturedWarnings() as captured:
                while time.monotonic() < deadline:
                    index += 1
                    await client.incoming.put(
                        _with_session(_work_frame(index), client.native_id)
                    )
                    await asyncio.sleep(TICK * 2)
                # Past the floor and past floor+stall of wall time, with the
                # counters moving the whole way: nothing may have fired.
                assert session.execution is execution, (
                    "a turn whose frames keep advancing must hold its lock"
                )
                assert not _turn_ends(host, execution.turn_id)
                assert client.disconnected is False
                assert execution.watchdog_progress_deferrals > 0, (
                    "progress past the floor must be observed as a deferral"
                )
                assert "stall verdict deferred by labour progress" in (
                    captured.joined()
                ), captured.joined()
                assert "watchdog fired" not in captured.joined()

                # The other direction: once the work truly stops, the stall
                # verdict still reaps it.
                await _wait_until(
                    lambda: bool(_turn_ends(host, execution.turn_id))
                )
            assert (
                f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}"
                in _fire_line(captured)
            )
            assert session.execution is None
            # The transport close happens strictly after the turn's end is
            # recorded (finish → retire), so wait for the close itself rather
            # than sampling the window between the two.
            await _wait_until(lambda: client.disconnected)
            assert client.disconnected is True
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# I5 — stillness is death, and the clock that matters is the stall clock
# --------------------------------------------------------------------------


def test_early_silence_fires_at_the_floor_with_the_stall_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """I5, early shape: one burst of labour, then silence ⇒ kill AT the floor.

    The stall clock is already past its budget well before the floor (the
    silence here is the turn's whole life), so the floor is the binding
    constraint: the verdict lands at STALL ≈ FLOOR, and not a tick earlier.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("early", None, "hello")
            session = await _settled_session(runtime, "early")
            execution = await _cast_with_labour(client, session)
            started = time.monotonic()

            # Past the fast kill, before the floor: the lock is still held.
            await asyncio.sleep(FAST_KILL * 3)
            assert session.execution is execution
            assert not _turn_ends(host, execution.turn_id)

            with _CapturedWarnings() as captured:
                await _wait_until(
                    lambda: bool(_turn_ends(host, execution.turn_id))
                )
            elapsed = time.monotonic() - started
            age, stall, budget = _fire_numbers(captured)
            assert (
                f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}"
                in _fire_line(captured)
            )
            assert elapsed >= FLOOR - 0.05, "no contenting kill may beat the floor"
            assert elapsed < FLOOR + 0.4, "early silence dies AT the floor"
            assert age >= FLOOR
            assert stall >= STALL
            assert budget == pytest.approx(STALL), (
                "a stall fire reports the stall budget, not the age"
            )
            assert _turn_ends(host, execution.turn_id)[-1]["outcome"] == "failed"
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_late_silence_fires_at_last_labour_plus_stall(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """I5, late shape: labour near the floor, then silence ⇒ FLOOR is early.

    The last labour lands close to the floor, so the stall clock — not the
    age — sets the verdict time: the kill comes strictly later than the
    floor alone would have produced, at last-labour + STALL.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("late", None, "hello")
            session = await _settled_session(runtime, "late")
            execution = await _cast_with_labour(client, session)
            baseline = execution.published_items
            started = time.monotonic()

            # Keep the turn alive until just past the floor, then let it go
            # silent. Each burst must actually land (observed by the counter)
            # before the next sleep, so the stall clock's zero point is real.
            await asyncio.sleep(0.25)
            await client.incoming.put(
                _with_session(_work_frame(2), client.native_id)
            )
            await _wait_until(lambda: execution.published_items > baseline)
            await asyncio.sleep(0.2)
            await client.incoming.put(
                _with_session(_work_frame(3), client.native_id)
            )
            await _wait_until(lambda: execution.published_items > baseline + 1)
            last_labour = time.monotonic() - started

            with _CapturedWarnings() as captured:
                await _wait_until(
                    lambda: bool(_turn_ends(host, execution.turn_id))
                )
            elapsed = time.monotonic() - started
            assert (
                f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}"
                in _fire_line(captured)
            )
            assert elapsed >= FLOOR + 0.05, (
                "the floor alone must not have set this verdict time"
            )
            assert elapsed >= last_labour + STALL - 0.05, (
                "the verdict may not beat last-labour + STALL"
            )
            assert elapsed < FLOOR + STALL + 0.6
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# I4 — chrome buys no time
# --------------------------------------------------------------------------


def test_chrome_frames_do_not_reset_the_stall_clock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """I4: chrome-only frames move neither counter and cannot push the kill out.

    The status handshake used here is the census's own chrome shape (0 tool
    items, 0 system items, no visible message). If chrome counted as labour,
    this spam would keep resetting the stall clock and the turn would outlive
    the whole spam; instead it dies at the floor, counters untouched.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("chrome", None, "hello")
            session = await _settled_session(runtime, "chrome")
            execution = await _cast_with_labour(client, session)
            baseline = (execution.published_items, execution.consumed_frames)
            started = time.monotonic()

            index = 0
            with _CapturedWarnings() as captured:
                while not _turn_ends(host, execution.turn_id):
                    index += 1
                    assert index < 60, (
                        "chrome spam must not keep a stalled turn alive"
                    )
                    await client.incoming.put(
                        _with_session(
                            {**CHROME_PROBE_FRAME, "uuid": f"chrome-{index}"},
                            client.native_id,
                        )
                    )
                    await asyncio.sleep(0.05)
            elapsed = time.monotonic() - started

            assert (
                f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}"
                in _fire_line(captured)
            )
            assert (execution.published_items, execution.consumed_frames) == (
                baseline
            ), "chrome frames must not move either counter"
            assert execution.watchdog_progress_deferrals == 0, (
                "chrome is not labour and must never count as a deferral"
            )
            assert "deferred by labour progress" not in captured.joined()
            assert elapsed < FLOOR + 0.4, (
                "chrome spam must not push the verdict past the floor"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# I2 — the ghost class is untouched
# --------------------------------------------------------------------------


def test_zero_content_ghost_still_reaps_on_the_fast_kill(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """I2 / C1 does not regress: no content ⇒ the fast kill, unchanged.

    The ghost must be gone long before the contenting budgets could matter,
    which is what keeps the P0 (a held lock with a disabled composer) at
    seconds rather than at the floor.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("ghost", None, "hello")
            session = await _settled_session(runtime, "ghost")
            started = time.monotonic()

            await client.incoming.put(
                _with_session(GHOST_MINT_FRAME, client.native_id)
            )
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            assert execution.published_items == 0
            assert execution.consumed_frames == 0

            with _CapturedWarnings() as captured:
                await _wait_until(
                    lambda: bool(_turn_ends(host, execution.turn_id))
                )
            elapsed = time.monotonic() - started
            assert (
                f"reason={lifecycle.WATCHDOG_REASON_ZERO_CONTENT}"
                in _fire_line(captured)
            )
            assert elapsed < FLOOR, (
                "the ghost must not be dragged onto the contenting path"
            )
            assert session.execution is None
            assert session.queued_execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# The hard cap — the one bound a never-stalling turn still meets
# --------------------------------------------------------------------------


def test_never_stalling_turn_is_bounded_by_the_hard_cap(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The degenerate loop: frames forever, settle never ⇒ the cap, not never.

    This is the red line §5 shape re-adjudicated: "progress arbitration" must
    not become "long turns never settle". A turn whose counters advance on
    every tick defeats the stall verdict by construction, so the hard cap is
    the only thing left that can end it — and it does, naming itself.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("loop", None, "hello")
            session = await _settled_session(runtime, "loop")
            execution = await _cast_with_labour(client, session)
            started = time.monotonic()

            index = 0
            with _CapturedWarnings() as captured:
                while not _turn_ends(host, execution.turn_id):
                    index += 1
                    assert time.monotonic() - started < HARD_CAP + 1.5, (
                        "the degenerate loop must be bounded by the hard cap"
                    )
                    await client.incoming.put(
                        _with_session(_work_frame(index), client.native_id)
                    )
                    await asyncio.sleep(TICK)
            elapsed = time.monotonic() - started
            age, stall, budget = _fire_numbers(captured)
            assert (
                f"reason={lifecycle.WATCHDOG_REASON_CONTENT_HARD_CAP}"
                in _fire_line(captured)
            )
            assert elapsed >= HARD_CAP - 0.15
            assert elapsed < HARD_CAP + 1.0
            assert budget == pytest.approx(HARD_CAP), (
                "a hard-cap fire reports the cap"
            )
            assert stall < STALL, "progress never actually stopped here"
            assert age >= HARD_CAP
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# The settle race — a turn that ends mid-poll is never fired on
# --------------------------------------------------------------------------


def test_a_settling_turn_wins_the_race_against_the_poller(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The poll loop observes `finished` and exits; no verdict, no retirement.

    The window exercised here is real: the turn is already in the polling
    phase (past the fast kill) when its result lands, so the watchdog is
    between ticks with a verdict's worth of age on the clock. It must stand
    down — and the transport must stay up (a fired watchdog would retire it).
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("race", None, "hello")
            session = await _settled_session(runtime, "race")
            execution = await _cast_with_labour(client, session)
            turn_id = execution.turn_id

            with _CapturedWarnings() as captured:
                # Deep inside phase two (past the fast kill, before the
                # floor), then the turn settles by itself.
                await asyncio.sleep(FAST_KILL * 3)
                assert session.execution is execution
                _complete(client)
                await _wait_until(lambda: session.execution is None)

            assert host.session_turn_ends[-1]["turn_id"] == turn_id
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert not _failed_ends(host)
            assert "watchdog fired" not in captured.joined()
            assert client.disconnected is False, (
                "a settled turn must not be retired by the watchdog"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())
