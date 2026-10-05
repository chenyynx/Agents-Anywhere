"""SubAgent progress display — connector data plane (L2, 2026-10-03).

Why this file exists
--------------------
L1 (``test_claude_background_guard.py``) made a background subagent survive
its dispatch reply; L2 makes it visible. The connector half of that is this
data plane (``.local-dev/claude-subagent-progress-tasks.md`` §3.4):

* parented subagent frames that reached silence — previously dropped by the
  L1 guard — are captured and projected through the shared
  ``ClaudeMessageProjector``, so their rows converge with the in-turn
  projection and the history rebuild;
* ordinary tool rows minted from those frames carry ``content.parentItemId``
  back to the Agent call card they belong to;
* the four task frames (started/progress/updated/notification) fold into the
  single card the dispatch minted: task↔card binding, an ``agents`` map,
  usage/last-tool updates, and one idempotent terminal closure carrying the
  subagent's verbatim final reply;
* the async launch receipt no longer lands the card "done" — the task is
  still running, and only task events finish it.

L1 invariants are re-pinned on the integrated path: captured frames still
mint no turn, and nothing on either route can take the transport down.

Wire payloads are parsed through the SDK's own ``parse_message``. They are
taken from ``.local-dev/recon/fixtures/task-*.json`` and the run1 dump
(``raw/session-20261003-l2a1-multitool.jsonl``), with the multi-kB
prompt/receipt bodies elided (shape untouched; elisions marked). The one
frame with no capture at all — a foreground (sync) Agent receipt — is
modelled on the real async receipt and labelled synthetic, exactly like the
wake frames in the L1 file.
"""

from __future__ import annotations

import asyncio
from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import (
    _FakeClaudeClient,
    _RecordingHost,
    _ScheduledClaudeClient,
)

from connector.runtime_protocol import AgentCallToolContent
from connector.runtime_protocol.timeline import timeline_content_hash
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import task_event_from_message
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
    agent_task_overlay_for_event,
    has_live_agent_tasks,
    is_async_agent_receipt,
    resolve_agent_card_status,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)
from connector.runtimes.claude.turns.lifecycle import (
    _parent_tool_use_id,
    _with_parent_card,
    _with_parent_cards,
)

SESSION = "c94c9a5a-649d-4bda-9010-1c4ee4eb7a6a"
DISPATCH_TUID = "call_00_XoYK7wc5ZhStczBBGCdE0574"
TASK_ID = "af869d8d7ce9675fd"
SUBAGENT_WRITE_TUID = "call_00_2PxecC16FBn9lY3k6r1G7734"
LOCAL_BASH_TUID = "call_00_6tFC5WwgqGk8bj1RwQ9t1891"

# --------------------------------------------------------------------------
# Verbatim wire payloads (shape untouched; long bodies elided and marked)
# --------------------------------------------------------------------------

# Main agent's Agent dispatch (run1 L485). Note there is no subagent_type key
# in the input — the CLI resolves it to general-purpose, which only the task
# data (below) knows.
WIRE_DISPATCH_TOOL_USE = {
    "type": "assistant",
    "message": {
        "id": "73551c87-301d-42f2-95eb-d469afa922f5",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "stop_sequence": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "tool_use",
                "id": DISPATCH_TUID,
                "name": "Agent",
                "input": {
                    "description": "Multi-tool file audit",
                    "run_in_background": True,
                    "prompt": (
                        "Work ONLY inside the directory .../run1/work. ... "
                        "(7-step audit prompt, elided)"
                    ),
                },
            }
        ],
        "usage": {
            "input_tokens": 7994,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 15232,
        },
        "context_management": None,
    },
    "parent_tool_use_id": None,
    "session_id": SESSION,
    "uuid": "35b60804-1dc0-4eb9-95fa-8a17b83298f7",
    "timestamp": "2026-10-03T03:10:43.954Z",
}

# The async launch receipt (run1 L491): metadata only, isAsync=true.
WIRE_DISPATCH_RECEIPT = {
    "type": "user",
    "message": {
        "role": "user",
        "content": [
            {
                "tool_use_id": DISPATCH_TUID,
                "type": "tool_result",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Async agent launched successfully. (This tool "
                            "result is internal metadata — never quote or "
                            "paste any part of it ...) (receipt body, elided)"
                        ),
                    }
                ],
            }
        ],
    },
    "parent_tool_use_id": None,
    "session_id": SESSION,
    "uuid": "0569f444-868f-4f2c-ab64-8696a86e89da",
    "timestamp": "2026-10-03T03:10:44.142Z",
    "tool_use_result": {
        "isAsync": True,
        "status": "async_launched",
        "agentId": TASK_ID,
        "description": "Multi-tool file audit",
        "resolvedModel": "deepseek-v4.1-flash",
        "prompt": "Work ONLY inside the directory ... (elided)",
        "output_file": (
            "/tmp/claude-1001/-home-ubuntu-aa-test-l2-a1-recon-run1/"
            f"{SESSION}/tasks/{TASK_ID}.output"
        ),
        "canReadOutputFile": True,
    },
}

# task_started (run1 L490): the binding frame. is_backgrounded /
# subagent_type / prompt / spawn_depth live only in `.data` on the SDK class.
WIRE_TASK_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": TASK_ID,
    "tool_use_id": DISPATCH_TUID,
    "description": "Multi-tool file audit",
    "subagent_type": "general-purpose",
    "is_backgrounded": True,
    "spawn_depth": 1,
    "task_type": "local_agent",
    "prompt": (
        "Work ONLY inside the directory .../run1/work. ... "
        "(7-step audit prompt, elided)"
    ),
    "uuid": "87c950d7-2ad1-45be-8b5c-029b95844494",
    "session_id": SESSION,
}

# first task_progress (run1 L511): one per tool start, 1-15 ms behind the
# tool_use frame (findings §3.1 — not a heartbeat).
WIRE_TASK_PROGRESS_FIRST = {
    "type": "system",
    "subtype": "task_progress",
    "task_id": TASK_ID,
    "tool_use_id": DISPATCH_TUID,
    "description": "Writing work/alpha.txt",
    "subagent_type": "general-purpose",
    "usage": {"total_tokens": 31981, "tool_uses": 1, "duration_ms": 4858},
    "last_tool_name": "Write",
    "uuid": "8a5410a8-1800-4191-8277-cf41c0afada2",
    "session_id": SESSION,
}

# last task_progress (run1 L541): tool 7 of 7.
WIRE_TASK_PROGRESS_LAST = {
    "type": "system",
    "subtype": "task_progress",
    "task_id": TASK_ID,
    "tool_use_id": DISPATCH_TUID,
    "description": "Counting lines",
    "subagent_type": "general-purpose",
    "usage": {"total_tokens": 33555, "tool_uses": 7, "duration_ms": 24723},
    "last_tool_name": "Bash",
    "uuid": "db091d7e-90e0-4d69-a20d-28b29bfd2b0a",
    "session_id": SESSION,
}

