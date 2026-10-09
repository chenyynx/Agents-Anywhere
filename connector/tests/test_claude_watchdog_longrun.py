"""The scheduled-turn watchdog must kill ghosts, not long autonomous turns.

Why this file exists
--------------------
``POLLED_TURN_WATCHDOG_SECONDS`` was a pure timer: a scheduled turn was
charged 30s the instant it was minted, and ``_scheduled_watchdog`` only ever
waited for a terminal event. In production it fired 17/17 times at exactly
cast + 30.002–30.007s regardless of content, background work, wake source or
transport health (.local-dev/recon/watchdog-longrun-findings.md §1.1).

A scheduled turn is not a ghost. A subagent-completion notification wakes the
main loop, which then spends minutes reviewing code and writing a report — a
completely legal shape. Killing it at 30.005s retired the transport, killed the
host CLI process, and took every subagent running inside that process with it:
2026-10-03 12:03, 12:55 and 13:49, three fatal rounds on one day. At 13:49 the
transcript's last write was 0.13s AFTER the firing line.

The breaker itself is the P0 defense and must not go away: a turn minted out of
silence that never projects anything and never sees a result holds
``session.execution`` forever, the session stays running and the composer stays
disabled. So the deadline is now an adjudication — a fast kill for the
zero-content class, and, for a turn that has shown real work, a stall verdict
that fires only once its labour frames have stood still past an age floor
(progress arbitration, `.local-dev/claude-watchdog-liveness-tasks.md` §2/§3).

The budgets here are compressed; the numbers in
``lifecycle.POLLED_TURN_WATCHDOG_SECONDS`` /
``lifecycle.CONTENTING_TURN_FLOOR_SECONDS`` /
``lifecycle.CONTENTING_TURN_STALL_SECONDS`` /
``lifecycle.CONTENTING_TURN_HARD_CAP_SECONDS`` are the product contract and are
pinned separately below.

Every fixture is an SDK-parsed shape (``parse_message``) or built from the
SDK's own dataclasses — the F5 lesson: hand-built lookalikes produced the P0
that the realwire file had to document.
"""

from __future__ import annotations

import asyncio
import contextlib
from types import SimpleNamespace
from typing import Any, Self

import pytest
from claude_agent_sdk import AssistantMessage
from claude_agent_sdk._internal.message_parser import parse_message
from test_claude_background_guard import (
    WIRE_TASK_STARTED,
    WIRE_WAKE_ASSISTANT,
)
from test_claude_compact_ghost import (
    _await_retirement_disclosure,
    _new_client_per_connection,
    _retirement_disclosures,
    _runtime_with,
    _single_client_factory,
    _turn_ends,
    _wait_until,
)
from test_claude_runtime import _RecordingHost, _ScheduledClaudeClient

from connector.logging import logger
from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.sdk import connection as claude_connection
from connector.runtimes.claude.turns import lifecycle

SESSION = "a0be10a0-b644-42f9-84a2-b3e191cd144a"

# Compressed budgets. The ratios are what matter — FLOOR above FAST_KILL (a
# ghost still reaps fast), and FLOOR >= FAST_KILL + STALL so "early silence"
# fires AT the floor exactly as the product numbers do. The numbers are what
# makes the file fast.
FAST_KILL = 0.1
FLOOR = 0.6
STALL = 0.3
HARD_CAP = 2.0
TICK = 0.02

# --------------------------------------------------------------------------
# Wire payloads
# --------------------------------------------------------------------------

# The 13:49 fatal round, verbatim shape: the subagent-completion wake that
# mints the scheduled turn, then the main agent's own review work. The wake
# frame casts the turn (passive arrival — it is excluded from the content
# gate); the turn's labour is the post-cast frame below.
WAKE_REVIEW_FRAME = WIRE_WAKE_ASSISTANT

# The turn's own labour AFTER the cast: deliberately the same payload as the
# wake frame, only later in the queue. What separates it from the cast frame
# is position — "was this the frame the cast arrived on" — never appearance,
# because a gate keyed on frame types dies by C3 (the trigger chain is not
# enumerable). Any test that needs "a turn which has shown work" casts with
# the wake frame and queues this one right behind it.
POST_CAST_WORK_FRAME = {**WAKE_REVIEW_FRAME, "uuid": "post-cast-work-1"}

# The 12:55 re-cast residue, both real shapes (B1 §3.1): the re-cast's
# minting frame is the in-flight tool's own receipt — `UserMessage(tool_result,
# parent_tool_use_id=None)` — or a StreamEvent the CLI emitted as it kept
# working at silence. Before the cast-frame gate each of these arrived and was
# booked as "this turn did work" the instant it landed (`consumed_frames`
# and/or `published_items` +1), which parked the residue on the 600s ceiling:
# ten minutes of held execution lock and a dead composer for a turn that would
# never settle, then the same `connection.close()` at the end of it.
RECAST_TOOL_RESULT_FRAME = {
    "type": "user",
    "message": {
        "role": "user",
        "content": [
            {
                "type": "tool_result",
                "tool_use_id": "toolu_recast_sleep",
                "content": "done",
            }
        ],
    },
    "uuid": "recast-tool-result-1",
    "session_id": SESSION,
}
RECAST_STREAM_EVENT_FRAME = {
    "type": "stream_event",
    "uuid": "recast-stream-1",
    "session_id": SESSION,
    "event": {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": "still chewing"},
    },
}

# A chrome frame the reader buffers at silence BEFORE the cast happens: at
# silence a `system` frame is parked in the reader's preamble, and the moment
# the re-cast residue lands the whole preamble is flushed into the response
# ahead of the cast frame (sdk/connection.py `_run`). `drive_turn` will
# process it first — and `compact_boundary` projects a compact marker. That
# marker is context this turn neither produced nor chose: booking it as this
# turn's labour would park a re-cast ghost on the 600s ceiling again, through
# the preamble instead of through the cast frame.
PREAMBLE_COMPACT_BOUNDARY = {
    "type": "system",
    "subtype": "compact_boundary",
    "compactMetadata": {},
    "uuid": "preamble-compact-boundary-1",
    "session_id": SESSION,
}

# A turn that only *consumes*: thinking deltas on the wire whose message_start
# never arrived. Production turn jmD_zip lost 1613 of these inside 30s and
# published nothing at all — "dropping Claude stream thinking without
# message_start id". A published-items-only anchor keeps killing exactly these.
DROPPED_THINKING_DELTA = {
    "type": "stream_event",
    "uuid": "dropped-delta-1",
    "session_id": SESSION,
    "event": {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": "reading the diff now"},
    },
}

# The residual ghost's minting frame: a real, non-chrome assistant frame that
# carries nothing. This is what the F5 chrome governance leaves behind — the
# reader mints on it (it is not chrome, not parented, not a task frame), the
# turn projects nothing, and no result ever follows. Both content counters
# must stay at zero here or the P0 comes back.
GHOST_MINT_FRAME = {
    "type": "assistant",
    "message": {"role": "assistant", "model": "claude-opus-5", "content": []},
    "uuid": "ghost-mint-1",
    "session_id": SESSION,
}


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _with_session(frame: dict[str, Any], native_id: str) -> Any:
    return _parse({**frame, "session_id": native_id})


