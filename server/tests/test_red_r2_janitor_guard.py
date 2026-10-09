"""R2 red-team: guard-premise and false-positive attacks on the T3 janitor.

B1  does a routine connector observation refresh the two silence columns?
    (the janitor's whole premise; if it does, the feature is inert = false neg)
B2  background subagent across turns: a session that is idle-looking but whose
    tool row is legitimately still live
B3  multi-worker idempotence: two janitors, same session, concurrently
B4  an in-flight connector write racing the close (fence re-validation)
B5  session deleted between probe and close
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import update

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store
from agent_server.services.timeline_janitor import TimelineJanitor

MAX_AGE_SECONDS = 48 * 60 * 60.0


def _ago(hours: float) -> str:
    return (datetime.now(UTC) - timedelta(hours=hours)).isoformat().replace(
        "+00:00", "Z"
    )


def tool_row(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    status: str = "running",
    age_hours: float = 50.0,
    item_type: str = "tool",
    role: str = "tool",
    content: dict[str, Any] | None = None,
) -> TimelineItemIn:
    stamp = _ago(age_hours)
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": item_type,
            "status": status,
            "role": role,
            "content": content
            if content is not None
            else {"kind": "bash", "toolName": "Bash"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
            "createdAt": stamp,
            "updatedAt": stamp,
        }
    )


async def _store(tmp_path: Any, *, tag: str = "main") -> tuple[Store, Any]:
    db_path = tmp_path / f"r2-guard-{tag}.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id=f"claude_ext_{tag}",
    )
    return store, session


async def _age(store: Store, session_id: str, *, hours: float = 50.0) -> None:
    async with store.engine.begin() as conn:
        await conn.execute(
            update(sessions_t)
            .where(sessions_t.c.id == session_id)
            .values(updated_at=_ago(hours))
        )


# ---------------------------------------------------------------------------
# B1: the guard premise — does a connector observation refresh the columns?
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_B1_connector_observation_does_not_refresh_the_silence_columns(
    tmp_path,
) -> None:
    """A pure lastActivityAt-only observation must not re-arm the session."""

    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id, hours=50)
        # The connector keeps reporting the SAME stale ordering time.
        for _ in range(5):
            await store.update_session_snapshot(
                session_id=session.id,
                last_activity_at=_ago(50.0),
                source_observed_at=_ago(0.0),
            )
        from sqlalchemy import select

        async with store.engine.connect() as conn:
            row = (
                await conn.execute(
                    select(
                        sessions_t.c.updated_at,
                        sessions_t.c.last_activity_at,
                        sessions_t.c.source_observed_at,
                    ).where(sessions_t.c.id == session.id)
                )
            ).first()
        print(
            f"\n[B1] after 5 observations: updated_at={row.updated_at} "
            f"last_activity_at={row.last_activity_at} "
            f"source_observed_at={row.source_observed_at}"
        )
        # The premise holds: observation refreshed source_observed_at only.
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"[B1] janitor closed = {closed} (premise intact)")
        assert closed == ["t1"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_B1b_connector_supplied_fresh_lastActivityAt_blocks_closure(
    tmp_path,
) -> None:
    """A connector that reports a NOW-shaped ordering time blocks forever.

    This is the inverse: a session whose source is gone but whose connector
    still reports a fresh lastActivityAt is never healed (false negative).
    The server does no validation or monotonicity check on the value.
    """

    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id, hours=50)
        for _ in range(5):
            await store.update_session_snapshot(
                session_id=session.id,
                last_activity_at=_ago(0.0),
                source_observed_at=_ago(0.0),
            )
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        for _ in range(3):
            assert await janitor.run_once() == []
        (item,) = await store.timeline.read_many(session.id, {"t1"})
        print(f"\n[B1b] status after 3 sweeps = {item.status}")
        assert item.status == "running"
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# B2: background subagent across turns (the documented legal live scenario)
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_B2_background_subagent_row_is_closed_when_session_silent(
    tmp_path,
) -> None:
    """A long-running background tool row, session idle past the bound.

    This is the intended trade (48h silence == dead), but it is worth pinning
    the exact shape so the choice is explicit rather than incidental.
    """

    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(
                    "bg_task",
                    session_id=session.id,
                    order_seq=1,
                    age_hours=72.0,
                    content={"kind": "bash", "toolName": "Bash", "background": True},
                )
            ],
        )
        await _age(store, session.id, hours=72.0)
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[B2] background row closed after 72h silence = {closed}")
        assert closed == ["bg_task"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# B4: in-flight write races the close
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_B4_inflight_row_above_fence_is_not_closed(tmp_path) -> None:
    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id, hours=50)
        # Simulate a buffered in-flight write: push the row's updated_seq above
        # the session fence, as the write buffer would before flushing.
        async with store.engine.begin() as conn:
            fence = (
                await conn.execute(
                    __import__("sqlalchemy").select(sessions_t.c.seq).where(
                        sessions_t.c.id == session.id
                    )
                )
            ).first().seq
            await conn.execute(
                update(timeline_items_t)
                .where(timeline_items_t.c.id == "t1")
                .values(updated_seq=int(fence) + 5_000)
            )
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[B4] closed with an in-flight row present = {closed}")
        assert closed == []
        (item,) = await store.timeline.read_many(session.id, {"t1"})
        assert item.status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_B4b_probe_then_write_race_is_rechecked_under_lock(tmp_path) -> None:
    """Between probe and close a connector writes the row back to running."""

    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row("t1", session_id=session.id, order_seq=1, status="done"),
                tool_row("t2", session_id=session.id, order_seq=2),
            ],
        )
        await _age(store, session.id, hours=50)
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        candidates = await store.stale_running_tool_candidates(
            older_than=datetime.now(UTC) - timedelta(seconds=MAX_AGE_SECONDS),
            limit=500,
        )
        print(f"\n[B4b] probe returned {candidates}")
        # The connector now pushes fresh activity for the session.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t3", session_id=session.id, order_seq=3, age_hours=0.0)],
        )
        closed = await janitor.run_once()
        print(f"[B4b] close after the connector wrote = {closed}")
        assert closed == []
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# B5: session vanishes between probe and close
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_B5_missing_session_is_skipped_without_raising(tmp_path) -> None:
    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id, hours=50)
        from sqlalchemy import delete

        async with store.engine.begin() as conn:
            await conn.execute(
                delete(timeline_items_t).where(
                    timeline_items_t.c.session_id == session.id
                )
            )
            await conn.execute(
                delete(sessions_t).where(sessions_t.c.id == session.id)
            )
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[B5] closed after the session vanished = {closed}")
        assert closed == []
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# B3: multi-worker idempotence
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_B3_two_independent_janitors_are_idempotent(tmp_path) -> None:
    store, session = await _store(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{index}", session_id=session.id, order_seq=index + 1)
                for index in range(6)
            ],
        )
        await _age(store, session.id, hours=50)
        janitor_a = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        janitor_b = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        results = await asyncio.gather(
            janitor_a.run_once(), janitor_b.run_once()
        )
        total = sum(len(r) for r in results)
        print(f"\n[B3] two janitors closed = {[len(r) for r in results]} total={total}")
        items = {item.id: item for item in await store.timeline.read(session.id)}
        interrupted = sorted(
            i for i, it in items.items() if it.status == "interrupted"
        )
        print(f"[B3] interrupted = {len(interrupted)}")
        assert len(interrupted) == 6
        assert total == 6
        for item in items.values():
            if item.status == "interrupted":
                assert item.revision == 2
    finally:
        await store.close()