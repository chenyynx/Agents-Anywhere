"""Claude /compact behaviour, driven with the message shapes the CLI sends.

The compaction fixtures here are parsed through the SDK's own `parse_message`,
not hand-built namespaces. The SDK wraps every non-task system message in
`SystemMessage(subtype=..., data=<the whole raw frame>)`, so `status`,
`compact_result` and `compactMetadata` are only reachable through `.data`.
A fixture that puts them at the top level proves nothing: it describes a
message shape the CLI never produces.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtime_protocol import (
    RuntimeAttachmentContent,
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeStatus,
    RuntimeTimelineItem,
)
from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.timeline.markers import (
    ClaudeTimelineMarkers,
    claude_compact_event,
    is_claude_init_message,
    is_compaction_control_message,
    is_local_command_echo,
    stable_compact_item_id,
)
from connector.runtimes.claude.timeline.messages import (
    CLAUDE_COMPACT_SUMMARY_PREFIX,
    is_compact_summary_text,
)

COMPACT_SESSION = "claude_compact_session"
MODEL = "claude-opus-5"


def test_claude_execute_command_accepts_compact() -> None:
    asyncio.run(_test_claude_execute_command_accepts_compact())


async def _test_claude_execute_command_accepts_compact() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(messages=_compaction_messages())
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_cmd", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_cmd"].active_task
    assert result.ok is True
    assert result.command == "compact"
    assert result.result["executionState"] == "accepted"
    assert result.result["turnId"].startswith("turn_claude_")
    assert task is not None

    await task

    # The CLI dispatches the native command from the prompt itself.
    assert client.queries == ["/compact"]
    assert [update["status"] for update in host.session_state_updates] == [
        "waiting",
        "running",
        "idle",
    ]
    assert host.session_turn_ends[-1]["outcome"] == "completed"


def test_claude_command_turn_publishes_no_user_bubble() -> None:
    asyncio.run(_test_claude_command_turn_publishes_no_user_bubble())


async def _test_claude_command_turn_publishes_no_user_bubble() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_bubble", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_bubble"].active_task
    assert result.ok is True
    assert task is not None
    await task

    assert [item.role for item in host.timeline_item_upserts if item.role == "user"] == []
    assert {item.type for item in host.timeline_item_upserts} == {"marker"}
    recorded = runtime._sessions["sess_bubble"].timeline_items
    assert [item_id.startswith("claude_compact_") for item_id in recorded] == [True]


def test_claude_command_turn_flips_one_marker_through_its_states() -> None:
    asyncio.run(_test_claude_command_turn_flips_one_marker_through_its_states())


async def _test_claude_command_turn_flips_one_marker_through_its_states() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_marker", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_marker"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert len({item.id for item in markers}) == 1
    assert markers[0].id.startswith("claude_compact_")
    # The command turn opens the separator before dispatch, then the CLI's own
    # `status` frame repeats it. Both land on the same item id.
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "completed",
        "completed",
    ]
    assert [item.status for item in markers] == ["running", "running", "done", "done"]
    assert [item.content["kind"] for item in markers] == ["compact"] * 4
    assert [item.content["label"] for item in markers] == [
        "正在压缩上下文",
        "正在压缩上下文",
        "对话已压缩",
        "对话已压缩",
    ]
    # The boundary repeats the completed state; its metadata is what settles.
    assert "preTokens" not in markers[2].content
    assert markers[2].content["compactResult"] == "success"
    assert markers[3].content["trigger"] == "manual"
    assert markers[3].content["preTokens"] == 18_000
    assert markers[3].content["postTokens"] == 900
    assert markers[3].content["cumulativeDroppedTokens"] == 17_100
    assert markers[3].content["durationMs"] == 12_000
    assert markers[0].content_hash == markers[1].content_hash, (
        "the CLI's start frame repeats the dispatched marker without adding state"
    )
    assert markers[0].content_hash != markers[2].content_hash
    assert markers[0].turn_id == markers[1].turn_id
    assert markers[0].source["runtime"] == "claude"
    assert markers[0].source["sessionId"] == COMPACT_SESSION


def test_claude_command_turn_reads_the_real_sdk_compaction_fields() -> None:
    """The tri-state marker must survive the SDK's `.data` nesting.

    Every compaction field the CLI sends lives inside `SystemMessage.data`;
    reading only top-level attributes silently drops the start, the result and
    the boundary's token metadata, so the marker degenerates to one state.
    """

    started = parse_message(
        {"type": "system", "subtype": "status", "status": "compacting", "uuid": "u1"}
    )
    result = parse_message(
        {
            "type": "system",
            "subtype": "status",
            "status": None,
            "compact_result": "success",
            "uuid": "u2",
        }
    )
    boundary = parse_message(
        {
            "type": "system",
            "subtype": "compact_boundary",
            "content": "Conversation compacted",
            "uuid": "db0784f0-8567-4625-bb8c-4020043ee630",
            "compactMetadata": {
                "trigger": "manual",
                "preTokens": 35134,
                "postTokens": 1865,
                "cumulativeDroppedTokens": 33269,
                "durationMs": 13997,
                "preservedSegment": {"headUuid": "h", "anchorUuid": "a", "tailUuid": "t"},
            },
        }
    )
    # The premise: the payload is nested, never promoted to an attribute.
    for message in (started, result, boundary):
        assert not hasattr(message, "status")
        assert not hasattr(message, "compact_result")
        assert not hasattr(message, "compactMetadata")

    start_event = claude_compact_event(started)
    result_event = claude_compact_event(result)
    boundary_event = claude_compact_event(boundary)

    assert start_event is not None
    assert start_event.state == "started"
    assert start_event.native_message_id == "u1"
    assert result_event is not None
    assert result_event.state == "completed"
    assert dict(result_event.metadata) == {"compactResult": "success"}
    assert boundary_event is not None
    assert boundary_event.state == "completed"
    assert boundary_event.native_message_id == "db0784f0-8567-4625-bb8c-4020043ee630"
    assert dict(boundary_event.metadata)["preTokens"] == 35134
    assert dict(boundary_event.metadata)["cumulativeDroppedTokens"] == 33269


def test_claude_command_turn_settles_failed_without_any_cli_evidence() -> None:
    """A compaction the CLI never reports must still leave a verdict."""

    asyncio.run(_test_claude_command_turn_settles_failed_without_any_cli_evidence())


async def _test_claude_command_turn_settles_failed_without_any_cli_evidence() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient([_result()]))

    result = await runtime.execute_command("sess_silent", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_silent"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["started", "failed"]
    assert [item.status for item in markers] == ["running", "failed"]
    assert len({item.id for item in markers}) == 1


def test_claude_command_turn_suppresses_cli_control_messages() -> None:
    asyncio.run(_test_claude_command_turn_suppresses_cli_control_messages())


async def _test_claude_command_turn_suppresses_cli_control_messages() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_suppress", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_suppress"].active_task
    assert result.ok is True
    assert task is not None
    await task

    # The summary, the local-command echo and the init handshake are CLI
    # bookkeeping; none of them may reach the timeline.
    texts = [
        item.content.get("text")
        for item in host.timeline_item_upserts
        if isinstance(item.content.get("text"), str)
    ]
    assert texts == []
    assert {item.content["kind"] for item in host.timeline_item_upserts} == {"compact"}


def test_claude_suppression_owns_a_system_handshake_that_could_be_shown() -> None:
    """The suppression predicate, not the generic role/text gate, owns this.

    Every other CLI control frame is also invisible because it is a user
    message or has no text. An `init` handshake that carries text would be
    published as an ordinary system message without suppression, so it is the
    one shape that separates the two.
    """

    asyncio.run(_test_claude_suppression_owns_a_system_handshake_that_could_be_shown())


async def _test_claude_suppression_owns_a_system_handshake_that_could_be_shown() -> (
    None
):
    host = _RecordingHost()
    runtime = _runtime(
        host=host,
        client=_FakeClaudeClient(
            [
                # The raw CLI control frame, before the SDK wraps it in
                # `.data`: a system-role message with text, which the turn loop
                # would otherwise project.
                _INIT_HANDSHAKE_WITH_TEXT,
                _result(),
            ]
        ),
    )

    result = await runtime.execute_command(
        "sess_init_text",
        "compact",
        COMPACT_SESSION,
    )
    task = runtime._sessions["sess_init_text"].active_task
    assert result.ok is True
    assert task is not None
    await task

    assert is_claude_init_message(_INIT_HANDSHAKE_WITH_TEXT)
    assert is_compaction_control_message(_INIT_HANDSHAKE_WITH_TEXT)
    assert host.timeline_item_upserts
    assert all(item.content["kind"] == "compact" for item in host.timeline_item_upserts)
    assert not any("session initialized" in str(item.content) for item in host.timeline_item_upserts)


def test_claude_cli_chrome_predicates_match_the_real_parsed_frames() -> None:
    """`is_local_command_echo` is the only guard the stdout frame has."""

    stdout = parse_message(
        {
            "type": "user",
            "uuid": "stdout-uuid",
            "session_id": COMPACT_SESSION,
            "message": {
                "role": "user",
                "content": "<local-command-stdout>Compacted </local-command-stdout>",
            },
        }
    )
    stderr = parse_message(
        {
            "type": "user",
            "uuid": "stderr-uuid",
            "session_id": COMPACT_SESSION,
            "message": {
                "role": "user",
                "content": "<local-command-stderr>compact failed</local-command-stderr>",
            },
        }
    )
    real_user_prompt = parse_message(
        {
            "type": "user",
            "uuid": "prompt-uuid",
            "session_id": COMPACT_SESSION,
            "message": {"role": "user", "content": "please compact this"},
        }
    )

    assert is_local_command_echo(stdout)
    assert is_local_command_echo(stderr)
    assert is_compaction_control_message(stdout)
    assert not is_local_command_echo(real_user_prompt)
    assert not is_compaction_control_message(real_user_prompt)
    assert is_claude_init_message(parse_message({"type": "system", "subtype": "init"}))


def test_claude_compact_summary_guard_matches_the_captured_summary() -> None:
    """The guard must cover the CLI's real two-sentence opening."""

    captured = (
        "This session is being continued from a previous conversation that ran "
        "out of context. The summary below covers the earlier portion of the "
        "conversation.\n\nSummary:\n1. Primary Request and Intent: ..."
    )
    assert is_compact_summary_text(captured)
    assert CLAUDE_COMPACT_SUMMARY_PREFIX in captured
    # A user quoting the first sentence alone is no longer mistaken for the
    # CLI's own bookkeeping.
    assert not is_compact_summary_text(
        "This session is being continued from a previous conversation that ran "
        "out of context. Please keep going."
    )