# task_updated (run1 L546): no tool_use_id at all — the card is found through
# the task_started binding.
WIRE_TASK_UPDATED = {
    "type": "system",
    "subtype": "task_updated",
    "task_id": TASK_ID,
    "patch": {"status": "completed", "end_time": 1790997071652},
    "uuid": "95ee3944-1675-45ba-9203-f0e4266cea34",
    "session_id": SESSION,
}

# task_notification (run1 L547): summary is the subagent's verbatim final
# reply (findings §3.3).
WIRE_TASK_NOTIFICATION = {
    "type": "system",
    "subtype": "task_notification",
    "task_id": TASK_ID,
    "tool_use_id": DISPATCH_TUID,
    "status": "completed",
    "output_file": f"/tmp/claude-1001/.../{TASK_ID}.output",
    "summary": "AUDIT DONE: 3 files, 7 tool calls",
    "usage": {"total_tokens": 33823, "tool_uses": 7, "duration_ms": 27571},
    "uuid": "b555c02d-5ec8-493b-9a63-454c9a8298a7",
    "session_id": SESSION,
}

# Subagent frames (run1 L508-L512), all parented to the dispatch call and all
# arriving at silence in the real session.
WIRE_SUBAGENT_THINKING = {
    "type": "assistant",
    "message": {
        "id": "d4c233f5-54f3-481c-bb1e-576888a3f4c3",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "thinking",
                "thinking": (
                    "The user wants me to do exactly these tool calls ... "
                    "(thinking body, elided)"
                ),
                "signature": "d4c233f5",
            }
        ],
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "d4c233f5-54f3-481c-bb1e-576888a3f4c3",
    "timestamp": "2026-10-03T03:10:48.600Z",
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

WIRE_SUBAGENT_TEXT = {
    "type": "assistant",
    "message": {
        "id": "d4c233f5-54f3-481c-bb1e-576888a3f4c3",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "text",
                "text": (
                    "I'll execute the steps in order. Note: no dedicated "
                    "Grep tool is available in this environment, so step 6 "
                    "uses Bash grep equivalently.\n\nStep 1."
                ),
            }
        ],
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "ddb3de29-400f-4f76-ba16-5409a36e20d0",
    "timestamp": "2026-10-03T03:10:48.755Z",
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

WIRE_SUBAGENT_TOOL_USE_WRITE = {
    "type": "assistant",
    "message": {
        "id": "d4c233f5-54f3-481c-bb1e-576888a3f4c3",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "tool_use",
                "id": SUBAGENT_WRITE_TUID,
                "name": "Write",
                "input": {
                    "file_path": ".../run1/work/alpha.txt",
                    "content": "alpha line one\nalpha line two\n",
                },
            }
        ],
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "58984891-77b8-4ef5-8f38-23bd79fbb1d5",
    "timestamp": "2026-10-03T03:10:48.933Z",
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

WIRE_SUBAGENT_TOOL_RESULT_WRITE = {
    "type": "user",
    "message": {
        "role": "user",
        "content": [
            {
                "tool_use_id": SUBAGENT_WRITE_TUID,
                "type": "tool_result",
                "content": (
                    "File created successfully at: .../run1/work/alpha.txt"
                ),
            }
        ],
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "a8456c10-fd35-4e77-a7a8-29ffafd6db8c",
    "timestamp": "2026-10-03T03:10:49.020Z",
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

# local_bash tasks (session-20261002-2323 L553/L554): owned_by_subagent, and
# their tool_use_id points *inside* the subagent (at its own Bash call) — the
# exact frames L2 must never attach to a card (findings §8.11). The three
# frames' native session_id is aligned to SESSION so the scenario stays one
# session; every other field is verbatim.
WIRE_LOCAL_BASH_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": "bpf6nx6cs",
    "owned_by_subagent": True,
    "tool_use_id": LOCAL_BASH_TUID,
    "description": "Wait 25 seconds",
    "is_backgrounded": False,
    "task_type": "local_bash",
    "uuid": "6e385240-d3a6-4256-986a-026450a582ea",
    "session_id": SESSION,
}

WIRE_LOCAL_BASH_NOTIFICATION = {
    "type": "system",
    "subtype": "task_notification",
    "task_id": "bpf6nx6cs",
    "tool_use_id": LOCAL_BASH_TUID,
    "status": "completed",
    "output_file": "",
    "summary": "Wait 25 seconds",
    "uuid": "52cedd41-cff0-4754-9010-0d22e65b6ddf",
    "session_id": SESSION,
}

# The subagent's own Bash call that the local_bash task above wraps (2323
# L537/L555) — captured at silence it projects as a card of its own, which
# the local_bash frames must not touch.
WIRE_SUBAGENT_TOOL_USE_BASH = {
    "type": "assistant",
    "message": {
        "id": "068e32d1-3dd9-4249-b508-7c5f044a6d4f",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "tool_use",
                "id": LOCAL_BASH_TUID,
                "name": "Bash",
                "input": {"command": "sleep 25", "description": "Wait 25 seconds"},
            }
        ],
    },
    "parent_tool_use_id": "call_01_0nlz6gJGgoVqb7lfwu8u8686",
    "session_id": SESSION,
    "uuid": "7c4e74a2-5c13-4da9-91ac-0e4158c0ef2a",
    "timestamp": "2026-10-02T23:23:32.951Z",
    "subagent_type": "general-purpose",
    "task_description": "Sleep 25 then reply DONE-B",
}

# Synthetic main-agent narration (parent_tool_use_id=None): the recon
# sessions' main agent only ever dispatched agents, so these model the CLI's
# own reply frames on the verified shape — labelled synthetic like
# WIRE_MAIN_RESULT.
WIRE_MAIN_AGENT_THINKING = {
    "type": "assistant",
    "message": {
        "id": "main-reply-1",
        "type": "message",
        "role": "assistant",
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "thinking",
                "thinking": "Checking the workspace first.",
                "signature": "main-reply-1",
            }
        ],
    },
    "parent_tool_use_id": None,
    "session_id": SESSION,
    "uuid": "main-reply-1",
}

WIRE_MAIN_AGENT_TEXT = {
    "type": "assistant",
    "message": {
        "id": "main-reply-1",
        "type": "message",
        "role": "assistant",
        "model": "deepseek-v4.1-flash",
        "content": [{"type": "text", "text": "Checking the workspace now."}],
    },
    "parent_tool_use_id": None,
    "session_id": SESSION,
    "uuid": "main-reply-2",
}

