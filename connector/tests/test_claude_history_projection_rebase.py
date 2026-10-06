"""Projection-era rebase: one full history rebuild when the projector changes.

Why this file exists
--------------------
A cursor only describes *where* a sync stopped, not *what* the projector was
when it stopped there. When the projection changes (the 2026-10-05 terminal
task fold was the first such change), every session already past its cursor
would keep its old items forever — the notices that close the stuck cards sit
behind the cursor, so an incremental slice can never reach them.

So the cursor carries a projection version. A stored cursor without the
current version makes ``messages_after_cursor`` rebase onto the whole chain
once, the sync writes the current version back, and every later pass is
incremental again. The session listing has to agree: a session whose cursor
is stale must be marked for sync even when its transcript has not moved.

These tests pin the classification, the one-shot rebuild at the syncer level,
its convergence, and the session-listing gate that lets the rebuild happen at
all. The fold itself is pinned in ``test_claude_task_notification_fold``.
"""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace
from typing import Any

from test_claude_history_compact import (
    _CompactHistorySdk,
    _syncer,
    _SyncStateHost,
)
from test_claude_task_notification_fold import (
    COMPLETED_NOTIFICATION,
    DISPATCH_TUID,
    EXTERNAL_SESSION_ID,
    SESSION_ID,
    _dispatch_message,
    _notification_message,
    _receipt_message,
    _session,
    _user_message,
)

from connector.runtime_protocol import RuntimeConfig
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.history.cursor import (
    HISTORY_PROJECTION_VERSION,
    REBASE_PROJECTOR_VERSION,
    ClaudeHistoryCursor,
    cursor_for,
    cursor_from_state,
    cursor_to_state,
    messages_after_cursor,
)
from connector.runtimes.claude.history.state import history_cursor_key
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.reader import (
    ClaudeSessionReader,
    _session_sync_key,
    _sync_marker,
)
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore
from connector.runtimes.claude.timeline.messages import stable_tool_item_id


def test_cursor_from_state_without_a_version_is_stale() -> None:
    state = cursor_to_state(
        ClaudeHistoryCursor(
            last_modified=1,
            file_size=2,
            message_count=3,
            last_message_uuid="m3",
        )
    )
    state.pop("projectorVersion")
    legacy = cursor_from_state(state)
    assert legacy is not None
    assert legacy.projector_version is None
    window = messages_after_cursor((), legacy)
    assert window.rebased is True
    assert window.reason == REBASE_PROJECTOR_VERSION
    # A round trip keeps the staleness: an un-rebuilt state is never silently
    # upgraded to the current version.
    round_tripped = cursor_from_state(cursor_to_state(legacy))
    assert round_tripped is not None
    assert round_tripped.projector_version is None
    # A cursor built in code is current by definition.
    stamped = cursor_from_state(
        cursor_to_state(
            ClaudeHistoryCursor(
                last_modified=1,
                file_size=2,
                message_count=3,
                last_message_uuid="m3",
            )
        )
    )
    assert stamped is not None
    assert stamped.projector_version == HISTORY_PROJECTION_VERSION


def test_history_sync_rebuilds_once_on_an_old_projection() -> None:
    asyncio.run(_test_history_sync_rebuilds_once_on_an_old_projection())


async def _test_history_sync_rebuilds_once_on_an_old_projection() -> None:
    chain = [
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
    ]
    sdk = _CompactHistorySdk(list(chain))
    host = _SyncStateHost()
    syncer = _syncer(host=host, sdk=sdk)
    # The legacy cursor describes the exact current chain — fingerprint,
    # count and uuid all match. Only the missing projection version makes it
    # stale, so this pins the version as the trigger, not a coincidental
    # chain change.
    host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)] = _legacy_cursor_state(
        sdk, chain
    )

    prepared = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert prepared is not None
    assert prepared.snapshot is not None
    assert prepared.snapshot.metadata["rebased"] is True
    cards = [
        item
        for item in prepared.snapshot.items
        if item.id == stable_tool_item_id(_session(), DISPATCH_TUID)
    ]
    assert len(cards) == 1
    assert cards[0].status == "done"
    await prepared.commit()
    state = host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)]
    assert state["projectorVersion"] == HISTORY_PROJECTION_VERSION

    # One rebuild, then convergence: the same chain no longer syncs at all.
    again = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert again is not None
    assert again.snapshot is None


def test_history_sync_resumes_incremental_after_the_rebuild() -> None:
    asyncio.run(_test_history_sync_resumes_incremental_after_the_rebuild())


async def _test_history_sync_resumes_incremental_after_the_rebuild() -> None:
    chain = [
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
    ]
    sdk = _CompactHistorySdk(list(chain))
    host = _SyncStateHost()
    syncer = _syncer(host=host, sdk=sdk)
    host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)] = _legacy_cursor_state(
        sdk, chain
    )
    prepared = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert prepared is not None and prepared.snapshot is not None
    await prepared.commit()

    sdk.messages.append(_user_message("u2", "next"))
    incremental = await syncer.prepare_session_timeline_sync(
        SESSION_ID, EXTERNAL_SESSION_ID
    )
    assert incremental is not None
    assert incremental.snapshot is not None
    assert incremental.snapshot.metadata["rebased"] is False
    assert incremental.snapshot.metadata["syncedMessageCount"] == 1
    assert all(
        item.id != stable_tool_item_id(_session(), DISPATCH_TUID)
        for item in incremental.snapshot.items
    )


