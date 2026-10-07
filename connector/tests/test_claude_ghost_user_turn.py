"""Ghost-user-turn fix (2026-10-07): the reader must not starve a pending turn.

The defect, reproduced in `test_ghost_user_turn_probe.py` (P2/P3): a human turn
is submitted -> `response_for()` registers a `ClaudeResponse` in
`connection.pending` -> the prompt's echo comes back mismatched, late, or never
-> the FIRST frame that reaches silence then fell through the reader's
pending-selection clause (it matched `failed` terminals only) into the mint
branch, cast a ghost, and took `current`. Every frame behind it — the pending's
own echo, reply and result — was routed into the ghost, and the human turn
never settled: human turns have no watchdog, so nothing would ever end it and
the user, whose message the CLI had accepted, never saw a reply.

The fix has two halves, both in `runtimes/claude/sdk/connection.py`:

  * the mint branch refuses to cast while `pending` is registered and routes
    the frame into the pending instead (the frame lands exactly where it would
    have landed had its echo matched);
  * the pending-selection clause accepts ANY terminal frame, so a turn whose
    whole stream is a bare result (empty reply, or a residue from a round that
    already settled) is selected and can settle — instead of being absorbed at
    silence and leaving the turn waiting forever.

Neither half hands a turn a verdict it cannot prove: `drive_turn` declines an
unowned `completed` (records the downgrade, keeps reading, bounded by
`DECLINED_TERMINAL_GRACE_SECONDS` — F1 release protocol, §8.1), so a leftover
cannot be "won" by the wrong turn, and a genuine empty reply settles on the
downgrade instead of hanging.

T1-a  mismatched echo + assistant frame first  -> routed to pending, answers.
T1-b  echo missing + assistant frame first     -> routed to pending, answers.
T1-c  echo missing + a bare non-failed terminal-> promotes the pending (not
      absorbed), the unowned completed is declined, and the turn settles on
      the bounded downgrade.
"""

from __future__ import annotations

import asyncio
from typing import Any, Self

import pytest
from claude_agent_sdk import UserMessage
from test_claude_background_guard import _parse
from test_claude_compact_ghost import _runtime_with, _single_client_factory
from test_claude_runtime import (
    AssistantMessage,
    _RecordingHost,
    _ScheduledClaudeClient,
)

from connector.runtimes.claude.sdk import connection as connection_module
from connector.runtimes.claude.sdk.connection import ClaudeConnection
from connector.runtimes.claude.turns.lifecycle import STALE_COMPLETION_REASON

# A bare success result — no origin, nothing for the chrome gate to know. The
# shape that is both a legitimate empty reply and a leftover, which is why the
# reader may route it but only `drive_turn` may judge it.
BARE_SUCCESS_RESULT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "num_turns": 1,
    "session_id": "ghost-user-turn-session",
    "result": "",
    "duration_ms": 12,
    "duration_api_ms": 10,
    "total_cost_usd": 0.0,
}


class _SelectSpy:
    """Record every `select_response` with the classification that matters.

    `from_pending` is sampled BEFORE the call, because `select_response`
    clears `pending` on the way in — the flag answers "was this reader
    decision a promotion of the registered turn, or a cast".
    """

    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []
        self._original = ClaudeConnection.select_response

    async def __aenter__(self) -> Self:
        spy = self

        async def wrapper(self: ClaudeConnection, response: Any) -> None:
            spy.events.append(
                {
                    "from_pending": self.pending is response,
                    "cast": response.cast_frame is not None,
                    "execution": response.execution is not None,
                    "maintenance": response.maintenance,
                }
            )
            await spy._original(self, response)

        ClaudeConnection.select_response = wrapper  # type: ignore[method-assign]
        return self

    async def __aexit__(self, *_: object) -> None:
        ClaudeConnection.select_response = self._original  # type: ignore[method-assign]

    def mints(self) -> list[dict[str, Any]]:
        return [e for e in self.events if e["cast"]]

    def promotions(self) -> list[dict[str, Any]]:
        return [e for e in self.events if e["from_pending"] and not e["cast"]]


class _AssistantFirstClient(_ScheduledClaudeClient):
    """Turn 2+: an assistant output frame reaches silence BEFORE the echo.

    `echo_uuid` replays the prompt with a uuid the connector never sent — the
    mismatched-echo half of the defect.
    """

    armed = False
    echo_uuid: str | None = None

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            if self.armed:
                await self.incoming.put(
                    AssistantMessage(
                        uuid="leftover-frame",
                        session_id=self.native_id,
                        content=[{"type": "text", "text": "leftover output"}],
                    )
                )
            await self.incoming.put(
                UserMessage(uuid=self.echo_uuid or message["uuid"], content=content)
            )
            await self.reply(f"reply:{content}")


class _EchoMissingClient(_ScheduledClaudeClient):
    """Turn 2+: the prompt echo is never replayed; its reply comes first.

    The first frame at silence is the assistant reply itself, so it is the
    candidate that used to mint the ghost.
    """

    armed = False

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            if not self.armed:
                await self.incoming.put(
                    UserMessage(uuid=message["uuid"], content=content)
                )
            await self.reply(f"reply:{content}")


class _BareTerminalNoEchoClient(_ScheduledClaudeClient):
    """Turn 2+: echo missing, and the round's whole stream is one bare result."""

    armed = False

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            if not self.armed:
                await self.incoming.put(
                    UserMessage(uuid=message["uuid"], content=content)
                )
                await self.reply(f"reply:{content}")
            else:
                await self.incoming.put(_parse(BARE_SUCCESS_RESULT))


def _turn_id_of(result: Any) -> str:
    return result.result["turnId"]


