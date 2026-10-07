"""Per-call token usage on Claude items + catalog context windows (Stage A).

Covers `.local-dev/context-usage-ring-tasks.md` §1: assistant message /
reasoning / tool items carry `content.usage` (four camelCase int keys, always
present, never null, missing counts as 0, main chain only — subagent sidechain
frames get none), and the claude model catalog declares
`metadata.contextWindow` (1M for `[1m]` entries, 200k for the claude family,
absent for gateway models).
"""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import (
    StreamEvent,
    _FakeClaudeClient,
    _HistorySdk,
    _RecordingHost,
    _runtime,
)

from connector.runtime_protocol import timeline_content_hash
from connector.runtimes.claude.domain.models import (
    claude_context_window,
    claude_model_catalog,
)
from connector.runtimes.claude.domain.session import ClaudeSession, stable_session_id
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    message_usage,
    stable_message_item_id,
)
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator

SESSION = "claude_ctx_usage"
TURN_ID = "turn_ctx"

USAGE_RAW: dict[str, Any] = {
    "input_tokens": 1200,
    "output_tokens": 30,
    "cache_read_input_tokens": 5000,
    "cache_creation_input_tokens": 7,
}
USAGE_WIRE = {
    "inputTokens": 1200,
    "outputTokens": 30,
    "cacheReadTokens": 5000,
    "cacheCreationTokens": 7,
}


def _session() -> ClaudeSession:
    return ClaudeSession(session_id="sess_ctx", external_session_id=SESSION)


def _stream_event(event: dict[str, Any], *, parent: str | None = None) -> StreamEvent:
    return StreamEvent(
        uuid="stream_uuid_1",
        session_id=SESSION,
        event=event,
        parent_tool_use_id=parent,
    )


def _message_start(message_id: str, usage: dict[str, Any] | None) -> dict[str, Any]:
    message: dict[str, Any] = {"id": message_id}
    if usage is not None:
        message["usage"] = usage
    return {"type": "message_start", "message": message}


def _text_delta(text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": text},
    }


def _thinking_delta(text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": text},
    }


# ---------------------------------------------------------------------------
# Wire-shape helpers
# ---------------------------------------------------------------------------


def assert_wire_usage(value: Any) -> None:
    """The frozen §1.1 shape: exactly four int keys, no nulls anywhere."""

    assert isinstance(value, Mapping)
    assert set(value) == {
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheCreationTokens",
    }
    for key, count in value.items():
        assert isinstance(count, int) and not isinstance(count, bool), key


def assert_no_turn_keys(value: Any) -> None:
    """`turnId`/`turn_id` must not appear at any depth (server strips them)."""

    if isinstance(value, Mapping):
        for key, item in value.items():
            assert key not in {"turnId", "turn_id"}
            assert_no_turn_keys(item)
    elif isinstance(value, list | tuple):
        for item in value:
            assert_no_turn_keys(item)


def assert_no_null_values(value: Any) -> None:
    """No nulls: `exclude_none` persistence would drop them, desyncing replay."""

    if isinstance(value, Mapping):
        for item in value.values():
            assert item is not None
            assert_no_null_values(item)
    elif isinstance(value, list | tuple):
        for item in value:
            assert_no_null_values(item)


# ---------------------------------------------------------------------------
# A1 · live streaming
# ---------------------------------------------------------------------------


def test_stream_accumulator_seeds_and_grows_usage() -> None:
    accumulator = ClaudeStreamAccumulator()
    projector = ClaudeMessageProjector()
    session = _session()

    assert (
        accumulator.item_from_stream_event(
            session=session,
            turn_id=TURN_ID,
            message=_stream_event(_message_start("msg_1", USAGE_RAW)),
            projector=projector,
        )
        is None
    )

    seeded = accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event(_text_delta("Hel")),
        projector=projector,
    )
    assert seeded is not None
    # message_start seeds input/cache; a message has produced no output yet.
    assert seeded.content["usage"] == {**USAGE_WIRE, "outputTokens": 0}

    grown = accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event({"type": "message_delta", "usage": {"output_tokens": 42}}),
        projector=projector,
    )
    assert grown is not None
    assert grown.id == seeded.id
    assert grown.content["usage"] == {**USAGE_WIRE, "outputTokens": 42}