# The dispatch turn's own end (synthetic shape, same as the L1 file's result
# frames — the live turn path produces no captureable fixture of its own).
WIRE_MAIN_RESULT = {
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

# Synthetic, not a capture: every Agent receipt in the recon sessions is
# async (background is the CLI default), so the foreground shape is modelled
# on the real one with isAsync/status flipped — a sync call's receipt *is*
# the outcome.
SYNTHETIC_SYNC_RECEIPT = {
    **WIRE_DISPATCH_RECEIPT,
    "uuid": "sync-receipt-1",
    "tool_use_result": {
        "isAsync": False,
        "status": "completed",
        "agentId": TASK_ID,
        "description": "Multi-tool file audit",
        "resolvedModel": "deepseek-v4.1-flash",
    },
}


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _session() -> ClaudeSession:
    return ClaudeSession(session_id="l2-subagent-progress", external_session_id=SESSION)


def _card_items(host: _RecordingHost, card_id: str) -> list[Any]:
    return [item for item in host.timeline_item_upserts if item.id == card_id]


def _card_agents(host: _RecordingHost, card_id: str) -> dict[str, Any]:
    card = _card_items(host, card_id)[-1]
    return dict(card.content.get("agents") or {})


def _nested_agent_status(item: Any) -> str | None:
    """The nested agent's status on one projected row.

    Read one key instead of comparing the whole entry: a task_started also
    carries subagentType/isBackgrounded/spawnDepth, and those are the event's
    business, not this fix's.
    """

    agents = dict(item.content.get("agents") or {})
    return str(agents.get(NESTED_TASK_ID, {}).get("status") or "") or None


class _DispatchClient(_ScheduledClaudeClient):
    """Replays the real run1 dispatch turn; idle frames are fed per test."""

    def __init__(self, receipt: dict[str, Any] = WIRE_DISPATCH_RECEIPT) -> None:
        super().__init__()
        self.receipt = receipt

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in (WIRE_DISPATCH_TOOL_USE, self.receipt, WIRE_MAIN_RESULT):
            await self.incoming.put(_parse(frame))


class _InTurnStartedClient(_DispatchClient):
    """The dispatch turn itself carries task_started (run1: L490 < result).

    The reader folds the event while the turn projection may not have minted
    the card yet — the order the two writers meet must not matter.
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        for frame in (
            WIRE_DISPATCH_TOOL_USE,
            WIRE_DISPATCH_RECEIPT,
            WIRE_TASK_STARTED,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


class _MainAgentReplyClient(_ScheduledClaudeClient):
    """A plain main-agent reply: thinking + text, no subagent at all."""

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        for frame in (
            WIRE_MAIN_AGENT_THINKING,
            WIRE_MAIN_AGENT_TEXT,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


async def _start_dispatch(runtime: Any) -> ClaudeSession:
    await runtime.start_turn("sub_progress", None, "hello")
    session: ClaudeSession = runtime._sessions["sub_progress"]
    await asyncio.wait_for(session.active_task, 5)
    return session


# --------------------------------------------------------------------------
# 1. task events fold into the card (started / progress / terminal)
# --------------------------------------------------------------------------


def test_task_started_binds_card_and_marks_running() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            # The async receipt already left the card running, not done.
            assert _card_items(host, card_id)[-1].status == "running"
            before = len(_card_items(host, card_id))

            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await _wait_until(
                lambda: "subagentType" in _card_agents(host, card_id).get(TASK_ID, {})
            )

            card = _card_items(host, card_id)[-1]
            assert len(_card_items(host, card_id)) == before + 1
            assert card.status == "running"
            # The double key: task_started.tool_use_id == card metadata
            # toolUseId; task_id == the receipt agentId (agents-map key).
            assert card.content["toolUseId"] == DISPATCH_TUID
            assert card.content["agentId"] == TASK_ID
            # subagent_type/is_backgrounded/spawn_depth exist only in .data.
            assert _card_agents(host, card_id)[TASK_ID] == {
                "status": "running",
                "subagentType": "general-purpose",
                "isBackgrounded": True,
                "spawnDepth": 1,
            }
            # The dispatch input never named the agent; the task data fills it.
            assert card.content["agentType"] == "general-purpose"
            # The dispatch input owns the prompt — the overlay never rewrites
            # a field the call already carried.
            assert card.content["prompt"] == WIRE_DISPATCH_TOOL_USE["message"][
                "content"
            ][0]["input"]["prompt"]
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_task_progress_updates_usage_and_last_tool() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_TASK_PROGRESS_FIRST))
            await client.incoming.put(_parse(WIRE_TASK_PROGRESS_LAST))
            await _wait_until(
                lambda: _card_agents(host, card_id)
                .get(TASK_ID, {})
                .get("lastToolName")
                == "Bash"
            )

            card = _card_items(host, card_id)[-1]
            assert card.status == "running"
            # Existing receipt key names (agent_calls._agent_call_usage).
            assert card.content["usage"] == {
                "durationMs": 24723,
                "tokens": 33555,
                "toolCalls": 7,
            }
            assert _card_agents(host, card_id)[TASK_ID]["lastToolName"] == "Bash"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_terminal_burst_closes_the_card_once_with_summary() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            for frame in (
                WIRE_TASK_STARTED,
                WIRE_TASK_PROGRESS_LAST,
                WIRE_TASK_UPDATED,
                WIRE_TASK_NOTIFICATION,
            ):
                await client.incoming.put(_parse(frame))
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "done"
            )

            # One card, one closure: once terminal the status never moves
            # (task_updated carries the end time, task_notification the
            # verbatim final reply — the burst merges into it).
            statuses = [item.status for item in _card_items(host, card_id)]
            terminal_at = [
                index
                for index, status in enumerate(statuses)
                if status in AGENT_CARD_TERMINAL_STATUSES
            ]
            assert terminal_at, "the burst must close the card"
            assert statuses[terminal_at[0] :] == ["done"] * len(
                statuses[terminal_at[0] :]
            )

            card = _card_items(host, card_id)[-1]
            assert card.content["summary"] == "AUDIT DONE: 3 files, 7 tool calls"
            assert card.content["endTime"] == 1790997071652
            # Usage is frozen at the notification's final snapshot.
            assert card.content["usage"] == {
                "durationMs": 27571,
                "tokens": 33823,
                "toolCalls": 7,
            }
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "completed"

            # A repeated terminal frame changes nothing and republishes
            # nothing — the pipeline's coalesce/dedup sits behind this, not a
            # second ledger of our own.
            published = len(_card_items(host, card_id))
            await client.incoming.put(_parse(WIRE_TASK_NOTIFICATION))
            await asyncio.sleep(0.05)
            assert len(_card_items(host, card_id)) == published
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_duplicate_progress_frame_republishes_nothing() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_TASK_PROGRESS_LAST))
            await _wait_until(
                lambda: _card_agents(host, card_id)
                .get(TASK_ID, {})
                .get("lastToolName")
                == "Bash"
            )
            published = len(_card_items(host, card_id))
            await client.incoming.put(_parse(WIRE_TASK_PROGRESS_LAST))
            await asyncio.sleep(0.05)
            assert len(_card_items(host, card_id)) == published
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_task_updated_carries_closure_through_the_task_started_binding() -> None:
    """task_updated has no tool_use_id; only the binding can find the card."""

    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_TASK_UPDATED))
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "done"
            )
            card = _card_items(host, card_id)[-1]
            assert card.content["endTime"] == 1790997071652
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_task_started_arriving_mid_turn_folds_without_rendering() -> None:
    """In-turn and idle task frames share the one observe point (findings §1)."""

    async def run() -> None:
        client = _InTurnStartedClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await _wait_until(
                lambda: "subagentType" in _card_agents(host, card_id).get(TASK_ID, {})
            )
            card = _card_items(host, card_id)[-1]
            assert card.content["toolUseId"] == DISPATCH_TUID
            assert card.status == "running"
            assert _card_agents(host, card_id)[TASK_ID]["subagentType"] == (
                "general-purpose"
            )
            # The task frame itself never becomes a timeline row of its own.
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.type == "system" and "task_started" in str(item.content)
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 2. local_bash never surfaces and never touches a card
# --------------------------------------------------------------------------


def test_local_bash_tasks_publish_nothing() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await _start_dispatch(runtime)
            published = len(host.timeline_item_upserts)

            await client.incoming.put(_parse(WIRE_LOCAL_BASH_STARTED))
            await client.incoming.put(_parse(WIRE_LOCAL_BASH_NOTIFICATION))
            await asyncio.sleep(0.05)

            assert len(host.timeline_item_upserts) == published
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_local_bash_never_attaches_to_the_bash_row_it_wraps() -> None:
    """The §8.11 trap: its tool_use_id points inside the subagent."""

    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            await client.incoming.put(_parse(WIRE_SUBAGENT_TOOL_USE_BASH))
            bash_row_id = stable_tool_item_id(session, LOCAL_BASH_TUID)
            await _wait_until(
                lambda: any(
                    item.id == bash_row_id for item in host.timeline_item_upserts
                )
            )
            published = len(host.timeline_item_upserts)

            await client.incoming.put(_parse(WIRE_LOCAL_BASH_STARTED))
            await client.incoming.put(_parse(WIRE_LOCAL_BASH_NOTIFICATION))
            await asyncio.sleep(0.05)

            assert len(host.timeline_item_upserts) == published
            row = [
                item
                for item in host.timeline_item_upserts
                if item.id == bash_row_id
            ][-1]
            assert "summary" not in row.content
            assert not row.content.get("agents")
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 3. the async receipt is not an outcome; the sync receipt still is
# --------------------------------------------------------------------------


def test_async_receipt_keeps_the_card_running() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            card = _card_items(host, card_id)[-1]
            assert card.status == "running", "async launch is not done"
            assert card.content["agents"] == {TASK_ID: {"status": "async_launched"}}
            assert card.content["output"].startswith("Async agent launched")
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_sync_agent_receipt_still_lands_done() -> None:
    async def run() -> None:
        client = _DispatchClient(receipt=SYNTHETIC_SYNC_RECEIPT)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            assert _card_items(host, card_id)[-1].status == "done"
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4. the capture route: rows at silence, parentItemId, still no new turns
# --------------------------------------------------------------------------


def test_idle_subagent_frames_project_as_rows_with_parent_item_id() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            turns_before = len(host.session_turn_ends)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)

            for frame in (
                WIRE_SUBAGENT_THINKING,
                WIRE_SUBAGENT_TEXT,
                WIRE_SUBAGENT_TOOL_USE_WRITE,
                WIRE_SUBAGENT_TOOL_RESULT_WRITE,
            ):
                await client.incoming.put(_parse(frame))

            tool_row_id = stable_tool_item_id(session, SUBAGENT_WRITE_TUID)
            await _wait_until(
                lambda: any(
                    item.id == tool_row_id and item.status == "done"
                    for item in host.timeline_item_upserts
                )
            )

            rows = [
                item for item in host.timeline_item_upserts if item.id == tool_row_id
            ]
            assert rows, "captured subagent tool row must be projected"
            assert rows[0].status == "running"
            assert rows[-1].status == "done"
            # The L2 backfill: the row points at the Agent card it belongs to.
            assert rows[0].content["parentItemId"] == card_id
            assert rows[-1].content["parentItemId"] == card_id
            assert rows[0].content["kind"] == "file_change"

            # Thinking and text frames were L1-dropped before; they are rows
            # now (the panel's thinking / last-text sources), and the capture
            # route attributes them to the same card as the tool rows — the
            # panel's per-subagent sections filter by this key.
            reasoning_rows = [
                item
                for item in host.timeline_item_upserts
                if item.type == "system" and item.content.get("kind") == "reasoning"
            ]
            assert reasoning_rows, "captured thinking must be a row"
            assert reasoning_rows[-1].content["parentItemId"] == card_id
            text_rows = [
                item
                for item in host.timeline_item_upserts
                if item.type == "message"
                and "I'll execute the steps in order" in str(item.content.get("text"))
            ]
            assert text_rows, "captured text must be a row"
            assert text_rows[-1].content["parentItemId"] == card_id

            # L1 invariant, integrated: nothing minted a turn, and the
            # transport is still alive for the next human message.
            assert len(host.session_turn_ends) == turns_before
            assert session.execution is None
            assert client.disconnected is False
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_projector_itself_never_tags_system_or_message_rows() -> None:
    """The parentItemId backfill for those rows lives above the projector.

    Both live routes (the capture route and the in-turn projection) share this
    projector and tag reasoning/message rows on the way out, through
    `_with_parent_card`; the history rebuild and nested Agent rows keep their
    exact content. So the projector itself still knows nothing about parents —
    which is what keeps this the single place a row is shaped.
    """

    projector = ClaudeMessageProjector()
    session = _session()

    system_items = projector.system_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_SUBAGENT_THINKING),
        event="claude.turn.system",
    )
    assert system_items
    assert "parentItemId" not in system_items[0].content

    text_item = projector.message_item(
        session=session,
        turn_id="turn-1",
        role="assistant",
        text="Step 1.",
        event="claude.turn.assistant",
        native_item_id="d4c233f5-54f3-481c-bb1e-576888a3f4c3",
    )
    assert "parentItemId" not in text_item.content


def test_main_agent_rows_stay_untagged() -> None:
    """The whole live path for a main-agent reply keeps its exact content."""

    async def run() -> None:
        client = _MainAgentReplyClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("main_rows", None, "hello")
            session = runtime._sessions["main_rows"]
            await asyncio.wait_for(session.active_task, 5)

            assert any(
                item.type == "system" and item.content.get("kind") == "reasoning"
                for item in host.timeline_item_upserts
            )
            assert any(
                item.type == "message"
                and item.content.get("text") == "Checking the workspace now."
                for item in host.timeline_item_upserts
            )
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.type in {"system", "message"}
                and "parentItemId" in item.content
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_projected_rows_reuse_the_shared_projector_order() -> None:
    """The capture must go through the runtime's one projector (findings §8.8)."""

    projector = ClaudeMessageProjector()
    session = _session()
    first = projector.tool_items_for_message(
        session=session,
        turn_id="turn_main",
        message=_parse(WIRE_DISPATCH_TOOL_USE),
    )[0]
    # Same shared instance projects the captured frame: ids converge and the
    # order slots continue instead of restarting.
    row = projector.tool_items_for_message(
        session=session,
        turn_id="turn_main",
        message=_parse(WIRE_SUBAGENT_TOOL_USE_WRITE),
    )[0]
    assert row.order_seq > first.order_seq
    again = projector.tool_items_for_message(
        session=session,
        turn_id="turn_main",
        message=_parse(WIRE_SUBAGENT_TOOL_USE_WRITE),
    )[0]
    assert again.id == row.id and again.order_seq == row.order_seq


# --------------------------------------------------------------------------
# 5. projector-level: parentItemId rules and event mapping edges
# --------------------------------------------------------------------------


def test_parent_item_id_only_for_frames_parented_to_a_call() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    parent_id = stable_tool_item_id(session, DISPATCH_TUID)

    subagent_row = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_SUBAGENT_TOOL_USE_WRITE),
    )[0]
    assert subagent_row.content["parentItemId"] == parent_id

    subagent_result = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_SUBAGENT_TOOL_RESULT_WRITE),
    )[0]
    assert subagent_result.content["parentItemId"] == parent_id

    # A main-agent frame (parent_tool_use_id=None) stays untouched. The recon
    # sessions' main agent only dispatched agents, so this shape is modelled
    # on the captured subagent frame with the parent removed.
    main_frame = {
        **WIRE_SUBAGENT_TOOL_USE_WRITE,
        "parent_tool_use_id": None,
        "message": {
            **WIRE_SUBAGENT_TOOL_USE_WRITE["message"],
            "content": [
                {
                    "type": "tool_use",
                    "id": "call_00_mainAgentBash",
                    "name": "Bash",
                    "input": {"command": "ls", "description": "List files"},
                }
            ],
        },
    }
    main_row = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(main_frame),
    )[0]
    assert "parentItemId" not in main_row.content

    # Nested Agent calls keep publishing it through their own content type.
    nested = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(
            {
                **WIRE_SUBAGENT_TOOL_USE_WRITE,
                "message": {
                    **WIRE_SUBAGENT_TOOL_USE_WRITE["message"],
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "call_00_nestedAgent",
                            "name": "Agent",
                            "input": {"description": "nested", "prompt": "p"},
                        }
                    ],
                },
            }
        ),
    )[0]
    assert nested.content.get("agentType") is None
    assert nested.content["parentItemId"] == parent_id