def test_claude_command_turn_without_success_evidence_settles_failed() -> None:
    asyncio.run(_test_claude_command_turn_without_success_evidence_settles_failed())


async def _test_claude_command_turn_without_success_evidence_settles_failed() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system(subtype="status", status="compacting", uuid="sys_start"),
            _result(is_error=True, errors=["compaction blew up"]),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_failed", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_failed"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "failed",
    ]
    assert [item.status for item in markers] == ["running", "running", "failed"]
    assert len({item.id for item in markers}) == 1
    assert host.session_turn_ends[-1]["outcome"] == "failed"


def test_claude_interrupted_command_turn_settles_failed() -> None:
    asyncio.run(_test_claude_interrupted_command_turn_settles_failed())


async def _test_claude_interrupted_command_turn_settles_failed() -> None:
    host = _RecordingHost()
    client = _GatedClaudeClient([_system(subtype="status", status="compacting")])
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_interrupt", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_interrupt"].active_task
    assert result.ok is True
    assert task is not None
    await _wait_until(lambda: bool(host.timeline_item_upserts))

    task.cancel()
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "failed",
    ]
    assert len({item.id for item in markers}) == 1
    assert host.session_turn_ends[-1]["outcome"] == "interrupted"


def test_claude_unsuccessful_compact_result_fails_the_marker() -> None:
    asyncio.run(_test_claude_unsuccessful_compact_result_fails_the_marker())


