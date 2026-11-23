"""Maintenance responses must not steal a wake reply's turn identity.

Production incident (2026-11-24 01:42 CST, sess_ddUX1KTcAEiFrw): a background
task's terminal notification armed the CLI's wake reply, and a context-window
probe (the 5 s sweep) claimed the transport in the gap before the reply's
first frame. The probe consumed that first message's frames, so the live mint
anchored the scheduled turn on the SECOND assistant message while the history
projection anchored it on the first. One contiguous tool run was split into
two step groups on every client.

The contract pinned here:

* a context probe yields at the first frame it cannot prove is its own, and
  hands that message's id back as the deferred anchor;
* a scheduled mint whose cast frame is a later message adopts the deferred
  anchor (and, in production, the transcript scan) instead of the cast frame;
* no calibration runs while a wake reply is owed — the gate that keeps the
  probe out of the window in the first place.

修前红: the probe holds the stream for its whole timeout and the mint anchors
on ``msg_wake_second`` (or nothing mints at all).
"""

from __future__ import annotations

import asyncio
import time
from types import SimpleNamespace
from typing import Any

import pytest

from test_claude_background_guard import (
    WIRE_TASK_NOTIFICATION_COMPLETED,
    WIRE_WAKE_ASSISTANT,
    WIRE_WAKE_RESULT,
    _parse,
)
from test_claude_compact_ghost import _wait_until
from test_claude_context_probe import (
    _ContextReportClaudeClient,
    _context_queries,
    _streaming_runtime,
)
from test_claude_runtime import (
    RECONCILE_PROMPT,
    AssistantMessage,
    StreamEvent,
    SystemMessage,
    _ReconcileClaudeClient,
    _ScheduledClaudeClient,
)

from connector.runtimes.claude.sdk.background import (
    WAKE_OWED_TIMEOUT_SECONDS,
    ClaudeBackgroundTasks,
)
from connector.runtimes.claude.sessions.reader import _history_turn_id
from connector.runtimes.claude.turns import lifecycle

SESSION = "sess_anchor"


def _message_start(message_id: str) -> Any:
    return StreamEvent(
        uuid=f"stream-{message_id}",
        session_id="native_timer",
        event={
            "type": "message_start",
            "message": {"id": message_id, "role": "assistant"},
        },
    )


def test_wake_owed_lifecycle() -> None:
    """The debt flag is set by a terminal task frame and clears on demand."""

    background = ClaudeBackgroundTasks()
    assert background.wake_owed() is False

    # A non-terminal update is work starting, not a reply owed.
    background.observed(
        {"subtype": "task_updated", "task_id": "t1", "patch": {"status": "running"}}
    )
    assert background.wake_owed() is False
    # A terminal update only patches a card; the CLI's wake promise is the
    # notice, and arming the window on updates would starve maintenance for
    # every drained task (the deferred-reconciliation tests model that shape).
    background.observed(
        {"subtype": "task_updated", "task_id": "t1", "patch": {"status": "completed"}}
    )
    assert background.wake_owed() is False

    background.observed(
        {"subtype": "task_notification", "task_id": "t1", "status": "completed"}
    )
    assert background.wake_owed() is True

    # The bound: a wake that never arrives must not block maintenance forever.
    assert (
        background.wake_owed(now=time.monotonic() + WAKE_OWED_TIMEOUT_SECONDS + 1)
        is False
    )
    # ...and the expired flag is dropped, not merely reported false.
    assert background.wake_owed() is False

    background.observed(
        {"subtype": "task_notification", "task_id": "t2", "status": "completed"}
    )
    assert background.wake_owed() is True
    background.clear_wake_owed()
    assert background.wake_owed() is False