def test_task_event_normalization_reads_data_fallback() -> None:
    started = task_event_from_message(_parse(WIRE_TASK_STARTED))
    assert started is not None
    assert started.kind == "started"
    assert started.task_type == "local_agent"
    assert started.session_id == SESSION
    assert started.tool_use_id == DISPATCH_TUID
    # These four are typed-attribute-less on the SDK class; .data supplies them.
    assert started.subagent_type == "general-purpose"
    assert started.prompt == WIRE_TASK_STARTED["prompt"]
    assert started.is_backgrounded is True
    assert started.spawn_depth == 1

    progress = task_event_from_message(_parse(WIRE_TASK_PROGRESS_LAST))
    assert progress is not None
    assert progress.last_tool_name == "Bash"
    assert progress.usage == {"total_tokens": 33555, "tool_uses": 7, "duration_ms": 24723}

    updated = task_event_from_message(_parse(WIRE_TASK_UPDATED))
    assert updated is not None
    assert updated.tool_use_id is None
    assert updated.status == "completed"
    assert updated.end_time == 1790997071652

    notification = task_event_from_message(_parse(WIRE_TASK_NOTIFICATION))
    assert notification is not None
    assert notification.summary == "AUDIT DONE: 3 files, 7 tool calls"
    assert notification.status == "completed"

    # Not a task frame, and a task frame without an id, both normalize to None.
    assert task_event_from_message(_parse(WIRE_MAIN_RESULT)) is None


