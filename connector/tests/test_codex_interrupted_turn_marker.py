"""Codex's durable "this turn was stopped" fact (pp 2026-11-14).

Codex already persists each turn's status and emits ``turn/interrupted`` on
the wire, but neither names a row the chat can hang the interrupted-response
notice under. This pins the projection's one addition: the stopped turn's
last main row carries ``content.turnInterrupted``, in both history and the
live settle, so another device or a relaunch reads the same fact.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from openai_codex.generated.v2_all import TurnStatus
from test_codex_runtime import FakeCodexClient, FakeHost, _config

from connector.runtimes.codex.runtime import CodexRuntime
from connector.runtimes.codex.timeline.accumulator import CodexTimelineAccumulator
from connector.runtimes.codex.timeline.interrupts import (
    interrupted_turn_ids_from_thread,
)

INTERRUPTED = "turnInterrupted"


def _items_with_flag(items: tuple[Any, ...]) -> list[Any]:
    return [item for item in items if item.content.get(INTERRUPTED) is True]


def test_raw_history_stamps_the_stopped_turns_last_main_row() -> None:
    accumulator = CodexTimelineAccumulator()
    items = accumulator.items_from_thread_snapshot(
        session_id="sess_1",
        external_session_id="thread_1",
        thread={
            "turns": [
                {
                    "id": "turn_done",
                    "status": "completed",
                    "items": [{"id": "done_message", "type": "agentMessage", "text": "ok"}],
                },
                {
                    "id": "turn_stopped",
                    "status": "interrupted",
                    "items": [
                        {
                            "id": "running_command",
                            "type": "commandExecution",
                            "command": "sleep 30",
                            "status": "inProgress",
                        }
                    ],
                },
            ]
        },
        limit=None,
    )

    flagged = _items_with_flag(items)
    assert len(flagged) == 1
    assert flagged[0].turn_id == "turn_stopped"
    assert flagged[0].type == "tool"


def test_typed_status_rows_are_recognized() -> None:
    thread = SimpleNamespace(
        turns=[
            SimpleNamespace(id="turn_done", status=TurnStatus.completed),
            SimpleNamespace(id="turn_stopped", status=TurnStatus.interrupted),
        ]
    )
    assert interrupted_turn_ids_from_thread(thread) == {"turn_stopped"}


def test_completed_history_has_no_interrupted_flag() -> None:
    accumulator = CodexTimelineAccumulator()
    items = accumulator.items_from_thread_snapshot(
        session_id="sess_1",
        external_session_id="thread_1",
        thread={
            "turns": [
                {
                    "id": "turn_done",
                    "status": "completed",
                    "items": [{"id": "done_message", "type": "agentMessage", "text": "ok"}],
                }
            ]
        },
        limit=None,
    )
    assert _items_with_flag(items) == []


def test_live_interrupt_stamps_before_the_turn_is_released() -> None:
    async def run() -> None:
        host = FakeHost()
        runtime = CodexRuntime(
            config=_config(), host=host, client=FakeCodexClient()
        )
        try:
            await runtime._handle_notification(
                {
                    "method": "turn/started",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_live",
                    },
                }
            )
            await runtime._handle_notification(
                {
                    "method": "item/started",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_live",
                        "item": {
                            "id": "live_message",
                            "type": "agentMessage",
                            "role": "assistant",
                            "status": "inProgress",
                            "text": "partial answer",
                        },
                    },
                }
            )
            await runtime._handle_notification(
                {
                    "method": "turn/interrupted",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_live",
                    },
                }
            )

            flagged = _items_with_flag(tuple(host.timeline_item_upserts))
            assert len(flagged) == 1
            assert flagged[0].turn_id == "turn_live"
            assert flagged[0].id == host.timeline_item_upserts[0].id
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_live_completion_does_not_stamp() -> None:
    async def run() -> None:
        host = FakeHost()
        runtime = CodexRuntime(
            config=_config(), host=host, client=FakeCodexClient()
        )
        try:
            await runtime._handle_notification(
                {
                    "method": "turn/started",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_done",
                    },
                }
            )
            await runtime._handle_notification(
                {
                    "method": "item/started",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_done",
                        "item": {
                            "id": "done_message",
                            "type": "agentMessage",
                            "role": "assistant",
                            "status": "inProgress",
                            "text": "answer",
                        },
                    },
                }
            )
            await runtime._handle_notification(
                {
                    "method": "turn/completed",
                    "params": {
                        "platformSessionId": "sess_1",
                        "threadId": "thread_1",
                        "turnId": "turn_done",
                    },
                }
            )
            assert _items_with_flag(tuple(host.timeline_item_upserts)) == []
        finally:
            await runtime.stop()

    asyncio.run(run())
