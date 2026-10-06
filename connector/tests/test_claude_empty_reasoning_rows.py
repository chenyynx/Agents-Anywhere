"""Empty reasoning blocks never become timeline rows (2026-10-05).

The affected model channel emits thinking blocks with an empty body and only
a signature (``{"type": "thinking", "thinking": "", "signature": "…"}``): 9 of
49 subagent blocks in the reported session, one-to-one with the 「推理」 rows
pp could not open. The client hides those rows
(``TimelineEntryPresentation.isVisibleInChat``); the connector must not mint
them at all.

All three routes share ``ClaudeMessageProjector.system_items_for_message`` —
live subagent frames, the turn-end projection and the history import — so the
gate is pinned on each. The block-level boundary table mirrors the client's
display caliber exactly (``TimelineText.reasoning``): summaries win when any
carries text, otherwise the first non-empty of rawText/text/summary, and the
winner is trimmed. The streaming "empty first, text later" path is a
different one and already guarded
(``test_claude_runtime.py::test_claude_runtime_streams_reasoning_partial_items``);
its final republish through this same projector is pinned here too.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import (
    _FakeClaudeClient,
    _HistorySdk,
    _RecordingHost,
    _runtime,
    _ScheduledClaudeClient,
)
from test_claude_subagent_progress import (
    WIRE_MAIN_RESULT,
    WIRE_SUBAGENT_THINKING,
    _DispatchClient,
    _parse,
)

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)

SUBAGENT_FRAME_MESSAGE_ID = WIRE_SUBAGENT_THINKING["message"]["id"]
EMPTY_SUBAGENT_MESSAGE_ID = "empty-thinking-subagent-1"


def _session() -> ClaudeSession:
    return ClaudeSession(session_id="empty-reasoning", external_session_id="empty-reasoning")


def _assistant_frame(content: list[dict[str, Any]], message_id: str = "msg-1") -> Any:
    """A raw wire message, kept as a mapping.

    The boundary table reads the block fields directly (``summaries``,
    ``signature``), and the SDK's own parser drops both: its ThinkingBlock
    keeps only `thinking`/`signature`, and `redacted_thinking` does not parse
    into a block at all. The projector's extractors accept mappings by
    design, and this is the shape that reaches them when the frame has not
    been through the SDK's typed conversion.
    """

    return {
        "type": "assistant",
        "message": {
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "model": "deepseek-v4.1-flash",
            "content": content,
        },
        "parent_tool_use_id": None,
        "session_id": "empty-reasoning",
        "uuid": message_id,
    }


def _reasoning_rows(items: list[Any]) -> list[Any]:
    return [
        item
        for item in items
        if item.type == "system" and item.content.get("kind") == "reasoning"
    ]


# --------------------------------------------------------------------------
# 1. the block boundary table (client caliber mirrored)
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("label", "content", "projects"),
    [
        (
            "signature-only thinking (the reported shape)",
            [{"type": "thinking", "thinking": "", "signature": "sig-1"}],
            False,
        ),
        (
            "whitespace-only thinking",
            [{"type": "thinking", "thinking": "   ", "signature": "sig-2"}],
            False,
        ),
        (
            "redacted thinking carries no readable text",
            [{"type": "redacted_thinking", "data": "ENCRYPTED"}],
            False,
        ),
        (
            "summaries present but all empty",
            [
                {
                    "type": "thinking",
                    "thinking": "",
                    "summaries": [{"text": ""}],
                    "signature": "sig-3",
                }
            ],
            False,
        ),
        (
            "whitespace summaries win over a real body (client shows them)",
            [
                {
                    "type": "thinking",
                    "thinking": "real body",
                    "summaries": [{"text": "  "}],
                    "signature": "sig-4",
                }
            ],
            False,
        ),
        (
            "summaries carry the display text",
            [
                {
                    "type": "thinking",
                    "thinking": "",
                    "summaries": [{"text": "sum one"}, {"text": "sum two"}],
                    "signature": "sig-5",
                }
            ],
            True,
        ),
        (
            "text carries the display text",
            [{"type": "thinking", "thinking": "real body", "signature": "sig-6"}],
            True,
        ),
    ],
    ids=[
        "signature-only",
        "whitespace-only",
        "redacted",
        "empty-summaries",
        "whitespace-summaries",
        "summaries",
        "text",
    ],
)
def test_reasoning_display_gate_matches_the_client_caliber(
    label: str, content: list[dict[str, Any]], projects: bool
) -> None:
    projector = ClaudeMessageProjector()
    items = projector.system_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_assistant_frame(content),
        event="claude.turn.system",
    )
    assert bool(items) is projects, label
    if projects:
        assert items[0].content["kind"] == "reasoning"


def test_non_empty_thinking_still_projects_with_its_revision() -> None:
    projector = ClaudeMessageProjector()
    items = projector.system_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_assistant_frame(
            [{"type": "thinking", "thinking": "real body", "signature": "sig"}]
        ),
        event="claude.turn.system",
        reasoning_revision=7,
    )
    assert len(items) == 1
    assert items[0].content["text"] == "real body"
    assert items[0].revision == 7


def test_empty_block_does_not_disturb_the_blocks_around_it() -> None:
    projector = ClaudeMessageProjector()
    items = projector.system_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=_assistant_frame(
            [
                {"type": "thinking", "thinking": "", "signature": "sig-empty"},
                {"type": "thinking", "thinking": "real body", "signature": "sig-real"},
                {"type": "redacted_thinking", "data": "ENCRYPTED"},
            ]
        ),
        event="claude.turn.system",
    )
    assert [item.content["text"] for item in items] == ["real body"]


# --------------------------------------------------------------------------
# 2. the live subagent frame route (`claude.subagent.system`)
# --------------------------------------------------------------------------

# The reported wire shape, parented to the dispatch call like every captured
# subagent frame (field set copied from WIRE_SUBAGENT_THINKING so the frame
# carries the same tool_use_result metadata).
WIRE_SUBAGENT_EMPTY_THINKING = {
    **WIRE_SUBAGENT_THINKING,
    "message": {
        "id": EMPTY_SUBAGENT_MESSAGE_ID,
        "type": "message",
        "role": "assistant",
        "stop_reason": None,
        "model": "deepseek-v4.1-flash",
        "content": [
            {"type": "thinking", "thinking": "", "signature": "sig-empty"},
        ],
    },
    "uuid": EMPTY_SUBAGENT_MESSAGE_ID,
}


def test_empty_subagent_thinking_frame_projects_no_row() -> None:
    async def run() -> None:
        client = _DispatchClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("empty_sub_frame", None, "hello")
            session: ClaudeSession = runtime._sessions["empty_sub_frame"]
            await asyncio.wait_for(session.active_task, 5)
            card_id = stable_tool_item_id(session, WIRE_SUBAGENT_THINKING["parent_tool_use_id"])

            await client.incoming.put(_parse(WIRE_SUBAGENT_EMPTY_THINKING))
            # A non-empty frame right behind it proves the queue drained in
            # order: once this row lands, the empty frame has been processed.
            await client.incoming.put(_parse(WIRE_SUBAGENT_THINKING))
            await _wait_until(
                lambda: any(
                    item.source.get("itemId") == SUBAGENT_FRAME_MESSAGE_ID
                    for item in _reasoning_rows(host.timeline_item_upserts)
                )
            )

            rows = _reasoning_rows(host.timeline_item_upserts)
            assert [row.source.get("itemId") for row in rows] == [
                SUBAGENT_FRAME_MESSAGE_ID
            ]
            assert all(
                item.source.get("itemId") != EMPTY_SUBAGENT_MESSAGE_ID
                for item in host.timeline_item_upserts
            )
            # The surviving row is the ordinary captured thinking row: still
            # parented to its card (the panel's attribution key).
            assert rows[0].content["parentItemId"] == card_id
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 3. the turn-end projection route (`claude.turn.system`)
# --------------------------------------------------------------------------

WIRE_MAIN_EMPTY_THINKING_REPLY = {
    "type": "assistant",
    "message": {
        "id": "main-empty-thinking-1",
        "type": "message",
        "role": "assistant",
        "model": "deepseek-v4.1-flash",
        "content": [
            {"type": "thinking", "thinking": "", "signature": "main-empty-thinking-1"},
            {"type": "text", "text": "Done."},
        ],
    },
    "parent_tool_use_id": None,
    "session_id": "empty_reasoning_turn",
    "uuid": "main-empty-thinking-1",
}


class _EmptyThinkingTurnClient(_ScheduledClaudeClient):
    """A main-agent reply whose thinking block is the empty wire shape."""

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        for frame in (WIRE_MAIN_EMPTY_THINKING_REPLY, WIRE_MAIN_RESULT):
            await self.incoming.put(_parse(frame))


def test_turn_end_projection_drops_the_empty_thinking_block() -> None:
    async def run() -> None:
        client = _EmptyThinkingTurnClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("empty_turn", None, "hello")
            session: ClaudeSession = runtime._sessions["empty_turn"]
            await asyncio.wait_for(session.active_task, 5)

            assert _reasoning_rows(host.timeline_item_upserts) == []
            # The rest of the same frame is untouched: the reply text lands.
            assert any(
                item.type == "message" and item.content.get("text") == "Done."
                for item in host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# 4. the history import route (`claude.history.system`)
# --------------------------------------------------------------------------


async def _history_snapshot_for(messages: list[Any]) -> tuple[Any, ...]:
    sdk = _HistorySdk(messages={"claude_history_empty_reasoning": messages})
    runtime = _runtime(sdk=sdk)
    snapshot = await runtime.get_session_snapshot(
        "sess_history_empty_reasoning",
        "claude_history_empty_reasoning",
    )
    return snapshot.items


def test_history_projection_drops_empty_thinking_blocks() -> None:
    async def run() -> None:
        items = await _history_snapshot_for(
            [
                SimpleNamespace(
                    type="user",
                    uuid="history-empty-user",
                    session_id="claude_history_empty_reasoning",
                    message={"role": "user", "content": "explain"},
                ),
                SimpleNamespace(
                    type="assistant",
                    uuid="history-empty-assistant",
                    session_id="claude_history_empty_reasoning",
                    message={
                        "id": "msg_history_empty",
                        "role": "assistant",
                        "content": [
                            {
                                "type": "thinking",
                                "thinking": "",
                                "signature": "sig-history-empty",
                            },
                            {"type": "text", "text": "visible answer"},
                        ],
                    },
                ),
            ]
        )
        assert _reasoning_rows(list(items)) == []
        assert [item.content["text"] for item in items if item.type == "message"] == [
            "explain",
            "visible answer",
        ]

    asyncio.run(run())


def test_history_projection_keeps_non_empty_thinking() -> None:
    async def run() -> None:
        items = await _history_snapshot_for(
            [
                SimpleNamespace(
                    type="assistant",
                    uuid="history-text-assistant",
                    session_id="claude_history_empty_reasoning",
                    message={
                        "id": "msg_history_text",
                        "role": "assistant",
                        "content": [
                            {
                                "type": "thinking",
                                "thinking": "checking context",
                                "signature": "sig-history-text",
                            },
                            {"type": "text", "text": "visible answer"},
                        ],
                    },
                ),
            ]
        )
        rows = _reasoning_rows(list(items))
        assert [row.content["text"] for row in rows] == ["checking context"]

    asyncio.run(run())
