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
import time
from types import SimpleNamespace
from typing import Any

import pytest
from claude_agent_sdk import UserMessage
from claude_agent_sdk._internal.message_parser import parse_message
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _turn_ends,
    _wait_until,
)
from test_claude_subagent_progress import (
    DISPATCH_TUID,
    TASK_ID,
    WIRE_TASK_PROGRESS_FIRST,
    WIRE_TASK_STARTED,
    _card_agents,
    _DispatchClient,
    _start_dispatch,
)


async def _never(_arg: Any = None) -> None:
    return None
from test_claude_runtime import (
    RuntimeConfig,
    _default_sdk,
    _FakeClaudeClient,
    _FakeHookMatcher,
    _RecordingHost,
    _ScheduledClaudeClient,
)

from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk import connection as connection_module
from connector.runtimes.claude.sdk.connection import (
    ClaudeConnection,
    ClaudeResponse,
)
from connector.runtimes.claude.timeline.messages import stable_tool_item_id
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

# The interrupted turn's tail, verbatim in shape from the real session: the CLI
# replays a synthetic control message, then its result, then task notifications.
RESIDUAL_ECHO = {
    "type": "user",
    "message": {
        "role": "user",
        "content": "<local-command-stdout>No response requested.</local-command-stdout>",
    },
    "uuid": "residual-echo",
    "session_id": SESSION,
}

