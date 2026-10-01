"""History edges around Claude /compact: cursor rebase and summary filtering.

A compaction rewrites the SDK chain: it restarts from a summary prompt and the
pre-compaction messages stop being reachable. These tests pin the two history
consequences - the stored cursor must rebase instead of slicing past the end of
a shorter list, and the summary prompt must never reach the timeline.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest

from connector.logging import logger
from connector.runtime_protocol import RuntimeConfig, RuntimeHostClient
from connector.runtimes.claude.domain.pending_messages import (
    ClaudeClientMessageBinding,
    ClaudeHistoryUserMessage,
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.history.cursor import (
    INCREMENTAL_COUNT_ANCHORED,
    INCREMENTAL_UUID_ANCHORED,
    REBASE_CHAIN_REWRITTEN,
    REBASE_NO_CURSOR,
    REBASE_UUID_DANGLING,
    ClaudeHistoryCursor,
    messages_after_cursor,
)
from connector.runtimes.claude.history.state import ClaudeHistoryCursorStore
from connector.runtimes.claude.history.syncer import ClaudeHistorySyncer
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    _session_title,
)
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore
from connector.runtimes.claude.timeline.messages import (
    CLAUDE_COMPACT_SUMMARY_PREFIX,
    is_compact_summary_text,
    is_synthetic_control_message,
    stable_message_item_id,
)

EXTERNAL_SESSION_ID = "claude_compact_history"
SESSION_ID = "sess_claude_compact_history"
SUMMARY_TEXT = (
    f"{CLAUDE_COMPACT_SUMMARY_PREFIX}\n\n"
    "## Conversation summary\n- earlier turns were dropped"
)


def _message(uuid: str, role: str, text: str) -> Any:
    return SimpleNamespace(
        type=role,
        uuid=uuid,
        session_id=EXTERNAL_SESSION_ID,
        message={"role": role, "content": text},
    )


def _uuids(messages: tuple[Any, ...]) -> tuple[str, ...]:
    return tuple(str(message.uuid) for message in messages)


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Compact history",
        cwd="/repo",
    )


def _cursor(
    *,
    last_message_uuid: str | None,
    message_count: int,
) -> ClaudeHistoryCursor:
    return ClaudeHistoryCursor(
        last_modified=None,
        file_size=None,
        message_count=message_count,
        last_message_uuid=last_message_uuid,
    )


def _registry_with_pending(*texts: str) -> ClaudePendingClientMessageRegistry:
    registry = ClaudePendingClientMessageRegistry("conn_test")
    for index, text in enumerate(texts):
        registry.register_live_message(
            session_id=SESSION_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            client_message_id=f"client_{index}",
            platform_item_id=f"platform_{index}",
            text=text,
            attachments=(),
        )
    return registry


def _history_user_messages(*texts: str) -> tuple[ClaudeHistoryUserMessage, ...]:
    return tuple(
        ClaudeHistoryUserMessage(native_message_id=f"native_{index}", text=text)
        for index, text in enumerate(texts)
    )


def _bound_client_messages(
    matches: dict[str, ClaudeClientMessageBinding],
) -> dict[str, str]:
    return {uuid: binding.client_message_id for uuid, binding in sorted(matches.items())}


def _user_item_ids(items: tuple[Any, ...]) -> list[str]:
    return [item.id for item in items if item.role == "user"]


def _register_late_pending(registry: ClaudePendingClientMessageRegistry) -> None:
    registry.register_live_message(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        client_message_id="client_late",
        platform_item_id="platform_late",
        text="hello",
        attachments=(),
    )


def test_claude_history_cursor_returns_only_new_messages_when_uuid_resolves() -> None:
    messages = (
        _message("u1", "user", "first"),
        _message("a1", "assistant", "answered"),
        _message("u2", "user", "second"),
    )

    window = messages_after_cursor(
        messages,
        _cursor(last_message_uuid="a1", message_count=2),
    )

    assert _uuids(window.messages) == ("u2",)
    assert (window.rebased, window.reason) == (False, INCREMENTAL_UUID_ANCHORED)


def test_claude_history_cursor_rebases_full_chain_when_uuid_is_dangling() -> None:
    before = (
        _message("u1", "user", "first"),
        _message("a1", "assistant", "answered"),
        _message("u2", "user", "second"),
        _message("a2", "assistant", "answered again"),
    )
    # After the compaction the chain restarts from the summary and is shorter
    # than the four messages the cursor was written against.
    after = (
        _message("summary", "user", SUMMARY_TEXT),
        _message("u3", "user", "third"),
    )

    window = messages_after_cursor(
        after,
        _cursor(last_message_uuid="a2", message_count=len(before)),
    )

    assert _uuids(window.messages) == ("summary", "u3")
    assert (window.rebased, window.reason) == (True, REBASE_UUID_DANGLING)


def test_claude_history_cursor_rebases_when_uuid_less_chain_shrinks() -> None:
    after = (_message("summary", "user", SUMMARY_TEXT),)

    window = messages_after_cursor(
        after,
        _cursor(last_message_uuid=None, message_count=9),
    )

    assert _uuids(window.messages) == ("summary",)
    assert (window.rebased, window.reason) == (True, REBASE_CHAIN_REWRITTEN)


def test_claude_history_cursor_returns_full_chain_without_cursor() -> None:
    messages = (_message("u1", "user", "first"), _message("a1", "assistant", "hi"))

    window = messages_after_cursor(
        messages,
        _cursor(
            last_message_uuid=None,
            message_count=0,
        ),
    )

    assert _uuids(window.messages) == ("u1", "a1")
    assert (window.rebased, window.reason) == (True, REBASE_CHAIN_REWRITTEN)


def test_claude_history_cursor_rebases_the_whole_chain_without_a_stored_cursor() -> None:
    """The first sync of a session covers everything, like a rebase does."""

    messages = (_message("u1", "user", "first"), _message("a1", "assistant", "hi"))

    window = messages_after_cursor(messages, None)

    assert _uuids(window.messages) == ("u1", "a1")
    assert (window.rebased, window.reason) == (True, REBASE_NO_CURSOR)


@pytest.mark.parametrize(
    ("label", "cursor", "want_uuids", "want_rebased", "want_reason"),
    [
        (
            "uuid anchored mid chain",
            _cursor(last_message_uuid="m2", message_count=99),
            ("m3", "m4"),
            False,
            INCREMENTAL_UUID_ANCHORED,
        ),
        (
            "uuid anchored at the tail leaves nothing new",
            _cursor(last_message_uuid="m4", message_count=5),
            (),
            False,
            INCREMENTAL_UUID_ANCHORED,
        ),
        (
            "uuid less chain that grew",
            _cursor(last_message_uuid=None, message_count=3),
            ("m3", "m4"),
            False,
            INCREMENTAL_COUNT_ANCHORED,
        ),
        (
            "uuid less chain rewritten in place",
            _cursor(last_message_uuid=None, message_count=5),
            ("m0", "m1", "m2", "m3", "m4"),
            True,
            REBASE_CHAIN_REWRITTEN,
        ),
        (
            "uuid less chain that shrank",
            _cursor(last_message_uuid=None, message_count=5),
            ("m0", "m1", "m2", "m3", "m4"),
            True,
            REBASE_CHAIN_REWRITTEN,
        ),
        (
            "uuid that no longer resolves",
            _cursor(last_message_uuid="gone", message_count=5),
            ("m0", "m1", "m2", "m3", "m4"),
            True,
            REBASE_UUID_DANGLING,
        ),
    ],
)
def test_claude_history_cursor_classifies_every_window_branch(
    label: str,
    cursor: ClaudeHistoryCursor,
    want_uuids: tuple[str, ...],
    want_rebased: bool,
    want_reason: str,
) -> None:
    """`rebased` is a stated signal, never a side effect of the slice length.

    The whole chain and an incremental slice are the two things the syncer acts
    on, and only one of them may switch pending matching to `prefer_latest`.
    """

    messages = tuple(
        _message(f"m{index}", "user", text)
        for index, text in enumerate(("hello", "world", "hello", "ok", "hello"))
    )

    window = messages_after_cursor(messages, cursor)

    assert _uuids(window.messages) == want_uuids, label
    assert (window.rebased, window.reason) == (want_rebased, want_reason), label


def test_claude_history_cursor_rebases_an_emptied_transcript_on_the_dangling_uuid() -> (
    None
):
    """A transcript that lost everything keeps the dangling-uuid classification.

    Which flag is right is unobservable here - there is nothing left to match -
    so the branch that republishes the whole chain is the one that stays.
    """

    window = messages_after_cursor((), _cursor(last_message_uuid="gone", message_count=5))

    assert window.messages == ()
    assert window.rebased is True
    assert window.reason == REBASE_UUID_DANGLING


def test_claude_pending_messages_bind_identical_sends_in_send_order() -> None:
    """R2 repro: three identical pending sends must bind m0/m2/m4, not m4/m2/m0.

    Walking the pending list backwards and taking the latest free occurrence
    from the tail is what keeps the pairing chronological - the newest send
    claims the newest occurrence, so every earlier send lands further up the
    chain. Walking forwards would invert the whole timeline.
    """

    registry = _registry_with_pending("hello", "hello", "hello")

    matches = registry.match_history_messages(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        messages=_history_user_messages("hello", "world", "hello", "ok", "hello"),
        prefer_latest=True,
    )

    assert _bound_client_messages(matches) == {
        "native_0": "client_0",
        "native_2": "client_1",
        "native_4": "client_2",
    }


def test_claude_pending_messages_bind_one_send_to_the_latest_occurrence() -> None:
    """A single pending send must not steal an older identical message's uuid."""

    registry = _registry_with_pending("hello")

    matches = registry.match_history_messages(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        messages=_history_user_messages("hello", "world", "hello", "ok", "hello"),
        prefer_latest=True,
    )

    assert _bound_client_messages(matches) == {"native_4": "client_0"}