async def _test_claude_unsuccessful_compact_result_fails_the_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system(subtype="status", status="compacting", uuid="sys_start"),
            _system(subtype="status", status=None, compact_result="error", uuid="sys_error"),
            _result(),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_result", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_result"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "failed",
    ]
    assert markers[2].content["compactResult"] == "error"


def test_claude_failed_compaction_is_a_final_state() -> None:
    """A boundary after a failure may add metadata but never clear the failure."""

    asyncio.run(_test_claude_failed_compaction_is_a_final_state())


async def _test_claude_failed_compaction_is_a_final_state() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system(subtype="status", status="compacting", uuid="sys_start"),
            _system(subtype="status", status=None, compact_result="error", uuid="sys_error"),
            _boundary(uuid="sys_boundary"),
            _result(),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_final", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_final"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "failed",
        "failed",
    ]
    assert [item.status for item in markers] == ["running", "running", "failed", "failed"]
    # The late boundary still contributes its evidence to the same item.
    assert markers[3].content["trigger"] == "manual"
    assert markers[3].content["preTokens"] == 18_000


def test_claude_boundary_alone_completes_the_marker() -> None:
    asyncio.run(_test_claude_boundary_alone_completes_the_marker())


async def _test_claude_boundary_alone_completes_the_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _boundary(uuid="sys_boundary"),
            _result(),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_boundary", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_boundary"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["started", "completed"]
    assert markers[1].status == "done"


def test_claude_second_compaction_gets_its_own_marker() -> None:
    asyncio.run(_test_claude_second_compaction_gets_its_own_marker())


async def _test_claude_second_compaction_gets_its_own_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(_compaction_messages())
    runtime = _runtime(host=host, client=client)

    for _ in range(2):
        result = await runtime.execute_command("sess_twice", "compact", COMPACT_SESSION)
        task = runtime._sessions["sess_twice"].active_task
        assert result.ok is True
        assert task is not None
        await task

    markers = host.timeline_item_upserts
    assert len({item.id for item in markers}) == 2
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "completed",
        "completed",
        "started",
        "started",
        "completed",
        "completed",
    ]
    assert markers[0].order_seq < markers[4].order_seq