def _complete(client: _ScheduledClaudeClient) -> None:
    client.incoming.put_nowait(SimpleNamespace(type="result", session_id=client.native_id))


def _failed_ends(host: _RecordingHost) -> list[dict[str, Any]]:
    return [end for end in host.session_turn_ends if end["outcome"] == "failed"]


async def _settled_session(runtime: Any, session_id: str) -> Any:
    """Run one healthy turn so the transport is up and the reader is at silence."""

    session = runtime._sessions[session_id]
    await asyncio.wait_for(session.active_task, 5)
    assert session.execution is None
    return session


class _CapturedWarnings:
    """Collect connector WARNING lines around a block."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self._sink: int | None = None

    def __enter__(self) -> Self:
        self._sink = logger.add(lambda message: self.lines.append(str(message)), level="WARNING")
        return self

    def __exit__(self, *_exc: object) -> None:
        assert self._sink is not None
        logger.remove(self._sink)

    def joined(self) -> str:
        return "\n".join(self.lines)


def _budgets(
    monkeypatch: pytest.MonkeyPatch,
    fast: float = FAST_KILL,
    floor: float = FLOOR,
    stall: float = STALL,
    cap: float = HARD_CAP,
    tick: float = TICK,
) -> None:
    monkeypatch.setattr(lifecycle, "POLLED_TURN_WATCHDOG_SECONDS", fast)
    monkeypatch.setattr(lifecycle, "CONTENTING_TURN_FLOOR_SECONDS", floor)
    monkeypatch.setattr(lifecycle, "CONTENTING_TURN_STALL_SECONDS", stall)
    monkeypatch.setattr(lifecycle, "CONTENTING_TURN_HARD_CAP_SECONDS", cap)
    monkeypatch.setattr(lifecycle, "WATCHDOG_STALL_POLL_SECONDS", tick)


async def _cast_with_labour(
    client: _ScheduledClaudeClient,
    session: Any,
    first: dict[str, Any] = WAKE_REVIEW_FRAME,
    second: dict[str, Any] = POST_CAST_WORK_FRAME,
) -> ClaudeExecution:
    """Cast a scheduled turn and give it post-cast labour, then wait for both.

    Both frames are queued before the test yields, so the reader absorbs the
    cast frame and the labour frame in the same scheduling slice: `drive_turn`
    counts the second frame's content in its first run — before the watchdog
    task ever starts its first deadline. The content precondition is therefore
    structural, not a race against the compressed fast-kill budget (this is
    the flake the single-frame version had: whether `drive_turn` had counted
    within `fast` was a scheduling bet).
    """

    await client.incoming.put(_with_session(first, client.native_id))
    await client.incoming.put(_with_session(second, client.native_id))
    await _wait_until(lambda: session.execution is not None)
    execution = session.execution
    await _wait_until(lambda: execution.has_turn_content)
    return execution


# --------------------------------------------------------------------------
# 1. The product numbers this batch was adjudicated with
# --------------------------------------------------------------------------


def test_watchdog_deadlines_are_the_adjudicated_product_budgets() -> None:
    """30s fast kill, then floor/stall/hard cap (pp verdict,
    `.local-dev/claude-watchdog-liveness-tasks.md` §3 micro-verdict).

    All four magnitudes are load-bearing and none is derivable from the code.
    The fast kill is the C1 budget for the ghost class; the floor is the age
    before which no contenting kill is permitted (a whole observed wake-cycle
    — 10-15 min of continuous work — fits inside it); the stall budget is how
    long labour may stand still before the turn is judged dead (5x the largest
    audited legal generation gap); the hard cap is the one absolute bound, and
    the only verdict an always-progressing turn can meet.
    """

    assert lifecycle.POLLED_TURN_WATCHDOG_SECONDS == 30.0
    assert lifecycle.CONTENTING_TURN_FLOOR_SECONDS == 600.0
    assert lifecycle.CONTENTING_TURN_STALL_SECONDS == 300.0
    assert lifecycle.CONTENTING_TURN_HARD_CAP_SECONDS == 3600.0


# --------------------------------------------------------------------------
# 2. The content gate itself: which counters exempt a turn
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("published_items", "consumed_frames", "expected"),
    [
        (0, 0, lifecycle.WATCHDOG_REASON_ZERO_CONTENT),
        (12, 0, lifecycle.WATCHDOG_REASON_CONTENT_STALL),
        (0, 7, lifecycle.WATCHDOG_REASON_CONTENT_STALL),
        (3, 4, lifecycle.WATCHDOG_REASON_CONTENT_STALL),
    ],
)
def test_content_gate_is_the_or_of_both_counters(
    published_items: int,
    consumed_frames: int,
    expected: str,
) -> None:
    """Both anchor red lines, pinned at the decision itself.

    `published_items` alone would re-murder the dropped-frame turns
    (`published == 0`, `consumed > 0`); `consumed_frames` alone would let a
    turn that published 12 items be killed like a ghost. Neither counter may be
    swapped for "the final answer text" either — jmD_zip published nothing at
    all and was not a ghost.

    The gate now selects the ADJUDICATION, not merely an exemption: (0, 0) is
    judged on the spot as a ghost, while any content routes the turn into the
    stall arbitration. The floor/stall budgets are zeroed so the decision is
    read directly, not a clock.
    """

    execution = ClaudeExecution(
        turn_id="turn_gate",
        published_items=published_items,
        consumed_frames=consumed_frames,
    )
    assert execution.has_turn_content is (
        expected != lifecycle.WATCHDOG_REASON_ZERO_CONTENT
    )

    async def run() -> None:
        verdict = await lifecycle.ClaudeTurnRunner._await_watchdog_deadlines(
            execution,
            0.01,  # fast kill
            0.0,  # floor: no age requirement for this read of the gate
            0.0,  # stall: no silence requirement for this read of the gate
            100.0,  # hard cap: never in play on either branch
            0.01,  # tick
            "turn_gate",
        )
        assert verdict is not None
        assert verdict.reason == expected

    asyncio.run(run())


def test_a_finished_turn_never_fires_a_deadline() -> None:
    execution = ClaudeExecution(turn_id="turn_done", published_items=4)
    execution.finished.set()

    async def run() -> None:
        verdict = await lifecycle.ClaudeTurnRunner._await_watchdog_deadlines(
            execution, 5.0, 600.0, 300.0, 3600.0, 5.0, "turn_done"
        )
        assert verdict is None

    asyncio.run(run())


# --------------------------------------------------------------------------
# 3. 修前红: a long autonomous turn is not fast-killed
# --------------------------------------------------------------------------


def test_long_turn_that_publishes_work_survives_the_fast_kill(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The 13:49 shape: a wake-driven review turn keeps its execution lock.

    修前红: with the single 30s deadline this turn is force-failed at exactly
    cast+30.002s, the transport is retired and the host CLI process — with
    every subagent in it — is killed, and the reply is lost. With the content
    gate it simply runs.

    The labour is the post-cast frame, not the cast frame: after B5 the wake
    frame itself is excluded from the gate (passive arrival), so this pins
    "the turn kept working after the cast" — the fact the exemption is keyed
    on — rather than "a frame once arrived".
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("longrun", None, "hello")
            session = await _settled_session(runtime, "longrun")

            # The CLI wakes the main loop with a subagent completion notice and
            # the main agent starts working.
            execution = await _cast_with_labour(client, session)

            # Well past the fast kill, with the review still going.
            await asyncio.sleep(FAST_KILL * 3)
            assert session.execution is execution, (
                "a turn that has published items must not be fast-killed"
            )
            assert execution.published_items > 0
            assert execution.has_turn_content is True
            assert not _turn_ends(host, execution.turn_id)
            assert client.disconnected is False

            # ...and it still finishes normally afterwards.
            _complete(client)
            await _wait_until(lambda: session.execution is None)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert not _failed_ends(host)
            assert client.disconnected is False
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_long_turn_that_only_consumes_frames_survives_the_fast_kill(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The jmD_zip shape: 1613 dropped thinking deltas, zero published items.

    Anchor red line #1 — this turn must NOT be judged by `published_items`.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("dropped", None, "hello")
            session = await _settled_session(runtime, "dropped")

            await client.incoming.put(_with_session(GHOST_MINT_FRAME, client.native_id))
            await client.incoming.put(
                _with_session(DROPPED_THINKING_DELTA, client.native_id)
            )
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            await _wait_until(lambda: execution.consumed_frames > 0)

            assert execution.published_items == 0, (
                "the thinking deltas are dropped before publication — that is "
                "the whole point of this shape"
            )
            assert execution.consumed_frames > 0
            assert execution.has_turn_content is True

            await asyncio.sleep(FAST_KILL * 3)
            assert session.execution is execution
            assert not _turn_ends(host, execution.turn_id)
            assert client.disconnected is False
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_content_turn_is_not_killed_by_frame_silence(monkeypatch: pytest.MonkeyPatch) -> None:
    """C4 boundary, re-adjudicated: silence under the stall budget never kills.

    A legal `sleep 75` produces 72.003s of zero-frame silence on the wire
    (findings §2.4), and this product's own normal usage includes 35s+ tools
    with a declared 600s timeout. Progress arbitration states the invariant
    more strongly than the old "no frame-based reset" rule did: silence
    shorter than CONTENTING_TURN_STALL_SECONDS fires nothing, even once the
    turn is past the age floor — the only clock that matters is the one
    measured from the last labour sample.

    The work has to be post-cast (the cast frame itself is excluded from the
    gate after B5), which matches the real wire: the wake frame casts, the
    agent's own frames follow, and only then does the tool go silent for 72s.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("silent", None, "hello")
            session = await _settled_session(runtime, "silent")
            execution = await _cast_with_labour(client, session)
            baseline = execution.published_items

            # A silence that reaches the age floor while the stall clock is
            # still fresh: the floor is what protects the turn here.
            await asyncio.sleep(FLOOR - FAST_KILL / 2)
            assert session.execution is execution, (
                "silence under the stall budget must not be re-armed into a "
                "short deadline"
            )

            # Fresh labour pushes the stall clock out again; the next stretch
            # of silence is still shorter than STALL and the turn is now past
            # the floor, so it must not die either.
            await client.incoming.put(
                _with_session(
                    {**POST_CAST_WORK_FRAME, "uuid": "silent-late-work"},
                    client.native_id,
                )
            )
            await _wait_until(lambda: execution.published_items > baseline)
            await asyncio.sleep(STALL / 2)
            assert session.execution is execution
            assert not _turn_ends(host, execution.turn_id)
            assert client.disconnected is False
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4. C1: the zero-content ghost is still reaped by the fast kill
# --------------------------------------------------------------------------