def test_claude_pending_messages_leave_older_occurrences_to_published_turns() -> None:
    """Two fresh sends out of three identical rows take the two newest ones."""

    registry = _registry_with_pending("hello", "hello")

    matches = registry.match_history_messages(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        messages=_history_user_messages("hello", "world", "hello", "ok", "hello"),
        prefer_latest=True,
    )

    assert _bound_client_messages(matches) == {
        "native_2": "client_0",
        "native_4": "client_1",
    }


def test_claude_pending_messages_match_incremental_history_in_send_order() -> None:
    registry = _registry_with_pending("hello", "hello")

    matches = registry.match_history_messages(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        messages=_history_user_messages("hello", "world", "hello", "ok", "hello"),
        prefer_latest=False,
    )

    assert _bound_client_messages(matches) == {
        "native_0": "client_0",
        "native_2": "client_1",
    }


def test_claude_history_sync_rebases_cursor_and_settles_on_the_new_tail() -> None:
    asyncio.run(_test_claude_history_sync_rebases_cursor_and_settles_on_the_new_tail())


async def _test_claude_history_sync_rebases_cursor_and_settles_on_the_new_tail() -> (
    None
):
    host = _SyncStateHost()
    sdk = _CompactHistorySdk(
        messages=[
            _message("u1", "user", "first"),
            _message("a1", "assistant", "answered"),
            _message("u2", "user", "second"),
            _message("a2", "assistant", "answered again"),
        ]
    )
    syncer = _syncer(host=host, sdk=sdk)

    first = await syncer.prepare_session_timeline_sync(
        SESSION_ID,
        EXTERNAL_SESSION_ID,
    )
    assert first is not None
    assert first.snapshot is not None
    assert first.snapshot.metadata["rebased"] is True
    assert first.snapshot.metadata["syncedMessageCount"] == 4
    await first.commit()

    # Compaction: the chain restarts from the summary and the old tail is gone.
    sdk.messages = [
        _message("summary", "user", SUMMARY_TEXT),
        _message("u3", "user", "third"),
        _message("a3", "assistant", "answered after compaction"),
    ]

    rebased = await syncer.prepare_session_timeline_sync(
        SESSION_ID,
        EXTERNAL_SESSION_ID,
    )
    assert rebased is not None
    assert rebased.snapshot is not None
    assert rebased.snapshot.metadata["rebased"] is True
    assert rebased.snapshot.metadata["syncedMessageCount"] == 3
    texts = [item.content["text"] for item in rebased.snapshot.items]
    assert SUMMARY_TEXT not in texts
    assert texts == ["third", "answered after compaction"]
    await rebased.commit()

    # The cursor now points at the new tail, so the next pass is a no-op.
    settled = await syncer.prepare_session_timeline_sync(
        SESSION_ID,
        EXTERNAL_SESSION_ID,
    )
    assert settled is not None
    assert settled.snapshot is None