def test_overlay_statuses_and_fill_only_fields() -> None:
    # Terminal statuses map defensively; unknown ones do not close a card.
    failed = task_event_from_message(
        _parse({**WIRE_TASK_NOTIFICATION, "status": "failed", "uuid": "failed-1"})
    )
    assert failed is not None
    _, status = agent_task_overlay_for_event(failed)
    assert status == "failed"

    stopped = task_event_from_message(
        _parse({**WIRE_TASK_NOTIFICATION, "status": "stopped", "uuid": "stopped-1"})
    )
    assert stopped is not None
    _, status = agent_task_overlay_for_event(stopped)
    assert status == "interrupted"

    # First terminal status sticks — no second closure, no regression.
    assert resolve_agent_card_status("done", "running") == "done"
    assert resolve_agent_card_status("running", "done") == "done"
    assert resolve_agent_card_status("done", "failed") == "done"
    assert resolve_agent_card_status(None, "running") == "running"


# --------------------------------------------------------------------------
# 6. the in-turn route: a subagent frame that lands mid-turn (2026-10-05)
# --------------------------------------------------------------------------
#
# The capture route (section 4) is only half the map. A frame that arrives
# while a turn — or a scheduled turn — is active is handed straight to the
# response queue without being sorted by parent, so `drive_turn` projects it
# as a `turn.*` row instead. Those rows carried no `parentItemId`, and the
# SubAgent panel's `groupKind == .agents` test let them into the main chat:
# 4 rows in pp's session sess_k4g1dE968ahtWg (recon findings §1.2, channels
# A and B).
#
# The frames below are the same shapes as section 4's, queued BEFORE the
# dispatch turn's result — the arrival order is the whole point, since it is
# what selects the route.

