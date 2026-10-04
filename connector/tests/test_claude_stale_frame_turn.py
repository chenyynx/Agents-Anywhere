"""Stale frames must never mint or settle a turn they cannot own (2026-10-04).

Why this file exists
--------------------
Real session ``sess_tPcEDi0z9xJYxQ``, 2026-10-04 12:18-12:24. pp interrupted a
turn; the CLI's tail frames ("No response requested." + a result + task
notifications) came out ~32 s later, into the session-scoped stream that no
turn was holding any more. pp sent a new message 47 s after the stop. The new
turn consumed the *previous* turn's result as its own and reported ``completed``
at 12:23:12 — while its own model request was still running (the client then
showed an idle session with no reply, so pp sent the message again).

Stage-1 differential work (``.local-dev/recon/stale-frame/findings.md``)
reproduced the mechanism on real CLI 2.1.285: a terminal frame that reaches the
reader while ``current is None`` is cast into a scheduled turn, which then
settles ``completed`` on it — 3/3 on the upstream tree, including one hit where
the phantom ``completed`` landed 0.27 s *before* the turn's own request was even
sent. Our L1 chrome gate caught only the one shape that happened to carry
``origin.kind == "task-notification"``; a bare ``ResultMessage(success)`` with
no origin still minted. That shape was never built, so it was only ever a
code-level claim — this file is where it finally gets executed.

Two entry points, one invariant — a terminal frame settles exactly one turn,
the one that can prove it started it:

* **I1** (`sdk/connection.py`): at silence, a ``completed`` frame is absorbed.
  It never mints, and it never becomes the pending turn's "first frame".
  Absorbed frames are NOT parked as preamble: preamble is flushed into
  whichever response is selected next, which would smuggle the result back in
  as that turn's terminal — the same ghost, through the back door.
* **B** (`turns/lifecycle.py`): in-turn, a terminal frame that arrives before
  the turn has shown a start it owns is deferred rather than settling the turn.

Every fixture is a REAL SDK message shape parsed through ``parse_message`` —
the lesson the /compact ghost file documents (hand-built lookalikes produced a
P0 there).
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from claude_agent_sdk import UserMessage
from claude_agent_sdk._internal.message_parser import parse_message
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _turn_ends,
)
from test_claude_runtime import _RecordingHost, _ScheduledClaudeClient

from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.sdk.connection import ClaudeResponse
from connector.runtimes.claude.turns import lifecycle

SESSION = "b5a5f0a4-2c17-4f8e-9a6b-1d0e7c4b9a21"

# A bare success result: no `origin`, nothing for the chrome predicate to
# recognize. This is the shape stage 1 could not build on the real CLI (2.1.285
# emits no frames for an idle control request) and could therefore only judge by
# reading the code. It is exactly the shape our L1 gate does not cover.
BARE_SUCCESS_RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "num_turns": 1,
    "session_id": SESSION,
    "result": "",
    "duration_ms": 12,
    "duration_api_ms": 10,
    "total_cost_usd": 0.0,
}

# The same result with an error: the one terminal status the reader must keep
# routing to the pending prompt, because a queued prompt that failed has to stay
# visible to the client (red line in claude-stale-frame-turn-tasks.md §4).
FAILED_RESULT = {
    **BARE_SUCCESS_RESULT,
    "subtype": "error_during_execution",
    "is_error": True,
    "error": "prompt rejected",
}

ASSISTANT_REPLY = {
    "type": "assistant",
    "message": {
        "role": "assistant",
        "model": "claude-opus-5",
        "content": [{"type": "text", "text": "the second answer"}],
    },
    "uuid": "assistant-second",
    "session_id": SESSION,
}


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


@pytest.fixture(autouse=True)
def _short_breaker_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    """Compress the product budgets so a minted ghost is observable fast.

    The deadlines are the contract's magnitude, not its content; nothing below
    depends on the numbers, so shrinking them keeps the file quick without
    inventing a second code path.
    """

    monkeypatch.setattr(lifecycle, "POLLED_TURN_WATCHDOG_SECONDS", 0.2)
    monkeypatch.setattr(lifecycle, "CONTENTING_TURN_WATCHDOG_SECONDS", 0.4)


# --------------------------------------------------------------------------
# I1 · a terminal frame at silence never mints a turn
# --------------------------------------------------------------------------


def test_bare_result_at_silence_mints_no_turn() -> None:
    """修前红 / 修后绿: the residual result is absorbed, not cast into a turn.

    Before the guard this frame fell through to the mint branch and became a
    scheduled turn that reported ``completed`` to the client — the 12:23 ghost,
    and the shape stage 1 could only judge by reading code (findings §2.3).
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("stale", None, "hello")
            session = runtime._sessions["stale"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.execution is None
            assert len(host.session_turn_ends) == 1

            connection = runtime._turns.runner.connections["stale"]
            assert connection.current is None
            assert connection.absorbed_terminal_frames == 0

            # The interrupted turn's tail arrives with nobody holding the stream.
            await client.incoming.put(_parse(BARE_SUCCESS_RESULT))
            await asyncio.sleep(0.05)

            assert session.execution is None, "a result must not mint a turn"
            assert session.queued_execution is None
            assert len(host.session_turn_ends) == 1, "no phantom completed"
            assert connection.absorbed_terminal_frames == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_absorbed_result_is_not_parked_as_preamble() -> None:
    """The back door: preamble is flushed into the NEXT response's queue.

    Buffering the absorbed result would hand it to whatever turn is selected
    afterwards, where it is that turn's first frame — and therefore, under the
    old code, that turn's terminal. This pins that the absorb path `continue`s
    without touching `preamble`, by proving the next turn sees only its own
    frames.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("stale", None, "hello")
            session = runtime._sessions["stale"]
            await asyncio.wait_for(session.active_task, 5)

            await client.incoming.put(_parse(BARE_SUCCESS_RESULT))
            await asyncio.sleep(0.05)

            # The next turn replies normally and settles on ITS OWN result.
            await runtime.start_turn("stale", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "completed"]
            assert session.execution is None
            assert runtime._turns.runner.foreign_terminal_frames == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# I1 · the pending-selection path, both directions
# --------------------------------------------------------------------------


class _ResidualFirstClient(_ScheduledClaudeClient):
    """A client whose previous turn's result is still on the wire at turn start.

    This is the reconnect/replay shape the real incident took (the transport was
    replaced at 12:22:54, so the session's frames were re-emitted into the new
    turn's queue). The residual lands before the new turn's prompt echo, so
    before the fix it became that turn's first frame and settled it `completed`
    with no reply at all.
    """

    def __init__(self, residual: dict[str, Any], *, from_query: int = 2) -> None:
        super().__init__()
        self.residual = residual
        self.from_query = from_query
        self.queries_seen = 0

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.queries_seen += 1
            if self.queries_seen >= self.from_query:
                # The previous turn's result is still on the wire when this
                # turn starts — before the prompt echo reaches the reader.
                await self.incoming.put(_parse(self.residual))
            await self.incoming.put(
                UserMessage(uuid=message["uuid"], content=content)
            )
        await self._complete_query(content)


def test_success_result_does_not_become_the_pending_turns_first_frame() -> None:
    """修前红 / 修后绿: the new turn answers, instead of completing on the old one."""

    async def run() -> None:
        client = _ResidualFirstClient(BARE_SUCCESS_RESULT, from_query=2)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("pending", None, "hello")
            session = runtime._sessions["pending"]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["pending"]

            await runtime.start_turn("pending", None, "second")
            await asyncio.wait_for(session.active_task, 5)

            assert [end["outcome"] for end in host.session_turn_ends] == [
                "completed",
                "completed",
            ]
            # The reply the user actually asked for reached the timeline.
            texts = [
                str(item.content.get("text", ""))
                for item in host.timeline_item_upserts
            ]
            assert "reply:second" in texts
            assert connection.absorbed_terminal_frames == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_failed_result_still_reaches_the_pending_turn() -> None:
    """The red line: a queued prompt's failure must stay visible.

    Narrowing the guard to `completed` is deliberate; this pins the other half
    so a future "simplification" cannot swallow it.
    """

    async def run() -> None:
        client = _ResidualFirstClient(FAILED_RESULT, from_query=2)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("queued", None, "hello")
            session = runtime._sessions["queued"]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["queued"]

            await runtime.start_turn("queued", None, "second")
            await asyncio.wait_for(session.active_task, 5)

            ends = host.session_turn_ends
            assert ends[-1]["outcome"] == "failed"
            assert host.session_state_updates[-1]["status"] == "error"
            assert (
                host.session_state_updates[-1]["error"]["code"]
                == "claude_result_error"
            )
            assert connection.absorbed_terminal_frames == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_pending_without_a_wire_uuid_still_takes_a_result() -> None:
    """A prompt submitted on a transport's first turn has no uuid to pair with.

    Nothing can be a residual of a turn this transport never ran, so the
    status quo is kept there: the result selects the pending and the turn ends.
    This is what keeps approval round-trips and empty replies working.
    """

    async def run() -> None:
        client = _ResidualFirstClient(BARE_SUCCESS_RESULT, from_query=1)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("first", None, "hello")
            session = runtime._sessions["first"]
            await asyncio.wait_for(session.active_task, 5)

            connection = runtime._turns.runner.connections["first"]
            assert connection.absorbed_terminal_frames == 0
            assert [end["outcome"] for end in host.session_turn_ends] == [
                "completed"
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# B · in-turn start gate: only a terminal this turn can own counts as its work
# --------------------------------------------------------------------------


class _ResidualAfterEchoClient(_ScheduledClaudeClient):
    """The reconnect shape: the old result lands while the NEW turn is live.

    The prompt echo reaches the reader first, so the turn owns the stream from
    that frame on — and the previous turn's result arrives right behind it,
    inside the queue the new turn is already draining. This is the in-turn
    sibling of the mint path I1 closes, and the shape findings §4 H-a names as
    the excluded candidate: the `break` in `turns/lifecycle.py` settles the turn
    on whatever result it reads first.
    """

    def __init__(self, residual: dict[str, Any], *, from_query: int = 2) -> None:
        super().__init__()
        self.residual = residual
        self.from_query = from_query
        self.queries_seen = 0

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.queries_seen += 1
            await self.incoming.put(
                UserMessage(uuid=message["uuid"], content=content)
            )
            if self.queries_seen >= self.from_query:
                await self.incoming.put(_parse(self.residual))
        await self._complete_query(content)


def test_unowned_in_turn_terminal_is_counted_for_the_observation_window() -> None:
    """The residue B exists to make visible: counted, named, not credited.

    修前红 / 修后绿 on the counter itself: with the gate removed this stays 0 and
    the occurrence is invisible in production, which is the whole reason the
    in-turn case was left measurable rather than silently tolerated.

    The turn still settles on the frame — see the gate's note in
    `drive_turn`: a leftover result and an empty reply are the same shape by the
    time they reach a turn, so refusing to settle it would hang real replies.
    I1 closes the entry point that stage 1 actually reproduced.
    """

    async def run() -> None:
        client = _ResidualAfterEchoClient(BARE_SUCCESS_RESULT)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("inturn", None, "hello")
            session = runtime._sessions["inturn"]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            assert runner.foreign_terminal_frames == 0

            await runtime.start_turn("inturn", None, "second")
            await asyncio.wait_for(session.active_task, 5)

            assert [end["outcome"] for end in host.session_turn_ends] == [
                "completed",
                "completed",
            ]
            assert runner.foreign_terminal_frames == 1
            # `session.execution` is deliberately NOT asserted empty here: the
            # frames the premature settle orphaned (this turn's own reply and
            # result) reach the reader at silence afterwards, and an assistant
            # frame at silence is the legitimate scheduled-wakeup mint. That
            # tail is another reason the entry point (I1) is where the fix
            # belongs, not the settle side.
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_terminal_at_the_cast_position_does_not_settle_the_turn() -> None:
    """The B1 position rule, promoted to settlement: the cast cannot complete.

    Whichever frame cast this turn out of silence is passive arrival — the turn
    neither produced it nor chose it. If it were ever a terminal again (I1 makes
    that impossible at the reader, so this is the second line), it must not
    become the turn's verdict.

    Driven in-process because the reader can no longer produce the shape: the
    response is handed `cast_frame` directly and then fed frames by hand.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("cast", None, "hello")
            session = runtime._sessions["cast"]
            await asyncio.wait_for(session.active_task, 5)

            connection = runtime._turns.runner.connections["cast"]
            cast_frame = _parse(BARE_SUCCESS_RESULT)
            response = ClaudeResponse(connection, cast_frame=cast_frame)
            execution = ClaudeExecution(turn_id="turn_claude_cast_probe")
            session.execution = execution
            task = asyncio.create_task(
                runtime._turns.runner.drive_turn(
                    session,
                    execution,
                    "",
                    (),
                    None,
                    scheduled=True,
                    response=response,
                )
            )
            await response.messages.put(cast_frame)
            await asyncio.wait_for(task, 5)

            ends = _turn_ends(host, execution.turn_id)
            assert ends[-1]["outcome"] != "completed"
            assert ends[-1]["metadata"]["terminalReason"] == (
                "stream_exhausted"
            )
            assert (
                runtime._turns.runner.foreign_terminal_frames == 0
            ), "the cast frame is skipped by position, not counted as foreign"
            assert execution.consumed_frames == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


class _ResultOnlyClient(_ScheduledClaudeClient):
    """An empty reply: the turn's whole stream is its single result.

    R1's false-kill risk in its purest form. The gate must count this turn as
    having met an unowned terminal and must still report exactly what it
    reported before the gate existed.
    """

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for _message in prompt:
            pass
        await self.incoming.put(_parse(BARE_SUCCESS_RESULT))


def test_empty_reply_turn_is_not_killed_by_the_start_gate() -> None:
    """R1: a turn whose only frame is its result still completes, not fails."""

    async def run() -> None:
        client = _ResultOnlyClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("empty", None, "hello")
            session = runtime._sessions["empty"]
            await asyncio.wait_for(session.active_task, 5)

            assert [end["outcome"] for end in host.session_turn_ends] == [
                "completed"
            ]
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
            assert runtime._turns.runner.foreign_terminal_frames == 1
        finally:
            await runtime.stop()

    asyncio.run(run())