def test_claude_history_sync_keeps_incremental_sync_off_the_rebase_path() -> None:
    asyncio.run(_test_claude_history_sync_keeps_incremental_sync_off_the_rebase_path())


async def _test_claude_history_sync_keeps_incremental_sync_off_the_rebase_path() -> (
    None
):
    host = _SyncStateHost()
    sdk = _CompactHistorySdk(
        messages=[_message("u1", "user", "first"), _message("a1", "assistant", "hi")]
    )
    syncer = _syncer(host=host, sdk=sdk)

    first = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    assert first is not None and first.commit is not None
    await first.commit()

    sdk.messages = [
        *sdk.messages,
        _message("u2", "user", "second"),
        _message("a2", "assistant", "hi again"),
    ]
    incremental = await syncer.prepare_session_timeline_sync(
        SESSION_ID,
        EXTERNAL_SESSION_ID,
    )

    assert incremental is not None
    assert incremental.snapshot is not None
    assert incremental.snapshot.metadata["rebased"] is False
    assert incremental.snapshot.metadata["syncedMessageCount"] == 2
    assert [item.content["text"] for item in incremental.snapshot.items] == [
        "second",
        "hi again",
    ]


def test_claude_history_sync_prefers_the_latest_occurrence_after_a_rebase() -> None:
    asyncio.run(_test_claude_history_sync_prefers_the_latest_occurrence_after_a_rebase())