def test_claude_second_compaction_in_one_turn_opens_a_new_marker() -> None:
    """A second compaction in the same turn gets its own separator.

    Reusing the finished one would leave the user with a single line that claims
    the conversation was compacted twice and hides the boundary between them.
    """

    asyncio.run(_test_claude_second_compaction_in_one_turn_opens_a_new_marker())


async def _test_claude_second_compaction_in_one_turn_opens_a_new_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system(subtype="status", status="compacting", uuid="sys_start_1"),
            _boundary(uuid="sys_boundary_1"),
            _system(subtype="status", status="compacting", uuid="sys_start_2"),
            _boundary(uuid="sys_boundary_2"),
            _result(),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_repeat", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_repeat"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert len({item.id for item in markers}) == 2
    assert [item.content["state"] for item in markers] == [
        "started",
        "started",
        "completed",
        "started",
        "completed",
    ]
    assert markers[0].order_seq < markers[3].order_seq
    # The finished separator must not slide back to "running" on the new start.
    assert markers[2].status == "done"
    assert markers[3].status == "running"


def test_claude_mid_turn_compaction_orders_after_the_published_items() -> None:
    """Marker and message slots come from one counter, so nothing collides."""

    asyncio.run(_test_claude_mid_turn_compaction_orders_after_the_published_items())


async def _test_claude_mid_turn_compaction_orders_after_the_published_items() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _assistant("first reply", "a1"),
            _system(subtype="status", status="compacting", uuid="sys_start"),
            _boundary(uuid="sys_boundary"),
            _assistant("second reply", "a2"),
            _result(result="second reply"),
        ]
    )
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn(
        "sess_mid",
        COMPACT_SESSION,
        "hello",
        client_message_id="cm1",
    )
    task = runtime._sessions["sess_mid"].active_task
    assert started.ok is True
    assert task is not None
    await task

    by_seq: dict[int, set[str]] = {}
    for item in host.timeline_item_upserts:
        # One item id may be upserted again as it changes state; two different
        # items may never claim the same slot.
        by_seq.setdefault(item.order_seq, set()).add(item.id)
    assert not {
        seq: ids for seq, ids in by_seq.items() if len(ids) > 1
    }, f"order_seq collision between timeline items: {by_seq}"

    marker = next(item for item in host.timeline_item_upserts if item.type == "marker")
    assert all(
        item.order_seq == marker.order_seq
        for item in host.timeline_item_upserts
        if item.id == marker.id
    ), "the marker must keep its slot"
    assert marker.order_seq < max(
        item.order_seq for item in host.timeline_item_upserts if item.type != "marker"
    ), "the separator is opened before the reply that follows it"


def test_claude_compact_marker_id_is_scoped_to_the_native_session() -> None:
    """The marker id follows the conversation, not the AA session row."""

    first = ClaudeSession(session_id="sess_a", external_session_id="native_a")
    other_conversation = ClaudeSession(session_id="sess_a", external_session_id="native_b")
    # The same native conversation reached through another AA session id is
    # still the same conversation, so it must resolve to the same row.
    renamed = ClaudeSession(session_id="sess_b", external_session_id="native_a")

    base = stable_compact_item_id(first, "turn_1")
    assert base.startswith("claude_compact_")
    assert stable_compact_item_id(first, "turn_1") == base
    assert stable_compact_item_id(renamed, "turn_1") == base
    assert stable_compact_item_id(other_conversation, "turn_1") != base
    assert stable_compact_item_id(first, "turn_2") != base
    # A second compaction inside one turn must not reuse the first separator.
    assert stable_compact_item_id(first, "turn_1", 1) != base
    # Before the native id is known, the AA session id stands in for it.
    cold = ClaudeSession(session_id="sess_cold", external_session_id=None)
    assert stable_compact_item_id(cold, "turn_1").startswith("claude_compact_")
    assert stable_compact_item_id(cold, "turn_1") != base