def test_stream_accumulator_attaches_usage_to_thinking_items() -> None:
    accumulator = ClaudeStreamAccumulator()
    projector = ClaudeMessageProjector()
    session = _session()

    accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event(_message_start("msg_think", USAGE_RAW)),
        projector=projector,
    )

    started = accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event(
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "thinking", "thinking": "why"},
            }
        ),
        projector=projector,
    )
    assert started is not None
    assert started.status == "running"
    # The turn's first streamed row already carries the measurement.
    assert started.content["usage"] == {**USAGE_WIRE, "outputTokens": 0}
    assert_wire_usage(started.content["usage"])
    assert_no_null_values(started.content)
    assert_no_turn_keys(started.content)

    accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event({"type": "message_delta", "usage": {"output_tokens": 9}}),
        projector=projector,
    )
    grown = accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event(_thinking_delta(" more")),
        projector=projector,
    )
    assert grown is not None
    assert grown.id == started.id
    assert grown.content["usage"] == {**USAGE_WIRE, "outputTokens": 9}


def test_stream_accumulator_sidechain_frames_carry_no_usage() -> None:
    accumulator = ClaudeStreamAccumulator()
    projector = ClaudeMessageProjector()
    session = _session()

    accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream_event(
            _message_start("msg_sub", USAGE_RAW),
            parent="call_dispatch",
        ),
        projector=projector,
    )
    for event in (
        _text_delta("Hel"),
        {"type": "message_delta", "usage": {"output_tokens": 42}},
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "thinking", "thinking": "why"},
        },
    ):
        item = accumulator.item_from_stream_event(
            session=session,
            turn_id=TURN_ID,
            message=_stream_event(event, parent="call_dispatch"),
            projector=projector,
        )
        assert item is not None
        assert "usage" not in item.content


# ---------------------------------------------------------------------------
# A1 · live turn (final frames, clobber paths, sidechain, tool-only calls)
# ---------------------------------------------------------------------------


async def _run_turn(messages: list[Any]) -> _RecordingHost:
    host = _RecordingHost()
    client = _FakeClaudeClient(messages=messages)
    runtime = _runtime(host=host, client=client)
    result = await runtime.start_turn("sess_ctx", None, "measure this")
    task = runtime._sessions["sess_ctx"].active_task
    assert result.ok is True
    assert task is not None
    await task
    return host


def test_live_turn_final_message_item_keeps_usage() -> None:
    asyncio.run(_test_live_turn_final_message_item_keeps_usage())


async def _test_live_turn_final_message_item_keeps_usage() -> None:
    host = await _run_turn(
        [
            _stream_event(_message_start("msg_1", USAGE_RAW)),
            _stream_event(_text_delta("Hel")),
            _stream_event(_text_delta("lo")),
            # The live SDK shape: usage top-level on the AssistantMessage.
            SimpleNamespace(
                type="assistant",
                message_id="msg_1",
                usage=USAGE_RAW,
                message={"role": "assistant", "content": [{"type": "text", "text": "Hello!"}]},
                session_id=SESSION,
            ),
            SimpleNamespace(type="result", session_id=SESSION),
        ]
    )

    assistant_items = [
        item for item in host.timeline_item_upserts if item.role == "assistant"
    ]
    assert len({item.id for item in assistant_items}) == 1
    assert [item.status for item in assistant_items] == ["running", "running", "done"]
    # The partials carry the streamed seed; the final write carries the frame's
    # exact per-call numbers — and it is the write that lands last.
    assert assistant_items[0].content["usage"] == {**USAGE_WIRE, "outputTokens": 0}
    assert assistant_items[-1].content["usage"] == USAGE_WIRE
    for item in assistant_items:
        assert_wire_usage(item.content["usage"])
        assert_no_turn_keys(item.content)
        assert_no_null_values(item.content)
        assert (
            timeline_content_hash(
                item.type, item.status, item.role, dict(item.content)
            )
            == item.content_hash
        )


def test_result_envelope_fallback_keeps_usage() -> None:
    asyncio.run(_test_result_envelope_fallback_keeps_usage())


async def _test_result_envelope_fallback_keeps_usage() -> None:
    # A tool-only call produces no message row; the reply text rides the
    # result envelope instead. The fallback republishes the same item id the
    # streamed partial used — with usage — rather than erasing it.
    host = await _run_turn(
        [
            _stream_event(_message_start("msg_2", USAGE_RAW)),
            _stream_event(_text_delta("wor")),
            SimpleNamespace(
                type="assistant",
                message_id="msg_2",
                usage=USAGE_RAW,
                message={
                    "role": "assistant",
                    "content": [
                        {"type": "tool_use", "id": "tool_1", "name": "Bash", "input": {"command": "ls"}}
                    ],
                },
                session_id=SESSION,
            ),
            SimpleNamespace(type="result", session_id=SESSION, result="the reply text"),
        ]
    )

    assistant_items = [
        item for item in host.timeline_item_upserts if item.role == "assistant"
    ]
    assert [item.source["event"] for item in assistant_items] == [
        "claude.turn.assistant.partial",
        "claude.turn.result",
    ]
    assert len({item.id for item in assistant_items}) == 1
    assert assistant_items[-1].content["text"] == "the reply text"
    assert assistant_items[-1].content["usage"] == {**USAGE_WIRE, "outputTokens": 0}