async def _test_claude_history_sync_prefers_the_latest_occurrence_after_a_rebase() -> (
    None
):
    """A rebase republishes the whole chain, so pending sends bind to its tail."""

    host = _SyncStateHost()
    sdk = _CompactHistorySdk(
        messages=[
            _message("u1", "user", "first"),
            _message("a1", "assistant", "answered"),
        ]
    )
    registry = ClaudePendingClientMessageRegistry("conn_test")
    syncer = _syncer(host=host, sdk=sdk, pending_messages=registry)
    first = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    assert first is not None and first.commit is not None
    await first.commit()

    _register_late_pending(registry)

    # The compaction drops the old tail, so the stored uuid dangles and the whole
    # post-compaction chain is synced again with two identical rows to choose
    # from. The pending send belongs to the newest one.
    sdk.messages = [
        _message("summary", "user", SUMMARY_TEXT),
        _message("u2", "user", "hello"),
        _message("a2", "assistant", "answered"),
        _message("u3", "user", "hello"),
        _message("a3", "assistant", "answered again"),
    ]
    rebased = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)

    assert rebased is not None
    assert rebased.snapshot is not None
    assert rebased.snapshot.metadata["rebased"] is True
    assert _user_item_ids(rebased.snapshot.items) == [
        stable_message_item_id(_session(), "u2"),
        "platform_late",
    ]


