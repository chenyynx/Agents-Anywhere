"""The first history sync of a session in a process is a full-chain rebase.

The Server can only append a row it learns about after newer rows exist, so a
hole left behind by a previous process — a stuck turn, a crash mid-turn — must
be backfilled *before* this process publishes a live row. The pre-turn gate
does that by forcing one history sync, and this syncer makes that first pass a
rebase regardless of the stored cursor: a matching cursor proves where the
previous process stopped reading, not that the Server received every row.

These tests pin the classification (first pass rebases, later passes go back to
incremental) and the pre-turn gate (one sync per session per process).
"""

from __future__ import annotations

import asyncio

from test_claude_history_compact import _CompactHistorySdk, _SyncStateHost, _syncer
from test_claude_task_notification_fold import (
    EXTERNAL_SESSION_ID,
    SESSION_ID,
    _assistant_message,
    _user_message,
)

from connector.runtimes.claude.runtime import ClaudeRuntime


def _messages() -> list[object]:
    return [
        _user_message("first-user", "在？"),
        _assistant_message("first-assistant", "在。"),
        _user_message("second-user", "继续"),
        _assistant_message("second-assistant", "好。"),
    ]


def test_first_sync_rebases_and_the_next_pass_is_incremental() -> None:
    host = _SyncStateHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None
    assert first.snapshot is not None
    assert first.snapshot.metadata["rebased"] is True
    assert len(first.snapshot.items) >= 4
    asyncio.run(first.commit())

    # Nothing changed on disk: the second pass has nothing to publish and must
    # not rebase again (the process has synced this session).
    second = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert second is not None
    assert second.snapshot is None


def test_an_incremental_window_declares_its_order() -> None:
    """A cursor window's order is authoritative for the rows it carries.

    The Server can only append a row the live path never published; declaring
    the window lets it place that row (a hook-error tool result) at its chain
    position instead of after later rows (2026-11-09).
    """

    host = _SyncStateHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None
    asyncio.run(first.commit())

    sdk.messages.append(_user_message("third-user", "再来"))
    second = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert second is not None and second.snapshot is not None
    assert second.snapshot.metadata["rebased"] is False
    assert second.snapshot.metadata["windowOrder"] is True


