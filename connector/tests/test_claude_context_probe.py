"""Engine-reported context windows: parsing, calibration, stamping (Stage A3).

Covers `.local-dev/context-usage-ring-tasks.md` §8 (v3): the context window is
the running engine's own `/context` self-report — never a model-name guess —
cached per session, and stamped onto the same `content.usage` blocks Stage A
already publishes (`model` from the probe or the frame, `contextWindow` from
the probe or the id rules, unknown keys omitted, never null).

Two guarantees are the reason the probe is safe to ship, and both are pinned
here: the probe's frames never reach the timeline (no projection, no minted
turn — the chrome filter is the second line when frames outlive the probe),
and no probe ever runs while a turn is live or takes the stream from it.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from test_claude_runtime import (
    AssistantMessage,
    StreamEvent,
    _config,
    _default_sdk,
    _FakeHookMatcher,
    _RecordingHost,
    _runtime,
    _ScheduledClaudeClient,
    _wait_until,
)

from connector.runtimes.claude.domain.context_report import (
    ClaudeContextProbe,
    is_context_report_text,
    parse_context_report,
)
from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.history.syncer import _history_session
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    enrich_usage,
    is_synthetic_control_message,
)
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator
from connector.runtimes.claude.turns import context_probe, lifecycle

# The verified live render (2026-10-08 probe): a fresh session, with the
# category table the CLI appends.
FRESH_REPORT = """## Context Usage

**Model:** deepseek-v4.1-flash
**Tokens:** 12.2k / 1m (1%)

### Estimated usage by category

| Category | Tokens | Percentage |
|----------|--------|------------|
| System tools | 2.3k | 0.2% |
| Skills | 9.9k | 1.0% |
| Messages | 8 | 0.0% |
| Free space | 954.8k | 95.5% |
| Autocompact buffer | 33k | 3.3% |
"""
# A session with history running a standard-window Claude model.
HISTORY_REPORT = """## Context Usage

**Model:** claude-sonnet-5
**Tokens:** 138.4k / 200k (69%)

