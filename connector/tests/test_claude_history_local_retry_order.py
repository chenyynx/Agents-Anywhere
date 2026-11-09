"""A live-store retry re-publishes missed rows at their chain position.

When the Server never received some live rows (a failed publish, a crash
mid-turn), the connector's next sync re-sends the live store snapshot. Those
rows' ``orderSeq`` values are their real chain positions, but the Server's
plain-sync path appends any unseen row after ``max(orderSeq)`` — so a missed
old turn is drawn at the end of the timeline. The retry snapshot must carry
``windowOrder`` so the Server's chain plan places the batch instead
(2026-11-10).
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_history_compact import (
    EXTERNAL_SESSION_ID,
    SESSION_ID,
    _CompactHistorySdk,
    _SyncStateHost,
    _syncer,
)

from connector.runtime_protocol import RuntimeTimelineSnapshot


class _RetryStore:
    """A store whose live rows have not all reached the Server yet."""

    def get(self, session_id: str, external_session_id: str | None = None) -> Any:
        return SimpleNamespace(
            active_turn_id=None, timeline_revision=2, synced_revision=1
        )

    def snapshot(
        self, *, session_id: str, external_session_id: str | None = None
    ) -> RuntimeTimelineSnapshot:
        return RuntimeTimelineSnapshot(
            session_id=session_id,
            external_session_id=external_session_id,
            runtime="claude",
            items=(),
            complete=False,
            metadata={"source": "claude.live.retry"},
        )

    def mark_synced(
        self, session_id: str, external_session_id: str | None = None
    ) -> None:
        raise AssertionError("the retry commit must not run in this test")


def test_live_store_retry_carries_chain_order_authority() -> None:
    syncer = _syncer(host=_SyncStateHost(), sdk=_CompactHistorySdk(messages=[]))
    syncer.session_store = _RetryStore()  # type: ignore[assignment]

    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )

    assert prepared is not None
    assert prepared.snapshot is not None
    # Without this flag the Server appends every unseen row after the newest
    # one; with it the chain plan inserts the batch by its live order.
    assert prepared.snapshot.metadata["windowOrder"] is True
    assert prepared.snapshot.metadata["source"] == "claude.live.retry"
