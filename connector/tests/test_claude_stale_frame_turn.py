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
from test_claude_background_guard import WIRE_DANGER_ASSISTANT_THINKING
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _turn_ends,
    _wait_until,
)
from test_claude_subagent_progress import (
    DISPATCH_TUID,
    TASK_ID,
    WIRE_DISPATCH_RECEIPT,
    WIRE_DISPATCH_TOOL_USE,
    WIRE_MAIN_RESULT,
    WIRE_TASK_PROGRESS_FIRST,
    WIRE_TASK_STARTED,
    WIRE_TASK_UPDATED,
    _card_agents,
    _card_items,
    _DispatchClient,
    _start_dispatch,
)


async def _never(_arg: Any = None) -> None:
    return None
from test_claude_runtime import (
    RuntimeConfig,
    StreamEvent,
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
from connector.runtimes.claude.sdk.tasks import task_event_from_message
from connector.runtimes.claude.timeline.messages import stable_tool_item_id
from connector.runtimes.claude.turns import lifecycle
from connector.runtimes.claude.turns.lifecycle import STALE_COMPLETION_REASON

SESSION = "b5a5f0a4-2c17-4f8e-9a6b-1d0e7c4b9a21"

# The decorative stream: parented subagent frames that reach silence. Used
# as the FLOOD in F2 — it is what an unbounded share of one FIFO lets evict
# state.
WIRE_SUBAGENT_THINKING = WIRE_DANGER_ASSISTANT_THINKING

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
            assert connection.absorbed_terminal_frames == 0, "selected, not absorbed"
            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted"
            ]
            assert host.session_turn_ends[-1]["metadata"]["terminalReason"] == (
                STALE_COMPLETION_REASON
            )
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