def test_tool_only_turn_carries_usage_on_tool_rows() -> None:
    asyncio.run(_test_tool_only_turn_carries_usage_on_tool_rows())


async def _test_tool_only_turn_carries_usage_on_tool_rows() -> None:
    second_usage = {
        "input_tokens": 1300,
        "output_tokens": 3,
        "cache_read_input_tokens": 6300,
        "cache_creation_input_tokens": 0,
    }
    host = await _run_turn(
        [
            SimpleNamespace(
                type="assistant",
                message_id="msg_3",
                usage=USAGE_RAW,
                message={
                    "role": "assistant",
                    "content": [
                        {"type": "tool_use", "id": "tool_1", "name": "Bash", "input": {"command": "ls"}}
                    ],
                },
                session_id=SESSION,
            ),
            SimpleNamespace(
                type="user",
                message={
                    "role": "user",
                    "content": [
                        {"type": "tool_result", "tool_use_id": "tool_1", "content": "ok"}
                    ],
                },
                session_id=SESSION,
            ),
            SimpleNamespace(
                type="assistant",
                message_id="msg_4",
                usage=second_usage,
                message={"role": "assistant", "content": [{"type": "text", "text": "done"}]},
                session_id=SESSION,
            ),
            SimpleNamespace(type="result", session_id=SESSION),
        ]
    )

    tool_items = [item for item in host.timeline_item_upserts if item.type == "tool"]
    assert [item.status for item in tool_items] == ["running", "done"]
    # The call's per-call usage survives the tool_result rewrite: the
    # completed row is the last write for this item id.
    for item in tool_items:
        assert item.content["usage"] == USAGE_WIRE
        assert_no_turn_keys(item.content)

    message_items = [
        item for item in host.timeline_item_upserts if item.role == "assistant"
    ]
    # Per-call, not turn-cumulative: the second call's row carries its own.
    assert message_items[-1].content["usage"] == {
        "inputTokens": 1300,
        "outputTokens": 3,
        "cacheReadTokens": 6300,
        "cacheCreationTokens": 0,
    }


def test_live_sidechain_frames_carry_no_usage() -> None:
    asyncio.run(_test_live_sidechain_frames_carry_no_usage())


async def _test_live_sidechain_frames_carry_no_usage() -> None:
    host = await _run_turn(
        [
            SimpleNamespace(
                type="assistant",
                parent_tool_use_id="call_dispatch",
                message_id="msg_sub",
                usage=USAGE_RAW,
                message={
                    "role": "assistant",
                    "content": [
                        {"type": "text", "text": "subagent words"},
                        {"type": "tool_use", "id": "tool_sub", "name": "Bash", "input": {"command": "pwd"}},
                    ],
                },
                session_id=SESSION,
            ),
            SimpleNamespace(type="result", session_id=SESSION),
        ]
    )

    projected = [
        item
        for item in host.timeline_item_upserts
        if item.role in {"assistant", "tool"}
    ]
    assert projected
    for item in projected:
        assert "usage" not in item.content


# ---------------------------------------------------------------------------
# A2 · history
# ---------------------------------------------------------------------------


def test_history_items_carry_usage() -> None:
    asyncio.run(_test_history_items_carry_usage())


async def _test_history_items_carry_usage() -> None:
    external_session_id = "claude_ctx_history"
    sdk = _HistorySdk(
        infos={
            external_session_id: SimpleNamespace(
                session_id=external_session_id,
                summary="History",
                cwd="/repo",
                last_modified=1_789_000_000_000,
                file_size=123,
            )
        },
        messages={
            external_session_id: [
                SimpleNamespace(
                    type="user",
                    uuid="user_1",
                    session_id=external_session_id,
                    message={"role": "user", "content": "hello"},
                ),
                SimpleNamespace(
                    type="assistant",
                    uuid="assistant_1",
                    session_id=external_session_id,
                    message={
                        "role": "assistant",
                        "content": [{"type": "text", "text": "hi"}],
                        "usage": USAGE_RAW,
                    },
                ),
            ]
        },
    )
    runtime = _runtime(sdk=sdk)

    snapshot = await runtime.get_session_snapshot(
        stable_session_id("conn_test", external_session_id),
        external_session_id,
    )

    assistant_item = next(item for item in snapshot.items if item.role == "assistant")
    user_item = next(item for item in snapshot.items if item.role == "user")
    assert assistant_item.content["usage"] == USAGE_WIRE
    assert_wire_usage(assistant_item.content["usage"])
    assert_no_turn_keys(assistant_item.content)
    assert_no_null_values(assistant_item.content)
    assert "usage" not in user_item.content
    # History and live ids are the same stable id, so the two writes converge
    # on one item for the same native message id.
    session = ClaudeSession(
        session_id=stable_session_id("conn_test", external_session_id),
        external_session_id=external_session_id,
    )
    assert assistant_item.id == stable_message_item_id(session, "assistant_1")