def test_claude_compaction_frames_from_another_turn_flip_the_dispatched_marker() -> None:
    """The frames belong to whoever reads them, not to whoever dispatched.

    The CLI streams `status:"compacting"`, `compact_result` and the boundary
    *after* the command turn's own result message, so the turn that reports
    them is a different one, with a turn id of its own. Markers keyed by turn
    left the dispatched separator running until its turn was settled as a
    failure, next to a second separator that had completed — one compaction,
    two lines, one of them a lie. The session owns the separator instead.
    """

    markers = _marker_tracker()
    session = _marker_session()
    command_turn = "turn_claude_command"
    reader_turn = "turn_claude_scheduled_reader"

    (dispatched,) = markers.open_command_marker(session=session, turn_id=command_turn)

    events = [
        event
        for event in (claude_compact_event(m) for m in _compaction_messages())
        if event is not None
    ]
    assert len(events) == 3, "the real wire sends exactly these three frames"
    items = [
        markers.item_for_event(session=session, turn_id=reader_turn, event=event)
        for event in events
    ]

    # The reader turn ends first and settles a marker it never opened: that is
    # the path that used to fail a separator whose success was already in.
    assert markers.settle_turn(session=session, turn_id=reader_turn) == ()
    # The dispatching turn ends afterwards, and by now it has proof.
    assert markers.settle_turn(session=session, turn_id=command_turn) == ()

    assert [item.id for item in items] == [dispatched.id] * 3
    assert [item.content["state"] for item in items] == [
        "started",
        "completed",
        "completed",
    ]
    assert [item.status for item in items] == ["running", "done", "done"]
    # The separator stays the one the user's command opened.
    assert dispatched.turn_id == command_turn
    assert {item.turn_id for item in items} == {command_turn}
    # The boundary's token metadata lands on the separator the reader completed.
    assert items[1].content["compactResult"] == "success"
    assert items[2].content["trigger"] == "manual"
    assert items[2].content["preTokens"] == 18_000
    assert items[2].content["postTokens"] == 900
    assert items[2].content["cumulativeDroppedTokens"] == 17_100
    assert items[2].content["durationMs"] == 12_000


def test_claude_trailing_evidence_corrects_a_separator_failed_for_want_of_it() -> None:
    """A settle that beat the CLI's verdict is undone by that verdict.

    Whichever turn ends first, the frames carry the evidence the separator was
    failed for. Correcting it in place is what keeps the one-outcome promise
    when the dispatching turn is settled before the CLI has answered.
    """

    markers = _marker_tracker()
    session = _marker_session()
    command_turn = "turn_claude_command"

    (opened,) = markers.open_command_marker(session=session, turn_id=command_turn)
    (settled,) = markers.settle_turn(session=session, turn_id=command_turn)
    assert settled.content["state"] == "failed"

    corrected = markers.item_for_event(
        session=session,
        turn_id="turn_claude_scheduled_reader",
        event=claude_compact_event(_boundary(uuid="sys_boundary")),
    )

    assert corrected.id == opened.id
    assert corrected.content["state"] == "completed"
    assert corrected.status == "done"
    assert corrected.content["preTokens"] == 18_000
    # The correction is spent: the next compaction opens the next separator
    # rather than re-running this one.
    again = markers.item_for_event(
        session=session,
        turn_id="turn_claude_scheduled_reader",
        event=claude_compact_event(
            _system(subtype="status", status="compacting", uuid="sys_again")
        ),
    )
    assert again.id != opened.id
    assert again.content["state"] == "started"


def test_claude_a_reported_failure_is_not_corrected_by_later_evidence() -> None:
    """The correction buys back a missing verdict, never overrides a real one."""

    markers = _marker_tracker()
    session = _marker_session()
    command_turn = "turn_claude_command"

    (opened,) = markers.open_command_marker(session=session, turn_id=command_turn)
    reported = markers.item_for_event(
        session=session,
        turn_id=command_turn,
        event=claude_compact_event(
            _system(subtype="status", status=None, compact_result="error", uuid="sys_err")
        ),
    )
    boundary = markers.item_for_event(
        session=session,
        turn_id="turn_claude_scheduled_reader",
        event=claude_compact_event(_boundary(uuid="sys_boundary")),
    )

    assert reported.content["state"] == "failed"
    assert boundary.id == opened.id
    assert boundary.content["state"] == "failed"
    # The boundary still contributes what it observed.
    assert boundary.content["preTokens"] == 18_000
    assert markers.settle_turn(session=session, turn_id=command_turn) == ()


def test_claude_opening_a_separator_settles_the_one_left_running() -> None:
    """A new command never queues behind a separator nobody is finishing."""

    markers = _marker_tracker()
    session = _marker_session()

    (stale,) = markers.open_command_marker(session=session, turn_id="turn_claude_gone")
    stale_item, opened = markers.open_command_marker(
        session=session,
        turn_id="turn_claude_next",
    )

    assert stale_item.id == stale.id
    assert stale_item.content["state"] == "failed"
    assert stale_item.status == "failed"
    assert opened.id != stale.id
    assert opened.content["state"] == "started"
    assert opened.status == "running"
    # Reopening from the turn that already owns a running separator republishes
    # it instead of failing and re-opening its own line.
    (again,) = markers.open_command_marker(session=session, turn_id="turn_claude_next")
    assert again.id == opened.id
    assert again.content["state"] == "started"


def _marker_session() -> ClaudeSession:
    return ClaudeSession(
        session_id="sess_marker_owner",
        external_session_id=COMPACT_SESSION,
    )


def _marker_tracker() -> ClaudeTimelineMarkers:
    """A marker tracker over the projector's ordering contract."""

    allocated: dict[str, int] = {}

    def order_seq_for(item_id: str) -> int:
        return allocated.setdefault(item_id, len(allocated) + 1)

    return ClaudeTimelineMarkers(order_allocator=order_seq_for)