| Category | Tokens | Percentage |
|----------|--------|------------|
| Messages | 129.2k | 64.6% |
"""

SESSION = "claude_ctx_probe"
TURN_ID = "turn_ctx_probe"
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


def _session(probe: ClaudeContextProbe | None = None) -> ClaudeSession:
    session = ClaudeSession(session_id="sess_probe", external_session_id=SESSION)
    session.context_probe = probe
    return session


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


def test_parse_context_report_reads_the_verified_render() -> None:
    assert parse_context_report(FRESH_REPORT) == (
        "deepseek-v4.1-flash",
        1_000_000,
        12_200,
    )


def test_parse_context_report_reads_a_history_render() -> None:
    assert parse_context_report(HISTORY_REPORT) == ("claude-sonnet-5", 200_000, 138_400)


def test_parse_context_report_tolerates_spacing_variants() -> None:
    assert parse_context_report("**Model:**gateway-x\n**Tokens:**1m/1m(100%)") == (
        "gateway-x",
        1_000_000,
        1_000_000,
    )
    assert parse_context_report(
        "** Model : ** claude-opus-5  \n**Tokens:** 15.6 k / 1 M (2%)"
    ) == ("claude-opus-5", 1_000_000, 15_600)
    assert parse_context_report("**Model:** x\n**Tokens:** 200000 / 200k") == (
        "x",
        200_000,
        200_000,
    )
    assert parse_context_report("**Model:** x\n**Tokens:** 0.5k / 262144 (0%)") == (
        "x",
        262_144,
        500,
    )


def test_parse_context_report_missing_pieces_stay_none() -> None:
    # No model line: the tokens line still parses on its own.
    assert parse_context_report("**Tokens:** 12.2k / 1m (1%)") == (
        None,
        1_000_000,
        12_200,
    )
    # No tokens line: never inferred from the model or the table.
    assert parse_context_report("**Model:** x\n| Free space | 954.8k | 95.5% |") == (
        "x",
        None,
        None,
    )
    # An empty model line must not swallow the next line's first token.
    assert parse_context_report("**Model:**  \n**Tokens:** 12.2k / 1m") == (
        None,
        1_000_000,
        12_200,
    )
    for empty in (None, "", "   ", "no report here"):
        assert parse_context_report(empty) == (None, None, None)


def test_is_context_report_text_matches_only_the_report_shape() -> None:
    assert is_context_report_text(FRESH_REPORT)
    assert is_context_report_text("**Model:** x  \n**Tokens:** 1k / 2k (50%)")
    # Not the report: a heading-less message without the tokens line, prose
    # that merely mentions the markers, and empty input.
    assert not is_context_report_text("**Model:** x")
    assert not is_context_report_text("Here is a **Model:** line somewhere")
    assert not is_context_report_text(
        "## Some answer\n\n**Model:** x\n**Tokens:** 1k / 2k"
    )
    assert not is_context_report_text(None)
    assert not is_context_report_text("")


def test_report_frame_is_synthetic_control_chrome() -> None:
    # The reader's mint gate and the turn's content gate both ask this
    # question through `is_synthetic_control_message`; a leaked probe frame
    # must answer yes.
    frame = AssistantMessage(
        type="assistant",
        message={
            "role": "assistant",
            "content": [{"type": "text", "text": FRESH_REPORT}],
        },
        session_id=SESSION,
    )
    assert is_synthetic_control_message(frame)
    ordinary = AssistantMessage(
        type="assistant",
        message={
            "role": "assistant",
            "content": [{"type": "text", "text": "hello"}],
        },
        session_id=SESSION,
    )
    assert not is_synthetic_control_message(ordinary)


# ---------------------------------------------------------------------------
# Probe state machine
# ---------------------------------------------------------------------------


def test_probe_state_bounds_attempts_per_selection() -> None:
    probe = ClaudeContextProbe()
    policy = {"limit": 3, "backoff_seconds": 5.0}
    assert probe.attempt_allowed("default", now=0.0, **policy)

    probe.begin_attempt("default", now=0.0)
    probe.record("gateway-x", None, 10)
    assert probe.attempts == 1
    # Backoff: the next attempt waits, the one after it waits longer.
    assert not probe.attempt_allowed("default", now=1.0, **policy)
    assert probe.attempt_allowed("default", now=5.0, **policy)
    probe.begin_attempt("default", now=5.0)
    assert not probe.attempt_allowed("default", now=10.0, **policy)
    assert probe.attempt_allowed("default", now=15.0, **policy)
    probe.begin_attempt("default", now=15.0)
    assert probe.attempts == 3
    assert not probe.attempt_allowed("default", now=10_000.0, **policy)


def test_probe_state_selection_change_resets_generation() -> None:
    probe = ClaudeContextProbe(
        selection="default",
        model="gateway-x",
        window=1_000_000,
        used=1000,
        attempts=3,
        last_attempt_at=5.0,
    )
    assert probe.covers("default")
    # A different model selection is a fresh generation: the budget restarts.
    assert probe.attempt_allowed("sonnet", now=5.0, limit=3, backoff_seconds=5.0)

    probe.begin_attempt("sonnet", now=6.0)
    assert probe.attempts == 1
    assert probe.model is None and probe.window is None and probe.used is None

    probe.record("claude-sonnet-5", 200_000, 138_400)
    assert probe.covers("sonnet")
    assert not probe.attempt_allowed(
        "sonnet", now=1000.0, limit=3, backoff_seconds=5.0
    )


def test_probe_state_ignores_failed_generations() -> None:
    probe = ClaudeContextProbe(selection=None, attempts=1, last_attempt_at=0.0)
    # No window recorded: still not covered, retries when the backoff allows.
    assert not probe.covers(None)
    assert not probe.attempt_allowed(None, now=1.0, limit=3, backoff_seconds=5.0)
    assert probe.attempt_allowed(None, now=5.0, limit=3, backoff_seconds=5.0)


# ---------------------------------------------------------------------------
# Enrichment
# ---------------------------------------------------------------------------


def test_enrich_usage_probe_wins_over_the_frame_model() -> None:
    probe = ClaudeContextProbe(model="deepseek-v4.1-flash", window=1_000_000)
    enriched = enrich_usage(USAGE_WIRE, model="claude-opus-5-5[1m]", probe=probe)
    assert enriched == {
        **USAGE_WIRE,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 1_000_000,
    }


def test_enrich_usage_falls_back_to_the_id_rules() -> None:
    counts = {
        "inputTokens": 1,
        "outputTokens": 0,
        "cacheReadTokens": 0,
        "cacheCreationTokens": 0,
    }
    # No probe yet: the `[1m]` marker and the claude family still size the row.
    assert enrich_usage(counts, model="claude-opus-5-5[1m]")["contextWindow"] == 1_000_000
    assert enrich_usage(counts, model="claude-sonnet-5")["contextWindow"] == 200_000
    # A gateway model carries no window information: the key is omitted, the
    # model is still named, and nothing is null.
    assert enrich_usage(counts, model="mimo-v2.6-flash") == {
        **counts,
        "model": "mimo-v2.6-flash",
    }
    # A probe that named a model but reported no window falls back the same
    # way (and omits the key for a model the rules cannot size).
    probed = ClaudeContextProbe(model="deepseek-v4.1-flash")
    assert enrich_usage(counts, model="claude-sonnet-5", probe=probed) == {
        **counts,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 200_000,
    }
    assert "contextWindow" not in enrich_usage(counts, model=None, probe=probed)


def test_enrich_usage_never_emits_null_or_empty_blocks() -> None:
    assert enrich_usage(None) is None
    assert enrich_usage({}) is None
    enriched = enrich_usage(
        {
            "inputTokens": 5,
            "outputTokens": 0,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
        },
        model=None,
        probe=ClaudeContextProbe(),
    )
    assert enriched is not None
    assert all(value is not None for value in enriched.values())
    assert "model" not in enriched and "contextWindow" not in enriched


def test_stamped_items_carry_the_probe_window() -> None:
    probe = ClaudeContextProbe(model="deepseek-v4.1-flash", window=1_000_000)
    session = _session(probe)
    projector = ClaudeMessageProjector()

    item = projector.message_item(
        session=session,
        turn_id=TURN_ID,
        role="assistant",
        text="hi",
        event="claude.turn.assistant",
        native_item_id="msg_probe",
        usage=USAGE_WIRE,
        usage_model="claude-opus-5-5",
    )
    assert item.content["usage"] == {
        **USAGE_WIRE,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 1_000_000,
    }

    reasoning = projector.reasoning_item(
        session=session,
        turn_id=TURN_ID,
        native_message_id="msg_probe",
        block_index=0,
        text="why",
        status="done",
        revision=1,
        usage=USAGE_WIRE,
    )
    assert reasoning.content["usage"]["contextWindow"] == 1_000_000
    assert reasoning.content["usage"]["model"] == "deepseek-v4.1-flash"


def test_tool_and_reasoning_rows_carry_the_probe_window() -> None:
    probe = ClaudeContextProbe(model="deepseek-v4.1-flash", window=1_000_000)
    session = _session(probe)
    projector = ClaudeMessageProjector()
    frame = SimpleNamespace(
        type="assistant",
        usage=USAGE_RAW,
        message={
            "role": "assistant",
            "model": "claude-opus-5-5",
            "content": [
                {"type": "thinking", "thinking": "why"},
                {
                    "type": "tool_use",
                    "id": "tool_probe",
                    "name": "Bash",
                    "input": {"command": "ls"},
                },
            ],
        },
    )

    tool_items = projector.tool_items_for_message(
        session=session,
        turn_id=TURN_ID,
        message=frame,
    )
    assert len(tool_items) == 1
    assert tool_items[0].content["usage"] == {
        **USAGE_WIRE,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 1_000_000,
    }

    system_items = projector.system_items_for_message(
        session=session,
        turn_id=TURN_ID,
        message=frame,
        event="claude.turn.system",
    )
    reasoning = next(
        item
        for item in system_items
        if item.content.get("blockType") == "thinking"
    )
    assert reasoning.content["usage"] == {
        **USAGE_WIRE,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 1_000_000,
    }


def test_stamped_items_fall_back_to_the_id_rules_without_a_probe() -> None:
    projector = ClaudeMessageProjector()
    counts = {
        "inputTokens": 1,
        "outputTokens": 0,
        "cacheReadTokens": 0,
        "cacheCreationTokens": 0,
    }
    item = projector.message_item(
        session=_session(),
        turn_id=TURN_ID,
        role="assistant",
        text="hi",
        event="claude.turn.assistant",
        native_item_id="msg_noprobe",
        usage=counts,
        usage_model="claude-sonnet-5",
    )
    assert item.content["usage"] == {
        **counts,
        "model": "claude-sonnet-5",
        "contextWindow": 200_000,
    }


def test_streamed_rows_carry_the_probe_window_and_frame_model() -> None:
    probe = ClaudeContextProbe(model="deepseek-v4.1-flash", window=1_000_000)
    session = _session(probe)
    accumulator = ClaudeStreamAccumulator()
    projector = ClaudeMessageProjector()

    accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream(
            {
                "type": "message_start",
                "message": {
                    "id": "msg_stream",
                    "model": "deepseek-v4.1-flash",
                    "usage": {"input_tokens": 10, "output_tokens": 0},
                },
            }
        ),
        projector=projector,
    )
    item = accumulator.item_from_stream_event(
        session=session,
        turn_id=TURN_ID,
        message=_stream(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "hi"},
            }
        ),
        projector=projector,
    )
    assert item is not None
    assert item.content["usage"] == {
        "inputTokens": 10,
        "outputTokens": 0,
        "cacheReadTokens": 0,
        "cacheCreationTokens": 0,
        "model": "deepseek-v4.1-flash",
        "contextWindow": 1_000_000,
    }


def _stream(event: dict[str, Any]) -> StreamEvent:
    return StreamEvent(
        uuid="stream_uuid_probe",
        session_id=SESSION,
        event=event,
        parent_tool_use_id=None,
    )


# ---------------------------------------------------------------------------
# Calibration lifecycle
# ---------------------------------------------------------------------------


class _ContextReportClaudeClient(_ScheduledClaudeClient):
    """A streaming transport that answers `/context` the way the CLI does.

    All other prompts take the ordinary scheduled-fake path (echo + reply), so
    one client drives both the turns and the probe. Its replies carry usage —
    the shape a real assistant frame has — so stamped items can be asserted.
    """

    def __init__(self, report: str = FRESH_REPORT) -> None:
        super().__init__()
        self.report = report
        self.context_queries = 0
        self.hold_context = False
        #: Let a turn stay live: its prompt is recorded but never answered.
        self.hold_prompts = False

    async def query(self, prompt: Any) -> None:
        if not isinstance(prompt, str) or prompt != context_probe.CLAUDE_CONTEXT_PROMPT:
            if self.hold_prompts:
                if not isinstance(prompt, str):
                    async for message in prompt:
                        self.prompt_uuids.append(message["uuid"])
                        self.queries.append(message["message"]["content"])
                else:
                    self.queries.append(prompt)
                return
            await super().query(prompt)
            return
        self.queries.append(prompt)
        self.context_queries += 1
        await self._answer_context()

    async def _answer_context(self) -> None:
        if self.hold_context:
            return
        # The verified frame order (2026-10-08): an init SystemMessage, the
        # assistant rendering, then the result envelope that repeats it.
        await self.incoming.put(
            SimpleNamespace(type="system", subtype="init", data={"subtype": "init"})
        )
        await self.incoming.put(
            AssistantMessage(
                uuid="assistant_context",
                session_id=self.native_id,
                content=[{"type": "text", "text": self.report}],
            )
        )
        await self.incoming.put(
            SimpleNamespace(
                type="result",
                session_id=self.native_id,
                result=self.report,
            )
        )

    async def reply(self, text: str) -> None:
        await self.incoming.put(
            AssistantMessage(
                uuid=f"assistant_{text}",
                session_id=self.native_id,
                content=[{"type": "text", "text": text}],
                usage=USAGE_RAW,
            )
        )
        await self.incoming.put(
            SimpleNamespace(type="result", session_id=self.native_id)
        )


def _streaming_runtime(client: Any):
    sdk = _default_sdk()
    sdk.HookMatcher = _FakeHookMatcher
    host = _RecordingHost()
    runtime = _runtime(
        client=client,
        sdk=sdk,
        host=host,
        config=_config(idle_timeout_seconds=3600),
    )
    return runtime, host


def _context_queries(client: Any) -> int:
    return client.queries.count(context_probe.CLAUDE_CONTEXT_PROMPT)


def test_turn_end_calibrates_the_window_without_touching_the_timeline() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            assert session.active_task is not None
            await asyncio.wait_for(session.active_task, 5)

            probe = session.context_probe
            assert probe is not None
            assert (probe.model, probe.window, probe.used) == (
                "deepseek-v4.1-flash",
                1_000_000,
                12_200,
            )
            assert probe.attempts == 1
            assert _context_queries(client) == 1
            # The probe never projects: nothing on the timeline carries the
            # report's text.
            assert not any(
                "Context Usage" in str(item.content)
                or "**Model:**" in str(item.content)
                for item in host.timeline_item_upserts
            )
            # And the turn machinery is untouched: the turn settled, no
            # execution is held, and the probe minted no turn state.
            assert session.execution is None
            assert host.session_state_updates[-1]["status"] == "idle"
            assert len(host.session_turn_ends) == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_stamped_items_carry_the_calibrated_window_after_the_probe() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.window == 1_000_000

            await runtime.start_turn("sess_probe", None, "again")
            await asyncio.wait_for(session.active_task, 5)

            # The probe is cached per model selection: one calibration for the
            # whole session, and every later row carries its window.
            assert _context_queries(client) == 1
            assistant_items = [
                item for item in host.timeline_item_upserts if item.role == "assistant"
            ]
            assert assistant_items
            assert any(
                item.content["usage"] == {
                    **USAGE_WIRE,
                    "model": "deepseek-v4.1-flash",
                    "contextWindow": 1_000_000,
                }
                for item in assistant_items
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_model_selection_change_recalibrates_the_window() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.window == 1_000_000

            # The rebuilt transport answers with the new engine's declaration.
            client.report = HISTORY_REPORT
            model = next(
                model
                for model in (await runtime.list_model_catalog()).models
                if model.id == "claude-sonnet-5"
            )
            result = await runtime.update_session_selections(
                "sess_probe",
                None,
                {"model": model.selection_id},
            )
            assert result.ok is True
            await _wait_until(
                lambda: session.context_probe.window == 200_000
            )
            assert session.context_probe.model == "claude-sonnet-5"
            assert _context_queries(client) == 2
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_never_runs_while_a_turn_is_registered() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        client.hold_prompts = True
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            assert isinstance(session.execution, ClaudeExecution)
            # A turn is live: the calibration call must be a no-op, and it must
            # not wait on anything either.
            await asyncio.wait_for(
                runtime._turns.runner.calibrate_context_window(session),
                1,
            )
            assert _context_queries(client) == 0
            assert session.context_probe is None
            await _wait_until(lambda: client.queries == ["hello"])
        finally:
            # The stop path interrupts the held turn.
            await runtime.stop()

    asyncio.run(run())


def test_probe_attempts_are_bounded_per_model_selection() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient(report="I could not read that.")
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            # The turn end attempted once and recorded the failure.
            assert session.context_probe.attempts == 1

            # Fast-forward the backoff so each explicit call retries; the
            # ledger never exceeds the limit.
            runner = runtime._turns.runner
            for _ in range(context_probe.CONTEXT_PROBE_RETRY_LIMIT + 3):
                session.context_probe.last_attempt_at -= (
                    10 * context_probe.CONTEXT_PROBE_RETRY_BACKOFF_SECONDS
                )
                await runner.calibrate_context_window(session)
            assert (
                session.context_probe.attempts
                == context_probe.CONTEXT_PROBE_RETRY_LIMIT
            )
            assert _context_queries(client) == context_probe.CONTEXT_PROBE_RETRY_LIMIT
            # The failed probe never took the transport down, and the session
            # keeps working.
            assert not client.disconnected
            await runtime.start_turn("sess_probe", None, "again")
            await asyncio.wait_for(session.active_task, 5)
            assert host.session_turn_ends[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_waits_out_the_backoff_between_attempts() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient(report="garbage")
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.attempts == 1

            # The immediate second turn is blocked by the backoff.
            await runtime.start_turn("sess_probe", None, "again")
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.attempts == 1
            assert _context_queries(client) == 1

            # Once the window has passed, the retry goes out.
            session.context_probe.last_attempt_at -= (
                10 * context_probe.CONTEXT_PROBE_RETRY_BACKOFF_SECONDS
            )
            await runtime.start_turn("sess_probe", None, "third")
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.attempts == 2
            assert _context_queries(client) == 2
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_timeout_leaves_the_session_usable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def run() -> None:
        monkeypatch.setattr(context_probe, "CONTEXT_PROBE_TIMEOUT_SECONDS", 0.05)
        client = _ContextReportClaudeClient()
        client.hold_context = True
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert session.context_probe.window is None
            assert client.disconnected is False

            # The transport is still usable: the next turn routes normally.
            client.hold_context = False
            await runtime.start_turn("sess_probe", None, "again")
            await asyncio.wait_for(session.active_task, 5)
            assert len(host.session_turn_ends) == 2
            assert host.session_turn_ends[-1]["outcome"] == "completed"
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_late_report_frames_never_mint_a_turn_or_a_bubble(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def run() -> None:
        monkeypatch.setattr(context_probe, "CONTEXT_PROBE_TIMEOUT_SECONDS", 0.05)
        client = _ContextReportClaudeClient()
        client.hold_context = True
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)

            # The report arrives after the probe gave up. Chrome buffering is
            # what keeps it from minting a scheduled turn from its own text.
            await client._answer_context()
            await asyncio.sleep(0.05)
            assert not any(
                "Context Usage" in str(item.content)
                for item in host.timeline_item_upserts
            )
            assert len(host.session_turn_ends) == 1

            # The next turn still owns its own frames and ends normally.
            await runtime.start_turn("sess_probe", None, "again")
            await asyncio.wait_for(session.active_task, 5)
            assert len(host.session_turn_ends) == 2
            assert host.session_turn_ends[-1]["outcome"] == "completed"
            assert not any(
                "Context Usage" in str(item.content)
                for item in host.timeline_item_upserts
            )
            # The failed generation's backoff holds: no retry went out.
            assert _context_queries(client) == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_is_skipped_for_sessions_hosting_scheduled_work() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "schedule")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections["sess_probe"]
            assert connection.task_ids
            # An uninvited wake can arrive in a session with scheduled tasks;
            # a probe holding the reader would swallow it, so none is run.
            assert _context_queries(client) == 0
            assert session.context_probe is None
        finally:
            await runtime.stop()

    asyncio.run(run())


# ---------------------------------------------------------------------------
# The background sweep (the third trigger, T1/T2/T3)
# ---------------------------------------------------------------------------


def test_sweep_probes_an_uncovered_idle_session() -> None:
    """A live idle transport with no cached window is probed by the sweep.

    This is the 2026-10-08 incident shape: the connector restarted, the probe
    cache was gone, and a session that ran no new turn never recalibrated.
    """

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert _context_queries(client) == 1  # the turn-end trigger

            # The restart wiped the in-memory probe; no turn has run since.
            session.context_probe = None
            runner = runtime._turns.runner
            assert "sess_probe" in runner.connections

            await runner._sweep_uncovered_sessions()

            assert session.context_probe is not None
            assert session.context_probe.window == 1_000_000
            assert _context_queries(client) == 2
            # The sweep never projects: nothing on the timeline carries the
            # report's text.
            assert not any(
                "Context Usage" in str(item.content)
                for item in _host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_sweep_is_a_noop_when_covered_or_the_transport_is_absent() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            assert session.context_probe.covers(session.selections.get("model"))

            # Already covered: no repeat probe, however often the sweep runs.
            for _ in range(3):
                await runner._sweep_uncovered_sessions()
            assert _context_queries(client) == 1

            # A session with no live transport is skipped outright — the sweep
            # must never force-create a transport just to probe.
            idle_session = runner.session_store.ensure(
                session_id="sess_no_transport",
                external_session_id="claude_no_transport",
            )
            idle_session.selections = dict(session.selections)
            await runner._sweep_uncovered_sessions()
            assert idle_session.context_probe is None
            assert "sess_no_transport" not in runner.connections
            assert _context_queries(client) == 1
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_sweep_never_probes_while_a_turn_is_registered() -> None:
    async def run() -> None:
        client = _ContextReportClaudeClient()
        client.hold_prompts = True
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            assert isinstance(session.execution, ClaudeExecution)
            # The sweep consults the same gates: a registered turn blocks it.
            await runtime._turns.runner._sweep_uncovered_sessions()
            assert _context_queries(client) == 0
            assert session.context_probe is None
        finally:
            # The stop path interrupts the held turn.
            await runtime.stop()

    asyncio.run(run())


def test_sweep_never_probes_a_transport_that_can_receive_uninvited_frames() -> None:
    """The swallow-frames red line: scheduled task ids and background work.

    Both mean a frame the connector did not ask for can arrive on this
    transport; a probe holding the reader would swallow it, so neither may be
    probed. Regression for the safety gates the sweep must reuse, not loosen.
    """

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "schedule")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            connection = runner.connections["sess_probe"]
            assert connection.task_ids
            session.context_probe = None

            # Scheduled task ids present: no probe, no window.
            await runner._sweep_uncovered_sessions()
            assert _context_queries(client) == 0
            assert session.context_probe is None

            # Same transport, task ids clear but background work live.
            connection.task_ids.clear()
            connection.background.active_ids.add("bg_1")
            await runner._sweep_uncovered_sessions()
            assert _context_queries(client) == 0
            assert session.context_probe is None
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_start_arms_the_sweep_and_first_tick_probes_a_warm_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A transport already live and idle is probed on the sweep's first tick.

    Covers the connector-startup case without force-creating anything: the
    session's transport was left warm, the window is uncovered, and `start`
    arms the sweep which probes it on the very next tick.
    """

    async def run() -> None:
        monkeypatch.setattr(
            lifecycle, "CONTEXT_PROBE_SWEEP_INTERVAL_SECONDS", 0.01
        )
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn("sess_probe", None, "hello")
            session = runtime._sessions["sess_probe"]
            await asyncio.wait_for(session.active_task, 5)
            assert _context_queries(client) == 1
            # Simulate the restart: warm transport, wiped cache, no new turn.
            session.context_probe = None

            await runtime.start()
            runner = runtime._turns.runner
            assert runner.sweep_task is not None

            # Real-time wait: `_wait_until` only yields, so it would not let
            # the sweep's interval timer fire.
            for _ in range(200):
                if (
                    session.context_probe is not None
                    and session.context_probe.window == 1_000_000
                ):
                    break
                await asyncio.sleep(0.01)
            assert session.context_probe is not None
            assert session.context_probe.window == 1_000_000
            assert _context_queries(client) == 2
        finally:
            await runtime.stop()
        assert runtime._turns.runner.sweep_task is None

    asyncio.run(run())


