"""Ghost-user-turn D1 (2026-10-07): a stop's late tail must not settle the next turn.

The regression the red team caught in the first cut of the ghost-user-turn fix
(`runtimes/claude/sdk/connection.py`, the pending-selection clause): that cut
routed ANY terminal frame into a registered pending. A user stops a turn, the
CLI's `aborted_streaming` / `aborted_tools` tail frames — an `interrupted`
terminal — are still in flight, and the user immediately re-sends. The new
prompt registers a fresh `pending` UNDER that tail, the tail was routed into
it, and `drive_turn`'s F1 decline guard covers `completed` only — `interrupted`
is a deliberate settle-immediately verdict — so the FRESH turn settled
`interrupted` ("this round produced nothing") before it produced anything,
while its real reply landed in a cast phantom turn behind it.

The fix restores the conservative rule: the pending terminal leg accepts
`completed` (only when the session hosts no unsolicited work, where `drive_turn`
can decline it via F1) and `failed` (unconditional — the queued-prompt red
line). `interrupted` never routes; an `interrupted` tail at silence is
ABSORBED, exactly as before the fix, because nothing here depends on it — the
pending's OWN interrupt is settled by the stop path that produced it
(`interrupt_session` on the live execution), not by this clause.

This file is the red-team attack `test_rt_a1` (from the now-deleted
`test_zz_rt_ghost_attacks.py`) converted into a positive nail: same wire, fixed
expectations — the tail is absorbed, the human turn completes with its own
reply, and no phantom turn exists.
"""

from __future__ import annotations

import asyncio
from typing import Any

from claude_agent_sdk import UserMessage
from test_claude_background_guard import _parse
from test_claude_compact_ghost import _runtime_with, _single_client_factory
from test_claude_runtime import (
    _RecordingHost,
    _ScheduledClaudeClient,
)
from test_claude_stale_frame_turn import ABORTED_TAIL


class _TailFirstClient(_ScheduledClaudeClient):
    """A stopped round's tail is still on the wire when the next turn starts.

    The wire order `[tail, echo, reply, result]` is the stop-and-resend shape:
    the previous round settled (as a stop settles), its `interrupted` terminal
    has not left the stream yet, and the human's next prompt is already
    registered when it lands.
    """

    armed = False
    residual: dict[str, Any] | None = None

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            await super().query(prompt)
            return
        content = ""
        async for message in prompt:
            content = message["message"]["content"]
            self.prompt_uuids.append(message["uuid"])
            if self.armed and self.residual is not None:
                await self.incoming.put(_parse(self.residual))
            await self.incoming.put(
                UserMessage(uuid=message["uuid"], content=content)
            )
        await self._complete_query(content)


def _turn_id_of(result: Any) -> str:
    return result.result["turnId"]


def _ends(host: _RecordingHost, turn_id: str) -> list[dict[str, Any]]:
    return [e for e in host.session_turn_ends if e["turn_id"] == turn_id]


def test_late_aborted_tail_is_absorbed_and_the_next_turn_completes() -> None:
    """修前红（D1 攻击复现）/ 修后绿: the tail is dropped, the human answers."""

    async def run() -> None:
        client = _TailFirstClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            first = await runtime.start_turn("ghost_tail", None, "hello")
            session = runtime._sessions["ghost_tail"]
            await asyncio.wait_for(session.active_task, 5)
            assert _ends(host, _turn_id_of(first))[-1]["outcome"] == "completed"

            client.armed = True
            client.residual = ABORTED_TAIL
            second = await runtime.start_turn(
                "ghost_tail", client.native_id, "again"
            )
            human_id = _turn_id_of(second)
            await asyncio.wait_for(session.active_task, 5)
            # A phantom cast would surface within microseconds of the settle;
            # give one room to appear if it ever does.
            await asyncio.sleep(0.2)

            connection = runtime._turns.runner.connections["ghost_tail"]
            runner = runtime._turns.runner
            # 1. The tail was ABSORBED at silence — not routed into the fresh
            #    turn (the D1 regression) and not cast into a phantom.
            assert connection.absorbed_terminal_frames == 1
            assert connection.absorbed_terminal_by_status == {"interrupted": 1}
            # 2. The fresh turn was never handed the tail's verdict: it is
            #    `completed` on its own result, not "interrupted / produced
            #    nothing", and the tail never reached a turn at all.
            assert _ends(host, human_id)[-1]["outcome"] == "completed"
            assert runner.foreign_terminal_frames == 0
            assert runner.stale_completion_downgrades == 0
            # 3. The human turn received its own reply...
            texts = [
                (item.turn_id, str(item.content.get("text", "")))
                for item in host.timeline_item_upserts
                if item.role == "assistant"
            ]
            assert (human_id, "reply:again") in texts
            # 4. ...and there is no phantom turn holding the answer instead:
            #    exactly the first round and the human's, nothing behind them.
            assert not any(
                turn_id != human_id and text == "reply:again"
                for turn_id, text in texts
            )
            assert [e["turn_id"] for e in host.session_turn_ends] == [
                _turn_id_of(first),
                human_id,
            ]
            assert session.execution is None
            assert connection.current is None
            assert connection.pending is None
        finally:
            await runtime.stop()

    asyncio.run(run())