def test_claude_automatic_compaction_marks_an_ordinary_turn() -> None:
    asyncio.run(_test_claude_automatic_compaction_marks_an_ordinary_turn())


async def _test_claude_automatic_compaction_marks_an_ordinary_turn() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _assistant("still here", "assistant_auto"),
            _boundary(uuid="sys_auto"),
            _result(),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.start_turn(
        "sess_auto",
        COMPACT_SESSION,
        "keep going",
        client_message_id="client_auto",
    )
    task = runtime._sessions["sess_auto"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = [
        item for item in host.timeline_item_upserts if item.type == "marker"
    ]
    assert [item.content["state"] for item in markers] == ["completed"]
    # The shared path keeps the ordinary turn intact: the user bubble still
    # leads and the separator lands after it.
    assert host.timeline_item_upserts[0].role == "user"
    assert markers[0].order_seq > host.timeline_item_upserts[0].order_seq
    assert any(item.role == "assistant" for item in host.timeline_item_upserts)


def test_claude_command_catalog_follows_session_state() -> None:
    asyncio.run(_test_claude_command_catalog_follows_session_state())


async def _test_claude_command_catalog_follows_session_state() -> None:
    runtime = _runtime()

    (idle,) = await runtime.list_commands("sess_catalog", COMPACT_SESSION)
    assert idle.enabled is True
    assert idle.id == "compact"

    await runtime._session_states.update("sess_catalog", COMPACT_SESSION, "running")
    (busy,) = await runtime.list_commands("sess_catalog", COMPACT_SESSION)
    assert busy.enabled is False
    assert busy.disabled_reason == "session_running"


def test_claude_command_catalog_resolves_the_loaded_session() -> None:
    asyncio.run(_test_claude_command_catalog_resolves_the_loaded_session())


async def _test_claude_command_catalog_resolves_the_loaded_session() -> None:
    runtime = _runtime()
    runtime._session_store.ensure("sess_loaded", external_session_id=COMPACT_SESSION)

    (loaded,) = await runtime.list_commands("sess_loaded")
    assert loaded.enabled is True

    (unloaded,) = await runtime.list_commands("sess_unknown")
    assert unloaded.enabled is False
    assert unloaded.disabled_reason == "session_unloaded"


def test_claude_execute_command_rejects_an_unloaded_session() -> None:
    asyncio.run(_test_claude_execute_command_rejects_an_unloaded_session())


async def _test_claude_execute_command_rejects_an_unloaded_session() -> None:
    runtime = _runtime()

    result = await runtime.execute_command("sess_unloaded", "compact")

    assert result.ok is False
    assert result.code == "command_unavailable"
    assert result.message == "session_unloaded"


def test_claude_execute_command_rejects_a_busy_session() -> None:
    asyncio.run(_test_claude_execute_command_rejects_a_busy_session())


async def _test_claude_execute_command_rejects_a_busy_session() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient([_result()])
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn("sess_busy", COMPACT_SESSION, "hello")
    task = runtime._sessions["sess_busy"].active_task
    assert started.ok is True

    result = await runtime.execute_command("sess_busy", "compact", COMPACT_SESSION)
    assert task is not None
    await task

    assert result.ok is False
    assert result.code == "command_unavailable"
    assert result.message == "session_waiting"
    assert client.queries == ["hello"]


def test_claude_command_turn_reports_an_unknown_dispatch() -> None:
    """A dispatch that raises must not invite the user to press again."""

    asyncio.run(_test_claude_command_turn_reports_an_unknown_dispatch())


async def _test_claude_command_turn_reports_an_unknown_dispatch() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient())
    runtime._turns.commands.actions = _RaisingActions()

    result = await runtime.execute_command("sess_unknown", "compact", COMPACT_SESSION)

    assert result.ok is False
    assert result.code == "command_outcome_unknown"
    assert result.result == {"executionState": "unknown", "retryable": False}
    assert "unknown" in (result.message or "").lower()
    # Nothing was dispatched, so nothing may be published or reported.
    assert host.timeline_item_upserts == []
    assert host.session_turn_ends == []


@pytest.mark.parametrize(
    ("command", "raw", "args", "code"),
    (
        ("compact", None, ("now",), "invalid_command"),
        ("compact", "/compact now", (), "invalid_command"),
        ("compact", "  /compact please  ", (), "invalid_command"),
        ("compact", "/clear", (), "invalid_command"),
        ("compact", "not a command", (), "invalid_command"),
        ("compact", None, ("a", "b"), "invalid_command"),
        ("compact", None, (1,), "invalid_command"),
        ("!!!", None, (), "invalid_command"),
        ("", None, (), "invalid_command"),
        ("clear", None, (), "unknown_command"),
        ("compact-thread", None, (), "unknown_command"),
    ),
)
def test_claude_execute_command_rejects_bad_input(
    command: str,
    raw: str | None,
    args: tuple[Any, ...],
    code: str,
) -> None:
    asyncio.run(
        _test_claude_execute_command_rejects_bad_input(command, raw, args, code)
    )