def test_claude_history_sync_keeps_pending_on_the_first_occurrence_when_incremental() -> (
    None
):
    asyncio.run(
        _test_claude_history_sync_keeps_pending_on_the_first_occurrence_when_incremental()
    )


async def _test_claude_history_sync_keeps_pending_on_the_first_occurrence_when_incremental() -> (
    None
):
    """Without a rebase the slice is only what the cursor has not covered, so
    matching stays in send order and takes the earliest free occurrence."""

    host = _SyncStateHost()
    sdk = _CompactHistorySdk(
        messages=[
            _message("u1", "user", "first"),
            _message("a1", "assistant", "answered"),
        ]
    )
    registry = ClaudePendingClientMessageRegistry("conn_test")
    syncer = _syncer(host=host, sdk=sdk, pending_messages=registry)
    first = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    assert first is not None and first.commit is not None
    await first.commit()

    _register_late_pending(registry)

    sdk.messages = [
        _message("u1", "user", "first"),
        _message("a1", "assistant", "answered"),
        _message("u2", "user", "hello"),
        _message("a2", "assistant", "answered"),
        _message("u3", "user", "hello"),
        _message("a3", "assistant", "answered again"),
    ]
    incremental = await syncer.prepare_session_timeline_sync(
        SESSION_ID,
        EXTERNAL_SESSION_ID,
    )

    assert incremental is not None
    assert incremental.snapshot is not None
    assert incremental.snapshot.metadata["rebased"] is False
    assert _user_item_ids(incremental.snapshot.items) == [
        "platform_late",
        stable_message_item_id(_session(), "u3"),
    ]


def test_claude_history_sync_prefers_latest_on_the_first_sync_of_a_session() -> None:
    asyncio.run(
        _test_claude_history_sync_prefers_latest_on_the_first_sync_of_a_session()
    )


async def _test_claude_history_sync_prefers_latest_on_the_first_sync_of_a_session() -> (
    None
):
    """No stored cursor means a first sync: full chain, and the same
    `prefer_latest` matching a rebase uses, so an old identical turn in the
    transcript never steals a fresh send."""

    host = _SyncStateHost()
    sdk = _CompactHistorySdk(
        messages=[
            _message("u1", "user", "hello"),
            _message("a1", "assistant", "old answer"),
            _message("u2", "user", "hello"),
            _message("a2", "assistant", "new answer"),
        ]
    )
    registry = ClaudePendingClientMessageRegistry("conn_test")
    _register_late_pending(registry)
    syncer = _syncer(host=host, sdk=sdk, pending_messages=registry)

    first = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)

    assert first is not None
    assert first.snapshot is not None
    assert first.snapshot.metadata["rebased"] is True
    assert _user_item_ids(first.snapshot.items) == [
        stable_message_item_id(_session(), "u1"),
        "platform_late",
    ]


def test_claude_history_sync_reports_why_the_cursor_rebased() -> None:
    asyncio.run(_test_claude_history_sync_reports_why_the_cursor_rebased())


async def _test_claude_history_sync_reports_why_the_cursor_rebased() -> None:
    """The rebase is what flips pending matching, so the log has to say why."""

    host = _SyncStateHost()
    sdk = _CompactHistorySdk(messages=[_message("u1", "user", "first")])
    syncer = _syncer(host=host, sdk=sdk)
    first = await syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    assert first is not None and first.commit is not None
    await first.commit()

    # The rewrite drops the uuid the cursor was written against.
    lines: list[str] = []
    sink = logger.add(lambda message: lines.append(str(message)), level="INFO")
    try:
        sdk.messages = [_message("u2", "user", "second")]
        rebased = await syncer.prepare_session_timeline_sync(
            SESSION_ID,
            EXTERNAL_SESSION_ID,
        )
    finally:
        logger.remove(sink)

    assert rebased is not None and rebased.snapshot is not None
    assert rebased.snapshot.metadata["rebased"] is True
    assert any(
        "rebased" in line and REBASE_UUID_DANGLING in line for line in lines
    ), lines