# ---------------------------------------------------------------------------
# History rebuilds (the last writer for every settled row)
# ---------------------------------------------------------------------------


def test_history_rebuild_carries_the_calibrated_window() -> None:
    """The settled rebuild republishes the same item ids the live stream wrote.

    Its projection session must carry the engine probe, or the last write for
    every settled row drops `contextWindow` — the client's ring flashed during
    a turn and vanished once the turn settled (live symptom, 2026-10-08).
    """

    probe = ClaudeContextProbe(model="deepseek-v4.1-flash", window=1_000_000)
    session = _session(probe)
    message = SimpleNamespace(
        message={
            "role": "assistant",
            "model": "deepseek-v4.1-flash",
            "usage": USAGE_RAW,
            "content": [{"type": "text", "text": "hello"}],
        }
    )
    items = _history_items_from_messages(session, (message,))
    stamped = [
        item
        for item in items
        if item.type == "message" and "usage" in item.content
    ]
    assert stamped, "the rebuild must stamp the assistant message"
    assert stamped[0].content["usage"]["contextWindow"] == 1_000_000
    assert stamped[0].content["usage"]["model"] == "deepseek-v4.1-flash"


def test_history_projection_session_factory_carries_the_probe() -> None:
    probe = ClaudeContextProbe(model="m", window=1_000)
    session = _history_session(
        "sess_probe",
        SESSION,
        None,
        context_probe=probe,
    )
    assert session.context_probe is probe