def test_two_rebuilds_of_one_chain_agree_item_for_item() -> None:
    asyncio.run(_test_two_rebuilds_of_one_chain_agree_item_for_item())


async def _test_two_rebuilds_of_one_chain_agree_item_for_item() -> None:
    chain = [
        _user_message("u1", "go"),
        _dispatch_message(),
        _receipt_message(),
        _notification_message(COMPLETED_NOTIFICATION),
        _user_message("u2", "and another thing"),
    ]
    sdk = _CompactHistorySdk(list(chain))
    host = _SyncStateHost()
    syncer = _syncer(host=host, sdk=sdk)

    fingerprints = []
    for _ in range(2):
        host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)] = (
            _legacy_cursor_state(sdk, chain)
        )
        prepared = await syncer.prepare_session_timeline_sync(
            SESSION_ID, EXTERNAL_SESSION_ID
        )
        assert prepared is not None and prepared.snapshot is not None
        fingerprints.append(_fingerprint(prepared.snapshot.items))
        await prepared.commit()
    assert fingerprints[0] == fingerprints[1]
    # The fold really is part of what is compared.
    assert any('"summary"' in entry for entry in fingerprints[0])


def test_session_listing_marks_old_projection_cursors_for_sync() -> None:
    asyncio.run(_test_session_listing_marks_old_projection_cursors_for_sync())


async def _test_session_listing_marks_old_projection_cursors_for_sync() -> None:
    host = _SyncStateHost()
    reader = _reader(host)
    sdk_session = _sdk_session()
    host.sync_states[_session_sync_key(EXTERNAL_SESSION_ID)] = {
        "marker": _sync_marker(sdk_session)
    }
    host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)] = (
        _legacy_cursor_state_from_fields(
            last_modified=1_789_000_000_000,
            file_size=500,
        )
    )

    meta = await reader._session_meta_from_sdk_session(
        sdk_session,
        external_session_id=EXTERNAL_SESSION_ID,
        force=False,
    )
    sync = meta.metadata["sync"]
    assert sync["changed"] is False
    assert sync["requires_timeline_sync"] is True
    assert sync["history_cursor_missing"] is False

    # The current version settles it: the same unchanged transcript no longer
    # asks for a sync.
    host.sync_states[history_cursor_key(EXTERNAL_SESSION_ID)] = cursor_to_state(
        ClaudeHistoryCursor(
            last_modified=1_789_000_000_000,
            file_size=500,
            message_count=4,
            last_message_uuid="m4",
        )
    )
    settled = await reader._session_meta_from_sdk_session(
        sdk_session,
        external_session_id=EXTERNAL_SESSION_ID,
        force=False,
    )
    assert settled.metadata["sync"]["requires_timeline_sync"] is False


def test_session_listing_syncs_a_session_without_any_cursor() -> None:
    asyncio.run(_test_session_listing_syncs_a_session_without_any_cursor())


async def _test_session_listing_syncs_a_session_without_any_cursor() -> None:
    host = _SyncStateHost()
    reader = _reader(host)
    sdk_session = _sdk_session()
    host.sync_states[_session_sync_key(EXTERNAL_SESSION_ID)] = {
        "marker": _sync_marker(sdk_session)
    }
    meta = await reader._session_meta_from_sdk_session(
        sdk_session,
        external_session_id=EXTERNAL_SESSION_ID,
        force=False,
    )
    sync = meta.metadata["sync"]
    assert sync["requires_timeline_sync"] is True
    assert sync["history_cursor_missing"] is True


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _reader(host: _SyncStateHost) -> ClaudeSessionReader:
    return ClaudeSessionReader(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=host,
        session_store=ClaudeSessionStore({}),
        sdk_loader=None,
        sync_states=ClaudeSessionSyncStateStore(host),
        pending_messages=ClaudePendingClientMessageRegistry("conn_test"),
    )


def _sdk_session() -> SimpleNamespace:
    return SimpleNamespace(
        session_id=EXTERNAL_SESSION_ID,
        last_modified=1_789_000_000_000,
        file_size=500,
        cwd="/repo",
        summary="Session",
    )


def _legacy_cursor_state(sdk: _CompactHistorySdk, messages: list[Any]) -> dict[str, Any]:
    info = sdk.get_session_info(EXTERNAL_SESSION_ID)
    state = cursor_to_state(cursor_for(info, tuple(messages)))
    state.pop("projectorVersion")
    return state


def _legacy_cursor_state_from_fields(
    *,
    last_modified: int,
    file_size: int,
) -> dict[str, Any]:
    return {
        "fingerprint": {
            "lastModified": last_modified,
            "fileSize": file_size,
        },
        "cursor": {
            "messageCount": 4,
            "lastMessageUuid": "m4",
        },
    }


def _fingerprint(items: tuple[Any, ...]) -> list[str]:
    return [
        json.dumps(
            {
                "id": item.id,
                "status": item.status,
                "content": dict(item.content),
            },
            sort_keys=True,
            default=str,
        )
        for item in items
    ]