def test_in_turn_residual_never_reports_a_plain_completed() -> None:
    """F1, the blocking half: the residual cannot pass itself off as success.

    修前红: the turn settled `completed` with no `terminalReason`, the client's
    reply never arrived, and the user was left looking at an idle session with
    an empty composer — the P1 report verbatim. I1 does not help here: this
    frame was already inside a LIVE turn, so the mint path never runs.

    The turn cannot simply refuse to settle (a leftover result and an empty
    reply are the same shape by the time they reach a turn, and refusing hangs
    real replies). So it settles honestly instead: `interrupted`, carrying the
    structured reason that names the condition, on a counter that is zero in
    normal operation.
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
            assert runner.stale_completion_downgrades == 0

            await runtime.start_turn("inturn", None, "second")
            await asyncio.wait_for(session.active_task, 5)

            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "interrupted"]
            assert ends[-1]["metadata"]["terminalReason"] == STALE_COMPLETION_REASON
            assert runner.stale_completion_downgrades == 1
            assert runner.foreign_terminal_frames == 1
            # The turn's own frames never reached the timeline, which is the
            # point: the user is told "this round produced nothing" instead of
            # being told it succeeded and then waiting for a reply that the
            # swallowed frame displaced.
            texts = [
                str(item.content.get("text", ""))
                for item in host.timeline_item_upserts
            ]
            assert "reply:second" not in texts
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_turn_with_content_still_reports_its_own_result() -> None:
    """The other half of F1, and the one that must not rot: real work, real verdict.

    F1 degrades a `completed` only when the turn produced nothing. A turn that
    actually did something keeps its verdict even if the frame it settled on was
    the one it cannot prove — downgrading there would throw away a real answer
    to fix a problem the answer does not have.
    """

    async def run() -> None:
        client = _ResidualAfterEchoClient(BARE_SUCCESS_RESULT)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("worked", None, "hello")
            session = runtime._sessions["worked"]
            await asyncio.wait_for(session.active_task, 5)

            # A client whose reply arrives BEFORE the leftover result, so the
            # turn has content by the time it settles.
            class _WorkThenResidualClient(_ScheduledClaudeClient):
                async def query(self, prompt: Any) -> None:
                    if isinstance(prompt, str):
                        await super().query(prompt)
                        return
                    async for message in prompt:
                        content = message["message"]["content"]
                        await self.incoming.put(
                            UserMessage(uuid=message["uuid"], content=content)
                        )
                        await self.incoming.put(_parse(ASSISTANT_REPLY))
                    await self.incoming.put(_parse(BARE_SUCCESS_RESULT))

            worked = _WorkThenResidualClient()
            host2 = _RecordingHost()
            runtime2 = _runtime_with(host2, _single_client_factory(worked))
            try:
                await runtime2.start_turn("worked2", None, "hello")
                session2 = runtime2._sessions["worked2"]
                await asyncio.wait_for(session2.active_task, 5)
                assert [e["outcome"] for e in host2.session_turn_ends] == ["completed"]
                texts = [
                    str(item.content.get("text", ""))
                    for item in host2.timeline_item_upserts
                ]
                assert ASSISTANT_REPLY["message"]["content"][0]["text"] in texts
                assert runtime2._turns.runner.stale_completion_downgrades == 0
            finally:
                await runtime2.stop()
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


def test_empty_reply_turn_settles_as_produced_nothing_not_as_success() -> None:
    """F1's deliberate cost, pinned as the target semantics.

    A turn whose whole stream is its own result cannot be told apart from a
    leftover, so it is degraded too. What it must NOT be is reported as a
    success: "this round produced nothing" is what happened, it leaves the
    session idle and re-sendable, and it carries the reason. R1 still holds in
    the sense that matters — the turn settles promptly instead of hanging until
    a ceiling, and nothing is force-failed.
    """

    async def run() -> None:
        client = _ResultOnlyClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("empty", None, "hello")
            session = runtime._sessions["empty"]
            await asyncio.wait_for(session.active_task, 5)

            assert [end["outcome"] for end in host.session_turn_ends] == [
                "interrupted"
            ]
            assert host.session_turn_ends[-1]["metadata"]["terminalReason"] == (
                STALE_COMPLETION_REASON
            )
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


async def _dispatched_subagent() -> tuple[Any, Any, Any, str]:
    """A dispatched subagent: the Agent card exists, nothing has bound it yet.

    Deliberately does NOT send `task_started` — the binding is what these tests
    are about, so it has to arrive inside the burst under test. Feeding it in
    the setup would make the binding unfalsifiable: it would survive whatever
    the burst did to the queue.
    """

    client = _TimedDispatchClient()
    host = _SlowHost(0.05)
    runtime = _runtime_with_values(host, _single_client_factory(client), {})
    session = await _start_dispatch(runtime)
    card_id = stable_tool_item_id(session, DISPATCH_TUID)
    assert ("sub_progress", TASK_ID) not in runtime._turns.runner.agent_task_calls
    return runtime, client, host, card_id


def _task_burst() -> list[dict[str, Any]]:
    """A subagent's whole task stream: bind, a run of progress rows, close."""

    return [
        WIRE_TASK_STARTED,
        *[_progress_frame(i) for i in range(12)],
        WIRE_TASK_UPDATED,
    ]


def _defer_all(
    connection: Any,
    callback: Any,
    frames: list[dict[str, Any]],
    *,
    state_bearing: bool,
) -> None:
    for frame in frames:
        event = task_event_from_message(_parse(frame))
        if event is None:
            continue
        connection.defer_event(callback, event, state_bearing=state_bearing)


def _last_card_status(host: Any, card_id: str) -> str | None:
    items = _card_items(host, card_id)
    return items[-1].status if items else None