def test_zero_content_ghost_is_reaped_by_the_fast_kill(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The P0 must not regress: cast → nothing, ever → failed terminal + unlock.

    修前红 if the content gate is removed the other way: exempting every turn
    leaves `session.execution` held forever, the session pinned to running and
    the composer disabled. That is the worse failure this whole batch exists to
    avoid, so it is asserted against the lock, not just against a log line.
    """

    # Deliberately wide contenting budgets: the ghost must be gone long before
    # them, so "exempt everything" cannot pass this by simply waiting longer.
    _budgets(monkeypatch, fast=FAST_KILL, floor=30.0, stall=30.0, cap=90.0)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("ghost", None, "hello")
            session = await _settled_session(runtime, "ghost")

            await client.incoming.put(_with_session(GHOST_MINT_FRAME, client.native_id))
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution

            # The ghost signature, asserted before the deadline rather than
            # assumed: no projected item, no counted non-chrome frame.
            await asyncio.sleep(FAST_KILL / 2)
            assert execution.published_items == 0
            assert execution.consumed_frames == 0
            assert execution.has_turn_content is False

            await _wait_until(lambda: bool(_turn_ends(host, execution.turn_id)))
            ended = _turn_ends(host, execution.turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            # This ghost is retired fatally, so the retirement disclosure is the
            # last word on the session — it lands after the turn end, hence the
            # explicit wait.
            await _await_retirement_disclosure(host)
            assert host.session_state_updates[-1]["status"] == "error"
            assert (
                host.session_state_updates[-1]["error"]["code"]
                == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            )
            assert session.execution is None
            assert session.queued_execution is None
            # The fast kill, not the contenting arbitration: the terminal text
            # names 0.2s.
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_ghost_recovery_never_waits_for_the_contenting_budgets(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Wide contenting budgets must not slow the ghost class down.

    The floor+stall path for a ghost would be "the session is running and the
    composer is dead for ten minutes" — a different P0 with the same symptom.
    The fast kill is measured from the cast, so the ghost is gone at 30s
    whatever those budgets are.
    """

    _budgets(monkeypatch, fast=FAST_KILL, floor=30.0, stall=30.0, cap=90.0)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("fastghost", None, "hello")
            session = await _settled_session(runtime, "fastghost")
            await client.incoming.put(_with_session(GHOST_MINT_FRAME, client.native_id))
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            await _wait_until(lambda: session.execution is None)
            assert _turn_ends(host, execution.turn_id)[-1]["outcome"] == "failed"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4b. B5: the frame that cast the turn is not evidence of work
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "cast_frame",
    [RECAST_TOOL_RESULT_FRAME, RECAST_STREAM_EVENT_FRAME],
    ids=["tool_result", "stream_event"],
)
def test_recast_ghost_is_reaped_by_the_fast_kill(
    cast_frame: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """12:55's re-cast residue must stay in the (0, 0) ghost class.

    The re-cast's minting frame IS the turn's first and only frame: the
    in-flight tool's own `tool_result` receipt (`parent_tool_use_id=None`),
    or a StreamEvent (B1 §3.1, both shapes seen on the 2026-10-03 12:55
    re-cast chain). Before the cast-frame gate its arrival alone satisfied
    the content gate — `consumed_frames` and/or `published_items` +1 the
    instant it landed — which reassigned the residue from the 30s fast kill
    to the 600s ceiling: the execution lock held for up to ten minutes, the
    composer stayed disabled the whole time, and `connection.close()` killed
    the CLI at the end of it anyway (the 10x damage the B5 e2e measured).

    Both counters are asserted at (0, 0) before the deadline rather than
    assumed, and the contenting budgets are deliberately wide (30s) against a 0.1s fast
    kill: a gate that exempted "anything that was ever seen" cannot pass by
    waiting longer — the reap must happen inside the fast kill, which the
    firing's own `reason=zero_content_fast_kill` line proves.
    """

    _budgets(monkeypatch, fast=FAST_KILL, floor=30.0, stall=30.0, cap=90.0)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("recast", None, "hello")
            session = await _settled_session(runtime, "recast")

            # The lone residue frame: it casts the turn, then nothing ever
            # follows — no terminal, no further labour.
            await client.incoming.put(_with_session(cast_frame, client.native_id))
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution

            # The ghost signature, asserted before the deadline: neither the
            # frame's consumption nor the items it projected may count.
            await asyncio.sleep(FAST_KILL / 2)
            assert execution.published_items == 0, (
                "the cast frame's projection must not be booked as labour"
            )
            assert execution.consumed_frames == 0, (
                "the cast frame's consumption must not be booked as labour"
            )
            assert execution.has_turn_content is False

            with _CapturedWarnings() as captured:
                # Fast kill (0.1s), not the wide contenting budgets: waiting
                # for them would blow this 5s timeout.
                await _wait_until(lambda: bool(_turn_ends(host, execution.turn_id)))
            ended = _turn_ends(host, execution.turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            await _await_retirement_disclosure(host)
            assert host.session_state_updates[-1]["status"] == "error"
            assert (
                host.session_state_updates[-1]["error"]["code"]
                == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            )
            assert session.execution is None
            assert session.queued_execution is None
            log = captured.joined()
            assert f"reason={lifecycle.WATCHDOG_REASON_ZERO_CONTENT}" in log, log
            assert "published_items=0" in log, log
            assert "consumed_frames=0" in log, log
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4c. The same principle for what was already in the queue before the cast
# --------------------------------------------------------------------------


def test_preamble_marker_does_not_lift_a_recast_ghost_to_the_ceiling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Preamble frames are passive context too — they may not buy time.

    The reader parks chrome at silence in a preamble buffer and flushes it
    into the response the moment a later frame casts the turn, so `drive_turn`
    sees [preamble..., cast frame, ...]. The compact marker that
    `compact_boundary` projects on its way through is real user-visible
    output — it is still upserted — but this turn did nothing to earn it:
    it was already lying there before the cast. If anything pre-cast counts,
    a re-cast ghost whose preamble happens to hold a stale `compact_boundary`
    is exempted from the fast kill and sits in the contenting arbitration with
    the composer disabled — the B5 damage, reached from the other side.

    Same red-line shape as the cast-frame test above: (0, 0) asserted before
    the deadline, deliberately wide contenting budgets (30s) against a 0.1s fast kill,
    and the firing's own `reason=zero_content_fast_kill` line as the proof
    which deadline fired. Position only — the marker's own payload would count
    if it arrived one frame later.
    """

    _budgets(monkeypatch, fast=FAST_KILL, floor=30.0, stall=30.0, cap=90.0)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("preamble", None, "hello")
            session = await _settled_session(runtime, "preamble")

            # Both frames go in before the test yields: the chrome boundary is
            # buffered at silence, then the residue casts — preamble first,
            # cast frame second, nothing ever after.
            await client.incoming.put(
                _with_session(PREAMBLE_COMPACT_BOUNDARY, client.native_id)
            )
            await client.incoming.put(
                _with_session(RECAST_TOOL_RESULT_FRAME, client.native_id)
            )
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution

            await asyncio.sleep(FAST_KILL / 2)
            assert execution.published_items == 0, (
                "the preamble's compact marker must not be booked as this "
                "turn's labour"
            )
            assert execution.consumed_frames == 0
            assert execution.has_turn_content is False

            with _CapturedWarnings() as captured:
                # Fast kill (0.1s), not the wide contenting budgets: waiting
                # for them would blow this 5s timeout.
                await _wait_until(lambda: bool(_turn_ends(host, execution.turn_id)))
            ended = _turn_ends(host, execution.turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            assert session.execution is None
            assert session.queued_execution is None
            log = captured.joined()
            assert f"reason={lifecycle.WATCHDOG_REASON_ZERO_CONTENT}" in log, log
            assert "published_items=0" in log, log
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 5. G2 re-adjudicated: a stalled contenting turn is still a deadline
# --------------------------------------------------------------------------


def test_stalled_contenting_turn_is_reaped_by_the_stall_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Exempt from the fast kill ≠ never settled (red line §5, re-adjudicated).

    A turn that showed work and then stalls takes the exact same
    forced-failure + release + retire path the ghost takes — the verdict is
    now `contenting_turn_stall`, fired once the labour counters have been
    still for STALL while the turn is past FLOOR. Pinned on timing, not just
    on the outcome: the turn must still be alive well past the fast kill, so
    collapsing the floor back onto the fast kill (or deleting the verdict)
    turns this red.

    Two races used to make the ceiling version of this test flaky (5/13
    isolated before the fix), both fixed at the cause rather than by
    loosening anything:

    1. Disconnection was asserted at turn-end time, but `_scheduled_watchdog`
       runs `finish_execution` (which records the turn's end and unlocks the
       session) BEFORE `retire_stuck_transport` closes the transport — the
       assertion was sampling the window between them. It now waits for the
       disconnection itself, which still fails if the close never comes.
    2. The content precondition was implicit: whether `drive_turn` had counted
       the arriving frame before the compressed fast-kill deadline ran out was
       a scheduling bet. The labour frame is now queued in the same slice as
       the cast (see `_cast_with_labour`) and the precondition is asserted
       explicitly before any timing starts.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("stall", None, "hello")
            session = await _settled_session(runtime, "stall")
            execution = await _cast_with_labour(client, session)
            assert execution.published_items > 0

            # Well past the fast kill, before the floor: the turn still owns
            # its lock, so the exemption has not collapsed onto the fast kill.
            await asyncio.sleep(FAST_KILL * 3)
            assert session.execution is execution
            assert not _turn_ends(host, execution.turn_id)

            with _CapturedWarnings() as captured:
                await _wait_until(lambda: bool(_turn_ends(host, execution.turn_id)))
            ended = _turn_ends(host, execution.turn_id)[-1]
            assert ended["outcome"] == "failed"
            assert ended["metadata"]["terminalReason"] == "scheduled_watchdog_timeout"
            log = captured.joined()
            assert f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}" in log, log
            assert "stall_seconds=" in log, log
            assert "age_seconds=" in log, log
            assert session.execution is None
            assert session.queued_execution is None
            # Transport close happens strictly after the turn's end is
            # recorded (finish → retire), so wait for the close rather than
            # asserting it in the window between the two.
            await _wait_until(lambda: client.disconnected)
            assert client.disconnected is True
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 6. L1 and the limiter are unchanged
# --------------------------------------------------------------------------


def test_live_background_work_still_blocks_retirement(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The do-not-retire invariant is untouched by the content gate.

    A turn that has shown work is now reaped by the stall verdict instead of
    the fast kill; when live background work rides the same transport, that
    verdict must still downgrade to "fail the turn, drop the ghost response,
    keep the process" exactly as before.
    """

    _budgets(monkeypatch)

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
            await runtime.start_turn("l1", None, "hello")
            session = await _settled_session(runtime, "l1")
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            connection = runtime._turns.runner.connections["l1"]
            await _wait_until(lambda: bool(connection.background.active_ids))

            execution = await _cast_with_labour(client, session)
            ghost_turn_id = execution.turn_id
            with _CapturedWarnings() as captured:
                await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
                # `drop_current` is the last thing the L1 branch does, so this
                # is the point at which the retirement decision is final.
                await _wait_until(lambda: connection.current is None)

            assert _turn_ends(host, ghost_turn_id)[-1]["outcome"] == "failed"
            assert session.execution is None
            assert connection.background.active_ids
            assert "Claude stuck-turn retirement skipped" in captured.joined(), (
                captured.joined()
            )
            assert client.disconnected is False, (
                "live background work rides this process; closing it would "
                "destroy work upstream cannot replay"
            )
            assert len(built) == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_repeat_containing_timeouts_still_report_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The client-visible limiter is untouched by the new adjudication."""

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("limit", None, "hello")
            session = await _settled_session(runtime, "limit")
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            connection = runtime._turns.runner.connections["limit"]
            await _wait_until(lambda: bool(connection.background.active_ids))

            for index in range(2):
                execution = await _cast_with_labour(
                    client,
                    session,
                    first={**WAKE_REVIEW_FRAME, "uuid": f"limit-{index}"},
                    second={**POST_CAST_WORK_FRAME, "uuid": f"limit-work-{index}"},
                )
                assert execution.has_turn_content is True
                await _wait_until(lambda: session.execution is None)
                assert session.queued_execution is None

            assert len(_failed_ends(host)) == 1, (
                "one connection window must surface at most one visible failure"
            )
            assert connection.stuck_timeout_reports == 1
            assert client.disconnected is False
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 7. G4: the fatal retirement must be visible even when the limiter is silent
# --------------------------------------------------------------------------


def test_fatal_retirement_is_logged_even_when_the_limiter_silences_the_report(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """13:49, exactly: the process death left no server-side trace.

    `stuck_timeout_reports` decides whether the failed turn reaches the client
    ledger. It has nothing to do with whether the host CLI process is about to
    be killed. On 2026-10-03 13:49 the one firing that actually closed the
    connection was a rate-limited repeat, so the only trace of a killed
    process and its subagents was "kept off the client ledger".

    Two halves, both load-bearing and both asserted here:

    * the ledger is still silenced — the limiter's meaning is unchanged;
    * the process death now reaches the USER as well as the log, on its own
      code. The log line was never enough: it reaches an operator who happens
      to be grepping, not the person whose turn just died.

    修前红: remove the dedicated line in `retire_stuck_transport` and this is
    the exact accident with nothing to grep for. Drop the disclosure call from
    the same method and the second half fails while the ledger half still
    passes — which is the point: neither one is allowed to stand in for the
    other.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("fatal", None, "hello")
            session = await _settled_session(runtime, "fatal")
            connection = runtime._turns.runner.connections["fatal"]
            # The ledger slot for this connection window is already spent, so the
            # firing below is the `publish=False` path.
            connection.stuck_timeout_reports = 1

            # A containing turn (post-cast labour), so the firing below is the
            # stall branch the assertion names.
            execution = await _cast_with_labour(client, session)

            with _CapturedWarnings() as captured:
                await _await_retirement_disclosure(host)

            # The client-visible LEDGER side stayed silent...
            assert not _turn_ends(host, execution.turn_id), (
                "this is the rate-limited branch; nothing may reach the ledger"
            )
            assert session.execution is None
            assert (
                "kept off the client ledger" in captured.joined()
            ), captured.joined()

            # ...but the USER side was told, on a code of its own. This is the
            # assertion that is the reason the code exists: gate this
            # disclosure on `publish` and only this half goes red.
            disclosure = _retirement_disclosures(host)
            assert len(disclosure) == 1, disclosure
            error = disclosure[0]["error"]
            assert error["code"] == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            assert disclosure[0]["status"] == "error"
            assert disclosure[0]["metadata"]["source"] == (
                lifecycle.CLAUDE_PROCESS_RETIRED_SOURCE
            )
            assert error["params"]["retirementConfirmed"] is True
            assert error["params"]["stuckSeconds"] == int(
                lifecycle.CONTENTING_TURN_STALL_SECONDS
            )
            assert error["message"] == lifecycle.PROCESS_RETIRED_MESSAGE

            # ...and the process death is on its own line, with the counters
            # that explain why the breaker fired at all.
            log = captured.joined()
            assert "Claude stuck transport retirement is FATAL" in log, log
            assert f"turn_id={execution.turn_id}" in log
            assert f"reason={lifecycle.WATCHDOG_REASON_CONTENT_STALL}" in log, log
            assert "client_reported=False" in log, log
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_every_firing_carries_the_content_counters(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """G4: a watchdog line must say which class it fired on, and why.

    Asserted ON the fired line itself, not merely "somewhere in the WARNING
    log": the fatal-retirement line repeats the same counters, so a whole-log
    membership check survived a mutation that stripped them out of the firing
    line (mutation-testing finding, 2026-10-03).
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("observe", None, "hello")
            session = await _settled_session(runtime, "observe")

            await client.incoming.put(_with_session(GHOST_MINT_FRAME, client.native_id))
            await _wait_until(lambda: session.execution is not None)
            ghost_turn_id = session.execution.turn_id
            with _CapturedWarnings() as captured:
                await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
            fired = [
                line
                for line in captured.joined().splitlines()
                if "watchdog fired" in line
            ]
            assert len(fired) == 1, captured.joined()
            line = fired[0]
            assert f"reason={lifecycle.WATCHDOG_REASON_ZERO_CONTENT}" in line, line
            assert "published_items=0" in line, line
            assert "consumed_frames=0" in line, line
            assert "active_tasks=0" in line, line
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_recovery_after_a_containing_timeout_completes_normally(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Bug-library lesson ②: releasing the lock is not recovering the session.

    The judgement is "the next message completes", so that is what is asserted.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        hanging = _ScheduledClaudeClient()
        healthy = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _new_client_per_connection([hanging, healthy]))
        try:
            await runtime.start_turn("recover", None, "schedule")
            session = await _settled_session(runtime, "recover")

            execution = await _cast_with_labour(hanging, session)
            ghost_turn_id = execution.turn_id
            await _wait_until(lambda: bool(_turn_ends(host, ghost_turn_id)))
            assert _turn_ends(host, ghost_turn_id)[-1]["outcome"] == "failed"
            await _wait_until(
                lambda: "recover" not in runtime._turns.runner.connections
            )

            recovery = await runtime.start_turn("recover", "native_timer", "after")
            assert recovery.ok is True
            await asyncio.wait_for(runtime._sessions["recover"].active_task, 5)
            ended = _turn_ends(host, recovery.result["turnId"])[-1]
            assert ended["outcome"] == "completed"
            assert host.session_state_updates[-1]["status"] == "idle"
            assert healthy.queries == ["after"]
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 8. A human turn is still never armed
# --------------------------------------------------------------------------


def test_human_turns_are_never_armed_even_when_they_publish(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The counters move on every turn; only a scheduled one reads them.

    Counting is unconditional so a human turn cannot take a different branch
    from a scheduled one just because a watchdog exists. What must not change is
    that a human turn is still never armed — thinking out loud for minutes is
    normal and the user typed it.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("human", None, "wait")
            session = runtime._sessions["human"]
            await client.incoming.put(
                AssistantMessage(
                    uuid="human-thinking",
                    model="claude-opus-5",
                    session_id=client.native_id,
                    content=[{"type": "text", "text": "still reviewing the diff"}],
                )
            )
            await _wait_until(
                lambda: session.execution is not None
                and session.execution.published_items > 0
            )
            execution = session.execution
            assert execution is not None
            assert execution.watchdog_task is None

            # Well past the fast kill: the human turn is untouched.
            await asyncio.sleep(FAST_KILL * 3)
            assert session.execution is execution
            assert not _turn_ends(host, execution.turn_id)

            await client.reply("done thinking")
            await asyncio.wait_for(session.active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 9. Property: the content gate cannot drift from what was actually projected
# --------------------------------------------------------------------------
#
# `lifecycle.py` states the hazard in its own words: "did this turn produce
# something" has TWO authorities — `drive_turn`'s publish branches, and the
# six-way `consumed_frames` test on the same frame. They are the same knowledge
# written twice and they WILL drift: add a `drive_turn` branch that projects a
# timeline item without matching one of those six shapes, and the turn sits at
# zero content, is misjudged a ghost, and is fast-killed at 30.002s with no
# log line saying why and no test going red.
#
# So the invariant is pinned from the OUTSIDE, by behaviour, over the real
# frame corpus. Nothing here reads the source, matches a token, or imports a
# predicate out of `lifecycle`: every assertion is made against
#
#   * `host.timeline_item_upserts` — what the user would really have seen, and
#   * `execution.published_items` / `.consumed_frames` — what the gate believes,
#
# after a REAL scheduled turn ran: real runtime, real reader, real mint branch,
# real `drive_turn`, real projector, real watchdog armed. The frame corpus is
# the SDK's own `parse_message` over real wire payloads — never a lookalike
# (the F5 lesson, and the reason the realwire file has to exist at all).
#
# Four arms, each with a mutation that turns it red (measured, not hoped for):
#
#   A   projected > 0 ⇒ `published_items` counted it AND `has_turn_content`
#                          (under-count → a real long turn is fast-killed)
#   A'  census says the shape consumes mid-turn, nothing was projected
#                          ⇒ `has_turn_content` (the dropped-frame exemption)
#   B   nothing projected AND the census says nothing consumable
#                          ⇒ NOT `has_turn_content` (over-exempt → ghost lives)
#   A'' census consumed verdict == `consumed_frames > 0`, term by term
#                          (an OR cannot see its own counters drift apart)
#   C   cast frame / anything at or before it ⇒ both counters stay 0 no matter
#      how much it projected                          (positional, B5)
#
# Arm A is the one the code comments ask for, and the only one that is purely
# observational. Arm B is its mirror: without it, "count every post-cast frame"
# passes A perfectly and parks every ghost on the contenting floor with the
# composer disabled. Arm C is what keeps the gate POSITIONAL — the same payload, one
# frame later, is counted; as the frame that cast the turn it is not, even when
# it published a timeline item of its own.
#
# Corpus: `.local-dev/recon/b5-mint-census.py` (`SHAPES`, 23 shapes, run
# 2026-10-03 → `.local-dev/recon/b5/mint-census.json`). The payloads below are
# that file's `SHAPES` verbatim and the last column is its `consumed` verdict —
# "what this shape counts as one frame later, mid-turn", i.e. the census's own
# frozen model of the six-way test. It is data, not a call into the predicate
# under test, so arms B and C are not the implementation agreeing with itself:
# they are the live gate against an independently written census.
#
# Why a census verdict can be carried as data at all: `consumed` is only a
# SELECTOR for arm B (which shapes are allowed to demand content), never the
# assertion. Arm A — the one that matters — is pure observation.

# (label, wire payload, provenance, census "consumed" verdict)
_CENSUS_CORPUS: list[tuple[str, dict[str, Any], str, bool]] = [
    (
        "assistant/text",
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [{"type": "text", "text": "reviewing the diff now"}],
            },
            "uuid": "census-a-text",
        },
        "ordinary assistant reply",
        True,
    ),
    (
        "assistant/thinking-only",
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [
                    {"type": "thinking", "thinking": "hmm", "signature": "sig"}
                ],
            },
            "uuid": "census-a-thinking",
        },
        "assistant frame whose only block is thinking",
        True,
    ),
    (
        "assistant/tool_use-only",
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_census",
                        "name": "Read",
                        "input": {"file_path": "/x"},
                    }
                ],
            },
            "uuid": "census-a-tool",
        },
        "assistant frame carrying only a tool call",
        True,
    ),
    (
        "assistant/empty-content",
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [],
            },
            "uuid": "census-a-empty",
        },
        "the B4 test's GHOST_MINT_FRAME — assistant frame with nothing on it",
        False,
    ),
    (
        "assistant/no-response-requested (synthetic)",
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "model": "<synthetic>",
                "content": [{"type": "text", "text": "No response requested."}],
            },
            "uuid": "census-a-noresp",
        },
        "CLI's synthetic 'nothing to say' assistant frame",
        False,
    ),
    (
        "assistant/text + ptu",
        {
            "type": "assistant",
            "parent_tool_use_id": "toolu_agent_dispatch",
            "message": {
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [{"type": "text", "text": "subagent working"}],
            },
            "uuid": "census-a-ptu",
        },
        "2026-10-03 family #2: subagent leak with a parent tool_use_id",
        True,
    ),
    (
        "user/tool_result (ptu=None)",
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_sleep",
                        "content": "done",
                    }
                ],
            },
            "uuid": "census-u-toolresult",
        },
        "B1 §3.1 re-cast frame: the in-flight tool's own receipt, ptu=None",
        True,
    ),
    (
        "user/plain-text (ptu=None)",
        {
            "type": "user",
            "message": {"role": "user", "content": "please review the diff"},
            "uuid": "census-u-text",
        },
        "a prompt-shaped user frame replayed at silence",
        False,
    ),
    (
        "user/empty-content (ptu=None)",
        {
            "type": "user",
            "message": {"role": "user", "content": []},
            "uuid": "census-u-empty",
        },
        "user frame with nothing on it",
        False,
    ),
    (
        "user/task-notification-origin",
        {
            "type": "user",
            "origin": {"kind": "task-notification", "producer": "session-task"},
            "message": {
                "role": "user",
                "content": (
                    "<task-notification><task-id>abc</task-id></task-notification>"
                ),
            },
            "uuid": "census-u-tasknotif",
        },
        "the legitimate wake frame (13:49 first frame)",
        False,
    ),
    (
        "user/command-name echo",
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": "<command-name>/compact</command-name>\n"
                           "<command-message>compact</command-message>",
            },
            "uuid": "census-u-cmd",
        },
        "2026-10-02 compact ghost, half 1 (session 84275e9e)",
        False,
    ),
    (
        "user/local-command-stdout echo",
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": "<local-command-stdout>Compacted </local-command-stdout>",
            },
            "uuid": "census-u-stdout",
        },
        "2026-10-02 compact ghost, half 2",
        False,
    ),
    (
        "user/compact-summary",
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": "This session is being continued from a previous "
                           "conversation that ran out of context. The summary below "
                           "covers the earlier portion of the conversation.\n...",
            },
            "uuid": "census-u-summary",
        },
        "post-/compact summary replay",
        False,
    ),
    (
        "user/interrupted marker",
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": "[Request interrupted by user]",
            },
            "uuid": "census-u-interrupt",
        },
        "interrupt echo",
        False,
    ),
    (
        "system/hook_started",
        {
            "type": "system",
            "subtype": "hook_started",
            "hook_event": "SessionStart",
            "hook_name": "SessionStart:compact",
            "uuid": "census-s-hookstart",
        },
        "2026-10-02 compact ghost, half 3 (SessionStart narration)",
        False,
    ),
    (
        "system/status handshake",
        {
            "type": "system",
            "subtype": "status",
            "status": "idle",
            "uuid": "census-s-status",
        },
        "CLI handshake",
        False,
    ),
    (
        "system/compact_boundary",
        {
            "type": "system",
            "subtype": "compact_boundary",
            "compactMetadata": {},
            "uuid": "census-s-boundary",
        },
        "post-compaction bookkeeping",
        False,
    ),
    (
        "system/task_notification",
        {
            "type": "system",
            "subtype": "task_notification",
            "task_id": "t1",
            "status": "completed",
            "summary": "done",
            "output_file": "/tmp/o.txt",
            "uuid": "census-s-tasknotif",
        },
        "subagent completion notification",
        False,
    ),
    (
        "stream_event/text_delta",
        {
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "reviewing"},
            },
            "uuid": "census-se-text",
        },
        "partial assistant text (connector runs with include_partial_messages)",
        True,
    ),
    (
        "stream_event/thinking_delta",
        {
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "thinking_delta", "thinking": "reading the diff"},
            },
            "uuid": "census-se-thinking",
        },
        "production jmD_zip: 1613 of these, zero items published",
        True,
    ),
    (
        "stream_event/message_start",
        {
            "type": "stream_event",
            "event": {
                "type": "message_start",
                "message": {
                    "id": "msg_census",
                    "model": "claude-opus-5",
                    "content": [],
                    "usage": {},
                },
            },
            "uuid": "census-se-start",
        },
        "partial message start",
        True,
    ),
    (
        "stream_event + ptu",
        {
            "type": "stream_event",
            "parent_tool_use_id": "toolu_agent_dispatch",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "subagent"},
            },
            "uuid": "census-se-ptu",
        },
        "subagent partial, parented",
        True,
    ),
    (
        "result/plain",
        {
            "type": "result",
            "subtype": "success",
            "duration_ms": 10,
            "duration_api_ms": 10,
            "is_error": False,
            "num_turns": 1,
            "uuid": "census-r-plain",
        },
        "an ordinary result frame replayed at silence",
        True,
    ),
]

_CENSUS_BY_LABEL = {row[0]: row[1] for row in _CENSUS_CORPUS}

# The chrome frame parked between the cast and the shape under test. It is the
# census's own `system/status handshake` payload, reused rather than re-typed,
# and it earns its place twice: it proves that a frame arriving AFTER the cast
# still buys nothing when it is chrome (the "chrome-after-cast ghost" of the
# fast-kill class), and it means the counters measured for the shape are the
# shape's alone.
CHROME_PROBE_FRAME = _CENSUS_BY_LABEL["system/status handshake"]

# The frame that ends a turn without touching either counter. A plain
# `result/plain` would settle the turn but also count itself (`terminal_message
# is not None` is one of the six shapes), which would make every zero-content
# assertion below meaningless — the turn would always look non-empty. The CLI
# really does replay `compact_result` as a system frame: it is one of the
# subtypes `_is_wire_chrome` names in its own docstring ("status probing
# frames, hook narration, compact_result, compact_boundary"), so this is a real
# shape, not a fixture. It is chrome (a `SystemMessage`) AND a terminal
# (`is_result_message` matches on the subtype), which is exactly the pair needed:
# `drive_turn` breaks the consume loop on it and `consumed_frames` skips it.
CHROME_SETTLE_FRAME = {
    "type": "system",
    "subtype": "compact_result",
    "compactMetadata": {"trigger": "manual"},
}

# Ceiling for the whole case. Every wait below has its own shorter budget and
# reports its own diagnostic; this is the backstop that turns "hung forever"
# into a named failure instead of a stalled run.
CASE_TIMEOUT_SECONDS = 30.0


async def _reach(label: str, predicate: Any, timeout: float = 5.0) -> None:
    """Poll until `predicate` holds; a condition that never holds is an assert.

    The previous version of this test used a bare `asyncio.timeout(...)` wait.
    When the condition never became true the `TimeoutError` unwound the whole
    `asyncio.run` — and because the runtime's teardown cancels its own tasks on
    the way out, the failure surfaced as a `CancelledError` from somewhere else
    entirely, pointing at the teardown instead of at the wait. So: poll to a
    deadline, then raise `AssertionError` with the label and the budget. A
    cancellation raised at THIS point still propagates (it means something
    outside cancelled us, which `_run_case` converts), but nothing here can
    manufacture one.
    """

    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        if predicate():
            return
        if loop.time() >= deadline:
            raise AssertionError(
                f"{label}: the expected state never arrived within {timeout}s"
            )
        await asyncio.sleep(0.005)


def _record_selected_responses(monkeypatch: pytest.MonkeyPatch) -> list[Any]:
    """Record every `ClaudeResponse` the reader selects, without altering one.

    A passively-read spy, needed because the casting frame must be *observed*
    rather than raced: a corpus shape that is itself a terminal (`result/plain`)
    casts a turn and settles it inside the reader's first scheduling slice, so
    polling `session.execution` either sees that turn or misses it forever. The
    reader's mint branch always calls `select_response`, so recording the
    responses and reading `response.execution` afterwards is deterministic and
    adds no behaviour of its own — the wrapper only delegates.
    """

    selected: list[Any] = []
    original = claude_connection.ClaudeConnection.select_response

    async def recording(self: Any, response: Any) -> None:
        selected.append(response)
        await original(self, response)

    monkeypatch.setattr(
        claude_connection.ClaudeConnection, "select_response", recording
    )
    return selected


def _run_case(label: str, body: Any) -> None:
    """Run one case under a hard cap, naming whatever ends it.

    Every failure mode of this test is allowed to fail loudly: a timeout, a
    cancellation from the runtime's teardown, an assertion. None of them may
    leave the runner with a silently-cancelled `asyncio.run`.
    """

    async def guarded() -> None:
        task = asyncio.ensure_future(body())
        try:
            await asyncio.wait_for(asyncio.shield(task), CASE_TIMEOUT_SECONDS)
        except (TimeoutError, asyncio.CancelledError) as exc:
            task.cancel()
            with contextlib.suppress(BaseException):
                await asyncio.wait_for(task, 2.0)
            raise AssertionError(
                f"{label}: the case did not finish inside "
                f"{CASE_TIMEOUT_SECONDS}s ({exc!r})"
            ) from exc

    asyncio.run(guarded())


@pytest.mark.parametrize(
    ("label", "payload", "provenance", "census_consumes"),
    _CENSUS_CORPUS,
    ids=[row[0] for row in _CENSUS_CORPUS],
)
def test_content_gate_counts_every_shape_that_projects_something(
    label: str,
    payload: dict[str, Any],
    provenance: str,
    census_consumes: bool,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Projecting a timeline item ⇒ the gate says this turn has content.

    One real scheduled turn per position, per shape, over the SDK's own
    `parse_message`. Phase 1 puts the shape FIRST — where the reader either
    mints the turn on it (it is then `ClaudeResponse.cast_frame`) or parks it
    in the preamble, and either way it is passive context; phase 2 puts the
    same payload one frame after a cast, where it is this turn's labour. The
    two phases differ by exactly one queue position, which is the whole content
    gate.
    """

    selected = _record_selected_responses(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("cover", None, "hello")
            session = await _settled_session(runtime, "cover")

            # ---------------- Phase 1: at or before the cast -------------
            base = len(host.timeline_item_upserts)
            # The human turn above was selected through the same reader, so the
            # spy is marked here: only the turns minted by THIS phase's frames
            # are the ones whose counters mean anything here.
            mark = len(selected)
            await client.incoming.put(_with_session(payload, client.native_id))
            await client.incoming.put(
                _with_session(GHOST_MINT_FRAME, client.native_id)
            )
            await client.incoming.put(
                _with_session(CHROME_PROBE_FRAME, client.native_id)
            )
            await client.incoming.put(
                _with_session(CHROME_SETTLE_FRAME, client.native_id)
            )
            await _reach(
                f"{label}/cast-settled",
                lambda: session.execution is None
                and client.incoming.qsize() == 0,
            )
            casting_turns = [
                response.execution
                for response in selected[mark:]
                if response.execution is not None
            ]
            assert casting_turns, (
                f"{label}: nothing minted at all — the reader never reached "
                "the mint branch"
            )
            # Carried into the arm-C messages below: when this is non-zero the
            # assertions that follow are not vacuous — a real timeline item
            # reached the client and the gate still has to call the turn empty.
            projected_while_casting = len(host.timeline_item_upserts) - base
            for turn in casting_turns:
                # Arm C. This is deliberately about the CASTERS, not about the
                # ghost shape: several shapes above publish a real timeline
                # item when they cast, and that item is still not evidence that
                # the turn did work (B5). A gate that counted it would park
                # every re-cast residue on the contenting floor.
                assert turn.published_items == 0, (
                    f"{label}: the casting frame projected "
                    f"{projected_while_casting} item(s) and booked "
                    f"{turn.published_items} of them as labour"
                )
                assert turn.consumed_frames == 0, (
                    f"{label}: the casting frame was booked as "
                    f"{turn.consumed_frames} consumed frame(s)"
                )
                assert turn.has_turn_content is False, (
                    f"{label}: the casting frame was exempted from the fast kill"
                )

            # ---------------- Phase 2: the same shape, one later ----------
            base = len(host.timeline_item_upserts)
            await client.incoming.put(
                _with_session(GHOST_MINT_FRAME, client.native_id)
            )
            await _reach(f"{label}/mint", lambda: session.execution is not None)
            execution = session.execution
            assert execution is not None
            assert selected[-1].cast_frame is not None, (
                f"{label}: the turn was not cast by the reader's mint branch"
            )
            await client.incoming.put(
                _with_session(CHROME_PROBE_FRAME, client.native_id)
            )
            await client.incoming.put(_with_session(payload, client.native_id))
            await client.incoming.put(
                _with_session(CHROME_SETTLE_FRAME, client.native_id)
            )
            await _reach(
                f"{label}/settled",
                lambda: session.execution is None
                and client.incoming.qsize() == 0,
            )

            projected = len(host.timeline_item_upserts) - base
            gate = execution.has_turn_content
            where = f"{label} ({provenance})"

            # Arm A — the forward property the source comments ask for. Purely
            # observational: "the user would have seen something" is read off
            # the host's upserts, never off the counter that is under test.
            if projected:
                # The gate is an OR, so the OR alone cannot tell the two
                # counters apart: flipping `counted=` off ONE publish path is
                # invisible whenever the same frame also matches a six-way
                # branch. `publish_items` states the stronger contract itself
                # ("Every publish point inside `drive_turn` goes through here so
                # `published_items` cannot drift from what the user actually
                # saw"), so post-cast the two must agree. `system/compact_boundary`
                # is the corpus's witness: its only evidence is the published
                # marker — `consumed_frames` stays 0 for it even now.
                assert execution.published_items >= projected, (
                    f"{where}: {projected} item(s) reached the client but "
                    f"published_items only counted "
                    f"{execution.published_items} — a publish path stopped "
                    "booking itself (consumed_frames="
                    f"{execution.consumed_frames})"
                )
                assert gate, (
                    f"{where}: drive_turn projected {projected} timeline item(s) "
                    "and the content gate still calls this turn empty — the "
                    "six-way consumed_frames test is missing a shape that "
                    "publishes (published_items="
                    f"{execution.published_items}, consumed_frames="
                    f"{execution.consumed_frames})"
                )
            elif census_consumes:
                # Arm A'. The census says this shape carries consumable work
                # mid-turn; if it ever stopped counting, the dropped-frame
                # turns (jmD_zip: 1613 thinking deltas, zero items published)
                # go straight back to being fast-killed at 30s.
                assert gate, (
                    f"{where}: the census records this shape as consumed "
                    "mid-turn and the live gate does not"
                )
            else:
                # Arm B — the mirror. Nothing was projected and the census says
                # this shape carries no consumable work, so the gate must still
                # call the turn empty. Without this arm, "count every post-cast
                # frame" passes arm A cleanly and buys every ghost ten minutes
                # of held execution lock.
                assert not gate, (
                    f"{where}: this shape projects nothing and the census "
                    "records nothing consumable in it, yet the turn was exempted "
                    f"(published_items={execution.published_items}, "
                    f"consumed_frames={execution.consumed_frames})"
                )

            # Arm A'' — the six-way test, one term at a time.
            #
            # Arms A and B read the gate as an OR, which is what the watchdog
            # reads; an OR cannot tell its two counters apart, and the two
            # overlap on most shapes: drop `bool(tool_items)`,
            # `bool(system_items)` or `has_visible_message` from the six-way
            # test and every corpus shape that matches those terms ALSO
            # publishes, so `published_items` covers the hole and the OR never
            # notices. That is not a cosmetic gap — it is the exact drift the
            # source comments warn about, one level down, and it is invisible
            # until a shape arrives that consumes without publishing.
            #
            # So the consumed counter is compared with the census's OWN frozen
            # model of that test, per shape. This is a golden cross-check, not
            # an observation: `b5-mint-census.py` re-derived the six terms
            # statically, in a different file, on a different day. Two
            # authorities that agree today are worth pinning precisely because
            # nothing would tell anyone when they stop.
            assert (execution.consumed_frames > 0) is census_consumes, (
                f"{where}: the six-way consumed_frames test "
                f"{'counted' if census_consumes else 'refused to count'} this "
                f"shape, and the census recorded "
                f"{'consumed' if census_consumes else 'nothing consumable'} "
                f"(published_items={execution.published_items}, "
                f"consumed_frames={execution.consumed_frames})"
            )
        finally:
            await runtime.stop()

    _run_case(label, run)