async def _test_claude_execute_command_rejects_bad_input(
    command: str,
    raw: str | None,
    args: tuple[Any, ...],
    code: str,
) -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient()
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command(
        "sess_reject",
        command,
        COMPACT_SESSION,
        raw=raw,
        args=args,
    )

    assert result.ok is False
    assert result.code == code
    assert client.queries == []
    assert host.timeline_item_upserts == []


def test_claude_execute_command_accepts_a_bare_raw_line() -> None:
    asyncio.run(_test_claude_execute_command_accepts_a_bare_raw_line())


async def _test_claude_execute_command_accepts_a_bare_raw_line() -> None:
    client = _FakeClaudeClient(_compaction_messages())
    runtime = _runtime(client=client)

    result = await runtime.execute_command(
        "sess_raw",
        "/Compact",
        COMPACT_SESSION,
        raw="/compact",
    )
    task = runtime._sessions["sess_raw"].active_task
    assert result.ok is True
    assert task is not None
    await task

    assert client.queries == ["/compact"]


def test_claude_command_turn_reports_a_rejected_dispatch() -> None:
    asyncio.run(_test_claude_command_turn_reports_a_rejected_dispatch())


async def _test_claude_command_turn_reports_a_rejected_dispatch() -> None:
    runtime = _runtime()
    await runtime._session_states.update("sess_reject_dispatch", COMPACT_SESSION, "idle")
    # The catalog reads the state cache, so a session that still owns an
    # execution is the only way to reach the branch where the shared turn
    # machinery refuses the dispatch itself.
    session = runtime._session_store.ensure(
        "sess_reject_dispatch",
        external_session_id=COMPACT_SESSION,
    )
    session.execution = ClaudeExecution(turn_id="turn_blocking")

    result = await runtime.execute_command(
        "sess_reject_dispatch",
        "compact",
        COMPACT_SESSION,
    )

    assert result.ok is False
    assert result.code == "command_rejected"
    assert result.result["executionState"] == "completed"
    assert "already" in (result.message or "")


# --- fixtures -------------------------------------------------------------


# An init handshake carrying text. Every other CLI control frame is invisible
# for a second reason as well (a user role, or no text at all), so only this
# shape can tell the suppression predicate apart from the generic role/text
# gate. It is the raw control frame, before the SDK wraps it into `.data`.
_INIT_HANDSHAKE_WITH_TEXT = {
    "type": "system",
    "subtype": "init",
    "session_id": COMPACT_SESSION,
    "message": {"role": "system", "content": "Session initialized with model opus"},
}


def _system(**fields: Any) -> Any:
    """A real `SystemMessage`: every payload field lands inside `.data`."""

    return parse_message({"type": "system", "session_id": COMPACT_SESSION, **fields})


def _boundary(**fields: Any) -> Any:
    return _system(
        subtype="compact_boundary",
        content="Conversation compacted",
        level="info",
        compactMetadata={
            "trigger": "manual",
            "preTokens": 18_000,
            "postTokens": 900,
            "cumulativeDroppedTokens": 17_100,
            "durationMs": 12_000,
        },
        **fields,
    )


def _user(text: str, uuid: str) -> Any:
    return parse_message(
        {
            "type": "user",
            "uuid": uuid,
            "session_id": COMPACT_SESSION,
            "message": {"role": "user", "content": text},
        }
    )


def _assistant(text: str, uuid: str) -> Any:
    return parse_message(
        {
            "type": "assistant",
            "uuid": uuid,
            "session_id": COMPACT_SESSION,
            "message": {
                "id": f"msg-{uuid}",
                "role": "assistant",
                "model": MODEL,
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
            },
        }
    )


def _result(result: str = "", is_error: bool = False, errors: list[str] | None = None) -> Any:
    return parse_message(
        {
            "type": "result",
            "subtype": "success" if not is_error else "error_during_execution",
            "session_id": COMPACT_SESSION,
            "is_error": is_error,
            "errors": errors or [],
            "num_turns": 0,
            "duration_ms": 1,
            "duration_api_ms": 1,
            "total_cost_usd": 0.0,
            "result": result,
        }
    )


def _compaction_messages() -> list[Any]:
    """Replay the 2026-10-02 probe order for a manual `/compact`."""

    return [
        _system(subtype="status", status="compacting", uuid="sys_start"),
        _system(subtype="init", uuid="sys_init"),
        _system(subtype="status", status=None, compact_result="success", uuid="sys_result"),
        _boundary(uuid="sys_boundary", logical_parent_uuid="sys_result"),
        _user(
            f"{CLAUDE_COMPACT_SUMMARY_PREFIX}\n\nSummary:\n1. The user asked me to ...",
            "user_summary",
        ),
        _user("<local-command-stdout>Compacted </local-command-stdout>", "user_stdout"),
        _result(),
    ]