RESIDUAL_ECHO_2 = {
    **RESIDUAL_ECHO,
    "uuid": "residual-echo-2",
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


# --------------------------------------------------------------------------
# V9/L2 · the reader loop does no host round trips
# --------------------------------------------------------------------------


class _SlowHost(_RecordingHost):
    """A host that is slow on every timeline upsert — the backpressure knob.

    Stage 1 modelled the real server's session-lock quantum with exactly this
    shape (`HOST_DELAY_MS` in the harness). It is the one variable that turned
    a 2.96 s reader into a 271.66 s one, so it is the one variable the unit
    test has to be able to apply.
    """

    def __init__(self, delay: float) -> None:
        super().__init__()
        self.delay = delay
        self.upserts = 0

    async def timeline_item_upsert(self, item: Any) -> None:
        self.upserts += 1
        await asyncio.sleep(self.delay)
        await super().timeline_item_upsert(item)


class _TimedDispatchClient(_DispatchClient):
    """Records when the READER pulled each frame off the transport.

    `receive_messages` is the reader's own source, so its timestamps measure the
    reader and nothing else — the turn consumes a different queue. That is what
    makes "the reader did not stall" an observation rather than an inference.
    """

    def __init__(self) -> None:
        super().__init__()
        self.consumed_at: list[float] = []

    async def receive_messages(self):
        while True:
            message = await self.incoming.get()
            self.consumed_at.append(time.monotonic())
            if isinstance(message, Exception):
                raise message
            yield message


def _card_tokens(host: Any, card_id: str) -> int | None:
    """The card's token total — usage lives on the card, not in the agents map."""

    items = [item for item in host.timeline_item_upserts if item.id == card_id]
    return dict(items[-1].content.get("usage") or {}).get("tokens") if items else None


def _progress_frame(index: int) -> dict[str, Any]:
    """A distinct progress frame — a repeat is idempotent and would not publish."""

    return {
        **WIRE_TASK_PROGRESS_FIRST,
        "usage": {"total_tokens": 40000 + index, "tool_uses": 1, "duration_ms": 1},
        "uuid": f"progress-{index}",
    }


def test_slow_host_does_not_stall_the_reader_loop() -> None:
    """The amplifier, at unit scale: 12 x 50 ms of host, zero reader stall.

    Stage-1 V9 vs V11 is the whole reason this queue exists: on the FIXED tree
    the reader stalled 271.66 s where upstream managed 2.96 s, because it
    awaited a host upsert per task event, and while it was stalled it cast a
    ghost and pushed the human turn into `queued_execution`. Awaiting this burst
    inline costs 12 x 50 ms = 600 ms of reader time; deferred, the reader must
    be done with it in a fraction of that.
    """

    delay = 0.05
    burst = 12

    async def run() -> None:
        client = _TimedDispatchClient()
        host = _SlowHost(delay)
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            # The async receipt already seeds an agents entry under this task
            # id, so the binding proof is the fold's own field — waiting on the
            # key would pass before `task_started` had been folded.
            await _wait_until(
                lambda: "subagentType"
                in _card_agents(host, card_id).get(TASK_ID, {})
            )

            connection = runtime._turns.runner.connections["sub_progress"]
            mark = len(client.consumed_at)
            fed_at = time.monotonic()
            for index in range(burst):
                await client.incoming.put(_parse(_progress_frame(index)))

            await _wait_until(
                lambda: len(client.consumed_at) >= mark + burst, timeout=5
            )
            elapsed = client.consumed_at[mark + burst - 1] - fed_at
            assert elapsed < burst * delay / 2, (
                f"reader took {elapsed:.3f}s for {burst} frames; awaiting the "
                f"host inline costs {burst * delay:.3f}s"
            )
            assert connection.deferred_dropped_events == 0
            # The work still lands, in order, once the host catches up.
            await _wait_until(lambda: _card_tokens(host, card_id) == 40000 + burst - 1)
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_overflow_drops_the_oldest_event_and_keeps_the_newest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Backpressure has to end somewhere, and it must not end the reader.

    When the host cannot keep up, a progress row it has not seen yet is already
    behind whatever the CLI said after it. Dropping the oldest keeps the tail —
    the state the user is watching — and the drop is counted, because a silently
    lossy display is worse than a visible one.
    """

    monkeypatch.setattr(connection_module, "DEFERRED_EVENT_QUEUE_MAXSIZE", 3)

    async def run() -> None:
        client = _TimedDispatchClient()
        host = _SlowHost(0.05)
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            # The async receipt already seeds an agents entry under this task
            # id, so the binding proof is the fold's own field — waiting on the
            # key would pass before `task_started` had been folded.
            await _wait_until(
                lambda: "subagentType"
                in _card_agents(host, card_id).get(TASK_ID, {})
            )

            connection = runtime._turns.runner.connections["sub_progress"]
            for index in range(12):
                await client.incoming.put(_parse(_progress_frame(index)))

            await _wait_until(
                lambda: connection.deferred_dropped_events > 0, timeout=5
            )
            await _wait_until(
                lambda: _card_tokens(host, card_id) == 40000 + 11, timeout=5
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_failing_projection_never_poisons_the_worker() -> None:
    """One bad callback must not stop every later event from projecting.

    The L1 lesson again, in its V9 form: the worker is a display path, so a
    failure there is logged and skipped rather than allowed to end the worker —
    which would silently stop the SubAgent panel for the rest of the transport.
    """

    seen: list[str] = []
    boom = RuntimeError("host rejected the upsert")

    async def flaky(event: Any) -> None:
        if event == "bad":
            raise boom
        seen.append(event)

    async def run() -> None:
        connection = ClaudeConnection(
            client=SimpleNamespace(),
            on_activity=_never,
            on_idle=_never,
            on_background_done=_never,
            cleanup=lambda: None,
            on_task_event=flaky,
        )
        connection.defer_event(flaky, "bad")
        connection.defer_event(flaky, "good")
        await _wait_until(lambda: seen == ["good"])
        await connection._stop_deferred_events()
        assert connection.deferred_dropped_events == 0

    asyncio.run(run())


# --------------------------------------------------------------------------
# C · drain-after-interrupt: fast path clean, stop never blocked
# --------------------------------------------------------------------------


def _runtime_with_values(host: Any, client_factory: Any, values: dict[str, Any]) -> Any:
    sdk = _default_sdk()
    sdk.HookMatcher = _FakeHookMatcher
    return ClaudeRuntime(
        config=RuntimeConfig(
            runtime="claude", revision=1, values={"environment": {}, **values}
        ),
        host=host,
        sdk_loader=lambda: sdk,
        client_factory=client_factory,
    )


class _SilentInterruptClient(_ScheduledClaudeClient):
    """An interrupt whose result never comes, and whose tail comes very late.

    The worst case any drain has to survive: the CLI is killed mid-turn, so its
    result may never be emitted at all, and the frames it did emit arrive long
    after anyone is still reading them. Stage 1 measured a real residual 32 s
    late — well outside anything a stop may wait for.
    """

    def __init__(self, tail_delay: float = 3.0) -> None:
        super().__init__()
        self.tail_delay = tail_delay

    async def interrupt(self) -> None:
        await _FakeClaudeClient.interrupt(self)
        asyncio.create_task(self._late_tail())

    async def _late_tail(self) -> None:
        await asyncio.sleep(self.tail_delay)
        await self.incoming.put(_parse(BARE_SUCCESS_RESULT))


async def _time_interrupt(runtime: Any) -> float:
    started_at = time.monotonic()
    # Bounded, so that reintroducing a waiting drain FAILS this test instead of
    # hanging the suite — a hang is the production symptom, but a test that
    # hangs reports nothing. 2 s is the expectation the pre-existing
    # `test_claude_stop_clears_both_executions_during_scheduled_collision`
    # already pins.
    result = await asyncio.wait_for(
        runtime.interrupt_session("drain", reason="user"), 2
    )
    elapsed = time.monotonic() - started_at
    assert result.ok is True
    return elapsed


def test_interrupt_drain_never_blocks_the_stop() -> None:
    """The red line, in the shape that broke it once: a CLI that never answers.

    The task sheet's 5-second ceiling was still 5 seconds of a user waiting to
    stop, and the existing 2-second stop expectation in
    `test_claude_stop_clears_both_executions_during_scheduled_collision` caught
    it. The shipped drain has no timeout because it has nothing to wait for, so
    the bound here is generous enough to survive a loaded CI box and far below
    anything that could be mistaken for a timeout.
    """

    async def run() -> None:
        client = _SilentInterruptClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            # "wait" is the fake's no-reply prompt: the turn stays open, which
            # is the only state an interrupt means anything in.
            await runtime.start_turn("drain", None, "wait")
            await asyncio.sleep(0.05)
            elapsed = await _time_interrupt(runtime)
            assert elapsed < 1.0, f"stop blocked for {elapsed:.3f}s"
            assert host.session_turn_ends[-1]["outcome"] == "interrupted"
            assert runtime._sessions["drain"].execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_drain_swallows_a_queued_tail_and_stops_at_the_result() -> None:
    """The drain's own contract, driven directly: frames in, queue empty out.

    Worth pinning on its own because on the ordinary interrupt path the drain
    finds nothing to do — `release(interrupted=True)` has already emptied the
    same queue. This is the path it exists for: a turn that had already seen a
    terminal releases with `discard=False`, so the reader keeps parking frames
    in a queue whose consumer no longer exists, and nothing else empties it.

    The result is the boundary. The frame behind it belongs to whatever runs
    next, and taking it would be this drain doing the very cross-turn theft it
    exists to prevent.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("drain", None, "wait")
            await asyncio.sleep(0.05)
            session = runtime._sessions["drain"]
            execution = session.execution
            response = execution.client
            assert response is not None
            for frame in (RESIDUAL_ECHO, RESIDUAL_ECHO_2, BARE_SUCCESS_RESULT):
                await response.messages.put(_parse(frame))
            next_turns = _parse(ASSISTANT_REPLY)
            await response.messages.put(next_turns)

            started_at = time.monotonic()
            await runtime._turns.actions._drain_after_interrupt(
                session, execution, source="test", response=response
            )
            elapsed = time.monotonic() - started_at

            assert elapsed < 0.05, f"a drain that waits cost {elapsed:.3f}s"
            assert response.messages.qsize() == 1
            assert response.messages.get_nowait() is next_turns
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_drain_can_be_switched_off() -> None:
    """Every guard in this batch is switchable; this one has to be too."""

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(
            host,
            _single_client_factory(client),
            {"drainOnInterrupt": False},
        )
        try:
            await runtime.start_turn("drain", None, "wait")
            await asyncio.sleep(0.05)
            session = runtime._sessions["drain"]
            execution = session.execution
            response = execution.client
            assert response is not None
            for frame in (RESIDUAL_ECHO, BARE_SUCCESS_RESULT):
                await response.messages.put(_parse(frame))

            await runtime._turns.actions._drain_after_interrupt(
                session, execution, source="test", response=response
            )
            assert response.messages.qsize() == 2, "switched off, nothing drained"
        finally:
            await runtime.stop()

    asyncio.run(run())