def test_calibration_skips_while_a_wake_reply_is_owed() -> None:
    """The incident's window: a probe must never claim the transport inside it."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            connection = runner.connections[SESSION]
            await _wait_until(lambda: connection.current is None)
            baseline = _context_queries(client)
            # Force the next explicit call to be a real probe, not a no-op
            # behind an already-calibrated report.
            session.context_probe = None

            # The background task finishes: the CLI now owes a wake reply.
            await client.incoming.put(_parse(WIRE_TASK_NOTIFICATION_COMPLETED))
            await _wait_until(lambda: connection.background.wake_owed())
            assert connection.background.active_ids == set()

            await asyncio.wait_for(
                runner.calibrate_context_window(session), 2
            )
            assert _context_queries(client) == baseline, (
                "a probe taken inside the wake window would swallow the reply"
            )
            assert session.context_probe is None

            # The wake reply lands; minting its turn satisfies the debt.
            await client.incoming.put(_parse(WIRE_WAKE_ASSISTANT))
            await client.incoming.put(_parse(WIRE_WAKE_RESULT))
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
            assert connection.background.wake_owed() is False

            # Maintenance is allowed again — the turn-end settle or this
            # explicit call calibrates the transport.
            await asyncio.wait_for(
                runner.calibrate_context_window(session), 2
            )
            await _wait_until(lambda: _context_queries(client) > baseline)
            assert session.context_probe is not None
            assert session.context_probe.window == 1_000_000
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_yields_and_the_mint_anchors_on_the_first_message() -> None:
    """The incident replayed under the fix: yield at the first foreign frame."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            connection = runner.connections[SESSION]
            # Let the turn-end calibration settle: its count is the baseline
            # this test must not disturb while the wake reply is in flight.
            await _wait_until(
                lambda: session.context_probe is not None
                and session.context_probe.window is not None
            )
            baseline = _context_queries(client)

            session.context_probe = None
            client.hold_context = True
            probe_task = asyncio.create_task(
                runner.calibrate_context_window(session)
            )
            await _wait_until(
                lambda: connection.current is not None
                and connection.current.maintenance
            )
            assert _context_queries(client) == baseline + 1

            # The wake reply's first message starts inside the probe's window.
            await client.incoming.put(_message_start("msg_wake_first"))
            # The probe must yield at once (its own timeout is 5 s), without
            # consuming anything else or retrying.
            await asyncio.wait_for(probe_task, 1)
            assert session.context_probe is not None
            assert session.context_probe.window is None
            assert _context_queries(client) == baseline + 1
            assert connection.current is None

            # The next visible frame is the SECOND message. Its own id would
            # be the wrong anchor — the yielded message's id is the right one.
            await client.incoming.put(_message_start("msg_wake_second"))
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            assert execution is not None
            assert execution.turn_id == _history_turn_id("msg_wake_first"), (
                "a frame swallowed by maintenance must still anchor the turn"
            )

            await client.incoming.put(
                AssistantMessage(
                    uuid="row_wake_second",
                    message_id="msg_wake_second",
                    session_id="native_timer",
                    model="test-model",
                    content=[{"type": "text", "text": "wake answer"}],
                )
            )
            await client.incoming.put(
                SimpleNamespace(type="result", session_id="native_timer")
            )
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
            assert any(
                item.role == "assistant"
                and item.content.get("text") == "wake answer"
                and item.turn_id == _history_turn_id("msg_wake_first")
                for item in host.timeline_item_upserts
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_reconcile_skips_while_a_wake_reply_is_owed() -> None:
    """The reconcile path shares the window: no task-list prompt may claim it."""

    async def run() -> None:
        client = _ReconcileClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("timer", None, "hello")
            session = runtime._sessions["timer"]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            connection = runner.connections["timer"]
            # Let the turn-end calibration finish: its own probe legitimately
            # claims the transport first (that gate passes when nothing else
            # is live), and the reconcile below must start from idle.
            await _wait_until(
                lambda: connection.current is None
                and session.execution is None
                and _context_queries(client) >= 1
            )
            # A live scheduled task is what makes the transport "retained"
            # and reconciliation due; the fake needs no real CronCreate.
            connection.task_ids.add("timer_1")
            assert connection.retained

            # The background task finishes: the CLI now owes a wake reply.
            await client.incoming.put(_parse(WIRE_TASK_NOTIFICATION_COMPLETED))
            await _wait_until(lambda: connection.background.wake_owed())

            connection.reconcile_needed = True
            await runner.reconcile_after_background(session, connection)
            await asyncio.sleep(0.05)
            assert RECONCILE_PROMPT not in client.queries, (
                "reconcile_tasks holds the reader and the maintenance tool "
                "lock; inside the wake window it would starve the reply"
            )

            # The wake reply lands and its mint satisfies the debt; the next
            # reconciliation is allowed again.
            await client.incoming.put(_parse(WIRE_WAKE_ASSISTANT))
            await client.incoming.put(_parse(WIRE_WAKE_RESULT))
            await _wait_until(
                lambda: connection.background.wake_owed() is False
                and session.execution is None
                and connection.current is None
            )
            # The wake turn's own end re-runs reconciliation (minting it
            # cleared the debt) — production has no manual retry, so the test
            # waits for that path rather than faking one.
            await _wait_until(lambda: RECONCILE_PROMPT in client.queries)
            assert connection.task_ids == set()
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_a_stale_transcript_anchor_never_merges_two_scheduled_turns(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A scan older than this turn's boundary must not re-key the new turn.

    Merging two turns is worse than the split this resolver repairs, so the
    resolver's answer is ignored when it names the turn that was just minted.
    """

    async def run() -> None:
        client = _ScheduledClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn("timer", None, "hello")
            session = runtime._sessions["timer"]
            await asyncio.wait_for(session.active_task, 5)

            await client.reply("first wake")
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
            first_id = host.session_turn_ends[-1]["turn_id"]

            async def stale_resolver(_session: Any) -> str:
                return first_id

            monkeypatch.setattr(
                lifecycle, "resolve_scheduled_turn_anchor", stale_resolver
            )

            await client.reply("second wake")
            await _wait_until(lambda: len(host.session_turn_ends) >= 3)
            second_id = host.session_turn_ends[-1]["turn_id"]
            assert second_id != first_id
            # The frame anchor is the honest fallback: the reply's row uuid.
            assert second_id == _history_turn_id("assistant_second wake")
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_mint_prefers_the_transcript_anchor_over_the_cast_frame(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The resolver's answer wins over whatever frame happened to mint."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections[SESSION]
            await _wait_until(
                lambda: connection.current is None and _context_queries(client) >= 1
            )

            async def resolver(_session: Any) -> str:
                return _history_turn_id("msg_wake_first")

            monkeypatch.setattr(
                lifecycle, "resolve_scheduled_turn_anchor", resolver
            )

            # The reader only sees the SECOND message; the transcript says the
            # turn started at the first one.
            await client.incoming.put(_message_start("msg_wake_second"))
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            assert execution is not None
            assert execution.turn_id == _history_turn_id("msg_wake_first")

            await client.incoming.put(
                AssistantMessage(
                    uuid="row_wake_second",
                    message_id="msg_wake_second",
                    session_id="native_timer",
                    model="test-model",
                    content=[{"type": "text", "text": "wake answer"}],
                )
            )
            await client.incoming.put(
                SimpleNamespace(type="result", session_id="native_timer")
            )
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
            assert host.session_turn_ends[-1]["turn_id"] == _history_turn_id(
                "msg_wake_first"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_deferred_bind_uses_the_transcript_anchor(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A reconnect-shaped mint rebinds to the transcript's first message."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections[SESSION]
            await _wait_until(
                lambda: connection.current is None and _context_queries(client) >= 1
            )

            calls = {"n": 0}

            async def resolver(_session: Any) -> str | None:
                # The mint's cast frame carries no anchor, so it gets nothing
                # from the transcript yet; the first anchor-bearing frame must
                # bind to the transcript's first message, not to itself.
                calls["n"] += 1
                return None if calls["n"] == 1 else _history_turn_id(
                    "msg_wake_first"
                )

            monkeypatch.setattr(
                lifecycle, "resolve_scheduled_turn_anchor", resolver
            )

            await client.incoming.put(
                StreamEvent(
                    uuid="wake-delta",
                    session_id="native_timer",
                    event={
                        "type": "content_block_delta",
                        "delta": {"type": "text_delta", "text": "wake"},
                    },
                )
            )
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            assert execution is not None
            assert execution.turn_id != _history_turn_id("msg_wake_first")

            await client.incoming.put(
                AssistantMessage(
                    uuid="row_wake_second",
                    message_id="msg_wake_second",
                    session_id="native_timer",
                    model="test-model",
                    content=[{"type": "text", "text": "wake answer"}],
                )
            )
            await _wait_until(
                lambda: session.execution is not None
                and session.execution.turn_id == _history_turn_id("msg_wake_first")
            )
            await client.incoming.put(
                SimpleNamespace(type="result", session_id="native_timer")
            )
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
            assert host.session_turn_ends[-1]["turn_id"] == _history_turn_id(
                "msg_wake_first"
            )
            assert all(
                item.turn_id == _history_turn_id("msg_wake_first")
                for item in host.timeline_item_upserts
                if item.role == "assistant"
                and item.content.get("text") == "wake answer"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_peer_frame_mint_keeps_the_hint_and_the_debt() -> None:
    """A user-frame mint is not the wake reply: it must not consume either."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            connection = runtime._turns.runner.connections[SESSION]
            await _wait_until(lambda: connection.current is None)

            connection.note_deferred_anchor("msg_other_turn")
            connection.background.note_wake_owed()

            await client.incoming.put(
                SimpleNamespace(
                    type="user",
                    uuid="peer-1",
                    session_id="native_timer",
                    message={"role": "user", "content": "peer question"},
                )
            )
            await _wait_until(lambda: session.execution is not None)
            execution = session.execution
            assert execution is not None
            assert execution.turn_id != _history_turn_id("msg_other_turn")
            assert connection.deferred_anchor() == "msg_other_turn"
            assert connection.background.wake_owed() is True

            await client.incoming.put(
                AssistantMessage(
                    uuid="row_peer",
                    session_id="native_timer",
                    model="test-model",
                    content=[{"type": "text", "text": "peer answer"}],
                )
            )
            await client.incoming.put(
                SimpleNamespace(type="result", session_id="native_timer")
            )
            await _wait_until(lambda: len(host.session_turn_ends) >= 2)
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_calibration_skips_while_a_yielded_anchor_is_open() -> None:
    """After maintenance yields, the rest of the reply may still be streaming."""

    async def run() -> None:
        client = _ContextReportClaudeClient()
        runtime, _host = _streaming_runtime(client)
        try:
            await runtime.start_turn(SESSION, None, "hello")
            session = runtime._sessions[SESSION]
            await asyncio.wait_for(session.active_task, 5)
            runner = runtime._turns.runner
            connection = runner.connections[SESSION]
            await _wait_until(
                lambda: connection.current is None and _context_queries(client) >= 1
            )
            baseline = _context_queries(client)
            session.context_probe = None
            connection.note_deferred_anchor("msg_in_flight")

            await asyncio.wait_for(runner.calibrate_context_window(session), 2)
            assert _context_queries(client) == baseline
            assert session.context_probe is None

            connection.clear_deferred_anchor()
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_probe_classifier_reads_real_sdk_content_blocks() -> None:
    """The production content blocks are dataclasses, not dicts."""

    from claude_agent_sdk import (
        AssistantMessage as SdkAssistantMessage,
    )
    from claude_agent_sdk import TextBlock, ThinkingBlock, ToolUseBlock

    from connector.runtimes.claude.turns.context_probe import _probe_foreign_reason

    assert (
        _probe_foreign_reason(
            SdkAssistantMessage(
                content=[ThinkingBlock(thinking="x", signature="s")], model="m"
            )
        )
        == "assistant:reasoning"
    )
    assert (
        _probe_foreign_reason(
            SdkAssistantMessage(
                content=[ToolUseBlock(id="t1", name="Bash", input={})], model="m"
            )
        )
        == "assistant:tool_use"
    )
    # Plain text stays unjudged: a garbled report is still the probe's own
    # output, and its attempt ledger must record that failure.
    assert (
        _probe_foreign_reason(
            SdkAssistantMessage(content=[TextBlock(text="hello")], model="m")
        )
        is None
    )


def test_probe_classifier_keeps_the_real_command_frames_clean() -> None:
    """The live /context wire order: caveat, echo, local-command stdout."""

    from connector.runtimes.claude.turns.context_probe import _probe_foreign_reason

    caveat = SimpleNamespace(
        type="user",
        message={
            "role": "user",
            "content": "<local-command-caveat>Caveat: the messages below were "
            "generated by the user while running local commands.</local-command-caveat>",
        },
    )
    echo = SimpleNamespace(
        type="user",
        message={
            "role": "user",
            "content": "<command-name>/context</command-name>\n"
            "<command-message>context</command-message>",
        },
    )
    stdout = SimpleNamespace(
        type="user",
        message={"role": "user", "content": "<local-command-stdout>## Context Usage</local-command-stdout>"},
    )
    init = SystemMessage(subtype="init", data={"subtype": "init"})

    assert _probe_foreign_reason(caveat) is None
    assert _probe_foreign_reason(echo) is None
    assert _probe_foreign_reason(stdout) is None
    assert _probe_foreign_reason(init) is None


def test_probe_ignores_background_subagent_frames() -> None:
    """A subagent's frames must never become the main turn's anchor."""

    from connector.runtimes.claude.turns.context_probe import _probe_foreign_reason

    subagent = StreamEvent(
        uuid="sub-stream",
        session_id="native_timer",
        parent_tool_use_id="call_subagent",
        event={"type": "message_start", "message": {"id": "msg_subagent"}},
    )
    assert _probe_foreign_reason(subagent) is None

    main = _message_start("msg_wake_first")
    assert _probe_foreign_reason(main) == "message_start"


def test_resolve_scheduled_turn_anchor_reads_the_real_transcript(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """End to end through path resolution + the off-loop scan service."""

    from test_claude_turn_id import _assistant_row, _task_notification_row

    from connector.runtimes.claude.domain.session import ClaudeSession
    from connector.runtimes.claude.sessions.reader import (
        resolve_scheduled_turn_anchor,
    )
    from connector.runtimes.claude.sessions.subagent_oracle import claude_project_key

    async def run() -> None:
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
        cwd = "/home/ubuntu/aa-anchor-e2e"
        project_dir = tmp_path / "projects" / claude_project_key(cwd)
        project_dir.mkdir(parents=True)
        lines = (
            _task_notification_row("notice-1", "task done"),
            _assistant_row("row-one", "one", message_id="msg_one"),
            _assistant_row("row-two", "two", message_id="msg_two"),
        )
        (project_dir / "native_anchor_e2e.jsonl").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )
        session = ClaudeSession(
            session_id="sess_anchor_e2e",
            external_session_id="native_anchor_e2e",
            cwd=cwd,
        )
        assert (
            await resolve_scheduled_turn_anchor(session)
            == _history_turn_id("msg_one")
        )

    asyncio.run(run())


def test_scheduled_anchor_from_scan_matches_the_history_rule() -> None:
    """The transcript-side half: the first assistant after the notice wins."""

    from test_claude_turn_id import _assistant_row, _task_notification_row
    from test_claude_turn_id import _visible_user_row

    from connector.runtimes.claude.sessions.reader import scheduled_anchor_from_scan
    from connector.runtimes.claude.sessions.subagent_oracle import (
        scan_raw_transcript,
    )

    # (a) Two assistant rows after one notice share the first one's anchor.
    raw = (
        _task_notification_row("notice-1", "task done"),
        _assistant_row("row-one", "one", message_id="msg_one"),
        _assistant_row("row-two", "two", message_id="msg_two"),
    )
    assert (
        scheduled_anchor_from_scan(scan_raw_transcript(raw))
        == _history_turn_id("msg_one")
    )

    # (b) The latest turn is a user prompt: no scheduled row to anchor on.
    raw_user_after = (
        _task_notification_row("notice-1", "task done"),
        _assistant_row("row-one", "one", message_id="msg_one"),
        _visible_user_row("user-two", "next question"),
        _assistant_row("row-three", "three", message_id="msg_three"),
    )
    assert scheduled_anchor_from_scan(scan_raw_transcript(raw_user_after)) is None

    # (c) A row without an API message id falls back to the row uuid — the
    # same chain the SDK walk's `_history_assistant_turn_anchor` uses
    # (`message_id`, which falls back to `.uuid`).
    raw_no_id = (
        _task_notification_row("notice-1", "task done"),
        _assistant_row("row-one", "one"),
    )
    assert (
        scheduled_anchor_from_scan(scan_raw_transcript(raw_no_id))
        == _history_turn_id("row-one")
    )

    # (d) No notice at all: nothing to anchor.
    assert scheduled_anchor_from_scan(scan_raw_transcript(())) is None