def test_state_queue_overflow_sheds_a_progress_row_not_the_binding(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F2: when the STATE queue overflows, a `task_progress` row pays first.

    修前红 on the deeper half: `task_started` is not protected merely by being
    early — it is protected by being evictable LAST. The bound here is 3 and
    the burst is fourteen task events, so progress rows must absorb the whole
    loss, and both the binding and the card closure must survive it. Evict by
    age instead (the pre-F2 rule) and the binding is the oldest thing in the
    queue: gone, and every later event for that subagent is unbound forever.

    Driven straight at the deferral point. The reader's own burst timing is a
    separate concern with its own test below; this one is about the policy.
    """

    monkeypatch.setattr(connection_module, "DEFERRED_TASK_QUEUE_MAXSIZE", 3)

    async def run() -> None:
        runtime, _client, host, card_id = await _dispatched_subagent()
        try:
            connection = runtime._turns.runner.connections["sub_progress"]
            _defer_all(
                connection,
                connection.on_task_event,
                _task_burst(),
                state_bearing=True,
            )

            await _wait_until(
                lambda: _last_card_status(host, card_id) == "done", timeout=5
            )
            assert connection.deferred_dropped_events > 0, "the burst overflowed"
            assert ("sub_progress", TASK_ID) in runtime._turns.runner.agent_task_calls
            # The whole loss fell on repeatable rows: no binding lost, no
            # closure lost.
            assert connection.deferred_dropped_state_events == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_decorative_burst_cannot_evict_the_task_binding(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """F2, the blocking half: decoration and state do not share a bound.

    修前红 (red team RT-4): one FIFO carried both callbacks, so a flood of
    parented subagent rows could evict the `task_started` that writes the
    task-to-card binding. With the binding gone, EVERY later task event for
    that subagent is unbound and returns immediately: the card stays `running`
    forever and P2-N1's "killed" fold is dead for that subagent too, because it
    reads the same table. A loss the pre-V9 inline `await` could not suffer.

    The decorative bound is 1 here and the whole task stream arrives alongside
    it, so under a shared queue the binding cannot survive; with the partition
    it does, and the card closes.
    """

    monkeypatch.setattr(connection_module, "DEFERRED_EVENT_QUEUE_MAXSIZE", 1)

    async def run() -> None:
        runtime, _client, host, card_id = await _dispatched_subagent()
        try:
            connection = runtime._turns.runner.connections["sub_progress"]
            decoration = [
                _parse({**WIRE_SUBAGENT_THINKING, "uuid": f"bg-{i}"})
                for i in range(10)
            ]
            for frame in decoration:
                connection.defer_event(connection.on_background_frame, frame)
            _defer_all(
                connection,
                connection.on_task_event,
                _task_burst(),
                state_bearing=True,
            )

            await _wait_until(
                lambda: _last_card_status(host, card_id) == "done", timeout=5
            )
            assert ("sub_progress", TASK_ID) in runtime._turns.runner.agent_task_calls
            # Decoration was shed; state was not touched at all.
            assert connection.deferred_dropped_events > 0
            assert connection.deferred_dropped_state_events == 0
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


# --------------------------------------------------------------------------
# P2-N1 · a stop says which subagents it killed, at the stop
# --------------------------------------------------------------------------


class _SubagentThenWaitClient(_DispatchClient):
    """Dispatches a background subagent, then leaves the turn running.

    The production shape: pp hits stop while a subagent is still working. The
    agent kept telling them it was "still running in the background" 20 s
    later, the client card took 4m41s to flip, and the CLI's own notification
    for the same events took 4m43s (real session sess_tPcEDi0z9xJYxQ,
    2026-10-04 12:18). Nothing was missing — the CLI reports every task it
    kills. It just reported it long after anyone was looking.
    """

    async def _complete_query(self, prompt: str) -> None:
        if prompt == "hello":
            # The dispatch turn settles normally; only the subagent is still
            # running when the user later hits stop on the NEXT turn.
            for frame in (
                WIRE_DISPATCH_TOOL_USE,
    WIRE_MAIN_RESULT,
                WIRE_DISPATCH_RECEIPT,
                WIRE_TASK_STARTED,
                WIRE_MAIN_RESULT,
            ):
                await self.incoming.put(_parse(frame))
            return
        await _FakeClaudeClient.query(self, prompt)


def test_stop_reports_the_subagents_it_killed_immediately() -> None:
    """T5: the card flips with the stop, not with the CLI's late notification.

    The bound is the point. The CLI's own `task_notification` for these tasks
    is never sent in this test, so anything that arrives is the connector
    reporting it itself — and it must arrive inside the stop call, not
    "eventually".
    """

    async def run() -> None:
        client = _SubagentThenWaitClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("sub_progress", None, "hello")
            session = runtime._sessions["sub_progress"]
            await asyncio.wait_for(session.active_task, 5)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await _wait_until(
                lambda: "subagentType"
                in _card_agents(host, card_id).get(TASK_ID, {})
            )
            assert _card_items(host, card_id)[-1].status == "running"
            before = len(_card_items(host, card_id))

            # A second turn the user can stop while the subagent still runs.
            # Waiting on `execution.client` rather than on `session.execution`:
            # the latter is set the moment the turn is queued, before
            # `drive_turn` has attached its transport, and a stop in that
            # window has nothing to interrupt (pre-existing, and correct — pp
            # cannot tap stop on a turn that has not been dispatched yet).
            await runtime.start_turn("sub_progress", None, "keep going")
            await _wait_until(
                lambda: session.execution is not None
                and session.execution.client is not None
            )

            started_at = time.monotonic()
            result = await runtime.interrupt_session("sub_progress", reason="user")
            elapsed = time.monotonic() - started_at

            assert result.ok is True
            assert elapsed < 1.0, f"the stop took {elapsed:.3f}s"
            cards = _card_items(host, card_id)
            assert len(cards) == before + 1, "exactly one row, published by the stop"
            assert cards[-1].status == "interrupted"
            # The agents-map entry records the wire status verbatim (a CLI
            # closure would read "completed" here); the timeline status is what
            # `AGENT_TASK_TERMINAL_STATUSES` maps killed -> interrupted onto.
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "killed"
            assert host.session_turn_ends[-1]["outcome"] == "interrupted"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_finished_subagent_card_is_never_walked_backwards() -> None:
    """The one guard the fold needs: only the caller-vouched live set is folded.

    A "killed" overlay on a card the CLI already closed as `done` would walk a
    finished card back to `interrupted`, so the live set is what decides — and
    a card that closed before the stop is not in it.
    """

    async def run() -> None:
        client = _SubagentThenWaitClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("sub_progress", None, "hello")
            session = runtime._sessions["sub_progress"]
            await asyncio.wait_for(session.active_task, 5)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await _wait_until(
                lambda: "subagentType"
                in _card_agents(host, card_id).get(TASK_ID, {})
            )
            # The CLI closes the card itself.
            await client.incoming.put(_parse(WIRE_TASK_UPDATED))
            await _wait_until(lambda: _card_items(host, card_id)[-1].status == "done")
            settled = dict(_card_items(host, card_id)[-1].content)

            connection = runtime._turns.runner.connections["sub_progress"]
            assert tuple(connection.background.active_ids) == ()
            await runtime._turns.runner.publish_stopped_subagents(session, ())
            assert dict(_card_items(host, card_id)[-1].content) == settled
            assert _card_items(host, card_id)[-1].status == "done"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# L3a · the settle-time batch is published in source order
# --------------------------------------------------------------------------


class _ReorderedThinkingClient(_ScheduledClaudeClient):
    """A resumed stream whose later thinking block arrives before the earlier one.

    Stage 1's H-b pinned the mechanism for the real machine's "same millisecond,
    out of order" batch: `order_seq_for` hands out a slot when an item is
    CREATED, so anything created during settle takes the session's largest slot
    and a thinking block that was semantically first renders last. The
    reconnect/replay path is what makes a later block arrive first, and it is
    the same shape as the residual-frame family this batch is about.

    Neither block is ever closed, so both are still open when the turn settles —
    which is exactly when `finalize_pending_thinking` publishes them.
    """

    def __init__(self) -> None:
        super().__init__()

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        frames = [
            StreamEvent(
                uuid="stream_uu",
                session_id="stream_sess",
                event={"type": "message_start", "message": {"id": "msg_l3a"}},
            ),
            # Block 1 first.
            StreamEvent(
                uuid="stream_uu",
                session_id="stream_sess",
                event={
                    "type": "content_block_delta",
                    "index": 1,
                    "delta": {"type": "thinking_delta", "thinking": "second thought"},
                },
            ),
            # Then block 0.
            StreamEvent(
                uuid="stream_uu",
                session_id="stream_sess",
                event={
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "thinking_delta", "thinking": "first thought"},
                },
            ),
            SimpleNamespace(type="result", session_id="stream_sess"),
        ]
        for frame in frames:
            await self.incoming.put(frame)


def _is_thinking(item: Any) -> bool:
    """The reasoning rows this stream produced (`derivedKey == "thinking"`)."""

    return dict(getattr(item, "source", {}) or {}).get("derivedKey") == "thinking"


def test_settle_time_thinking_batch_is_published_in_source_order() -> None:
    """T4: the batch that forms at settle goes out in source order.

    `finalize_pending_thinking` closes thinking blocks that never received a
    `content_block_stop`, and it is the one place a whole batch of rows is
    created outside the frame loop. Publishing it in the order the CLI produced
    the blocks — not in the order they happened to arrive, and not in slot
    allocation order — is what keeps a resumed stream from rendering its last
    thought above its first.

    Pinned rather than changed: reading the code at 70262b64, this already
    iterates `sorted(self.partial_thinking_blocks)`, so the suite now holds the
    invariant instead of leaving it to be re-broken by a well-meaning edit.
    """

    async def run() -> None:
        client = _ReorderedThinkingClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("l3a", None, "think")
            session = runtime._sessions["l3a"]
            await asyncio.wait_for(session.active_task, 5)

            settled = [
                item for item in host.timeline_item_upserts if _is_thinking(item)
            ]
            assert [
                item.content["text"] for item in settled if item.status == "running"
            ] == [
                "second thought",
                "first thought",
            ], "arrival order — each block was published as its delta arrived"

            # The settle-time closure is the final revision of the same two
            # rows, and it must go out in source order.
            assert [
                item.content["text"] for item in settled if item.status == "done"
            ] == [
                "first thought",
                "second thought",
            ]
            assert host.session_turn_ends[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# L3b · a settled turn refreshes its own session instead of waiting a beat
# --------------------------------------------------------------------------


class _SettleSignalHost(_RecordingHost):
    """Records the L3b settle signal the turn's host receives."""

    def __init__(self) -> None:
        super().__init__()
        self.settled: list[tuple[str, str | None]] = []

    async def on_turn_settled(
        self,
        session_id: str,
        external_session_id: str | None = None,
    ) -> None:
        self.settled.append((session_id, external_session_id))


def test_a_settled_turn_asks_for_its_own_session_refresh() -> None:
    """L3b: the push already carried the rows; this carries the snapshot.

    The two roads are not redundant. The runtime pushes each row as it is
    projected, and the connector's periodic sync re-reads the transcript and
    ships a snapshot that catches whatever the push published late, out of
    order, or not at all — which is the 2026-10-04 12:24 batch. Waiting for the
    global beat is what turned a settled reply into 30-50 s of an idle-looking
    session.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _SettleSignalHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("l3b", None, "hello")
            session = runtime._sessions["l3b"]
            await asyncio.wait_for(session.active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert host.settled, "a settled turn must ask for its session refresh"
            assert [sid for sid, _ in host.settled] == ["l3b"]
            assert host.settled[0][1] == session.external_session_id

            # A second turn asks again — the signal is per settle, not per
            # session-lifetime.
            await runtime.start_turn("l3b", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            assert len(host.settled) == 2
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_host_without_the_signal_keeps_its_behavior() -> None:
    """The protocol default is a no-op, so nothing depends on the signal existing."""

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with_values(host, _single_client_factory(client), {})
        try:
            await runtime.start_turn("l3b", None, "hello")
            session = runtime._sessions["l3b"]
            await asyncio.wait_for(session.active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_settled_session_refresh_is_coalesced_and_returns_at_once() -> None:
    """The sync runner side: one refresh per session, and never awaited.

    Two properties the turn's settle path depends on. It returns immediately —
    a settle must not wait for the very sync it is asking for, or L3b would
    trade one lag for another. And it coalesces — a session that settles three
    times in a second is one transcript read, not three.
    """

    async def run() -> None:
        from test_connector_runtime import (
            FakeAgentRuntime,
            FakeRuntimeSupervisor,
            RecordingRuntimeHost,
            _client,
            unused_notification_sender,
        )

        from connector.runtime_protocol import SessionMeta
        from connector.server.runtime_sync import RuntimeSyncRunner

        class _Runtime(FakeAgentRuntime):
            def __init__(self) -> None:
                super().__init__()
                self.reads: list[str] = []

            async def list_sessions(self, **kwargs: Any) -> tuple[SessionMeta, ...]:
                return (
                    SessionMeta(
                        session_id="l3b",
                        external_session_id="l3b",
                        runtime="codex",
                        metadata={
                            "sync": {"changed": True, "requires_timeline_sync": True}
                        },
                    ),
                )

            async def prepare_session_timeline_sync(
                self, session_id: str, external: str | None
            ) -> None:
                self.reads.append(session_id)
                await asyncio.sleep(0.05)

        runtime = _Runtime()
        runner = RuntimeSyncRunner(
            config=_client().config,
            supervisor=FakeRuntimeSupervisor(runtime),
            host=RecordingRuntimeHost(),
            preferences_reader=dict,
            send_notification=unused_notification_sender,
            ingest_notifications=None,
        )
        try:
            started_at = time.monotonic()
            for _ in range(3):
                runner.on_turn_settled("codex", "l3b", "l3b")
            assert time.monotonic() - started_at < 0.05, "the settle path waited"

            await asyncio.gather(*tuple(runner._session_sync_tasks))
            assert runtime.reads == ["l3b"], "three settles, one transcript read"
            assert runner._pending_session_syncs == set()
        finally:
            await runner.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# F3 · every terminal status is absorbed at silence, not just `completed`
# --------------------------------------------------------------------------


ABORTED_TAIL = {**BARE_SUCCESS_RESULT, "terminal_reason": "aborted_streaming"}


def test_aborted_tail_at_silence_mints_no_turn_and_no_error_state() -> None:
    """F3, the blocking half: `interrupted` tails mint nothing either.

    修前红: a user stops, sends nothing, and ~32 s later the CLI's
    `aborted_streaming` tail lands at silence. The guard only matched
    `completed`, so this frame fell through to the mint branch — and the
    resulting turn, whose only content IS the abort, was then refused by the
    cast-frame position gate, exhausted its stream and published
    `claude_stream_ended_without_result`. A session turned red with no user
    action anywhere in it.

    Both halves are asserted because either alone would be a partial fix: no
    second turn, and no error state. The per-status breakdown is what makes the
    counter usable (F6): this is an `interrupted` absorption, which is a normal
    consequence of stopping, not the `completed` ghost shape.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("aborted", None, "hello")
            session = runtime._sessions["aborted"]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["aborted"]
            assert connection.current is None

            await client.incoming.put(_parse(ABORTED_TAIL))
            await asyncio.sleep(0.2)

            assert len(host.session_turn_ends) == 1, "an abort tail minted a turn"
            assert session.execution is None
            assert session.queued_execution is None
            assert host.session_state_updates[-1]["status"] == "idle"
            assert connection.absorbed_terminal_frames == 1
            assert connection.absorbed_terminal_by_status == {"interrupted": 1}
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_failed_tail_at_silence_mints_nothing_either() -> None:
    """`failed` keeps its visibility through the PENDING branch, and nowhere else.

    The red line is that a queued prompt whose CLI failed must still show that
    failure — which is what `test_failed_result_still_reaches_the_pending_turn`
    pins. With no pending to land on there is nothing to be visible to, so the
    mint branch must not invent a turn to carry it: an invented failed turn is a
    red bubble on a session the user never broke.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("failed_tail", None, "hello")
            session = runtime._sessions["failed_tail"]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["failed_tail"]

            await client.incoming.put(_parse(FAILED_RESULT))
            await asyncio.sleep(0.2)

            assert len(host.session_turn_ends) == 1
            assert session.execution is None
            assert host.session_state_updates[-1]["status"] == "idle"
            assert connection.absorbed_terminal_by_status == {"failed": 1}
        finally:
            await runtime.stop()

    asyncio.run(run())