def test_a_restarted_process_rebases_even_with_a_matching_cursor() -> None:
    host = _SyncStateHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)
    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None and prepared.snapshot is not None
    asyncio.run(prepared.commit())

    # A new syncer is a new process: the durable cursor matches the transcript,
    # but the Server may still be missing rows the old process never published.
    restarted = _syncer(host=host, sdk=sdk)
    again = asyncio.run(
        restarted.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert again is not None
    assert again.snapshot is not None
    assert again.snapshot.metadata["rebased"] is True


def test_a_failed_pass_does_not_mark_the_session_synced() -> None:
    host = _SyncStateHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    # Prepared but never published: the next attempt must still be a rebase.
    assert syncer.has_synced(EXTERNAL_SESSION_ID) is False
    retry = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert retry is not None and retry.snapshot is not None
    assert retry.snapshot.metadata["rebased"] is True


class _RecordingSyncHost(_SyncStateHost):
    """A host that records published timeline snapshots."""

    def __init__(self) -> None:
        super().__init__()
        self.timeline_syncs: list[dict[str, object]] = []
        self.timeline_sync_attempts = 0

    async def timeline_sync(self, **params: object) -> None:
        self.timeline_sync_attempts += 1
        self.timeline_syncs.append(params)


def test_ensure_first_sync_publishes_once_per_process() -> None:
    host = _RecordingSyncHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    asyncio.run(syncer.ensure_first_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    assert syncer.has_synced(EXTERNAL_SESSION_ID) is True
    assert len(host.timeline_syncs) == 1
    assert host.timeline_syncs[0]["metadata"]["rebased"] is True

    asyncio.run(syncer.ensure_first_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    assert len(host.timeline_syncs) == 1


def test_ensure_first_sync_retries_after_a_failed_publish() -> None:
    class _FailingHost(_SyncStateHost):
        def __init__(self) -> None:
            super().__init__()
            self.attempts = 0

        async def timeline_sync(self, **params: object) -> None:
            self.attempts += 1
            raise RuntimeError("host down")

    host = _FailingHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    asyncio.run(syncer.ensure_first_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    assert syncer.has_synced(EXTERNAL_SESSION_ID) is False
    asyncio.run(syncer.ensure_first_sync(SESSION_ID, EXTERNAL_SESSION_ID))
    assert host.attempts == 2


def test_the_turn_path_delegates_to_the_syncer_gate() -> None:
    class _FakeSyncer:
        def __init__(self) -> None:
            self.calls: list[tuple[str, str | None]] = []

        async def ensure_first_sync(
            self, session_id: str, external_session_id: str | None
        ) -> None:
            self.calls.append((session_id, external_session_id))

    runtime = object.__new__(ClaudeRuntime)
    fake = _FakeSyncer()
    runtime._history_syncer = fake  # type: ignore[attr-defined]

    asyncio.run(runtime._ensure_first_history_sync(SESSION_ID, EXTERNAL_SESSION_ID))

    assert fake.calls == [(SESSION_ID, EXTERNAL_SESSION_ID)]


def test_snapshot_carries_the_rebuild_ordering_time() -> None:
    host = _RecordingSyncHost()
    sdk = _CompactHistorySdk(_messages())
    syncer = _syncer(host=host, sdk=sdk)

    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None and prepared.snapshot is not None
    ordering_time = prepared.snapshot.metadata["orderingTime"]
    assert isinstance(ordering_time, str) and ordering_time


def test_publish_falls_back_to_the_snapshot_ordering_time() -> None:
    from connector.runtime_protocol import RuntimeTimelineItem, RuntimeTimelineSnapshot
    from connector.server.runtime_sync import _timeline_sync_notification

    item = RuntimeTimelineItem(
        id="claude_tool_x",
        session_id=SESSION_ID,
        type="tool",
        status="done",
        order_seq=1,
        content_hash="sha256:x",
    )
    snapshot = RuntimeTimelineSnapshot(
        session_id=SESSION_ID,
        runtime="claude",
        external_session_id=EXTERNAL_SESSION_ID,
        items=(item,),
        metadata={"orderingTime": "2026-11-05T05:30:52.874000Z"},
    )

    # The discovered session carried no ordering time; the snapshot's own
    # value must fill the backfilled row's timestamps, not "now".
    notification = _timeline_sync_notification(snapshot, fallback_item_time=None)
    payload = notification["params"]["items"][0]
    assert payload["createdAt"] == "2026-11-05T05:30:52.874000Z"
    assert payload["updatedAt"] == "2026-11-05T05:30:52.874000Z"


def test_direct_sync_payload_declares_the_snapshot_ordering_time() -> None:
    """The pre-turn first sync goes straight through the runtime host.

    It never passes ``_timeline_sync_notification``, so without the same
    fallback here the Server stamps every backfilled row with ``now`` and the
    old session climbs to the top of the sidebar — the fix would cover only
    the periodic path.
    """

    from connector.runtime_protocol import RuntimeTimelineItem
    from connector.server.runtime_host import _timeline_sync_item_payloads

    item = RuntimeTimelineItem(
        id="claude_history_msg_x",
        session_id=SESSION_ID,
        type="message",
        status="done",
        order_seq=1,
        content_hash="sha256:x",
    )

    payloads = _timeline_sync_item_payloads(
        (item,), {"orderingTime": "2026-11-05T05:30:52.874000Z"}
    )
    assert payloads[0]["createdAt"] == "2026-11-05T05:30:52.874000Z"
    assert payloads[0]["updatedAt"] == "2026-11-05T05:30:52.874000Z"

    # No declared ordering time (and a live snapshot): the host must not
    # fabricate one; the Server decides what an undated row means.
    plain = _timeline_sync_item_payloads((item,), {})
    assert "createdAt" not in plain[0]
    assert "updatedAt" not in plain[0]