def _runtime(
    host: _RecordingHost | None = None,
    client: _FakeClaudeClient | None = None,
) -> ClaudeRuntime:
    active_host = host or _RecordingHost()
    active_client = client or _FakeClaudeClient()

    def client_factory(sdk: Any, options: Any) -> _FakeClaudeClient:
        _ = sdk
        active_client.options = options
        return active_client

    return ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=active_host,
        sdk_loader=lambda: SimpleNamespace(
            __version__="1.0",
            ClaudeAgentOptions=_FakeOptions,
            list_sessions=lambda **_: [],
            get_session_info=lambda **_: None,
            get_session_messages=lambda **_: [],
        ),
        client_factory=client_factory,
    )


class _FakeOptions:
    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs


class _RaisingActions:
    """Stands in for a dispatch that dies after the prompt may have been sent."""

    async def start_turn(self, **kwargs: Any) -> Any:
        raise ConnectionError("claude stream closed")


class _FakeClaudeClient:
    def __init__(self, messages: list[Any] | None = None) -> None:
        self.messages = list(messages or [])
        self.options: Any = None
        self.connected = False
        self.disconnected = False
        self.interrupted = False
        self.queries: list[str] = []

    async def connect(self) -> None:
        self.connected = True

    async def disconnect(self) -> None:
        self.disconnected = True

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            self.queries.append(prompt)
            return
        # The connector pre-assigns a prompt UUID on reused connections, so the
        # SDK receives a message envelope instead of a bare string.
        envelopes = [message async for message in prompt]
        self.queries.append(envelopes[0]["message"]["content"])

    async def receive_response(self) -> list[Any]:
        return self.messages

    async def interrupt(self) -> None:
        self.interrupted = True


class _GatedClaudeClient(_FakeClaudeClient):
    """Stream the opening events, then hold the reply open for an interrupt."""

    def __init__(self, messages: list[Any] | None = None) -> None:
        super().__init__(messages)
        self.release = asyncio.Event()

    async def receive_response(self) -> Any:
        for message in self.messages:
            yield message
        await self.release.wait()


class _RecordingHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.session_meta_upserts: list[dict[str, Any]] = []
        self.session_state_updates: list[dict[str, Any]] = []
        self.session_turn_ends: list[dict[str, Any]] = []
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []
        self.timeline_syncs: list[dict[str, Any]] = []
        self.session_capability_updates: list[Any] = []
        self.notice_upserts: list[Any] = []
        self.sync_states: dict[str, dict[str, Any]] = {}

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def session_meta_upsert(
        self,
        session_id: str,
        runtime: str,
        external_session_id: str | None = None,
        title: str | None = None,
        cwd: str | None = None,
        ordering_time: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_meta_upserts.append(
            {
                "session_id": session_id,
                "external_session_id": external_session_id,
                "metadata": metadata or {},
            }
        )

    async def session_state_update(
        self,
        session_id: str,
        runtime: str,
        status: RuntimeStatus | None = None,
        selections: dict[str, str | None] | None = None,
        external_session_id: str | None = None,
        status_reason: str | None = None,
        error: dict[str, str] | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_state_updates.append(
            {
                "session_id": session_id,
                "status": status,
                "external_session_id": external_session_id,
                "error": error,
                "metadata": metadata or {},
            }
        )

    async def session_turn_ended(
        self,
        session_id: str,
        runtime: str,
        external_session_id: str | None = None,
        turn_id: str | None = None,
        outcome: str = "completed",
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_turn_ends.append(
            {
                "session_id": session_id,
                "turn_id": turn_id,
                "outcome": outcome,
                "metadata": metadata or {},
            }
        )

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)

    async def session_capabilities_update(self, capabilities: Any) -> None:
        self.session_capability_updates.append(capabilities)

    async def timeline_sync(
        self,
        session_id: str,
        runtime: str,
        items: tuple[RuntimeTimelineItem, ...],
        external_session_id: str | None = None,
        complete: bool = False,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.timeline_syncs.append({"session_id": session_id, "metadata": metadata or {}})

    async def notice_upsert(self, notice: Any) -> None:
        self.notice_upserts.append(notice)

    async def attachment_download(
        self,
        session_id: str,
        file_id: str,
    ) -> RuntimeAttachmentContent:
        raise NotImplementedError

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.sync_states.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.sync_states[key] = value

    async def sync_state_delete(self, key: str) -> None:
        self.sync_states.pop(key, None)


async def _wait_until(predicate: Any) -> None:
    for _ in range(200):
        if predicate():
            return
        await asyncio.sleep(0.005)
    assert predicate()