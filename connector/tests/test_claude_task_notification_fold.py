"""Import-path terminal folding for background Agent cards (2026-10-05).

Why this file exists
--------------------
Terminal task frames never reach the transcript — the live stream carries
them, the file does not. The CLI persisting a background task's completion as
a plain ``<task-notification>`` user message is the *only* evidence the
file-sync import path ever sees. The live SDK path folds its own frames, so
its cards close; the import path read those messages as synthetic control
chrome (correctly: no bubble, no turn) and never folded them, leaving every
background card ``running`` forever. Real session aba0a291 had ten such
cards, and its replay closes seven of them with this fold (the other three
have no user-message notice at all — see the delivery report).

What is pinned here
-------------------
* the parser (``task_event_from_notification_text``): four terminal
  statuses, ``<result>`` over ``<summary>``, missing usage, the shapes that
  must be skipped without raising;
* the projection fold (``_history_items_from_messages``): in-window merge,
  dispatch-outside-window synthesized card, nested dispatch, duplicate
  notices, no bubble / no turn, coexistence with the missing-result
  synthesis, and the resume-after-stop guard.

The projection-era rebase lives in ``test_claude_history_projection_rebase``;
these fixtures (messages and notices) are shared with it.

Fixtures: the completed, failed, local-bash and multi-task-stop notices are
verbatim from the real transcript (``aba0a291-…jsonl`` lines 877/1350/2921/
2920; long result bodies elided and marked, tags untouched); killed/stopped
agent notices are synthetic, modelled on the same template.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import (
    task_event_from_notification_text,
    task_events_from_notification_text,
)
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    _history_tool_call_context,
    _message_timestamp_ms,
)
from connector.runtimes.claude.timeline.agent_calls import (
    agent_task_terminal_status,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudePendingToolCall,
    ClaudeToolBlock,
    is_synthetic_control_message,
    is_task_notification_message,
    stable_tool_item_id,
)

EXTERNAL_SESSION_ID = "aba0a291-2194-4438-87ed-d8c76539ad09"
SESSION_ID = "sess_claude_notification_fold"
DISPATCH_TUID = "call_00_m4ylLEhjGWSTqMKLNhUo3092"
TASK_ID = "af0d00add5d2a33ae"
OUTER_TUID = "call_00_outer000000000000000000"
CHILD_TUID = "call_00_child000000000000000000"
BASH_TUID = "call_01_C2D7CoSCnJzu51oNGIh93553"
NOTICE_TIMESTAMP = "2026-10-05T07:43:11.045Z"
NOTICE_TIMESTAMP_MS = 1_791_186_191_045

COMPLETED_USAGE = (
    "<usage><subagent_tokens>175587</subagent_tokens>"
    "<tool_uses>138</tool_uses><duration_ms>1968808</duration_ms></usage>"
)

# Verbatim shape of transcript line 877 (tags and usage untouched; the
# multi-kB result body is elided and marked).
COMPLETED_NOTIFICATION = f"""<task-notification>
<task-id>{TASK_ID}</task-id>
<tool-use-id>{DISPATCH_TUID}</tool-use-id>
<output-file>/tmp/claude-1001/.../tasks/{TASK_ID}.output</output-file>
<status>completed</status>
<summary>Agent "D0 侦察：切模型/灰键修复" finished</summary>
<note>A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once.</note>
<result>Reconnaissance complete. (result body elided; shape untouched)</result>
{COMPLETED_USAGE}
</task-notification>"""

# Verbatim transcript line 1350.
FAILED_NOTIFICATION = """<task-notification>
<task-id>a86a564e206445a29</task-id>
<tool-use-id>call_00_rQCNPFrYFsteetTBzUdG0681</tool-use-id>
<output-file>/tmp/claude-1001/.../tasks/a86a564e206445a29.output</output-file>
<status>failed</status>
<summary>Agent "实施：catalog 修订号慢病修复" failed: Agent terminated early due to an API error: API Error: 400 All target providers failed. (error type unknown, HTTP 400, model sent to the API: deepseek-v4.1-flash)</summary>
<note>A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once.</note>
<result>Let me review the complete diff before committing.</result>
</task-notification>"""

# Synthetic, modelled on the completed/failed template: killed notices carry
# no <result> (the CLI cut the agent short), so the summary is the fallback.
KILLED_NOTIFICATION = """<task-notification>
<task-id>akilled00000000000</task-id>
<tool-use-id>call_00_killed0000000000000000000</tool-use-id>
<output-file>/tmp/claude-1001/.../tasks/akilled00000000000.output</output-file>
<status>killed</status>
<summary>Agent "Workflow experiment" was stopped</summary>
<note>A task-notification fires each time this agent stops with no live background children of its own.</note>
</task-notification>"""

STOPPED_NOTIFICATION = """<task-notification>
<task-id>astopped0000000000</task-id>
<tool-use-id>call_00_stopped000000000000000000</tool-use-id>
<status>stopped</status>
<summary>Agent "Long tail" was stopped before finishing</summary>
<note>No completion record was found for it.</note>
</task-notification>"""

# Verbatim transcript line 2921: a local_bash task's stop. It parses like any
# notice — the projection is what must not fold it (its id points at a Bash
# call, not an Agent card).
LOCAL_BASH_STOPPED_NOTIFICATION = f"""<task-notification>
<task-id>b521uzwzg</task-id>
<tool-use-id>{BASH_TUID}</tool-use-id>
<status>stopped</status>
<summary>Background shell command didn't finish before the previous session ended</summary>
<note>No completion record was found for it in the previous session. It may have been stopped (via the UI, Monitor timeout, or agent teardown — these leave no transcript marker), or it may have been running when the previous Claude Code process exited. Check the output file for partial results before assuming it completed.</note>
</task-notification>"""

# Verbatim transcript line 2920: five agents stopped at once, cited by
# task-id only — no tool-use-id, so nothing owns a card and nothing folds.
MULTI_TASK_STOP_NOTIFICATION = """<task-notification>
<task-id>a41f7661b33739de1</task-id>
<task-id>a64c78f786875c233</task-id>
<task-id>a8d76e50c71f4fe13</task-id>
<task-id>a354bcc0319ed8c22</task-id>
<task-id>aa1182a19227bde19</task-id>
<status>stopped</status>
<summary>5 background agents didn't finish before the previous session ended: "工位A：机制", "工位B：iOS", "工位D：Web", "工位E：Android", "工位C：红队".</summary>
<note>No completion record was found for them in the previous session.</note>
</task-notification>"""


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Notification fold",
    )


def _user_message(uuid: str, text: str) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        message={"role": "user", "content": text},
    )


def _assistant_message(uuid: str, text: str) -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        message={"role": "assistant", "content": text},
    )


def _notification_message(
    text: str,
    *,
    uuid: str = "notice-native",
    timestamp: str | None = NOTICE_TIMESTAMP,
) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        timestamp=timestamp,
        message={"role": "user", "content": text},
    )


def _dispatch_message(
    *,
    tool_use_id: str = DISPATCH_TUID,
    uuid: str = "dispatch-native",
    parent_tool_use_id: str | None = None,
    description: str = "D0 侦察：切模型/灰键修复",
    prompt: str = "Recon the composer.",
) -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        parent_tool_use_id=parent_tool_use_id,
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": "Agent",
                    "input": {
                        "description": description,
                        "prompt": prompt,
                        "run_in_background": True,
                    },
                }
            ],
        },
    )


def _send_message_message(
    *,
    to: str = TASK_ID,
    tool_use_id: str = "call_01_resume0000000000000000000",
    uuid: str = "resume-native",
) -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": "SendMessage",
                    "input": {"to": to, "message": "Continue the same task."},
                }
            ],
        },
    )


def _receipt_message(
    *,
    tool_use_id: str = DISPATCH_TUID,
    uuid: str = "receipt-native",
    task_id: str = TASK_ID,
    description: str = "D0 侦察：切模型/灰键修复",
) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        message={
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                "Async agent launched successfully.\n"
                                f"agentId: {task_id} (internal ID - do not mention to user.)"
                            ),
                        }
                    ],
                }
            ],
        },
    )


def _child_activity_message(
    *,
    uuid: str = "child-native",
    parent_tool_use_id: str = DISPATCH_TUID,
) -> Any:
    """A subagent frame leaking into the parent chain, parented to the card."""

    return SimpleNamespace(
        type="assistant",
        uuid=uuid,
        parent_tool_use_id=parent_tool_use_id,
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": CHILD_TUID,
                    "name": "Bash",
                    "input": {"command": "ls"},
                }
            ],
        },
    )


def _card_items(items: tuple[Any, ...], tool_use_id: str = DISPATCH_TUID) -> list[Any]:
    card_id = stable_tool_item_id(_session(), tool_use_id)
    return [item for item in items if item.id == card_id]


def _project(
    messages: tuple[Any, ...],
    *,
    lookup: dict[str, Any] | None = None,
) -> tuple[Any, ...]:
    return _history_items_from_messages(
        _session(),
        messages,
        tool_call_lookup=lookup,
    )


# --------------------------------------------------------------------------
# 1. The parser
# --------------------------------------------------------------------------


def test_notification_parser_reads_the_real_completed_notice() -> None:
    event = task_event_from_notification_text(
        COMPLETED_NOTIFICATION,
        timestamp_ms=NOTICE_TIMESTAMP_MS,
    )
    assert event is not None
    assert event.kind == "notification"
    assert event.task_id == TASK_ID
    assert event.tool_use_id == DISPATCH_TUID
    assert event.status == "completed"
    assert agent_task_terminal_status(event.status) == "done"
    assert event.summary == (
        "Reconnaissance complete. (result body elided; shape untouched)"
    )
    # Usage is renamed into the keys task_usage already consumes.
    assert dict(event.usage or {}) == {
        "total_tokens": 175587,
        "tool_uses": 138,
        "duration_ms": 1968808,
    }
    assert event.end_time == NOTICE_TIMESTAMP_MS


def test_notification_parser_maps_every_terminal_status() -> None:
    cases = (
        (COMPLETED_NOTIFICATION, "completed", "done"),
        (FAILED_NOTIFICATION, "failed", "failed"),
        (STOPPED_NOTIFICATION, "stopped", "interrupted"),
        (KILLED_NOTIFICATION, "killed", "interrupted"),
    )
    for text, status, card_status in cases:
        event = task_event_from_notification_text(text)
        assert event is not None, status
        assert event.status == status
        assert agent_task_terminal_status(event.status) == card_status
        assert event.summary is not None


def test_notification_parser_prefers_the_verbatim_result_over_summary() -> None:
    event = task_event_from_notification_text(FAILED_NOTIFICATION)
    assert event is not None
    assert event.summary == "Let me review the complete diff before committing."


def test_notification_parser_falls_back_to_summary_without_a_result() -> None:
    event = task_event_from_notification_text(KILLED_NOTIFICATION)
    assert event is not None
    assert event.summary == 'Agent "Workflow experiment" was stopped'
    assert event.usage is None


def test_notification_parser_tolerates_a_missing_usage_block() -> None:
    text = COMPLETED_NOTIFICATION.replace(COMPLETED_USAGE, "")
    event = task_event_from_notification_text(text)
    assert event is not None
    assert event.usage is None
    assert event.summary is not None


def test_notification_parser_keeps_partial_usage_fields() -> None:
    text = COMPLETED_NOTIFICATION.replace(
        "<tool_uses>138</tool_uses><duration_ms>1968808</duration_ms>", ""
    )
    event = task_event_from_notification_text(text)
    assert event is not None
    assert dict(event.usage or {}) == {"total_tokens": 175587}


def test_notification_parser_skips_text_that_is_not_a_notice() -> None:
    assert task_event_from_notification_text(None) is None
    assert task_event_from_notification_text("hello world") is None
    assert task_event_from_notification_text("<task-notification> truncated") is None
    assert task_event_from_notification_text("</task-notification>") is None


def test_notification_parser_skips_a_notice_missing_a_required_tag() -> None:
    # No tool-use-id: nothing owns a card (real shape, transcript line 2920).
    assert task_event_from_notification_text(MULTI_TASK_STOP_NOTIFICATION) is None
    # No status: the closure the notice asks for is unknown.
    text = (
        "<task-notification>\n<task-id>x</task-id>\n"
        "<tool-use-id>y</tool-use-id>\n</task-notification>"
    )
    assert task_event_from_notification_text(text) is None


def test_notification_parser_reads_a_local_bash_notice() -> None:
    # Parsing is agnostic; the projection is what refuses to fold it.
    event = task_event_from_notification_text(LOCAL_BASH_STOPPED_NOTIFICATION)
    assert event is not None
    assert event.tool_use_id == BASH_TUID
    assert event.status == "stopped"
    assert event.summary == (
        "Background shell command didn't finish before the previous session ended"
    )


def test_notification_predicate_matches_both_channels() -> None:
    by_text = _notification_message(COMPLETED_NOTIFICATION)
    by_origin = SimpleNamespace(
        type="user",
        uuid="origin-native",
        origin={"kind": "task-notification"},
        message={"role": "user", "content": "Malformed notice body."},
    )
    assert is_task_notification_message(by_text)
    assert is_task_notification_message(by_origin)
    assert not is_task_notification_message(_user_message("u1", "hello"))
    # Behaviour preservation: the "no bubble" skip still swallows both.
    assert is_synthetic_control_message(by_text)
    assert is_synthetic_control_message(by_origin)


def test_message_timestamp_ms_reads_iso_and_epoch_shapes() -> None:
    assert _message_timestamp_ms(_notification_message(COMPLETED_NOTIFICATION)) == (
        NOTICE_TIMESTAMP_MS
    )
    assert _message_timestamp_ms(SimpleNamespace(timestamp=1_791_186_191_045)) == (
        1_791_186_191_045
    )
    assert _message_timestamp_ms(SimpleNamespace(timestamp="not a date")) is None
    assert _message_timestamp_ms(SimpleNamespace()) is None


# --------------------------------------------------------------------------
# 2. The projection fold
# --------------------------------------------------------------------------


def test_full_window_folds_the_async_card_to_done() -> None:
    messages = (
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    card = cards[0]
    assert card.status == "done"
    assert card.source["event"] == "claude.agent.task"
    assert dict(card.content["agents"])[TASK_ID]["status"] == "completed"
    assert card.content["summary"] == (
        "Reconnaissance complete. (result body elided; shape untouched)"
    )
    assert card.content["usage"] == {
        "durationMs": 1968808,
        "tokens": 175587,
        "toolCalls": 138,
    }
    assert card.content["endTime"] == NOTICE_TIMESTAMP_MS
    assert card.content["prompt"] == "Recon the composer."
    assert card.content["description"] == "D0 侦察：切模型/灰键修复"
    assert card.content["agentId"] == TASK_ID
    assert card.content["targetIds"] == [TASK_ID]
    assert "Async agent launched successfully." in card.content["output"]


def test_incremental_window_synthesizes_the_card_from_the_lookup() -> None:
    # The dispatch and its receipt sit before the cursor; only the notice is
    # in this window. The lookup is what the syncer hands in: built over the
    # whole visible chain.
    full = (_user_message("u1", "go"), _dispatch_message(), _receipt_message())
    notice = _notification_message(COMPLETED_NOTIFICATION)
    lookup, hidden = _history_tool_call_context(_session(), (*full, notice))

    items = _project((notice,), lookup=lookup)
    assert len(items) == 1
    card = items[0]
    assert card.id == stable_tool_item_id(_session(), DISPATCH_TUID)
    assert card.status == "done"
    assert card.turn_id == lookup[DISPATCH_TUID].turn_id
    assert card.content["description"] == "D0 侦察：切模型/灰键修复"
    assert card.content["prompt"] == "Recon the composer."
    assert card.content["runInBackground"] is True
    assert dict(card.content["agents"])[TASK_ID]["status"] == "completed"
    assert card.content["summary"] == (
        "Reconnaissance complete. (result body elided; shape untouched)"
    )
    assert hidden == frozenset()


def test_incremental_fold_keeps_the_nested_parent() -> None:
    outer = _dispatch_message(
        tool_use_id=OUTER_TUID,
        uuid="outer-native",
        description="Outer dispatch",
    )
    nested = _dispatch_message(
        tool_use_id=DISPATCH_TUID,
        uuid="nested-native",
        parent_tool_use_id=OUTER_TUID,
        description="Nested dispatch",
    )
    notice = _notification_message(COMPLETED_NOTIFICATION)
    lookup, _ = _history_tool_call_context(_session(), (outer, nested, notice))

    items = _project((notice,), lookup=lookup)
    card = _card_items(items)[0]
    assert card.content["parentItemId"] == stable_tool_item_id(_session(), OUTER_TUID)


def test_repeated_notices_fold_once_and_the_last_one_wins() -> None:
    resumed_text = COMPLETED_NOTIFICATION.replace(
        "<result>Reconnaissance complete. (result body elided; shape untouched)</result>",
        "<result>Second round done.</result>",
    ).replace(
        "<usage><subagent_tokens>175587</subagent_tokens>"
        "<tool_uses>138</tool_uses><duration_ms>1968808</duration_ms></usage>",
        "<usage><subagent_tokens>200000</subagent_tokens>"
        "<tool_uses>140</tool_uses><duration_ms>2000000</duration_ms></usage>",
    )
    messages = (
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION, uuid="notice-1"),
        _notification_message(resumed_text, uuid="notice-2"),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "done"
    assert cards[0].content["summary"] == "Second round done."
    assert cards[0].content["usage"]["tokens"] == 200000


def test_notice_after_child_activity_is_not_folded() -> None:
    # Resume-after-stop: the notice says "completed", but the agent was
    # resumed afterwards (its child frame follows the notice), so folding it
    # would lie the card closed while the agent runs again.
    messages = (
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
        _child_activity_message(),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "running"
    # A later child frame reopens the task; history no longer keeps a stale
    # terminal overlay or leaves the async receipt marker as the card status.
    agents = dict(cards[0].content.get("agents") or {})
    assert agents[TASK_ID]["status"] == "running"


def test_notice_before_child_activity_still_folds_the_last_notice() -> None:
    # One resume round: notice 1, more child activity, notice 2. The last
    # notice postdates the activity, so it closes the card.
    resumed_text = COMPLETED_NOTIFICATION.replace(
        "<result>Reconnaissance complete. (result body elided; shape untouched)</result>",
        "<result>Resume round finished.</result>",
    )
    messages = (
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION, uuid="notice-1"),
        _child_activity_message(),
        _notification_message(resumed_text, uuid="notice-2"),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "done"
    assert cards[0].content["summary"] == "Resume round finished."


def test_local_bash_notice_folds_nothing() -> None:
    lookup = {
        BASH_TUID: _pending_call(
            tool_use_id=BASH_TUID,
            tool_name="Bash",
            tool_input={"command": "sleep 300", "run_in_background": True},
        )
    }
    items = _project(
        (_notification_message(LOCAL_BASH_STOPPED_NOTIFICATION),),
        lookup=lookup,
    )
    assert items == ()


def test_multi_task_stop_notice_folds_nothing() -> None:
    items = _project((_notification_message(MULTI_TASK_STOP_NOTIFICATION),))
    assert items == ()


def test_notice_produces_no_bubble_and_no_turn() -> None:
    base = [_user_message("u1", "first"), _dispatch_message(), _receipt_message()]
    with_notice = [
        *base,
        _notification_message(COMPLETED_NOTIFICATION),
        _user_message("u2", "second"),
        _assistant_message("a2", "reply"),
    ]
    without_notice = [
        *base,
        _user_message("u2", "second"),
        _assistant_message("a2", "reply"),
    ]
    lookup, _ = _history_tool_call_context(_session(), tuple(with_notice))
    items_with = _project(tuple(with_notice), lookup=lookup)
    items_without = _project(tuple(without_notice), lookup=lookup)

    def message_rows(items: tuple[Any, ...]) -> list[tuple[str, str | None, str]]:
        return [
            (item.role, item.turn_id, item.content["text"])
            for item in items
            if item.type == "message"
        ]

    # Same bubbles, same turn ids: the notice neither mints a message nor
    # bumps the turn counter (its absence and presence are indistinguishable
    # to every later row).
    assert message_rows(items_with) == message_rows(items_without)
    assert all(
        "<task-notification>" not in text
        for _, _, text in message_rows(items_with)
    )


def test_notice_coexists_with_the_missing_result_synthesis() -> None:
    # A dispatch whose receipt has not been written yet gets a synthetic
    # "no tool result" row from missing_history_tool_result_items. The fold
    # is applied after it, so the boilerplate can not clobber the terminal
    # overlay.
    messages = (
        _user_message("u1", "go"),
        _dispatch_message(),
        _notification_message(COMPLETED_NOTIFICATION),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    card = cards[0]
    assert card.status == "done"
    assert dict(card.content["agents"])[TASK_ID]["status"] == "completed"
    assert card.content["summary"] == (
        "Reconnaissance complete. (result body elided; shape untouched)"
    )


def test_malformed_notice_leaves_the_card_running() -> None:
    truncated = COMPLETED_NOTIFICATION.split("<status>")[0] + "</task-notification>"
    messages = (
        _dispatch_message(),
        _receipt_message(),
        _notification_message(truncated),
    )
    items = _project(messages)
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "running"


def _pending_call(
    *,
    tool_use_id: str,
    tool_name: str,
    tool_input: dict[str, Any],
) -> ClaudePendingToolCall:
    return ClaudePendingToolCall(
        block=ClaudeToolBlock(
            block_type="tool_use",
            tool_use_id=tool_use_id,
            tool_name=tool_name,
            tool_input=tool_input,
        ),
        turn_id="turn_lookup",
    )



# --------------------------------------------------------------------------
# 3. task-id lineage across resumed and batched notifications
# --------------------------------------------------------------------------


def test_notification_parser_accepts_multiple_task_ids_without_tool_id() -> None:
    text = """<task-notification>