def test_claude_history_projection_drops_compact_summary_message() -> None:
    post_compact = (
        _message("summary", "user", SUMMARY_TEXT),
        _message("u3", "user", "third"),
        _message("a3", "assistant", "answered after compaction"),
    )

    items = _history_items_from_messages(_session(), post_compact)

    assert [item.type for item in items] == ["message", "message"]
    assert [item.role for item in items] == ["user", "assistant"]
    assert [item.content["text"] for item in items] == [
        "third",
        "answered after compaction",
    ]


def test_claude_history_projection_keeps_turn_grouping_across_compaction() -> None:
    clean = (
        _message("u3", "user", "third"),
        _message("a3", "assistant", "answered after compaction"),
    )
    post_compact = (_message("summary", "user", SUMMARY_TEXT), *clean)

    clean_items = _history_items_from_messages(_session(), clean)
    compacted_items = _history_items_from_messages(_session(), post_compact)

    # The summary must not consume a turn index or seed the turn id, otherwise
    # every post-compaction turn lands in a group of its own.
    assert [(item.id, item.turn_id) for item in compacted_items] == [
        (item.id, item.turn_id) for item in clean_items
    ]
    assert len({item.turn_id for item in compacted_items}) == 1


def test_claude_history_marks_compact_summary_by_prefix_only_for_user_messages() -> (
    None
):
    assert is_compact_summary_text(SUMMARY_TEXT) is True
    assert is_compact_summary_text("This session is being continued") is False
    assert is_compact_summary_text("") is False
    assert is_synthetic_control_message(_message("s", "user", SUMMARY_TEXT)) is True
    assert (
        is_synthetic_control_message(_message("s", "assistant", SUMMARY_TEXT)) is False
    )
    assert is_synthetic_control_message(_message("u3", "user", "third")) is False


def test_claude_session_title_skips_compact_summary_text() -> None:
    assert _session_title(SimpleNamespace(summary=SUMMARY_TEXT)) is None
    assert (
        _session_title(
            SimpleNamespace(
                custom_title=SUMMARY_TEXT,
                first_prompt="First real prompt",
                summary=SUMMARY_TEXT,
            )
        )
        == "First real prompt"
    )
    assert _session_title(SimpleNamespace(summary="A normal session")) == (
        "A normal session"
    )


class _CompactHistorySdk:
    def __init__(self, messages: list[Any]) -> None:
        self.__version__ = "1.0"
        self.messages = list(messages)

    def get_session_info(self, session_id: str) -> Any | None:
        return SimpleNamespace(
            session_id=session_id,
            custom_title="Compact history",
            cwd="/repo",
            last_modified=1_789_000_000_000,
            file_size=100 + len(self.messages),
        )

    def get_session_messages(self, session_id: str) -> list[Any]:
        _ = session_id
        return list(self.messages)


class _SyncStateHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.sync_states: dict[str, dict[str, Any]] = {}

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.sync_states.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.sync_states[key] = value


def _syncer(
    *,
    host: _SyncStateHost,
    sdk: _CompactHistorySdk,
    pending_messages: ClaudePendingClientMessageRegistry | None = None,
) -> ClaudeHistorySyncer:
    return ClaudeHistorySyncer(
        config=RuntimeConfig(
            runtime="claude",
            revision=1,
            values={"environment": {}},
        ),
        host=host,
        session_store=ClaudeSessionStore({}),
        sdk_loader=lambda: sdk,
        cursor_store=ClaudeHistoryCursorStore(host),
        sync_states=ClaudeSessionSyncStateStore(host),
        pending_messages=(
            ClaudePendingClientMessageRegistry("conn_test")
            if pending_messages is None
            else pending_messages
        ),
    )
