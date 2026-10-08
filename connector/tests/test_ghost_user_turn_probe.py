"""Investigation probes: can a human turn's `pending` take over the reader?

Written for the sess_5pfVojtk-2Adhw investigation (2026-10-07). The probes
found the ghost-user-turn defect; P2/P3 now pin the FIXED behavior (they
asserted the bug when they were written — see each test's note).

The question under test (all references are
`connector/runtimes/claude/sdk/connection.py` unless said otherwise):

  When a human message is submitted, `response_for()` registers the prompt's
  `ClaudeResponse` in `connection.pending`. The reader promotes `pending` to
  `current` inside `if self.current is None:`, under the condition that used
  to accept only `failed` terminals (L1087-1097) — so a first frame that was
  not the echo and not a failure fell through to the mint branch, cast a
  ghost, and starved the human turn. Both halves are now closed by the
  ghost-user-turn fix: the pending clause takes ANY terminal, and the mint
  branch refuses to cast while a pending is registered, routing the frame
  into the pending instead.

  Probes:
  P1  normal flow  — does the prompt echo (matching uuid) select the pending?
  P2  echo mismatch — what happens when the replay uuid != pending.user_id?
      (fix: the mismatched echo is routed to the pending, not cast)
  P3  frame before echo — what happens when any other frame reaches silence
      while the pending is registered (the "leftover frame" shape)?
      (fix: routed to the pending, not cast)
  P4  ghost live — can a human turn even start while a minted ghost holds the
      execution lock? (still yes — the run_when_idle ghost shape; a separate
      question from this fix)
  P5  ghost force-failed with retirement skipped — is `current` left behind?
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from connector.runtimes.claude.sdk.connection import ClaudeConnection
from connector.runtimes.claude.turns import lifecycle
from test_claude_background_guard import WIRE_TASK_STARTED, _parse
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import (
    AssistantMessage,
    UserMessage,
    _RecordingHost,
    _ScheduledClaudeClient,
)


class _SelectSpy:
    """Record every `select_response` with the question's classification."""

    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []
        self._original = ClaudeConnection.select_response

    async def __aenter__(self) -> "_SelectSpy":
        spy = self

        async def wrapper(self: ClaudeConnection, response: Any) -> None:
            spy.events.append(
                {
                    "user_id": response.user_id,
                    "prompt_uuid": response.prompt_uuid,
                    "from_pending": self.pending is response,
                    "cast": response.cast_frame is not None,
                    "execution": response.execution is not None,
                    "maintenance": response.maintenance,
                }
            )
            await spy._original(self, response)

        ClaudeConnection.select_response = wrapper  # type: ignore[method-assign]
        return self

    async def __aexit__(self, *_: Any) -> None:
        ClaudeConnection.select_response = self._original  # type: ignore[method-assign]

    def selections(self) -> list[dict[str, Any]]:
        return [e for e in self.events if not e["maintenance"]]

    def promotions(self) -> list[dict[str, Any]]:
        # Turn promotions only. The connector's own maintenance responses
        # (the context-window calibration, task reconciliation) are registered
        # through `response_for` too — one event each, `maintenance` true and
        # no execution — and they are not promotions of a user's prompt.
        return [
            e
            for e in self.events
            if e["execution"] is True and not e["cast"]
        ]

    def mints(self) -> list[dict[str, Any]]:
        return [e for e in self.events if e["cast"]]


class _RecordingEchoClient(_ScheduledClaudeClient):
    """Normal client: records every envelope uuid, echoes it back verbatim."""

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            await self.incoming.put(
                UserMessage(uuid=message["uuid"], content=content)
            )
        await self._complete_query(content)


def _turn_id_of(result: Any) -> str:
    return result.result["turnId"]


def _ends_for(host: _RecordingHost, turn_id: str) -> list[dict[str, Any]]:
    return [e for e in host.session_turn_ends if e["turn_id"] == turn_id]


# --------------------------------------------------------------------------
# P1 — normal flow: the prompt echo selects the pending
# --------------------------------------------------------------------------