<task-id>task-one</task-id>
<task-id>task-two</task-id>
<status>stopped</status>
<summary>Two tasks stopped with the previous session.</summary>
</task-notification>"""
    events = task_events_from_notification_text(text)
    assert [event.task_id for event in events] == ["task-one", "task-two"]
    assert all(event.tool_use_id is None for event in events)
    assert all(event.status == "stopped" for event in events)
    # The legacy one-event API remains conservative for multi-task wrappers.
    assert task_event_from_notification_text(text) is None


def test_task_id_only_multi_stop_closes_each_receipted_agent_card() -> None:
    second_tuid = "call_00_second0000000000000000000"
    second_task = "asecondtask000000000"
    second_dispatch = _dispatch_message(
        tool_use_id=second_tuid,
        uuid="dispatch-second",
        description="Second task",
    )
    second_receipt = _receipt_message(
        tool_use_id=second_tuid,
        uuid="receipt-second",
        task_id=second_task,
        description="Second task",
    )
    text = f"""<task-notification>
<task-id>{TASK_ID}</task-id>
<task-id>{second_task}</task-id>
<status>stopped</status>
<summary>Both tasks stopped before completion.</summary>
<note>No completion record was found.</note>
</task-notification>"""
    items = _project(
        (
            _user_message("u1", "go"),
            _dispatch_message(),
            _receipt_message(),
            second_dispatch,
            second_receipt,
            _notification_message(text),
        )
    )
    cards = [*_card_items(items), *_card_items(items, second_tuid)]
    assert len(cards) == 2
    assert {card.status for card in cards} == {"interrupted"}
    assert all(card.content["summary"] == "Both tasks stopped before completion." for card in cards)


def test_send_message_notification_updates_the_original_agent_card() -> None:
    resume_tuid = "call_01_resume0000000000000000000"
    resumed = _send_message_message(tool_use_id=resume_tuid)
    resumed_notice = COMPLETED_NOTIFICATION.replace(
        f"<tool-use-id>{DISPATCH_TUID}</tool-use-id>",
        f"<tool-use-id>{resume_tuid}</tool-use-id>",
    ).replace(
        "Reconnaissance complete. (result body elided; shape untouched)",
        "The resumed task is complete.",
    )
    items = _project(
        (
            _user_message("u1", "go"),
            _dispatch_message(),
            _receipt_message(),
            resumed,
            _notification_message(resumed_notice),
        )
    )
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "done"
    assert cards[0].content["summary"] == "The resumed task is complete."
    assert dict(cards[0].content["agents"])[TASK_ID]["status"] == "completed"
    send_card_id = stable_tool_item_id(_session(), resume_tuid)
    assert not any(
        item.id == send_card_id and item.content.get("kind") == "agent_call"
        for item in items
    )


def test_send_message_after_terminal_reopens_original_agent_card() -> None:
    resumed = _send_message_message()
    items = _project(
        (
            _user_message("u1", "go"),
            _dispatch_message(),
            _receipt_message(),
            _notification_message(COMPLETED_NOTIFICATION, uuid="notice-first"),
            resumed,
        )
    )
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "running"
    assert dict(cards[0].content["agents"])[TASK_ID]["status"] == "running"
    assert "summary" not in cards[0].content


def test_later_send_message_terminal_wins_over_an_earlier_failure() -> None:
    task_id = "a86a564e206445a29"
    dispatch_tuid = "call_00_rQCNPFrYFsteetTBzUdG0681"
    resume_tuid = "call_01_XAusbv44B3VEAPPUjGYT6984"
    dispatch = _dispatch_message(
        tool_use_id=dispatch_tuid,
        description="Catalog revision repair",
    )
    receipt = _receipt_message(
        tool_use_id=dispatch_tuid,
        task_id=task_id,
        description="Catalog revision repair",
    )
    failed = FAILED_NOTIFICATION
    completed = f"""<task-notification>