def _ends(host: _RecordingHost, turn_id: str) -> list[dict[str, Any]]:
    return [e for e in host.session_turn_ends if e["turn_id"] == turn_id]


@pytest.fixture()
def short_grace(monkeypatch: pytest.MonkeyPatch) -> None:
    """Shrink the F1 declined-terminal window so T1-c settles in milliseconds.

    Same rationale as `test_claude_stale_frame_turn.py`: the 30 s production
    value is a latency trade, not a semantic one, and the constant is read at
    call time so a test may shrink it without patching call sites.
    """

    monkeypatch.setattr(
        connection_module, "DECLINED_TERMINAL_GRACE_SECONDS", 0.2
    )


# --------------------------------------------------------------------------
# T1-a · mismatched echo + earlier assistant frame
# --------------------------------------------------------------------------


def test_t1a_mismatched_echo_and_earlier_frame_answer_the_human_turn() -> None:
    """探针 P2+P3 的合体形状：修后，真人回合自己拿到回复并结算。"""

    async def run() -> None:
        client = _AssistantFirstClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("ghost_a", None, "hello")
            session = runtime._sessions["ghost_a"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.armed = True
            client.echo_uuid = "cli-replayed-wrong-uuid"
            async with _SelectSpy() as spy:
                second = await runtime.start_turn(
                    "ghost_a", client.native_id, "again"
                )
                human_id = _turn_id_of(second)
                await asyncio.wait_for(session.active_task, 5)

            assert client.prompt_uuids[-1] != "cli-replayed-wrong-uuid"
            # No ghost was cast: the first frame was routed into the pending.
            assert spy.mints() == [], (
                "the first frame must not mint a scheduled ghost while a "
                "human prompt is registered"
            )
            promotions = spy.promotions()
            assert len(promotions) == 1 and promotions[-1]["from_pending"] is True
            assert promotions[-1]["execution"] is True
            # The routed frame reached the human turn's queue...
            texts = [
                (item.turn_id, str(item.content.get("text", "")))
                for item in host.timeline_item_upserts
                if item.role == "assistant"
            ]
            assert (human_id, "leftover output") in texts, (
                "the routed frame must reach the pending turn"
            )
            # ... and the turn settled on its own reply.
            assert (human_id, "reply:again") in texts
            assert _ends(host, human_id)[-1]["outcome"] == "completed"
            connection = runtime._turns.runner.connections["ghost_a"]
            assert connection.current is None
            assert connection.pending is None
            assert connection.absorbed_terminal_frames == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# T1-b · echo missing entirely
# --------------------------------------------------------------------------


def test_t1b_missing_echo_first_assistant_frame_answers_the_human_turn() -> None:
    async def run() -> None:
        client = _EchoMissingClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("ghost_b", None, "hello")
            session = runtime._sessions["ghost_b"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.armed = True
            async with _SelectSpy() as spy:
                second = await runtime.start_turn(
                    "ghost_b", client.native_id, "again"
                )
                human_id = _turn_id_of(second)
                await asyncio.wait_for(session.active_task, 5)

            assert spy.mints() == [], (
                "a frame arriving before the echo must not mint a ghost"
            )
            promotions = spy.promotions()
            assert len(promotions) == 1 and promotions[-1]["from_pending"] is True
            assert any(
                item.turn_id == human_id
                and item.role == "assistant"
                and "reply:again" in str(item.content.get("text"))
                for item in host.timeline_item_upserts
            ), "the human turn must receive its own reply"
            assert _ends(host, human_id)[-1]["outcome"] == "completed"
            assert not any(
                item.turn_id != human_id
                and item.role == "assistant"
                and "reply:again" in str(item.content.get("text"))
                for item in host.timeline_item_upserts
            ), "no other turn consumed the human's reply"
            connection = runtime._turns.runner.connections["ghost_b"]
            assert connection.current is None
            assert connection.pending is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# T1-c · echo missing + a bare, non-failed terminal
# --------------------------------------------------------------------------


def test_t1c_bare_terminal_promotes_the_pending_instead_of_being_absorbed(
    short_grace: None,
) -> None:
    """I1 不再吞掉这个终局：pending 升位，未自证归属的 completed 被降级结算。"""

    async def run() -> None:
        client = _BareTerminalNoEchoClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("ghost_c", None, "hello")
            session = runtime._sessions["ghost_c"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.armed = True
            async with _SelectSpy() as spy:
                second = await runtime.start_turn(
                    "ghost_c", client.native_id, "again"
                )
                human_id = _turn_id_of(second)
                await asyncio.wait_for(session.active_task, 5)

            connection = runtime._turns.runner.connections["ghost_c"]
            # The terminal reached the pending turn instead of being swallowed
            # by the I1 absorb branch (the old `failed`-only clause did).
            assert connection.absorbed_terminal_frames == 0, (
                "a bare terminal with a prompt waiting for it must not be "
                "absorbed at silence"
            )
            assert spy.mints() == []
            promotions = spy.promotions()
            assert len(promotions) == 1 and promotions[-1]["from_pending"] is True
            # The turn settled — no hang — on the honest downgrade, not on a
            # "success" it cannot prove.
            assert _ends(host, human_id)[-1]["outcome"] == "interrupted"
            assert (
                _ends(host, human_id)[-1]["metadata"]["terminalReason"]
                == STALE_COMPLETION_REASON
            )
            runner = runtime._turns.runner
            assert runner.foreign_terminal_frames == 1
            assert runner.stale_completion_downgrades == 1
            assert host.session_state_updates[-1]["status"] == "idle"
            assert session.execution is None
            assert connection.current is None
            assert connection.pending is None
        finally:
            await runtime.stop()

    asyncio.run(run())
