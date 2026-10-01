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

from connector.runtime_protocol import RuntimeConfig, RuntimeHostClient
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.history.cursor import (
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


def test_claude_history_cursor_returns_only_new_messages_when_uuid_resolves() -> None:
    messages = (
        _message("u1", "user", "first"),
        _message("a1", "assistant", "answered"),
        _message("u2", "user", "second"),
    )

    incremental = messages_after_cursor(
        messages,
        _cursor(last_message_uuid="a1", message_count=2),
    )

    assert _uuids(incremental) == ("u2",)


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

    rebased = messages_after_cursor(
        after,
        _cursor(last_message_uuid="a2", message_count=len(before)),
    )

    assert _uuids(rebased) == ("summary", "u3")
    assert "u3" in _uuids(rebased)


def test_claude_history_cursor_rebases_when_uuid_less_chain_shrinks() -> None:
    after = (_message("summary", "user", SUMMARY_TEXT),)

    rebased = messages_after_cursor(
        after,
        _cursor(last_message_uuid=None, message_count=9),
    )

    assert _uuids(rebased) == ("summary",)


def test_claude_history_cursor_returns_full_chain_without_cursor() -> None:
    messages = (_message("u1", "user", "first"), _message("a1", "assistant", "hi"))

    assert _uuids(
        messages_after_cursor(
            messages,
            _cursor(
                last_message_uuid=None,
                message_count=0,
            ),
        )
    ) == ("u1", "a1")


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


def _syncer(*, host: _SyncStateHost, sdk: _CompactHistorySdk) -> ClaudeHistorySyncer:
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
        pending_messages=ClaudePendingClientMessageRegistry("conn_test"),
    )