# Synthetic, not a capture: no recon session produced a parented result frame,
# so this models the CLI's sidechain result on the dispatch turn's own shape.
WIRE_SUBAGENT_RESULT = {
    **WIRE_MAIN_RESULT,
    "result": "AUDIT DONE: 3 files, 7 tool calls",
    "duration_ms": 2104,
    "parent_tool_use_id": DISPATCH_TUID,
}


class _InTurnSubagentClient(_ScheduledClaudeClient):
    """The dispatch turn, with the subagent's own frames landing before it ends."""

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        for frame in (
            WIRE_DISPATCH_TOOL_USE,
            WIRE_SUBAGENT_THINKING,
            WIRE_SUBAGENT_TEXT,
            WIRE_SUBAGENT_TOOL_USE_WRITE,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


class _InTurnSubagentResultClient(_ScheduledClaudeClient):
    """A parented result frame in-turn: the `turn.result` publish point."""

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        for frame in (WIRE_DISPATCH_TOOL_USE, WIRE_SUBAGENT_RESULT):
            await self.incoming.put(_parse(frame))


def _rows_with_event(host: _RecordingHost, event: str) -> list[Any]:
    return [
        item for item in host.timeline_item_upserts if item.source.get("event") == event
    ]


def _last_row(host: _RecordingHost, event: str, text: str) -> Any:
    rows = [
        item
        for item in _rows_with_event(host, event)
        if text in str(item.content.get("text", ""))
    ]
    assert rows, f"no {event} row carrying {text!r}"
    return rows[-1]


def test_in_turn_subagent_rows_carry_the_parent_card() -> None:
    """The leak itself: `turn.*` rows from a subagent frame, attributed."""

    async def run() -> None:
        client = _InTurnSubagentClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("in_turn", None, "hello")
            session = runtime._sessions["in_turn"]
            await asyncio.wait_for(session.active_task, 5)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)

            # The thinking row the leak report filed as seq 16. It must be an
            # in-turn row (`claude.turn.system`), NOT a capture-route row
            # (`claude.subagent.system`) — otherwise this test would be
            # asserting the already-correct half and proving nothing.
            thinking = _rows_with_event(host, "claude.turn.system")
            assert thinking, "the subagent thinking frame must project in-turn"
            assert not _rows_with_event(host, "claude.subagent.system"), (
                "these frames belong to the in-turn route"
            )
            for row in thinking:
                assert row.content["parentItemId"] == card_id
                # The key rides along with the hash, so the row still dedupes
                # against its own content.
                assert row.content_hash == timeline_content_hash(
                    item_type=row.type,  # type: ignore[arg-type]
                    status=row.status,  # type: ignore[arg-type]
                    role=row.role,  # type: ignore[arg-type]
                    content=row.content,
                )

            # ... and the text row the report filed as seq 10.
            text_row = _last_row(
                host,
                "claude.turn.assistant",
                "I'll execute the steps in order",
            )
            assert text_row.content["parentItemId"] == card_id

            # The tool row of the same frame keeps the projector's own tag and
            # its own content: the backfill never re-projects a tool row.
            tool_row_id = stable_tool_item_id(session, SUBAGENT_WRITE_TUID)
            tool_rows = [
                item for item in host.timeline_item_upserts if item.id == tool_row_id
            ]
            assert tool_rows, "the subagent tool row must project in-turn"
            assert tool_rows[-1].content["parentItemId"] == card_id
            assert tool_rows[-1].content["kind"] == "file_change"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_result_frames_lose_the_parent_at_the_sdk_boundary() -> None:
    """Why the `turn.result` publish point is only the defensive half.

    `drive_turn` reads the parent off the frame the same way it does for every
    other frame, and wraps the terminal row with it — but `parse_message` types
    a result frame into `ResultMessage`, which has no `parent_tool_use_id`
    field, so the signal does not survive parsing. The wrap is kept (it costs
    nothing and starts working if a future SDK carries the field), and this
    test pins the boundary so the day it moves, it is a red test here rather
    than a silent gap.
    """

    parsed = _parse(WIRE_SUBAGENT_RESULT)
    assert _parent_tool_use_id(parsed) is None
    # The frames that DO leak (assistant thinking / text, user tool_result)
    # keep it — the attribution this fix relies on is real.
    assert _parent_tool_use_id(_parse(WIRE_SUBAGENT_THINKING)) == DISPATCH_TUID

    async def run() -> None:
        client = _InTurnSubagentResultClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("in_turn_result", None, "hello")
            session = runtime._sessions["in_turn_result"]
            await asyncio.wait_for(session.active_task, 5)

            result_row = _last_row(host, "claude.turn.result", "AUDIT DONE")
            assert "parentItemId" not in result_row.content
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_main_agent_in_turn_rows_never_gain_a_parent_card() -> None:
    """The other half of the invariant: this fix must not tag the main agent.

    `_MainAgentReplyClient` is the whole live path for a main-agent reply
    (thinking + text, `parent_tool_use_id=None` on every frame), and the reply
    must reach the chat exactly as it did before.
    """

    async def run() -> None:
        client = _MainAgentReplyClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("main_untouched", None, "hello")
            session = runtime._sessions["main_untouched"]
            await asyncio.wait_for(session.active_task, 5)

            assert _rows_with_event(host, "claude.turn.system")
            assert _last_row(
                host, "claude.turn.assistant", "Checking the workspace now."
            )
            assert not [
                item
                for item in host.timeline_item_upserts
                if "parentItemId" in item.content
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_parent_card_helper_is_the_identity_without_a_parent() -> None:
    """Pins the transform itself: no parent → the very same objects come back."""

    projector = ClaudeMessageProjector()
    session = _session()
    parent_id = stable_tool_item_id(session, DISPATCH_TUID)

    system_row = projector.system_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_SUBAGENT_THINKING),
        event="claude.turn.system",
    )[0]
    tool_row = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_SUBAGENT_TOOL_USE_WRITE),
    )[0]

    # Unparented: identity, so a main-agent turn publishes exactly what it
    # published before this fix — same object, not a rebuilt copy.
    assert _with_parent_card(system_row, None) is system_row
    assert _with_parent_cards((system_row,), None)[0] is system_row
    # Parented: the free-JSON key, plus the matching hash.
    tagged = _with_parent_cards((system_row,), parent_id)[0]
    assert tagged is not system_row
    assert tagged.content["parentItemId"] == parent_id
    assert tagged.content_hash == timeline_content_hash(
        item_type=tagged.type,  # type: ignore[arg-type]
        status=tagged.status,  # type: ignore[arg-type]
        role=tagged.role,  # type: ignore[arg-type]
        content=tagged.content,
    )
    assert "parentItemId" not in system_row.content

    # Tool rows are the projector's business (messages.py already tags them);
    # the helper must not re-touch one on either route.
    assert tool_row.content["parentItemId"] == parent_id
    assert _with_parent_card(tool_row, parent_id) is tool_row
    assert _with_parent_cards((tool_row,), parent_id)[0] is tool_row