def test_p1_echo_with_matching_uuid_promotes_pending() -> None:
    async def run() -> None:
        client = _RecordingEchoClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            async with _SelectSpy() as spy:
                # Turn 1 on a fresh transport: `response_for` leaves user_id
                # None (retained/queried both false) — the no-wire-uuid branch.
                first = await runtime.start_turn("probe", None, "hello")
                session = runtime._sessions["probe"]
                await asyncio.wait_for(session.active_task, 5)
                first_id = _turn_id_of(first)

                # Turn 2 on the used transport: queried is set, so
                # `response_for` assigns a wire uuid and `ensure_prompt_uuid`
                # reuses it for the envelope.
                second = await runtime.start_turn("probe", "native_timer", "again")
                await asyncio.wait_for(session.active_task, 5)
                second_id = _turn_id_of(second)

            assert len(client.prompt_uuids) == 2
            assert _ends_for(host, first_id)[-1]["outcome"] == "completed"
            assert _ends_for(host, second_id)[-1]["outcome"] == "completed"

            promotions = spy.promotions()
            print("P1 SELECT EVENTS:", spy.events)
            print("P1 ENVELOPE UUIDS:", client.prompt_uuids)
            # Turn 1: no wire uuid — the echo (or any frame) promotes it.
            assert promotions[0]["user_id"] is None
            # Turn 2: the promotion carries the SAME uuid the envelope sent.
            assert promotions[1]["user_id"] == client.prompt_uuids[1], (
                "pending.user_id must equal the uuid carried by the envelope"
            )
            # No ghost was minted for either turn.
            assert spy.mints() == []
            connection = runtime._turns.runner.connections["probe"]
            assert connection.absorbed_terminal_frames == 0
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# P2 — replay uuid differs from pending.user_id
# --------------------------------------------------------------------------


class _WrongEchoClient(_ScheduledClaudeClient):
    """Replays the prompt with a uuid the connector never sent."""

    echo_uuid: str | None = None

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            await self.incoming.put(
                UserMessage(uuid=self.echo_uuid or message["uuid"], content=content)
            )
        await self._complete_query(content)