# ---------------------------------------------------------------------------
# A3 · catalog context windows
# ---------------------------------------------------------------------------


def test_context_window_derivation_three_branches() -> None:
    assert claude_context_window("claude-opus-5-5[1m]", "opus[1m]") == 1_000_000
    assert claude_context_window(None, "opus[1m]") == 1_000_000
    assert claude_context_window("claude-opus-4-8") == 200_000
    assert claude_context_window("default", "claude-opus-5-5") == 200_000
    assert claude_context_window("gateway-model", "mimo-v2.6-flash") is None
    assert claude_context_window("default", None) is None


def test_cli_catalog_items_declare_context_window() -> None:
    catalog = claude_model_catalog(
        revision=1,
        cli_models=[
            {"value": "default", "resolvedModel": "claude-opus-5-5[1m]"},
            {"value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001"},
            {"value": "gateway-model", "resolvedModel": "mimo-v2.6-flash"},
        ],
    )
    by_id = {model.id: model for model in catalog.models}
    assert by_id["default"].metadata["contextWindow"] == 1_000_000
    assert by_id["haiku"].metadata["contextWindow"] == 200_000
    assert "contextWindow" not in by_id["gateway-model"].metadata


def test_static_catalog_items_declare_context_window() -> None:
    catalog = claude_model_catalog(revision=1)
    assert catalog.models
    assert all(
        model.metadata["contextWindow"] == 200_000 for model in catalog.models
    )


def test_custom_models_get_no_context_window() -> None:
    # Gateway/custom models carry no window information; the key is omitted so
    # clients hide their context indicator instead of guessing.
    catalog = claude_model_catalog(
        revision=1,
        custom_models=[{"modelId": "gateway-custom", "displayName": "Gateway"}],
    )
    custom = next(model for model in catalog.models if model.id == "gateway-custom")
    assert custom.metadata["custom"] is True
    assert "contextWindow" not in custom.metadata


# ---------------------------------------------------------------------------
# Usage extraction primitives
# ---------------------------------------------------------------------------


def test_message_usage_reads_both_frame_shapes() -> None:
    # Live SDK AssistantMessage: usage top-level.
    live = SimpleNamespace(type="assistant", usage=USAGE_RAW)
    assert message_usage(live) == USAGE_WIRE
    # Historical SessionMessage / raw wire frame: usage nested in `message`.
    history = SimpleNamespace(type="assistant", message={"usage": USAGE_RAW})
    assert message_usage(history) == USAGE_WIRE
    wire = {"type": "assistant", "message": {"usage": USAGE_RAW}, "parent_tool_use_id": None}
    assert message_usage(wire) == USAGE_WIRE


def test_message_usage_gaps_become_zero_never_null() -> None:
    usage = message_usage(SimpleNamespace(type="assistant", usage={"input_tokens": 12}))
    assert usage == {
        "inputTokens": 12,
        "outputTokens": 0,
        "cacheReadTokens": 0,
        "cacheCreationTokens": 0,
    }
    assert_wire_usage(usage)
    # No usage mapping at all → no key (not a zeroed object).
    assert message_usage(SimpleNamespace(type="assistant", message={"content": []})) is None
    # A usage object holding no token count measured nothing either.
    assert (
        message_usage(
            SimpleNamespace(type="assistant", usage={"service_tier": "standard"})
        )
        is None
    )


def test_message_usage_ignores_sidechain_frames() -> None:
    frame = SimpleNamespace(
        type="assistant",
        usage=USAGE_RAW,
        parent_tool_use_id="call_dispatch",
    )
    assert message_usage(frame) is None


def test_content_hash_changes_when_usage_changes() -> None:
    session = _session()
    projector = ClaudeMessageProjector()

    def item(usage: Mapping[str, int] | None) -> Any:
        return projector.message_item(
            session=session,
            turn_id=TURN_ID,
            role="assistant",
            text="hi",
            event="claude.turn.assistant",
            native_item_id="msg_hash",
            usage=usage,
        )

    without = item(None)
    with_usage = item(USAGE_WIRE)
    bumped = item({**USAGE_WIRE, "outputTokens": USAGE_WIRE["outputTokens"] + 1})

    assert without.content_hash != with_usage.content_hash
    assert with_usage.content_hash != bumped.content_hash
    assert with_usage.content_hash == timeline_content_hash(
        with_usage.type,
        with_usage.status,
        with_usage.role,
        dict(with_usage.content),
    )