# --------------------------------------------------------------------------
# 7. the nested dispatch: a subagent dispatching its own subagent
# --------------------------------------------------------------------------
#
# Session sess_VPALa6eqfhLLBg, 2026-10-05: a nested Agent dispatch published
# `status=done` with `agents[*].status=running` still sitting under it, and the
# terminal status never moved again — the CLI writes NO `toolUseResult` on a
# tool_result frame produced inside a sidechain, so the metadata-only guard
# read None, called the launch receipt an outcome, and
# `resolve_agent_card_status` made that first terminal permanent.
#
# The frames below are the outer dispatch's own shapes plus the keys a
# sidechain frame carries (parent_tool_use_id + isSidechain); the receipt is
# the real one with its `tool_use_result` key removed — that missing key IS
# the defect, and it is the only difference from the passing root-level case.

NESTED_TUID = "call_00_Ne5tedDispatchK7d0"
NESTED_TASK_ID = "c40d9e1b83af4277"

WIRE_NESTED_DISPATCH_TOOL_USE = {
    "type": "assistant",
    "message": {
        "id": "1f0d5a6c-9a4e-4c62-9b0e-2f7b6c1d84aa",
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {
                "type": "tool_use",
                "id": NESTED_TUID,
                "name": "Agent",
                "input": {
                    "description": "Second opinion on alpha.txt",
                    "prompt": "Read .../run1/work/alpha.txt and ...",
                },
            }
        ],
        "usage": {
            "input_tokens": 31204,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 20480,
        },
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "6d1a4c77-1f8b-4a92-9a3d-0c5b7e2f41d8",
    "timestamp": "2026-10-03T03:10:50.114Z",
    "isSidechain": True,
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

# Same body as WIRE_DISPATCH_RECEIPT, minus `tool_use_result`.
WIRE_NESTED_DISPATCH_RECEIPT = {
    "type": "user",
    "message": {
        "role": "user",
        "content": [
            {
                "tool_use_id": NESTED_TUID,
                "type": "tool_result",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Async agent launched successfully. (This tool "
                            "result is internal metadata — never quote or "
                            "paste any part of it ...) (receipt body, elided)"
                        ),
                    }
                ],
            }
        ],
    },
    "parent_tool_use_id": DISPATCH_TUID,
    "session_id": SESSION,
    "uuid": "b6f0c2a4-7d31-4e58-8a19-3c0d5b8e6f42",
    "timestamp": "2026-10-03T03:10:50.233Z",
    "isSidechain": True,
    "subagent_type": "general-purpose",
    "task_description": "Multi-tool file audit",
}

WIRE_NESTED_TASK_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": NESTED_TASK_ID,
    "tool_use_id": NESTED_TUID,
    "description": "Second opinion on alpha.txt",
    "subagent_type": "general-purpose",
    "is_backgrounded": True,
    "spawn_depth": 2,
    "task_type": "local_agent",
    "prompt": "Read .../run1/work/alpha.txt and ...",
    "uuid": "e2f7b0c9-4a13-4d6f-b58e-7c1a9d3f20b6",
    "session_id": SESSION,
}

WIRE_NESTED_TASK_PROGRESS = {
    "type": "system",
    "subtype": "task_progress",
    "task_id": NESTED_TASK_ID,
    "tool_use_id": NESTED_TUID,
    "description": "Reading alpha.txt",
    "subagent_type": "general-purpose",
    "usage": {"total_tokens": 33412, "tool_uses": 2, "duration_ms": 3118},
    "last_tool_name": "Read",
    "uuid": "0a9e7c53-6b28-4f19-8d70-15e3b9c2a846",
    "session_id": SESSION,
}

WIRE_NESTED_TASK_UPDATED = {
    "type": "system",
    "subtype": "task_updated",
    "task_id": NESTED_TASK_ID,
    "patch": {"status": "completed", "end_time": 1790997079000},
    "uuid": "5c9a1d3e-7b02-4f86-91ca-0d4e8b2f6137",
    "session_id": SESSION,
}

# Synthetic, not a capture: the nested receipt above is the one shape this fix
# can read. This is the guard's blind spot, and it is what I1 exists for — a
# sidechain receipt whose body does not announce a launch (CLI phrasing drift,
# or any body the prefix does not match) leaves nothing in the metadata, so
# only the agents map still knows the call has not finished.
UNREADABLE_NESTED_RECEIPT = {
    **WIRE_NESTED_DISPATCH_RECEIPT,
    "uuid": "nested-unreadable-1",
    "message": {
        **WIRE_NESTED_DISPATCH_RECEIPT["message"],
        "content": [
            {
                "tool_use_id": NESTED_TUID,
                "type": "tool_result",
                "content": "The nested run ended without reporting back.",
            }
        ],
    },
}

LAUNCH_RECEIPT_TEXT = (
    "Async agent launched successfully. (This tool result is internal "
    "metadata — never quote or paste any part of it ...)"
)


class _NestedDispatchClient(_ScheduledClaudeClient):
    """The dispatch turn, with the subagent's own Agent dispatch inside it.

    The frames arrive in the order production sent them: the nested launch
    receipt lands before the nested task_started, which is what left the card
    with a decision already made by the time the agent was known to be alive.
    """

    def __init__(
        self, receipt: dict[str, Any] = WIRE_NESTED_DISPATCH_RECEIPT
    ) -> None:
        super().__init__()
        self.receipt = receipt

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in (
            WIRE_DISPATCH_TOOL_USE,
            WIRE_DISPATCH_RECEIPT,
            WIRE_TASK_STARTED,
            WIRE_NESTED_DISPATCH_TOOL_USE,
            self.receipt,
            WIRE_NESTED_TASK_STARTED,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


def test_sidechain_receipt_keeps_the_card_running() -> None:
    """The production nail: a nested launch must never read as done."""

    async def run() -> None:
        client = _NestedDispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, NESTED_TUID)
            await _wait_until(
                lambda: _nested_agent_status(_card_items(host, card_id)[-1])
                == "running"
            )

            card = _card_items(host, card_id)[-1]
            assert card.status == "running", "a launch is not an outcome"
            assert card.content["output"].startswith("Async agent launched")
            # The stronger form: no upsert of this card ever claimed done.
            assert not [
                item
                for item in _card_items(host, card_id)
                if item.status in AGENT_CARD_TERMINAL_STATUSES
            ]
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_receipt_text_recognises_a_sidechain_dispatch() -> None:
    # No metadata at all — the sidechain case, where the guard used to read
    # None and land done.
    assert is_async_agent_receipt(None) is False
    assert is_async_agent_receipt(None, LAUNCH_RECEIPT_TEXT) is True
    # Leading whitespace must not hide it: the CLI wraps the boilerplate.
    assert is_async_agent_receipt(None, f"\n  {LAUNCH_RECEIPT_TEXT}") is True
    # The real nested frame's own body, as the projector extracts it.
    nested_body = WIRE_NESTED_DISPATCH_RECEIPT["message"]["content"][0]["content"][0][
        "text"
    ]
    assert is_async_agent_receipt(None, nested_body) is True
    # An ordinary outcome is not a receipt.
    assert is_async_agent_receipt(None, "3 files checked, no findings") is False
    # Neither is a non-string body smuggled into the text slot.
    assert is_async_agent_receipt(None, 42) is False