def test_p2_mismatched_echo_is_routed_to_the_pending() -> None:
    """FIXED behavior (2026-10-07). This probe used to assert the bug:
    the mismatched echo minted a ghost (cast, execution None), the human's
    pending was never promoted, and `session.active_task` never settled.

    With the ghost-user-turn fix the same frame is routed to the pending by
    the mint-branch hard gate, the human turn consumes its own reply and
    settles `completed`, and no ghost is cast."""

    async def run() -> None:
        client = _WrongEchoClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("probe", None, "hello")
            session = runtime._sessions["probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends_for(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.echo_uuid = "cli-replayed-wrong-uuid"
            async with _SelectSpy() as spy:
                second = await runtime.start_turn("probe", "native_timer", "again")
                human_id = _turn_id_of(second)
                await asyncio.wait_for(session.active_task, 5)

            sent_uuid = client.prompt_uuids[-1]
            assert sent_uuid != "cli-replayed-wrong-uuid"

            print("HUMAN TURN ID:", human_id)
            print("SELECT EVENTS:", spy.events)
            print(
                "TURN ENDS:",
                [(e["turn_id"], e["outcome"]) for e in host.session_turn_ends],
            )
            print(
                "ASSISTANT ITEMS:",
                [
                    (
                        i.turn_id,
                        "HUMAN" if i.turn_id == human_id else "OTHER",
                        str(i.content.get("text"))[:40],
                    )
                    for i in host.timeline_item_upserts
                    if i.role == "assistant"
                ],
            )
            # No ghost was cast: the mismatched echo selected the pending.
            assert spy.mints() == []
            # The human turn settled (`active_task` awaited above), and its
            # OWN reply is in its own turn.
            assert session.execution is None
            assert _ends_for(host, human_id)[-1]["outcome"] == "completed"
            assert any(
                i.turn_id == human_id
                and i.role == "assistant"
                and "reply:again" in str(i.content.get("text"))
                for i in host.timeline_item_upserts
            )
            # No OTHER turn consumed the human's reply (turn 1's own
            # "reply:hello" belongs to turn 1 and is expected).
            assert not any(
                i.turn_id != human_id
                and i.role == "assistant"
                and "reply:again" in str(i.content.get("text"))
                for i in host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# P3 — some other frame reaches silence before the echo
# --------------------------------------------------------------------------


class _AssistantBeforeEchoClient(_ScheduledClaudeClient):
    """A leftover main-agent frame arrives ahead of the prompt echo."""

    delay_echo = False

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            if self.delay_echo:
                await self.incoming.put(
                    AssistantMessage(
                        uuid="leftover-frame",
                        session_id=self.native_id,
                        content=[{"type": "text", "text": "leftover output"}],
                    )
                )
                await asyncio.sleep(0.2)
            await self.incoming.put(
                UserMessage(uuid=message["uuid"], content=content)
            )
            await self.reply(f"reply:{content}")


def test_p3_frame_before_echo_is_routed_and_the_human_answers() -> None:
    """FIXED behavior (2026-10-07). This probe used to assert the bug: the
    leftover frame at silence minted a ghost even though a human prompt was
    registered, the human's echo and reply were consumed by the ghost, and
    the human turn never settled.

    With the ghost-user-turn fix the mint branch routes the frame into the
    pending instead of casting, so the human turn owns its reply and settles
    `completed`."""

    async def run() -> None:
        client = _AssistantBeforeEchoClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("probe", None, "hello")
            session = runtime._sessions["probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends_for(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.delay_echo = True
            async with _SelectSpy() as spy:
                second = await runtime.start_turn("probe", "native_timer", "again")
                human_id = _turn_id_of(second)
                await asyncio.wait_for(session.active_task, 5)

            print("HUMAN TURN ID:", human_id)
            print("SELECT EVENTS:", spy.events)
            print(
                "TURN ENDS:",
                [(e["turn_id"], e["outcome"]) for e in host.session_turn_ends],
            )
            print(
                "ASSISTANT ITEMS:",
                [
                    (
                        i.turn_id,
                        "HUMAN" if i.turn_id == human_id else "OTHER",
                        str(i.content.get("text"))[:40],
                    )
                    for i in host.timeline_item_upserts
                    if i.role == "assistant"
                ],
            )
            # No ghost: the leftover frame was routed into the pending turn.
            assert spy.mints() == []
            assert session.execution is None
            assert _ends_for(host, human_id)[-1]["outcome"] == "completed"
            # The human's OWN reply is in its own turn, not in a ghost's.
            assert any(
                i.turn_id == human_id
                and i.role == "assistant"
                and "reply:again" in str(i.content.get("text"))
                for i in host.timeline_item_upserts
            )
            assert not any(
                i.turn_id != human_id
                and i.role == "assistant"
                and "reply:again" in str(i.content.get("text"))
                for i in host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# P4 — a live ghost blocks the human turn at the door
# --------------------------------------------------------------------------


def test_p4_live_ghost_rejects_human_turn() -> None:
    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("probe", None, "hello")
            session = runtime._sessions["probe"]
            await asyncio.wait_for(session.active_task, 5)

            # A stray main-agent frame at silence mints a scheduled ghost.
            await client.incoming.put(
                AssistantMessage(
                    uuid="stray-wake",
                    session_id="native_timer",
                    content=[{"type": "text", "text": "stray wake"}],
                )
            )
            await _wait_until(lambda: session.execution is not None)
            ghost_id = session.execution.turn_id

            result = await runtime.start_turn("probe", "native_timer", "after")
            print("HUMAN START RESULT:", result.ok, result.code)
            assert result.ok is False
            assert result.code == "claude_turn_already_running"
            assert session.execution.turn_id == ghost_id
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# P5 — ghost force-failed, retirement skipped: is `current` left behind?
# --------------------------------------------------------------------------


@pytest.fixture()
def _short_watchdog(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(lifecycle, "POLLED_TURN_WATCHDOG_SECONDS", 0.2)
    monkeypatch.setattr(lifecycle, "CONTENTING_TURN_WATCHDOG_SECONDS", 0.4)


def test_p5_skipped_retirement_clears_current_then_human_turn_works(
    _short_watchdog: None,
) -> None:
    async def run() -> None:
        client = _ScheduledClaudeClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("probe", None, "hello")
            session = runtime._sessions["probe"]
            await asyncio.wait_for(session.active_task, 5)

            # Background work goes live, then a stray frame mints a ghost.
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            connection = runtime._turns.runner.connections["probe"]
            await _wait_until(lambda: bool(connection.background.active_ids))
            await client.incoming.put(
                AssistantMessage(
                    uuid="stray-wake",
                    session_id="native_timer",
                    content=[{"type": "text", "text": "stray wake"}],
                )
            )
            await _wait_until(lambda: session.execution is not None)
            ghost_id = session.execution.turn_id
            await _wait_until(lambda: bool(_ends_for(host, ghost_id)))
            await _wait_until(lambda: session.execution is None)
            await asyncio.sleep(0.05)

            # The residual check: after the skipped retirement the reader must
            # be back at silence with no response parked on `current`.
            print(
                "after ghost: current=%(c)s pending=%(p)s background=%(b)s"
                % {
                    "c": connection.current is not None,
                    "p": connection.pending is not None,
                    "b": bool(connection.background.active_ids),
                }
            )
            assert connection.current is None, "current slot must be free"
            assert connection.pending is None

            result = await runtime.start_turn("probe", "native_timer", "after")
            human_id = _turn_id_of(result)
            await asyncio.wait_for(session.active_task, 5)
            assert _ends_for(host, human_id)[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())
