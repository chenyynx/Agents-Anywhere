"""The limiter cell: a process death must reach the USER, not just the log.

Why this file exists
--------------------
`stuck_timeout_reports` gates the FAILED TURN on the client ledger. It has
nothing to do with whether the host CLI process is about to be killed — and
`retire_stuck_transport` kills it unconditionally once live background work
does not veto it. On 2026-10-03 13:49 the one firing that actually closed the
connection was a rate-limited repeat, so a killed process and every subagent in
it left exactly one artifact nobody was ever going to read:

    WARNING Claude repeat scheduled-timeout failure kept off the client ledger

An operator grepping finds that. The person whose turn just died does not. They
were told "Scheduled work did not report a result within 600 seconds" — a
sentence that reads as *the model was slow* — while the truth was *the process
was terminated and your background work ended with it*. So they rescue nothing
and retry nothing.

This file is the probe from
`.local-dev/recon/b5-final/findings.md` PREFIX#3, promoted to a permanent
regression suite. It pins the whole environment-difference matrix, because the
core claim is invariant-shaped, not trigger-shaped:

    a process death is disclosed whether or not any limiter is engaged.

`claude_process_retired` is therefore driven by the FACT that `close()`
happened. The three cells that could have gated it — the ledger limiter, the
`update_state` ownership check, and live background work — are each a row
below. The first two must still disclose; the third must NOT, because nothing
was killed there and a disclosure that fires when the process survived teaches
users to distrust it.

Every fixture is an SDK-parsed shape (`parse_message`), never a hand-built
lookalike — the F5 lesson the sibling files document.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from test_claude_background_guard import WIRE_TASK_STARTED
from test_claude_compact_ghost import (
    _await_retirement_disclosure,
    _parse,
    _retirement_disclosures,
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import _RecordingHost, _ScheduledClaudeClient
from test_claude_watchdog_longrun import (
    _budgets,
    _cast_with_labour,
    _settled_session,
)

from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.sdk import connection as claude_connection
from connector.runtimes.claude.sdk.connection import ClaudeResponse
from connector.runtimes.claude.turns import lifecycle


def _timeout_errors(host: _RecordingHost) -> list[dict[str, Any]]:
    """The pre-existing `claude_scheduled_turn_timeout` state updates."""
    return [
        update
        for update in host.session_state_updates
        if (update.get("error") or {}).get("code") == "claude_scheduled_turn_timeout"
    ]


def _only_disclosure(host: _RecordingHost) -> dict[str, Any]:
    """Assert there is exactly one and hand it back.

    "Exactly one" is the half of the contract that "at least one" cannot state:
    the limiter's job is to suppress repeats, and a disclosure that fires once
    per retirement is the same repeat-noise the ledger gate exists to prevent —
    except this one is deliberately NOT behind that gate, so the discipline has
    to live here instead.
    """
    disclosures = _retirement_disclosures(host)
    assert len(disclosures) == 1, disclosures
    return disclosures[0]


# --------------------------------------------------------------------------
# Row 1 — THE CORE CELL: limiter spent, disclosure still sent
# --------------------------------------------------------------------------


def test_process_retirement_is_disclosed_while_the_limiter_silences_the_ledger(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The 13:49 accident, in both halves at once.

    This is the assertion the whole change exists for. Gate the disclosure on
    `publish` and this goes red while every other test in the file stays green
    — the ledger half and the user half are independent, which is exactly the
    point of the split.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("limited", None, "hello")
            session = await _settled_session(runtime, "limited")
            connection = runtime._turns.runner.connections["limited"]
            # The window's single client-visible slot is already spent, so this
            # firing is the `publish=False` path.
            connection.stuck_timeout_reports = 1

            execution = await _cast_with_labour(client, session)
            # Waited on the DISCLOSURE, never on `client.disconnected`: the
            # client learns it is disconnected from its own reader task, which
            # resumes before the retirement's `close()` returns — so the
            # disconnection is a strictly weaker signal and waiting on it is a
            # coin flip for the assertion that follows.
            await _await_retirement_disclosure(host)
            assert client.disconnected is True
            disclosure = _only_disclosure(host)

            # --- ledger half: unchanged, still silenced -------------------
            assert not [
                end
                for end in host.session_turn_ends
                if end["turn_id"] == execution.turn_id
            ], "the rate-limited branch must still reach nothing on the ledger"
            assert connection.stuck_timeout_reports == 1

            # --- user half: the process death is now disclosed -----------
            assert disclosure["status"] == "error"
            assert disclosure["metadata"]["source"] == (
                lifecycle.CLAUDE_PROCESS_RETIRED_SOURCE
            )
            error = disclosure["error"]
            assert error["code"] == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            assert error["message"] == lifecycle.PROCESS_RETIRED_MESSAGE
            assert error["params"] == {
                "retirementConfirmed": True,
                "stuckSeconds": int(lifecycle.CONTENTING_TURN_WATCHDOG_SECONDS),
                "interruptedBackgroundTaskCount": 0,
            }

            # The old code still says what it always said. Splitting the two
            # is only a fix if it did not also overwrite the timeout path.
            assert len(_timeout_errors(host)) == 1, host.session_state_updates
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# Row 2 — limiter free: the original path must not regress or double-report
# --------------------------------------------------------------------------


def test_process_retirement_is_disclosed_once_when_the_limiter_is_free(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Limiter open, same process death, same disclosure — sent exactly once.

    Two ways to get this wrong and both are invisible in row 1: moving the
    disclosure inside a branch that only the limited path reaches, and
    publishing it per-something-else so a second retirement stacks a duplicate
    the user reads twice.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("open", None, "hello")
            session = await _settled_session(runtime, "open")
            connection = runtime._turns.runner.connections["open"]
            assert connection.stuck_timeout_reports == 0

            execution = await _cast_with_labour(client, session)
            await _await_retirement_disclosure(host)

            # The un-limited path still reaches the ledger...
            failed = [
                end
                for end in host.session_turn_ends
                if end["turn_id"] == execution.turn_id
                and end["outcome"] == "failed"
            ]
            assert len(failed) == 1, host.session_turn_ends
            assert connection.stuck_timeout_reports == 1

            # ...and the disclosure is byte-identical to the limited one. The
            # text a user reads must not depend on limiter state — that is what
            # "the limiter is a ledger concern" has to mean end to end.
            disclosure = _only_disclosure(host)
            assert disclosure["error"]["code"] == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            assert disclosure["error"]["message"] == lifecycle.PROCESS_RETIRED_MESSAGE
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# Row 3 — live background work vetoes the kill, so nothing is disclosed
# --------------------------------------------------------------------------


def test_live_background_work_vetoes_both_the_kill_and_the_disclosure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The do-not-retire invariant must stay silent too.

    This is the counterweight to rows 1 and 2. A disclosure tied to "the
    watchdog fired" rather than to "a process was killed" would fire here and
    tell the user their subagents died while they are demonstrably still
    running. One false retirement message costs more trust than the outage it
    was meant to explain.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("l1", None, "hello")
            session = await _settled_session(runtime, "l1")
            connection = runtime._turns.runner.connections["l1"]
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await _wait_until(lambda: bool(connection.background.active_ids))
            assert connection.has_live_background_work is True

            await _cast_with_labour(client, session)
            # `drop_current` is the last thing the veto branch does.
            await _wait_until(lambda: connection.current is None)

            assert client.disconnected is False, (
                "live background work rides this process; closing it would "
                "destroy work upstream cannot replay"
            )
            assert _retirement_disclosures(host) == [], (
                "no process was killed, so none may be disclosed"
            )
            # The timeout code is what this cell is left with, and it is enough:
            # the turn failed, the process survived, nothing else was lost.
            assert len(_timeout_errors(host)) == 1, host.session_state_updates
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# Rows 4-6 — driven straight at the runner
#
# These three are about branches the end-to-end fixtures above cannot reach
# without contrivance: a close that raises, an execution that never owned the
# session status, and background work that exists but does not veto. Calling
# `_scheduled_watchdog` with a hand-built execution is the established pattern
# here (test_claude_background_guard.py::test_limiter_is_atomic_across_
# _concurrent_watchdogs); the deadline, the limiter and the whole retirement
# path below it are the production ones either way.
# --------------------------------------------------------------------------


def test_close_failure_degrades_the_disclosure_instead_of_dropping_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`close()` raised → "not confirmed", still told, never silent.

    The tempting failure here is `except: logger.exception(...)` and stop —
    which is exactly what the code did before this change, and it leaves the
    worst case (a kill that may or may not have happened) as the one case the
    user is told nothing about. Downgraded is fine; silent is not.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("closefail", None, "hello")
            session = await _settled_session(runtime, "closefail")
            connection = runtime._turns.runner.connections["closefail"]
            runner = runtime._turns.runner

            # Only the retirement's close fails. Every later close (teardown)
            # runs normally, so the failure under test is the retirement and
            # nothing else.
            original = claude_connection.ClaudeConnection.close
            attempts: list[int] = []

            async def failing_close(self: Any) -> None:
                if not attempts:
                    attempts.append(1)
                    raise OSError("simulated shutdown failure")
                await original(self)

            monkeypatch.setattr(claude_connection.ClaudeConnection, "close", failing_close)

            execution = ClaudeExecution(turn_id="turn_closefail")
            session.execution = execution
            response = ClaudeResponse(connection)
            connection.current = response
            await runner._scheduled_watchdog(session, execution, response, 0.0)

            assert attempts == [1], "the retirement close is the one that failed"
            disclosure = _only_disclosure(host)
            error = disclosure["error"]
            assert error["code"] == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            assert error["message"] == lifecycle.PROCESS_RETIRED_UNCONFIRMED_MESSAGE
            assert error["message"] != lifecycle.PROCESS_RETIRED_MESSAGE, (
                "the unconfirmed copy must not claim a shutdown it could not see"
            )
            assert error["params"]["retirementConfirmed"] is False
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_queued_execution_still_reveals_the_retirement(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`update_state=False` is ownership, not permission to stay silent.

    A queued execution never owned the session status, so
    `publish_terminal_state` returns before writing any state at all — the
    `claude_scheduled_turn_timeout` error never reaches the user on this path.
    If the disclosure inherited that gate, this cell would be a process death
    with zero client-visible trace, i.e. the 13:49 accident wearing a different
    hat.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("queued", None, "hello")
            session = await _settled_session(runtime, "queued")
            connection = runtime._turns.runner.connections["queued"]
            runner = runtime._turns.runner

            execution = ClaudeExecution(turn_id="turn_queued")
            # The shape that matters: this execution is the QUEUED one.
            session.execution = ClaudeExecution(turn_id="turn_queued_next")
            session.queued_execution = execution
            response = ClaudeResponse(connection)
            connection.current = response

            await runner._scheduled_watchdog(session, execution, response, 0.0)

            assert _timeout_errors(host) == [], (
                "update_state=False means the timeout code never reached the user"
            )
            disclosure = _only_disclosure(host)
            assert disclosure["status"] == "error"
            assert disclosure["error"]["code"] == lifecycle.CLAUDE_PROCESS_RETIRED_CODE
            assert disclosure["error"]["params"]["retirementConfirmed"] is True
            assert disclosure["error"]["params"]["stuckSeconds"] == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_retirement_count_names_the_background_work_the_close_interrupted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The count is read from what the CLI last reported, and it is not invented.

    Background work that is still live vetoes the kill (row 3), so the honest
    non-zero case is a transport that already failed or was closing: the veto
    correctly stands down, and then the kill takes work with it. That is the
    cell where a user most needs to be told how much they lost, and it is the
    cell where a hardcoded `0` — which is what the pre-existing log line does,
    correctly, because the veto has already ruled — would be a lie.
    """

    _budgets(monkeypatch)

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("counted", None, "hello")
            session = await _settled_session(runtime, "counted")
            connection = runtime._turns.runner.connections["counted"]
            runner = runtime._turns.runner
            # A dead transport cannot protect its host process, so the veto
            # stands down even with work outstanding — and the outstanding work
            # is exactly what the close interrupts.
            connection.background.active_ids.update({"bg_a", "bg_b"})
            connection.failure = OSError("transport died under the work")
            assert connection.has_live_background_work is False

            execution = ClaudeExecution(turn_id="turn_counted")
            session.execution = execution
            response = ClaudeResponse(connection)
            connection.current = response
            await runner._scheduled_watchdog(session, execution, response, 0.0)

            params = _only_disclosure(host)["error"]["params"]
            assert params["interruptedBackgroundTaskCount"] == 2, params

            # Same shape, nothing outstanding: the count reads zero rather than
            # disappearing, so a client can interpolate it unconditionally.
            host.session_state_updates.clear()
            connection.background.active_ids.clear()
            connection.failure = None
            second = ClaudeExecution(turn_id="turn_counted_empty")
            session.execution = second
            await runner._scheduled_watchdog(
                session, second, ClaudeResponse(connection), 0.0
            )
            empty = _only_disclosure(host)["error"]["params"]
            assert empty["interruptedBackgroundTaskCount"] == 0, empty
            assert empty["retirementConfirmed"] is True, empty
        finally:
            await runtime.stop()

    asyncio.run(run())