def test_explicit_metadata_status_wins_over_receipt_text() -> None:
    """The sync guardrail: a foreground call's receipt *is* its outcome."""

    assert is_async_agent_receipt({"status": "completed"}, LAUNCH_RECEIPT_TEXT) is (
        False
    )
    assert is_async_agent_receipt({"status": "failed"}, LAUNCH_RECEIPT_TEXT) is False
    # Metadata without a status is no opinion, so the body decides.
    assert is_async_agent_receipt({"agentId": TASK_ID}, LAUNCH_RECEIPT_TEXT) is True
    assert is_async_agent_receipt({"status": ""}, LAUNCH_RECEIPT_TEXT) is True
    assert is_async_agent_receipt({"status": "async_launched"}, "") is True
    # And the wire regression itself, through the parsed frame.
    assert is_async_agent_receipt({"status": "async_launched"}) is True


def test_live_agents_map_forbids_a_terminal_card() -> None:
    """I1: agents still alive means the card is not finished, whatever said so."""

    projector = ClaudeMessageProjector()
    session = _session()
    card_id = stable_tool_item_id(session, NESTED_TUID)

    projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_NESTED_DISPATCH_TOOL_USE),
    )
    started = task_event_from_message(_parse(WIRE_NESTED_TASK_STARTED))
    assert started is not None
    overlay, status = agent_task_overlay_for_event(started)
    projector.fold_agent_task_event(
        session, tool_use_id=NESTED_TUID, overlay=overlay, status=status
    )

    # A receipt the guard cannot read as a launch, with a live agent under it.
    row = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(UNREADABLE_NESTED_RECEIPT),
    )[0]
    assert row.id == card_id
    assert _nested_agent_status(row) == "running"
    assert row.status == "running", "a live agent outranks a terminal frame"


def test_terminal_entry_is_not_clamped() -> None:
    """An agents entry with no status is not an agent in flight."""

    assert has_live_agent_tasks(AgentCallToolContent(agents={"a": {}})) is False
    assert (
        has_live_agent_tasks(
            AgentCallToolContent(agents={"a": {}, "b": {"status": "completed"}})
        )
        is False
    )
    assert (
        has_live_agent_tasks(AgentCallToolContent(agents={"a": {"status": "running"}}))
        is True
    )
    assert (
        has_live_agent_tasks(
            AgentCallToolContent(agents={"a": {"status": "async_launched"}})
        )
        is True
    )

    # End to end: a status-less task event leaves `{}` in the map, and the card
    # it closes is allowed to reach terminal.
    projector = ClaudeMessageProjector()
    session = _session()
    projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(WIRE_NESTED_DISPATCH_TOOL_USE),
    )
    # task_updated with no status in its patch: the agents entry is `{}`.
    blank = task_event_from_message(
        _parse(
            {
                **WIRE_NESTED_TASK_UPDATED,
                "uuid": "nested-blank-1",
                "patch": {"end_time": 1790997079000},
            }
        )
    )
    assert blank is not None
    overlay, status = agent_task_overlay_for_event(blank)
    assert overlay.agents == {NESTED_TASK_ID: {}}
    projector.fold_agent_task_event(
        session, tool_use_id=NESTED_TUID, overlay=overlay, status=status
    )

    row = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=_parse(UNREADABLE_NESTED_RECEIPT),
    )[0]
    assert row.content["agents"] == {NESTED_TASK_ID: {}}
    assert row.status == "done", "no live agent, nothing to clamp"


def test_false_done_self_heals_on_the_next_progress() -> None:
    """A card pinned done by a misread frame is un-pinned, item and ledger."""

    async def run() -> None:
        client = _NestedDispatchClient(receipt=UNREADABLE_NESTED_RECEIPT)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, NESTED_TUID)
            # The production state: terminal card, live agent underneath.
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status
                in AGENT_CARD_TERMINAL_STATUSES
                and _nested_agent_status(_card_items(host, card_id)[-1]) == "running"
            )

            # The next projection of the dispatch frame — what a reconnect
            # replays — is what un-sticks it. The task route alone cannot:
            # `resolve_agent_card_status` keeps a terminal status forever.
            await client.incoming.put(_parse(WIRE_NESTED_DISPATCH_TOOL_USE))
            await client.incoming.put(_parse(WIRE_NESTED_TASK_PROGRESS))
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status == "running"
            )

            card = _card_items(host, card_id)[-1]
            assert card.status == "running"
            assert _nested_agent_status(card) == "running"
            # Ledger and item agree, so the next terminal frame is not blocked
            # by the status the bad frame left behind.
            assert runtime._timeline._agent_cards[card_id].status == "running"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_task_updated_after_a_false_done_still_closes() -> None:
    """The clamp is not a latch: a real closure still lands exactly once."""

    async def run() -> None:
        client = _NestedDispatchClient(receipt=UNREADABLE_NESTED_RECEIPT)
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, NESTED_TUID)
            await _wait_until(
                lambda: _card_items(host, card_id)[-1].status
                in AGENT_CARD_TERMINAL_STATUSES
            )

            await client.incoming.put(_parse(WIRE_NESTED_TASK_UPDATED))
            await _wait_until(
                lambda: _nested_agent_status(_card_items(host, card_id)[-1])
                == "completed"
            )

            card = _card_items(host, card_id)[-1]
            assert card.status == "done"
            # Still one closure, and the progress that followed it did not
            # reopen the card on its way.
            assert card.content["endTime"] == 1790997079000
            published = len(_card_items(host, card_id))
            await client.incoming.put(_parse(WIRE_NESTED_TASK_UPDATED))
            await asyncio.sleep(0.05)
            assert len(_card_items(host, card_id)) == published
            assert _card_items(host, card_id)[-1].status == "done"
        finally:
            await runtime.stop()

    asyncio.run(run())
