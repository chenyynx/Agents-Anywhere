"""One stable turn id across live and history for user text and scheduled turns.

Why this file exists
--------------------
Turn identity is the seam the Code timeline groups tools by. Before this
change the live turn id was a random token minted when the execution was
created, while history derived a digest of a user message: the same turn had
two ids, so every replay re-keyed the rows. A scheduled turn (no user
message at all) had no history seed change either — it inherited the previous
turn's id and merged across the boundary.

Scope: the two turn kinds that share an anchor on both sides. A native
COMMAND turn is a known exception, not a regression — the live side mints a
random opaque id before dispatch (``turns/actions.py``) and the CLI's command
rows are synthetic chrome the history projection never emits, so there is no
transcript id both sides can hash; its compaction marker is the whole surface.
``test_command_history_rows_do_not_seed_a_turn`` and the live command probe
below pin that exception rather than hide it. Every "a turn" below means one
of the two anchored kinds.

These tests pin the contract:

* a real user text turn is seeded by the prompt uuid the connector itself
  assigns and the SDK replays as the transcript user row's uuid;
* a user-less turn is seeded by its FIRST assistant message id, which the
  live ``message_start`` frame carries before any partial row is published;
* the seed is hashed ALONE: neither the AA session id (one native session has
  two aliases, platform and discovery) nor the native Claude id (which does
  not exist yet on a new session's first turn) may enter the hash;
* the seed is computed over the FULL chain, so an incremental projection
  window reproduces the ids the full import already published;
* the raw transcript's hidden fired-prompt rows are what mark a scheduled
  turn boundary in history.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import replace
from types import SimpleNamespace
from typing import Any

from claude_agent_sdk import AssistantMessage, StreamEvent, UserMessage

from test_claude_history_compact import (
    _CompactHistorySdk,
    _SyncStateHost,
    _syncer,
)
from test_claude_runtime import (
    _default_sdk,
    _FakeClaudeClient,
    _FakeHookMatcher,
    _RecordingHost,
    _runtime,
    _ScheduledClaudeClient,
    _wait_until,
)

from connector.runtime_protocol import RuntimeAttachment, RuntimeAttachmentContent
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.history.cursor import (
    HISTORY_PROJECTION_VERSION,
    ClaudeHistoryCursor,
    messages_after_cursor,
)
from connector.runtimes.claude.sessions import reader as reader_module
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    _history_turn_id,
    _history_turn_ids,
    _scan_turn_id,
)
from connector.runtimes.claude.sessions.subagent_oracle import scan_raw_transcript
from connector.runtimes.claude.turns.lifecycle import _turn_anchor_from_frame

SESSION_ID = "sess_turn_id_probe"
EXTERNAL_SESSION_ID = "native-turn-id-probe"


def _session(
    *,
    session_id: str = SESSION_ID,
    external_session_id: str | None = EXTERNAL_SESSION_ID,
) -> ClaudeSession:
    return ClaudeSession(
        session_id=session_id,
        external_session_id=external_session_id,
    )


def _user(uuid: str, text: str, *, is_meta: bool = False) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        message={"role": "user", "content": text},
        isMeta=is_meta,
    )


def _assistant(uuid: str, text: str, *, message_id: str | None = None) -> Any:
    content: Any = text
    message: dict[str, Any] = {"role": "assistant", "content": content}
    if message_id is not None:
        message["id"] = message_id
    return SimpleNamespace(type="assistant", uuid=uuid, message=message)


def _assistant_row(uuid: str, text: str, *, message_id: str | None = None) -> str:
    message: dict[str, Any] = {"role": "assistant", "content": text}
    if message_id is not None:
        message["id"] = message_id
    return json.dumps({"type": "assistant", "uuid": uuid, "message": message})


def _fired_prompt_row(uuid: str, text: str) -> str:
    """A fired scheduled prompt as the CLI persists it (real 2.1.285 shape)."""

    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "isMeta": True,
            "message": {"role": "user", "content": text},
        }
    )


def _enqueue_row(text: str) -> str:
    return json.dumps({"type": "queue-operation", "operation": "enqueue", "content": text})


def _hidden_meta_row(uuid: str, text: str) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "isMeta": True,
            "message": {"role": "user", "content": text},
        }
    )


def _visible_user_row(uuid: str, text: str) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "message": {"role": "user", "content": text},
        }
    )


def _task_notification_row(uuid: str, text: str) -> str:
    """The CLI's persisted background-task notice (real 2.1.285 shape).

    A plain user row with text, distinguished only by its origin metadata —
    the connector's ``is_task_notification_message`` also accepts the text
    wrapper, which is what the SDK-stripped top-level read leaves.
    """

    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "origin": {
                "kind": "task-notification",
                "producer": "session-task",
                "runId": f"run-{uuid}",
            },
            "promptSource": "system",
            "message": {
                "role": "user",
                "content": f"<task-notification>\n{text}\n</task-notification>",
            },
        }
    )


def _task_notification(uuid: str, text: str) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        origin={
            "kind": "task-notification",
            "producer": "session-task",
            "runId": f"run-{uuid}",
        },
        promptSource="system",
        message={
            "role": "user",
            "content": f"<task-notification>\n{text}\n</task-notification>",
        },
    )


def _turn_id_by_text(items: tuple[Any, ...], text: str) -> str:
    matches = [item.turn_id for item in items if item.content.get("text") == text]
    assert len(matches) == 1, f"expected one item with text {text!r}, got {matches!r}"
    assert matches[0] is not None
    return matches[0]


# ---------------------------------------------------------------------------
# Raw transcript shape
# ---------------------------------------------------------------------------


def test_scan_marks_only_enqueue_matched_hidden_prompts() -> None:
    raw = (
        _enqueue_row("Reply with exactly: PROBE"),
        "{}",
        _hidden_meta_row("hidden-fire", "Reply with exactly: PROBE"),
        _assistant_row("assistant-fire", "PROBE"),
        # A local-command caveat is hidden too, but its text never equals the
        # queued command; it must not become a turn boundary.
        _enqueue_row("/context"),
        _hidden_meta_row("hidden-caveat", "<local-command-caveat>cmd"),
        json.dumps(
            {
                "type": "user",
                "uuid": "user-command",
                "message": {"role": "user", "content": "<command-name>/context</command-name>"},
            }
        ),
        # An image placeholder is a hidden user row with no enqueue beside it.
        _hidden_meta_row("hidden-image", "[Image: original 1x1]"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows == {"hidden-fire": 2}


def test_scan_detects_two_consecutive_fired_prompts() -> None:
    raw = (
        _enqueue_row("Prompt one"),
        _hidden_meta_row("hidden-1", "Prompt one"),
        _assistant_row("assistant-1", "one"),
        _enqueue_row("Prompt two"),
        _hidden_meta_row("hidden-2", "Prompt two"),
        _assistant_row("assistant-2", "two"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows == {"hidden-1": 1, "hidden-2": 4}


def test_visible_user_row_consumes_the_enqueue_before_a_later_hidden_row() -> None:
    """A real prompt's enqueue belongs to its visible row, not a later hidden one.

    The CLI writes an enqueue before it persists any prompt. A fired scheduled
    prompt is persisted hidden (``isMeta``); a real user prompt is persisted as
    a visible row. Only the hidden row marks a turn boundary, so the visible
    row must consume the queue entry: without the clear, the hidden meta row
    that follows with the same text would be misread as a fired prompt and
    start a phantom scheduled turn.
    """

    raw = (
        _enqueue_row("X"),
        _visible_user_row("visible-user-row", "X"),
        _hidden_meta_row("hidden-meta-row", "X"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows == {}


# ---------------------------------------------------------------------------
# History seeds
# ---------------------------------------------------------------------------


def test_real_user_turn_seed_is_the_prompt_uuid() -> None:
    prompt_uuid = "11111111-2222-3333-4444-555555555555"
    raw = (
        json.dumps(
            {
                "type": "user",
                "uuid": prompt_uuid,
                "message": {"role": "user", "content": "go"},
            }
        ),
        _assistant_row("assistant-1", "done"),
    )
    session = _session()
    messages = (_user(prompt_uuid, "go"), _assistant("assistant-1", "done"))
    items = _history_items_from_messages(session, messages, raw_lines=raw)
    expected = _history_turn_id(prompt_uuid)
    assert items
    assert {item.turn_id for item in items} == {expected}


def test_turn_id_depends_on_neither_session_id() -> None:
    # A new session's first turn has no native id yet, and the same transcript
    # is projected under the platform alias and the discovery alias. The seed
    # alone must carry the identity: a late native id and a different AA alias
    # must not move the id.
    seed = "33333333-4444-5555-6666-777777777777"
    raw = (_visible_user_row(seed, "go"),)
    messages = (_user(seed, "go"),)
    expected = _history_turn_id(seed)
    for session in (
        _session(external_session_id=None),
        _session(external_session_id="native-later"),
        _session(
            session_id="sess_claude_2a8440e6956b15810b3f0726",
            external_session_id="native-later",
        ),
    ):
        (item,) = _history_items_from_messages(session, messages, raw_lines=raw)
        assert item.turn_id == expected


def test_two_scheduled_turns_get_distinct_anchored_ids() -> None:
    raw = (
        _enqueue_row("Prompt one"),
        _hidden_meta_row("hidden-1", "Prompt one"),
        _assistant_row("assistant-1", "one"),
        _enqueue_row("Prompt two"),
        _hidden_meta_row("hidden-2", "Prompt two"),
        _assistant_row("assistant-2", "two"),
    )
    session = _session()
    messages = (
        _assistant("assistant-1", "one"),
        _assistant("assistant-2", "two"),
    )
    items = _history_items_from_messages(session, messages, raw_lines=raw)
    by_text = {item.content.get("text"): item.turn_id for item in items}
    assert by_text == {
        "one": _history_turn_id("assistant-1"),
        "two": _history_turn_id("assistant-2"),
    }
    assert by_text["one"] != by_text["two"]


def test_scheduled_turn_does_not_inherit_the_previous_user_turn() -> None:
    prompt_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    raw = (
        json.dumps(
            {
                "type": "user",
                "uuid": prompt_uuid,
                "message": {"role": "user", "content": "ask"},
            }
        ),
        _assistant_row("assistant-user-turn", "answer"),
        _enqueue_row("Prompt scheduled"),
        _hidden_meta_row("hidden-scheduled", "Prompt scheduled"),
        _assistant_row("assistant-scheduled", "scheduled answer"),
    )
    session = _session()
    messages = (
        _user(prompt_uuid, "ask"),
        _assistant("assistant-user-turn", "answer"),
        _assistant("assistant-scheduled", "scheduled answer"),
    )
    items = _history_items_from_messages(session, messages, raw_lines=raw)
    by_text = {item.content.get("text"): item.turn_id for item in items}
    assert by_text["answer"] == _history_turn_id(prompt_uuid)
    assert by_text["scheduled answer"] == _history_turn_id("assistant-scheduled")
    assert by_text["scheduled answer"] != by_text["answer"]


def test_task_notification_starts_a_scheduled_turn_anchored_on_its_first_assistant() -> None:
    """A background-task wake-up is a user-less turn, not the previous turn.

    The CLI persists the fired task as a ``<task-notification>`` user row. It
    is chrome (`is_synthetic_control_message`), so history used to skip it and
    keep the previous user turn's seed — while the live reader cast a new
    scheduled turn on the first assistant ``message_start``. At the turn's end
    the history sync then re-keyed the wake-up rows to the previous turn's id
    (b1278 10:05:55: 5 rows, the client split and merged a step group, the page
    jumped 46 pt). The boundary seed must be the first assistant message, the
    same anchor live hashes.
    """

    prompt_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    raw = (
        _visible_user_row(prompt_uuid, "ask"),
        _assistant_row("assistant-user-turn", "answer"),
        _task_notification_row("notice-1", "background task done"),
        _assistant_row("assistant-wakeup", "wake-up answer"),
    )
    session = _session()
    messages = (
        _user(prompt_uuid, "ask"),
        _assistant("assistant-user-turn", "answer"),
        _task_notification("notice-1", "background task done"),
        _assistant("assistant-wakeup", "wake-up answer"),
    )
    items = _history_items_from_messages(session, messages, raw_lines=raw)
    by_text = {item.content.get("text"): item.turn_id for item in items}
    assert by_text["answer"] == _history_turn_id(prompt_uuid)
    assert by_text["wake-up answer"] == _history_turn_id("assistant-wakeup")
    assert by_text["wake-up answer"] != by_text["answer"]


def test_two_task_notifications_get_distinct_scheduled_ids() -> None:
    raw = (
        _task_notification_row("notice-1", "one"),
        _assistant_row("assistant-1", "one"),
        _task_notification_row("notice-2", "two"),
        _assistant_row("assistant-2", "two"),
    )
    session = _session()
    messages = (
        _task_notification("notice-1", "one"),
        _assistant("assistant-1", "one"),
        _task_notification("notice-2", "two"),
        _assistant("assistant-2", "two"),
    )
    items = _history_items_from_messages(session, messages, raw_lines=raw)
    by_text = {item.content.get("text"): item.turn_id for item in items}
    assert by_text["one"] == _history_turn_id("assistant-1")
    assert by_text["two"] == _history_turn_id("assistant-2")
    assert by_text["one"] != by_text["two"]


class _RecordingLogger:
    """Captures the WARN the history projector owes on a turn-id divergence."""

    def __init__(self) -> None:
        self.warnings: list[str] = []

    def warning(self, message: str, *args: object) -> None:
        # The connector logger is loguru: `{}` placeholders, not `%s`.
        try:
            text = message.format(*args)
        except (IndexError, KeyError, ValueError):
            text = message
        self.warnings.append(text)


def test_history_keeps_the_turn_id_the_live_side_published(monkeypatch) -> None:
    """History must never rewrite the turn id of a row live already published.

    The client groups by the declared id, so a mid-session re-key splits one
    step run into two turn buckets. When a projection rule drifts, the live
    id stays and the divergence is logged instead of silently re-keying.
    """

    prompt_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    raw = (
        _visible_user_row(prompt_uuid, "ask"),
        _assistant_row("assistant-1", "answer"),
    )
    session = _session()
    messages = (_user(prompt_uuid, "ask"), _assistant("assistant-1", "answer"))
    live_items = _history_items_from_messages(session, messages, raw_lines=raw)
    reply = next(item for item in live_items if item.content.get("text") == "answer")
    live_turn_id = "turn_claude_live_published"
    session.timeline_items[reply.id] = replace(
        reply,
        turn_id=live_turn_id,
        source={**reply.source, "turnId": live_turn_id},
    )
    drifted = {
        key: "turn_claude_projection_drift"
        for key in _history_turn_ids(messages, scan_raw_transcript(raw))
    }
    recorder = _RecordingLogger()
    monkeypatch.setattr(reader_module, "logger", recorder)
    items = _history_items_from_messages(
        session, messages, raw_lines=raw, turn_ids=drifted
    )
    assert _turn_id_by_text(items, "answer") == live_turn_id
    assert any("turn id diverged" in message for message in recorder.warnings)


def test_incremental_window_reuses_the_full_chain_turn_ids() -> None:
    prompt_one = "11111111-1111-1111-1111-111111111111"
    prompt_two = "22222222-2222-2222-2222-222222222222"
    raw = (
        json.dumps(
            {
                "type": "user",
                "uuid": prompt_one,
                "message": {"role": "user", "content": "one"},
            }
        ),
        _assistant_row("assistant-one", "reply one"),
        json.dumps(
            {
                "type": "user",
                "uuid": prompt_two,
                "message": {"role": "user", "content": "two"},
            }
        ),
        _assistant_row("assistant-two", "reply two"),
    )
    session = _session()
    full_chain = (
        _user(prompt_one, "one"),
        _assistant("assistant-one", "reply one"),
        _user(prompt_two, "two"),
        _assistant("assistant-two", "reply two"),
    )
    scan = scan_raw_transcript(raw)
    full_ids = _history_turn_ids(full_chain, scan)

    # The incremental projection starts at the second assistant row — the
    # exact shape a cursor's suffix produces. Derived from the suffix alone it
    # would re-seed "initial"; with the full mapping it keeps the same id.
    window = full_chain[3:]
    items = _history_items_from_messages(
        session, window, raw_lines=raw, turn_ids=full_ids
    )
    assert [item.turn_id for item in items] == [full_ids["uuid:assistant-two"]]
    assert items[0].turn_id == _history_turn_id(prompt_two)


def test_syncer_computes_turn_ids_over_the_full_chain_not_the_window() -> None:
    """Production mapping: the syncer, not the test, chooses the chain.

    ``_history_turn_ids`` is only as good as the chain the caller hands it.
    This drives the real ``ClaudeHistorySyncer`` twice over the same transcript:
    a first sync projects the whole chain, then a cursor makes the next sync a
    one-message suffix of the SAME turn. The suffix row must keep the id the
    full import published. If the syncer hashed its incremental window instead
    of the full visible chain, the suffix row would re-seed on its own row uuid
    and re-key a turn already on the timeline.
    """

    asyncio.run(_test_syncer_computes_turn_ids_over_the_full_chain_not_the_window())


async def _test_syncer_computes_turn_ids_over_the_full_chain_not_the_window() -> None:
    prompt_uuid = "55555555-6666-7777-8888-999999999999"
    user = SimpleNamespace(
        type="user",
        uuid=prompt_uuid,
        message={"role": "user", "content": "go"},
    )
    reply_one = SimpleNamespace(
        type="assistant",
        uuid="row-reply-one",
        message={"role": "assistant", "content": "first reply"},
    )
    reply_two = SimpleNamespace(
        type="assistant",
        uuid="row-reply-two",
        message={"role": "assistant", "content": "second reply"},
    )
    expected = _history_turn_id(prompt_uuid)

    # Full-view computation: a first sync has no cursor and projects the chain.
    full_prepared = await _syncer(
        host=_SyncStateHost(),
        sdk=_CompactHistorySdk([user, reply_one, reply_two]),
    ).prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    assert full_prepared is not None and full_prepared.snapshot is not None
    assert full_prepared.snapshot.metadata["rebased"] is True
    assert _turn_id_by_text(full_prepared.snapshot.items, "second reply") == expected

    # Incremental-window computation: commit a cursor after reply-one, append
    # reply-two, and sync again. The window is exactly that one message.
    sdk = _CompactHistorySdk([user, reply_one])
    syncer = _syncer(host=_SyncStateHost(), sdk=sdk)
    primed = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert primed is not None and primed.snapshot is not None
    await primed.commit()

    sdk.messages.append(reply_two)
    incremental = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert incremental is not None and incremental.snapshot is not None
    assert incremental.snapshot.metadata["rebased"] is False
    assert incremental.snapshot.metadata["syncedMessageCount"] == 1
    assert _turn_id_by_text(incremental.snapshot.items, "second reply") == expected


def test_assistant_api_message_id_is_preferred_over_the_row_uuid() -> None:
    # One API message is persisted as several rows (thinking/tool/text) that
    # share message.id; the live message_start carries that same id, so the
    # anchor is the API id, not whichever row happened to arrive first.
    raw = (
        _enqueue_row("Prompt"),
        _hidden_meta_row("hidden", "Prompt"),
        _assistant_row("row-thinking", "", message_id="msg_shared"),
        _assistant_row("row-text", "answer", message_id="msg_shared"),
    )
    messages = (
        _assistant("row-thinking", "", message_id="msg_shared"),
        _assistant("row-text", "answer", message_id="msg_shared"),
    )
    ids = _history_turn_ids(messages, scan_raw_transcript(raw))
    expected = _history_turn_id("msg_shared")
    assert set(ids.values()) == {expected}


# ---------------------------------------------------------------------------
# Live anchors
# ---------------------------------------------------------------------------


def test_live_message_start_anchor_is_the_api_message_id() -> None:
    frame = StreamEvent(
        uuid="fresh-stream-uuid",
        session_id=EXTERNAL_SESSION_ID,
        event={
            "type": "message_start",
            "message": {"id": "msg_live_start", "role": "assistant"},
        },
    )
    assert _turn_anchor_from_frame(frame) == "msg_live_start"


def test_live_assistant_frame_anchor_prefers_message_id() -> None:
    frame = SimpleNamespace(
        type="assistant",
        uuid="row-uuid",
        message_id="msg_live_full",
        message={"role": "assistant", "content": "done"},
    )
    assert _turn_anchor_from_frame(frame) == "msg_live_full"


def test_live_user_frame_is_not_a_turn_anchor() -> None:
    frame = SimpleNamespace(
        type="user",
        uuid="peer-row-uuid",
        message={"role": "user", "content": "injected"},
    )
    assert _turn_anchor_from_frame(frame) is None


def test_live_and_history_scheduled_turn_ids_match_end_to_end() -> None:
    class TwoScheduledReplies(_ScheduledClaudeClient):
        def __init__(self) -> None:
            super().__init__()
            self.envelope_uuids: list[str] = []

        async def query(self, prompt):
            if isinstance(prompt, str):
                await super().query(prompt)
                return
            async for message in prompt:
                self.envelope_uuids.append(message["uuid"])
                await self.incoming.put(
                    UserMessage(uuid=message["uuid"], content=message["message"]["content"])
                )
                await self._complete_query(message["message"]["content"])

        async def streamed_reply(
            self, *, message_id: str, row_uuid: str, text: str
        ) -> None:
            # The production shape: message_start carries the API message id
            # before any partial row, so the turn is anchored from the first
            # frame.
            await self.incoming.put(
                StreamEvent(
                    uuid=f"stream-{row_uuid}",
                    session_id=self.native_id,
                    event={
                        "type": "message_start",
                        "message": {"id": message_id, "role": "assistant"},
                    },
                )
            )
            await self.incoming.put(
                AssistantMessage(
                    uuid=row_uuid,
                    message_id=message_id,
                    session_id=self.native_id,
                    model="test-model",
                    content=[{"type": "text", "text": text}],
                )
            )
            await self.incoming.put(
                SimpleNamespace(type="result", session_id=self.native_id)
            )

        async def full_frame_reply(self, *, row_uuid: str, text: str) -> None:
            # A frame with no API id falls back to the transcript row uuid.
            await self.incoming.put(
                AssistantMessage(
                    uuid=row_uuid,
                    session_id=self.native_id,
                    model="test-model",
                    content=[{"type": "text", "text": text}],
                )
            )
            await self.incoming.put(
                SimpleNamespace(type="result", session_id=self.native_id)
            )

    async def run() -> None:
        client = TwoScheduledReplies()
        host = _RecordingHost()
        sdk = _default_sdk()
        sdk.HookMatcher = _FakeHookMatcher
        runtime = _runtime(client=client, sdk=sdk, host=host)
        try:
            result = await runtime.start_turn("timer", None, "schedule")
            await runtime._sessions["timer"].active_task
            prompt_uuid = client.envelope_uuids[0]

            # Two consecutive user-less turns at silence: each is its own
            # scheduled execution and must get its own id.
            await client.streamed_reply(
                message_id="msg_sched_one", row_uuid="row_sched_one", text="scheduled one"
            )
            await client.full_frame_reply(
                row_uuid="row_sched_two", text="scheduled two"
            )
            await _wait_until(lambda: len(host.session_turn_ends) >= 3)

            replies = {
                item.content.get("text"): item.turn_id
                for item in host.timeline_item_upserts
                if item.role == "assistant"
            }
            # The real user turn: both its user item and its reply hash the
            # pre-assigned prompt uuid (not a random token, not the native id).
            expected_user_turn = _history_turn_id(prompt_uuid)
            assert replies["reply:schedule"] == expected_user_turn
            user_items = [
                item
                for item in host.timeline_item_upserts
                if item.role == "user" and item.content.get("text") == "schedule"
            ]
            assert user_items and all(
                item.turn_id == expected_user_turn for item in user_items
            )
            # The scheduled turns: distinct from each other and from the
            # previous turn, anchored on their FIRST assistant message.
            assert replies["scheduled one"] == _history_turn_id("msg_sched_one")
            assert replies["scheduled two"] == _history_turn_id("row_sched_two")
            assert (
                len(
                    {
                        replies["scheduled one"],
                        replies["scheduled two"],
                        expected_user_turn,
                    }
                )
                == 3
            )

            # The history projection of the same transcript-shaped rows
            # produces exactly the live ids.
            history_messages = (
                _assistant("row_sched_one", "scheduled one", message_id="msg_sched_one"),
                _assistant("row_sched_two", "scheduled two"),
            )
            raw = (
                _enqueue_row("scheduled one"),
                _hidden_meta_row("hidden-1", "scheduled one"),
                _assistant_row("row_sched_one", "scheduled one", message_id="msg_sched_one"),
                _enqueue_row("scheduled two"),
                _hidden_meta_row("hidden-2", "scheduled two"),
                _assistant_row("row_sched_two", "scheduled two"),
            )
            projected = _history_items_from_messages(
                _session(session_id="timer"), history_messages, raw_lines=raw
            )
            assert {item.turn_id for item in projected} == {
                replies["scheduled one"],
                replies["scheduled two"],
            }
            assert result.ok
        finally:
            await runtime.stop()

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Live/history convergence on real sends
# ---------------------------------------------------------------------------


def test_pure_attachment_prompt_turn_ids_match_live_and_history() -> None:
    """An attachment-only send already converges without a seed fix.

    The prompt has no user-typed text (``content=""``), and the live side
    pre-assigns the prompt uuid before dispatch, so the live user item's id is
    ``hash(prompt uuid)``. History sees the row the CLI persisted, whose
    content is the connector's injected ``Attached files:`` note — that note is
    text, so the seed condition (``role == "user" and text``) already selects
    the same uuid. Unlike a raw attachment block, the note guarantees a
    text-bearing prompt row, which is why no reader-side widening is needed.
    """

    asyncio.run(_test_pure_attachment_prompt_turn_ids_match_live_and_history())


async def _test_pure_attachment_prompt_turn_ids_match_live_and_history() -> None:
    session_id = "sess_turn_id_attachment"
    external_session_id = "native-turn-id-attachment"
    host = _RecordingHost()
    host.attachments["file_att"] = RuntimeAttachmentContent(
        file_id="file_att",
        name="image.png",
        media_type="image/png",
        content=b"x",
    )
    client = _FakeClaudeClient(
        echo_prompt=True,
        echo_suffix=[
            SimpleNamespace(
                type="assistant",
                uuid="attachment-reply-row",
                message={"role": "assistant", "content": "done"},
            ),
            SimpleNamespace(type="result", session_id=external_session_id),
        ],
    )

    def session_messages(**_: Any) -> list[Any]:
        # The real SDK replays the wire prompt uuid and the exact content the
        # connector sent (attachments materialized as notes).
        return [
            SimpleNamespace(
                type="user",
                uuid=client.prompt_uuids[0],
                message={"role": "user", "content": client.queries[0]},
            ),
            SimpleNamespace(
                type="assistant",
                uuid="attachment-reply-row",
                message={"role": "assistant", "content": "done"},
            ),
        ]

    sdk = _default_sdk()
    sdk.get_session_messages = session_messages
    runtime = _runtime(host=host, client=client, sdk=sdk)
    try:
        result = await runtime.start_turn(
            session_id,
            external_session_id,
            "",
            attachments=(
                RuntimeAttachment(
                    file_id="file_att",
                    name="image.png",
                    media_type="image/png",
                ),
            ),
        )
        assert result.ok is True
        await runtime._sessions[session_id].active_task

        live_users = [
            item for item in host.timeline_item_upserts if item.role == "user"
        ]
        assert len(live_users) == 1
        # The send really is attachment-only: no typed text, one attachment.
        assert live_users[0].content.get("text") == ""
        assert live_users[0].content.get("attachments")
        expected = _history_turn_id(client.prompt_uuids[0])
        assert live_users[0].turn_id == expected

        handled = await runtime.sync_session_timeline(
            session_id, external_session_id
        )
        assert handled is True
        history_items = host.timeline_syncs[-1]["items"]
        history_users = [item for item in history_items if item.role == "user"]
        assert len(history_users) == 1
        assert history_users[0].turn_id == expected
        assert history_users[0].content.get("attachments")
        history_assistants = [
            item for item in history_items if item.role == "assistant"
        ]
        assert history_assistants
        assert {item.turn_id for item in history_assistants} == {expected}
        # And the live reply carried the same id, so the replay converges.
        live_assistants = [
            item for item in host.timeline_item_upserts if item.role == "assistant"
        ]
        assert live_assistants
        assert {item.turn_id for item in live_assistants} == {expected}
    finally:
        await runtime.stop()


def test_command_history_rows_do_not_seed_a_turn() -> None:
    """Command turns are the documented exception to the live/history claim.

    The live side mints a random opaque id before dispatch (a command has no
    prompt uuid on the wire), and the CLI persists the command as synthetic
    chrome rows (``<command-name>…``) that the history projection never emits.
    With no transcript id both sides can hash, history attributes whatever
    follows the command to the previous user turn. This pins today's behavior;
    it is not a target to "fix" by inventing an id on one side only.
    """

    prompt_uuid = "aaaaaaaa-1111-2222-3333-444444444444"
    messages = (
        _user(prompt_uuid, "go"),
        _assistant("assistant-before", "before"),
        _user("command-row", "<command-name>/compact</command-name>"),
        _assistant("assistant-after", "after"),
    )
    previous_turn = _history_turn_id(prompt_uuid)
    turn_ids = _history_turn_ids(messages, None)
    assert turn_ids["uuid:command-row"] == previous_turn
    assert turn_ids["uuid:assistant-after"] == previous_turn

    items = _history_items_from_messages(_session(), messages)
    # The command chrome is synthetic: no user bubble, and no turn of its own.
    assert [item.content.get("text") for item in items if item.role == "user"] == [
        "go"
    ]
    assert {item.turn_id for item in items} == {previous_turn}


def test_command_turn_live_id_is_opaque_and_not_repeatable() -> None:
    """The other half of the exception: live command ids share no anchor.

    Two identical commands in one session get two different random ids, so
    there is no deterministic value history could have derived.
    """

    asyncio.run(_test_command_turn_live_id_is_opaque_and_not_repeatable())


async def _test_command_turn_live_id_is_opaque_and_not_repeatable() -> None:
    session_id = "sess_turn_id_command_probe"
    external_session_id = "native-turn-id-command-probe"
    client = _FakeClaudeClient(
        messages=[SimpleNamespace(type="result", session_id=external_session_id)]
    )
    runtime = _runtime(host=_RecordingHost(), client=client)
    try:
        first = await runtime.execute_command(
            session_id, "compact", external_session_id
        )
        await runtime._sessions[session_id].active_task
        second = await runtime.execute_command(
            session_id, "compact", external_session_id
        )
        await runtime._sessions[session_id].active_task

        assert first.ok is True and second.ok is True
        first_id = first.result["turnId"]
        second_id = second.result["turnId"]
        assert first_id.startswith("turn_claude_")
        assert second_id.startswith("turn_claude_")
        assert first_id != second_id
        assert client.queries == ["/compact", "/compact"]
    finally:
        await runtime.stop()


# ---------------------------------------------------------------------------
# Projection version
# ---------------------------------------------------------------------------


def test_projection_version_is_eight_and_older_cursors_rebase() -> None:
    assert HISTORY_PROJECTION_VERSION == 8
    stale = ClaudeHistoryCursor(
        last_modified=1,
        file_size=2,
        message_count=3,
        last_message_uuid="m3",
        projector_version=7,
    )
    window = messages_after_cursor((object(),), stale)
    assert window.rebased is True


# ---------------------------------------------------------------------------
# Session-alias invariance
# ---------------------------------------------------------------------------


def test_turn_ids_are_identical_under_two_session_aliases() -> None:
    """One native transcript must project one turn map under any AA id.

    The platform session (``sess_<random>``) and the discovery session
    (``sess_claude_<hash>``, ``stable_session_id``) are aliases of the same
    Claude session; the Server resolves a discovery sync into the platform
    session by external id (``sessions.resolve_connector_session_id``). A turn
    id that hashes the AA id therefore flips every row when the two writers
    alternate — 2026-11-22: one connector restart rewrote 56 sessions /
    27,052 items, and one turn kept two ids, splitting its step group
    (``sess_iTPt9D48BXhspg``: 874 of 2058 rows on the discovery id).
    """

    prompt = "cccccccc-1111-2222-3333-444444444444"
    raw = (
        _visible_user_row(prompt, "go"),
        _assistant_row("assistant-1", "done"),
        _enqueue_row("Prompt two"),
        _hidden_meta_row("hidden-2", "Prompt two"),
        _assistant_row("assistant-2", "scheduled answer", message_id="msg_sched"),
    )
    messages = (
        _user(prompt, "go"),
        _assistant("assistant-1", "done"),
        _assistant("assistant-2", "scheduled answer", message_id="msg_sched"),
    )
    attached = _session(
        session_id="sess_platform_alias",
        external_session_id=EXTERNAL_SESSION_ID,
    )
    discovered = _session(
        session_id="sess_claude_2a8440e6956b15810b3f0726",
        external_session_id=EXTERNAL_SESSION_ID,
    )

    def projected_items(session: ClaudeSession) -> list[Any]:
        # The whole row, not just the id: a future alias-dependent field must
        # fail here too. The AA session id is the one field allowed to differ.
        return [
            replace(item, session_id="alias")
            for item in _history_items_from_messages(
                session, messages, raw_lines=raw
            )
        ]

    assert projected_items(attached) == projected_items(discovered)
    # Both seed kinds land on the plain seed hash: a real prompt on its uuid,
    # the user-less turn on its first assistant message id.
    assert {item.turn_id for item in projected_items(attached)} == {
        _history_turn_id(prompt),
        _history_turn_id("msg_sched"),
    }


def test_syncer_snapshot_is_identical_under_two_session_aliases() -> None:
    """The sync payload is alias-invariant end to end.

    Drives the real ``ClaudeHistorySyncer`` (cursor, full-chain walk, projection)
    twice over the same transcript under the two AA aliases the Server merges
    into one session, comparing every field except the AA session id itself.
    Any difference here is a row the Server would rewrite.
    """

    asyncio.run(_test_syncer_snapshot_is_identical_under_two_session_aliases())


async def _test_syncer_snapshot_is_identical_under_two_session_aliases() -> None:
    prompt_uuid = "dddddddd-1111-2222-3333-444444444444"
    user = SimpleNamespace(
        type="user", uuid=prompt_uuid, message={"role": "user", "content": "go"}
    )
    reply = SimpleNamespace(
        type="assistant", uuid="row-reply", message={"role": "assistant", "content": "done"}
    )

    async def prepare(session_id: str):
        prepared = await _syncer(
            host=_SyncStateHost(),
            sdk=_CompactHistorySdk([user, reply]),
        ).prepare_session_timeline_sync(session_id, EXTERNAL_SESSION_ID)
        assert prepared is not None and prepared.snapshot is not None
        return [
            replace(item, session_id="alias")
            for item in prepared.snapshot.items
        ]

    attached = await prepare("sess_platform_alias")
    discovered = await prepare("sess_claude_2a8440e6956b15810b3f0726")
    assert len(attached) >= 2
    assert {item.turn_id for item in attached} == {_history_turn_id(prompt_uuid)}
    assert attached == discovered


def test_raw_walk_anchors_a_fired_prompt_turn_like_history_and_live() -> None:
    """A fired prompt opens a scheduled turn for the raw walk too.

    ``enqueue`` + hidden meta prompt + assistant. The SDK walk marks the
    boundary from ``injected_prompt_rows`` and the live side casts the turn on
    the first ``message_start``; the raw walk must hash the same message id.
    It used to keep the previous user turn's seed there, so an Agent card
    rebuilt from a dispatch row outside the visible chain landed on the wrong
    turn (2026-11-22 review).
    """

    raw = (
        _enqueue_row("Prompt"),
        _hidden_meta_row("hidden-fired", "Prompt"),
        _assistant_row("row-answer", "answer", message_id="msg_fired"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows.get("hidden-fired") is not None
    assert scan.turn_seeds.get("row-answer") == "msg_fired"
    messages = (_assistant("row-answer", "answer", message_id="msg_fired"),)
    assert set(_history_turn_ids(messages, scan).values()) == {
        _history_turn_id("msg_fired")
    }
    # The raw walk's anchor-less fallback translates to the same seed the SDK
    # walk uses, so a card rebuilt from it keeps the turn.
    assert _scan_turn_id("scheduled@42") == _history_turn_id("scheduled:42")


def test_a_cross_session_message_anchors_like_a_fired_prompt() -> None:
    """A peer message is a hidden enqueued prompt, so it anchors the turn.

    Real 2.1.285 shape (2026-11-02): ``queue-operation`` enqueue, then the
    hidden ``<cross-session-message>`` user row. The SDK view drops that row,
    so history sees only the assistant that follows; the enqueue + exact-text
    pair is what makes it a boundary and anchors that assistant's message id,
    the same frame live casts the turn on.
    """

    text = (
        '<cross-session-message from="uds:/tmp/peer.sock" from-name="ubuntu-a0">'
        "hello</cross-session-message>"
    )
    raw = (
        _visible_user_row("p1", "go"),
        _assistant_row("a1", "first"),
        _enqueue_row(text),
        _hidden_meta_row("peer", text),
        _assistant_row("a2", "peer reply", message_id="msg_peer"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows.get("peer") is not None
    messages = (
        _user("p1", "go"),
        _assistant("a1", "first"),
        _assistant("a2", "peer reply", message_id="msg_peer"),
    )
    assert set(_history_turn_ids(messages, scan).values()) == {
        _history_turn_id("p1"),
        _history_turn_id("msg_peer"),
    }
    assert scan.turn_seeds.get("a2") == "msg_peer"


def test_a_compact_boundary_drops_pre_compact_fired_prompt_boundaries() -> None:
    """A fired prompt compacted away must not anchor the post-compact row.

    The compaction continues the turn that was running; live keeps that turn's
    id. The raw walk used to carry the stale boundary across the summary and
    anchor the first assistant row after it on its own message id (2026-11-22
    review, constructed repro).
    """

    raw = (
        _visible_user_row("p1", "go"),
        _assistant_row("a1", "first"),
        _enqueue_row("Prompt"),
        _hidden_meta_row("hidden-fired", "Prompt"),
        json.dumps({
            "type": "system",
            "subtype": "compact_boundary",
            "uuid": "compact-1",
            "compactMetadata": {},
        }),
        _assistant_row("a2", "after compact", message_id="msg_after"),
    )
    scan = scan_raw_transcript(raw)
    assert scan.injected_prompt_rows == {}
    messages = (
        _user("p1", "go"),
        _assistant("a1", "first"),
        _assistant("a2", "after compact", message_id="msg_after"),
    )
    assert set(_history_turn_ids(messages, scan).values()) == {_history_turn_id("p1")}
    assert scan.turn_seeds.get("a2") == "p1"