<task-id>{task_id}</task-id>
<tool-use-id>{resume_tuid}</tool-use-id>
<status>completed</status>
<summary>Agent finished after resume</summary>
<result>Recovered and verified.</result>
</task-notification>"""
    items = _project(
        (
            _user_message("u1", "go"),
            dispatch,
            receipt,
            _notification_message(failed, uuid="notice-failed"),
            _send_message_message(to=task_id, tool_use_id=resume_tuid),
            _notification_message(completed, uuid="notice-completed"),
        )
    )
    cards = _card_items(items, dispatch_tuid)
    assert len(cards) == 1
    assert cards[0].status == "done"
    assert cards[0].content["summary"] == "Recovered and verified."
    assert dict(cards[0].content["agents"])[task_id]["status"] == "completed"


def test_child_activity_after_send_message_reopens_old_terminal() -> None:
    resume_tuid = "call_01_resume0000000000000000000"
    child = _child_activity_message(parent_tool_use_id=resume_tuid)
    items = _project(
        (
            _user_message("u1", "go"),
            _dispatch_message(),
            _receipt_message(),
            _notification_message(COMPLETED_NOTIFICATION, uuid="notice-first"),
            _send_message_message(tool_use_id=resume_tuid),
            child,
        )
    )
    card = _card_items(items)[0]
    assert card.status == "running"
    assert dict(card.content["agents"])[TASK_ID]["status"] == "running"
    assert "summary" not in card.content


def test_incremental_fold_rebuilds_receipt_content_from_the_full_lookup() -> None:
    chain = (
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
    )
    lookup, hidden = _history_tool_call_context(_session(), chain)
    items = _history_items_from_messages(
        _session(),
        (chain[-1],),
        tool_call_lookup=lookup,
        hidden_tool_use_ids=hidden,
    )
    card = _card_items(items)[0]
    assert card.status == "done"
    assert card.content["agentId"] == TASK_ID
    assert card.content["targetIds"] == [TASK_ID]
    assert "Async agent launched successfully." in card.content["output"]
    assert "agentId: " + TASK_ID in card.content["output"]
    assert card.content["outputText"] == card.content["output"]
    assert card.content["outputPreview"] == card.content["output"]
    assert card.content["outputLength"] == len(card.content["output"])
    assert card.content["isError"] is False
    assert card.content["result"]


def test_notification_usage_ignores_fixture_tags_inside_result() -> None:
    decoy = (
        "<usage><subagent_tokens>999</subagent_tokens>"
        "<tool_uses>7</tool_uses><duration_ms>42</duration_ms></usage>"
    )
    text = COMPLETED_NOTIFICATION.replace(
        "Reconnaissance complete. (result body elided; shape untouched)",
        f"Fixture example: {decoy}",
    )
    event = task_event_from_notification_text(text)
    assert event is not None
    assert dict(event.usage or {}) == {
        "total_tokens": 175587,
        "tool_uses": 138,
        "duration_ms": 1968808,
    }


def test_foreign_tool_id_still_folds_through_task_id_lineage() -> None:
    """A notice whose tool id is not on the visible chain (trimmed or
    sidechain calls, other providers' id shapes) still folds: the receipt's
    task-id lineage is the join, and the notice behaves like one without a
    tool id. Regression: session 2a98e985, card "Verify subagent after resume".
    """
    foreign_notice = COMPLETED_NOTIFICATION.replace(
        f"<tool-use-id>{DISPATCH_TUID}</tool-use-id>",
        "<tool-use-id>call_00_sEWmWXNsQCe4OGwNTQ32Z1382</tool-use-id>",
    )
    items = _project(
        (
            _user_message("u1", "go"),
            _dispatch_message(),
            _receipt_message(),
            _notification_message(foreign_notice),
        )
    )
    cards = _card_items(items)
    assert len(cards) == 1
    assert cards[0].status == "done"
