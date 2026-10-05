"""F1 release protocol: a residual terminal is declined, and the read continues.

`claude-stale-frame-f1-release-protocol.md` §8.1-§8.2 and §9.

The shape under test is the 2026-10-04 P1 report: the previous turn's result
is still on the wire when the next message starts, so it lands inside the
queue the new turn is already draining, and the turn settles on it. The F1
gate made that honest (`interrupted`, never a false `completed`), but the real
reply — queued BEHIND the swallowed frame — was still lost.

The protocol now declines an unowned `completed` terminal and keeps reading to
the turn's own result, bounded by a grace window so a turn whose only frame
was a leftover still settles. These tests pin both halves: the recovery, and
the bound. The counter pair is the whole claim — `stale_terminal_recoveries`
up with `stale_completion_downgrades` at zero is the fix working; the
downgrade counter alone is not a symptom report.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from claude_agent_sdk import UserMessage
from claude_agent_sdk._internal.message_parser import parse_message
from test_claude_compact_ghost import _runtime_with, _single_client_factory
from test_claude_runtime import _RecordingHost, _ScheduledClaudeClient

from connector.runtimes.claude.sdk import connection as connection_module
from connector.runtimes.claude.sdk.connection import ClaudeResponse
from connector.runtimes.claude.turns.lifecycle import STALE_COMPLETION_REASON

SESSION = "b5a5f0a4-2c17-4f8e-9a6b-1d0e7c4b9a21"

# The leftover: the previous turn's result. `result` carries text on purpose —
# a bare success has nothing to publish, so it could not tell "declined and
# skipped" apart from "declined and published anyway".
LEFTOVER_RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "num_turns": 1,
    "session_id": SESSION,
    "result": "the PREVIOUS turn's answer",
    "duration_ms": 12,
    "duration_api_ms": 10,
    "total_cost_usd": 0.0,
}

# The reply the user actually asked for, queued behind the leftover.
ASSISTANT_REPLY = {
    "type": "assistant",
    "message": {
        "role": "assistant",
        "model": "claude-opus-5",
        "content": [{"type": "text", "text": "the real answer"}],
    },
    "uuid": "assistant-real",
    "session_id": SESSION,
}

# The real wire opens with the CLI handshake, ahead of the prompt echo: 31/31
# captures put `init` first (recon/stale-frame/f1-preamble-gate-finding.md).
# These are what made the residual look OWNED — the gate opened on a
# handshake and the leftover passed as this turn's own verdict.
INIT_FRAME = {
    "type": "system",
    "subtype": "init",
    "session_id": SESSION,
    "uuid": "wire-init-1",
}
STATUS_FRAME = {
    "type": "system",
    "subtype": "status",
    "status": None,
    "session_id": SESSION,
    "uuid": "wire-status-1",
}

THE_REAL_ANSWER = "the real answer"
THE_PREVIOUS_ANSWER = "the PREVIOUS turn's answer"

# What follows the echo on a scripted turn. The names are the assertion: a
# fixture that silently drifts is worse than no fixture.
#   "residual+reply" — leftover, the real reply, then this turn's own result.
#   "double"         — two leftovers in a row, then the same reply and result.
#   "residual-silent" — the leftover and then nothing at all.
#   "empty"          — this turn's own result with nothing before it.
#   "clean"          — an ordinary turn, the base client's own reply.
TAIL_REMAINDER: dict[str, tuple[str, ...]] = {
    "residual+reply": ("residual", "reply", "own_result"),
    "double": ("residual", "residual", "reply", "own_result"),
    "residual-silent": ("residual",),
    "empty": ("own_result",),
    "clean": ("reply", "own_result"),
}


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


@pytest.fixture
def short_grace(monkeypatch: pytest.MonkeyPatch) -> None:
    """Shrink the declined-terminal grace window.

    The production value is 30 s by design (same class as the 30 s fast kill
    and the ~32 s residual window). Tests that deliberately starve the read
    pay it in wall clock otherwise; tests that do not must NOT patch it, so a
    recovery is never measured against a window production did not have.
    """

    monkeypatch.setattr(connection_module, "DECLINED_TERMINAL_GRACE_SECONDS", 0.2)


class _ScriptedTurnClient(_ScheduledClaudeClient):
    """Turn 1 is an ordinary completed turn; later turns run a scripted order.

    Turn 1 goes through the base client's own reply and result so the
    transport is live and already settled before turn 2 — the real
    precondition, since the leftover belongs to a turn that ALREADY settled.

    `script` maps a query number to its tail; `default_tail` covers the rest.
    Every emitted frame order is recorded per query in `emitted`, so each test
    asserts the wire order it thinks it is testing.
    """

    def __init__(
        self,
        script: dict[int, str] | None = None,
        *,
        default_tail: str = "residual+reply",
        preamble: bool = False,
    ) -> None:
        super().__init__()
        self.script = script or {}
        self.default_tail = default_tail
        self.preamble = preamble
        self.queries_seen = 0
        self.emitted: dict[int, list[str]] = {}

    def _tail_for(self, index: int) -> str:
        if index == 1:
            return "clean"
        return self.script.get(index, self.default_tail)

    async def _own_result(self) -> None:
        # The same shape the base client uses for its own terminal.
        await self.incoming.put(
            SimpleNamespace(type="result", session_id=self.native_id)
        )

    async def _emit_turn(self, turn: int, uuid: str, content: str) -> None:
        tail = self._tail_for(turn)
        remainder = TAIL_REMAINDER[tail]
        frames: list[Any] = []
        names: list[str] = []
        if self.preamble:
            frames += [_parse(INIT_FRAME), _parse(STATUS_FRAME)]
            names += ["init", "status"]
        frames.append(UserMessage(uuid=uuid, content=content))
        names.append("echo")
        leftovers = 0
        for name in remainder:
            if name == "residual":
                frames.append(
                    _parse({**LEFTOVER_RESULT, "uuid": f"leftover-{leftovers}"})
                )
                names.append("residual")
                leftovers += 1
            elif name == "reply" and tail != "clean":
                frames.append(_parse(ASSISTANT_REPLY))
                names.append("reply")
            elif name == "own_result" and tail != "clean":
                # Emitted by `_own_result()` after the frames above.
                names.append("own_result")
        if tail == "clean":
            # The base client's own reply, so an ordinary turn still looks
            # ordinary (`reply:<prompt>`) rather than like the probe text.
            # It emits the assistant frame and the terminal together.
            names += [f"reply:{content}", "own_result"]
        self.emitted[turn] = names
        for frame in frames:
            await self.incoming.put(frame)
        if tail == "clean":
            await self.reply(f"reply:{content}")
        elif "own_result" in remainder:
            await self._own_result()

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.queries_seen += 1
            await self._emit_turn(self.queries_seen, message["uuid"], content)


def _published(host: _RecordingHost) -> list[str]:
    return [str(item.content.get("text", "")) for item in host.timeline_item_upserts]


def test_a_residual_behind_the_echo_is_declined_and_the_reply_is_delivered() -> None:
    """The main judgement: the reply reaches the timeline in the turn that
    asked for it, and that turn ends `completed` — exactly once.

    Frames for turn 2: echo → leftover → the real reply → this turn's own
    result. Before the protocol the leftover ended the turn, and the reply
    plus the real result died in a queue nobody drained.
    """

    async def run() -> None:
        client = _ScriptedTurnClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("release", None, "hello")
            session = runtime._sessions["release"]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            assert runner.stale_completion_downgrades == 0

            await runtime.start_turn("release", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[2] == ["echo", "residual", "reply", "own_result"]
            # 1 · exactly one turn end for turn 2, and it is a success.
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "completed"]
            assert "terminalReason" not in ends[-1]["metadata"]
            # 2 · the answer the user asked for is in THIS turn's bubble.
            texts = _published(host)
            assert THE_REAL_ANSWER in texts
            # The declined frame publishes nothing: its text belongs to the
            # turn that already answered, so putting it here would show the
            # user a second copy of an answer they have.
            assert THE_PREVIOUS_ANSWER not in texts
            # 3-5 · the counter pair. A recovery is not a downgrade.
            assert runner.stale_completion_downgrades == 0
            assert runner.stale_terminal_recoveries == 1
            assert runner.foreign_terminal_frames == 1
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_two_leftovers_behind_the_echo_are_both_declined_and_still_recover() -> None:
    """The same shape with two leftovers in a row.

    The window re-arms for each decline, so the second leftover must not
    close the read either — and neither of them may count as a recovery: a
    turn recovers once, no matter how many frames it had to skip.
    """

    async def run() -> None:
        client = _ScriptedTurnClient({2: "double"}, default_tail="double")
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("twice", None, "hello")
            session = runtime._sessions["twice"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("twice", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[2] == [
                "echo",
                "residual",
                "residual",
                "reply",
                "own_result",
            ]
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "completed"]
            texts = _published(host)
            assert THE_REAL_ANSWER in texts
            assert THE_PREVIOUS_ANSWER not in texts
            runner = runtime._turns.runner
            # Two frames skipped, one turn recovered.
            assert runner.stale_terminal_recoveries == 1
            assert runner.stale_completion_downgrades == 0
            assert runner.foreign_terminal_frames == 2
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_declined_terminal_with_nothing_behind_it_still_settles(
    short_grace,
) -> None:
    """R1: the bound. A leftover and then silence must NOT hang the turn.

    A human turn has no watchdog — `arm_scheduled_watchdog` is only installed
    for scheduled activity — so nothing else would ever end this turn. When
    the window expires the turn settles on the downgraded verdict it recorded
    at decline time: today's behavior, G later. And the transport is handed
    back, because a reader still holding `current` would park the next
    message's echo in a dead queue.
    """

    async def run() -> None:
        client = _ScriptedTurnClient({2: "residual-silent"}, default_tail="residual-silent")
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("starved", None, "hello")
            session = runtime._sessions["starved"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("starved", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[2] == ["echo", "residual"]
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "interrupted"]
            assert ends[-1]["metadata"]["terminalReason"] == STALE_COMPLETION_REASON
            runner = runtime._turns.runner
            # Nothing of its own arrived, so the fallback fired — and it is
            # counted as the fallback, not as a recovery.
            assert runner.stale_completion_downgrades == 1
            assert runner.stale_terminal_recoveries == 0
            assert runner.foreign_terminal_frames == 1
            assert THE_REAL_ANSWER not in _published(host)
            # Settled, not hanging: the session is free and usable again.
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
            connection = runtime._turns.runner.connections["starved"]
            assert connection.current is None, (
                "the reader is still holding a response whose turn has settled"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_the_real_wire_order_recovers_the_reply() -> None:
    """§9: the order the CLI actually sends — [init, status, echo, residual,
    reply, own result] — now reaches the same recovery.

    This is the case the synthetic shape alone could not reach. The handshake
    frames arrive ahead of the echo, so before §9 they opened the start gate
    and the leftover passed as OWNED: the turn settled `completed` before its
    own model request, and the reply was phantomized into a later turn. That
    is the P1 report verbatim, which is why the gate counts a frame as work
    only once it is not wire chrome.
    """

    async def run() -> None:
        client = _ScriptedTurnClient(preamble=True)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("wire", None, "hello")
            session = runtime._sessions["wire"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("wire", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[2] == [
                "init",
                "status",
                "echo",
                "residual",
                "reply",
                "own_result",
            ]
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "completed"]
            texts = _published(host)
            assert THE_REAL_ANSWER in texts
            assert THE_PREVIOUS_ANSWER not in texts
            runner = runtime._turns.runner
            assert runner.stale_completion_downgrades == 0
            assert runner.stale_terminal_recoveries == 1
            assert runner.foreign_terminal_frames == 1
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_the_real_wire_empty_reply_is_bounded_and_downgraded(short_grace) -> None:
    """§9: [init, status, echo, own empty result] — the accepted cost.

    With the gate chrome-aware this shape is now an unowned `completed`, so it
    is declined like any other and settled by the grace window instead of
    claiming a success it did not have. This is pp's earlier approved trade
    ("this round produced nothing"), now reachable on the real wire because
    the handshake no longer opens the gate in front of it.
    """

    async def run() -> None:
        client = _ScriptedTurnClient({2: "empty"}, default_tail="empty", preamble=True)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("wire_empty", None, "hello")
            session = runtime._sessions["wire_empty"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("wire_empty", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[2] == ["init", "status", "echo", "own_result"]
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == ["completed", "interrupted"]
            assert ends[-1]["metadata"]["terminalReason"] == STALE_COMPLETION_REASON
            runner = runtime._turns.runner
            assert runner.stale_completion_downgrades == 1
            assert runner.stale_terminal_recoveries == 0
            assert runner.foreign_terminal_frames == 1
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_declined_terminal_does_not_swallow_the_next_turn(short_grace) -> None:
    """The transport stays routable after a decline.

    The reader keeps `current` across a decline so the frames behind the
    leftover still reach the same response. If the turn then ends without
    another terminal, `release()` has to take `current` back — otherwise the
    idle reclaim can never arm again and every later frame, including the next
    message's prompt echo, is parked in a dead queue: the session looks
    unlocked and answers nothing.
    """

    async def run() -> None:
        client = _ScriptedTurnClient({2: "residual-silent"}, default_tail="clean")
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("handover", None, "hello")
            session = runtime._sessions["handover"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("handover", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["handover"]
            assert connection.current is None, "a settled turn kept the transport"

            # The next message must still be answered on the same transport.
            await runtime.start_turn("handover", None, "third")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.2)

            assert client.emitted[3] == ["echo", "reply:third", "own_result"]
            ends = host.session_turn_ends
            assert [end["outcome"] for end in ends] == [
                "completed",
                "interrupted",
                "completed",
            ]
            assert "reply:third" in _published(host)
            assert connection.current is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# Red team round 3 · B1/B2 — the ruling is consumed exactly once
# --------------------------------------------------------------------------


class _SettleWindowHost(_RecordingHost):
    """A host that offers the transport frames while a turn is settling.

    `session_turn_ended` is the last host round trip before
    `finish_execution` calls `release()`, so a frame pushed to the client from
    here lands strictly inside the window: the turn has already chosen its
    verdict and the reader must still be parked on it. The latency widens that
    window so the measurement is not a race with the scheduler — on a real
    device the same span is the whole settle phase, measured at hundreds of
    milliseconds of host backpressure (V9).
    """

    def __init__(self, frames: list[Any], *, latency: float = 0.25) -> None:
        super().__init__()
        self.frames = frames
        self.latency = latency
        # Frames still in the transport's inbound queue when the window
        # closes: the measure of whether the reader was parked.
        self.left_in_queue: int | None = None

    def watch(self, client: _ScheduledClaudeClient, turn_index: int = 1) -> None:
        self._client = client
        self._turn_index = turn_index

    async def session_turn_ended(self, **kwargs: Any) -> None:
        if len(self.session_turn_ends) == self._turn_index:
            for frame in self.frames:
                await self._client.incoming.put(frame)
            await asyncio.sleep(self.latency)
            self.left_in_queue = self._client.incoming.qsize()
        return await super().session_turn_ended(**kwargs)


def test_frames_arriving_in_the_settle_window_are_not_destroyed() -> None:
    """Red team B1, product-visible: a frame the transport offers while a turn
    settles must survive it.

    The reader parks on the turn's own terminal, so nothing is read past the
    verdict until the turn releases the transport — that park is what makes
    the window safe. A ruling that outlives the park it answered (a stale
    `terminal_declined` left set by the decline) pre-empts the next park: the
    reader never stops, reads the whole settle phase, and every frame that
    arrives in it is routed into a response whose turn has already settled
    and is destroyed with it — silently, uncounted.

    A scheduled task waking up is that frame class in production: it is a
    cast frame, it should mint a turn, and instead the task simply never runs.
    """

    async def run() -> None:
        wakes = [
            _parse(
                {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "model": "claude-opus-5",
                        "content": [{"type": "text", "text": f"WAKE-{index}"}],
                    },
                    "uuid": f"wake-{index}",
                    "session_id": SESSION,
                }
            )
            for index in range(3)
        ]
        client = _ScriptedTurnClient()
        host = _SettleWindowHost(wakes)
        host.watch(client)
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("window", None, "hello")
            session = runtime._sessions["window"]
            await asyncio.wait_for(session.active_task, 5)

            await runtime.start_turn("window", None, "second")
            await asyncio.wait_for(session.active_task, 5)
            await asyncio.sleep(0.5)

            assert host.left_in_queue == len(wakes), (
                "the reader was not parked through the settle: it read ahead "
                "and consumed frames no turn was waiting for"
            )
            # Not merely queued — they reached the routing layer and the first
            # one minted the turn its text was waiting for.
            texts = _published(host)
            assert [f"WAKE-{index}" for index in range(3)] == [
                text for text in texts if text.startswith("WAKE-")
            ], texts
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_one_decline_ruling_answers_exactly_one_park() -> None:
    """Red team B2, unit level: the decline ruling is one-shot.

    It travels on three channels — the level event, the remembered flag for a
    ruling that arrived with nobody parked, and the future handed to a parked
    reader — and whichever channel answers a park must consume the others
    with it. Otherwise the ruling survives its own consumption and answers
    the NEXT park without waiting, which is the reader-side half of the
    read-ahead above.
    """

    async def run() -> None:
        connection = SimpleNamespace(
            drop_current=lambda _response: True, arm_idle=lambda: None
        )
        response = ClaudeResponse(connection)  # type: ignore[arg-type]

        # The turn rules before the reader parks; the ruling is remembered.
        response.decline_terminal()
        assert response._verdict_pending is True

        # The first park consumes it, and destroys it in the consuming.
        assert await response.await_terminal_verdict() is False

        # The next terminal has NOT been ruled on. A park here must really
        # wait — a stale channel answering it is the defect.
        second = asyncio.create_task(response.await_terminal_verdict())
        await asyncio.sleep(0.05)
        assert not second.done(), (
            "a consumed decline ruling answered a second park without waiting"
        )
        response.release()
        assert await asyncio.wait_for(second, 1) is True

    asyncio.run(run())