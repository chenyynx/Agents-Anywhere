"""R2 red-team: causality proof for the self-stranding defect (A2).

The finding was that a closure refreshed ``sessions.updated_at`` — the very
column the silence guard reads — so a sweep covering part of a session
re-armed it and the remainder was stuck until the 48h bound elapsed a second
time. These three tests are that proof run backwards: the same scenarios must
now heal on their own, with nobody re-aging anything by hand.

C1  Causality, inverted: the closure leaves updated_at where it was, so the
    capped remainder closes on the next sweep with no operator action.
C2  Realistic trigger: the 500 candidate cap is GLOBAL, so a backlog above it
    splits across sessions — both must drain, and neither may be starved.
C3  Endurance: repeated sweeps keep healing instead of leaving a permanent
    tail behind.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import select, update

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store
from agent_server.services.timeline_janitor import (
    DEFAULT_CANDIDATE_LIMIT,
    TimelineJanitor,
)

MAX_AGE_SECONDS = 48 * 60 * 60.0


def _ago(hours: float) -> str:
    return (datetime.now(UTC) - timedelta(hours=hours)).isoformat().replace(
        "+00:00", "Z"
    )


def tool_row(
    item_id: str, *, session_id: str, order_seq: int, age_hours: float = 50.0
) -> TimelineItemIn:
    stamp = _ago(age_hours)
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": "running",
            "role": "tool",
            "content": {"kind": "bash", "toolName": "Bash"},
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


async def _store(tmp_path: Any, *, tag: str) -> tuple[Store, Any]:
    db_path = tmp_path / f"r2-strand-{tag}.sqlite3"
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


async def _updated_at(store: Store, session_id: str) -> str:
    async with store.engine.connect() as conn:
        row = (
            await conn.execute(
                select(sessions_t.c.updated_at).where(sessions_t.c.id == session_id)
            )
        ).first()
    return str(row.updated_at)


async def _stuck(store: Store, session_id: str) -> list[str]:
    items = await store.timeline.read(session_id)
    return sorted(i.id for i in items if i.status == "running")


@pytest.mark.anyio
async def test_C1_the_closure_is_no_longer_its_own_blocker(tmp_path) -> None:
    store, session = await _store(tmp_path, tag="c1")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i}", session_id=session.id, order_seq=i + 1)
                for i in range(5)
            ],
        )
        await _age(store, session.id)
        aged = await _updated_at(store, session.id)
        janitor = TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=2
        )

        first = await janitor.run_once()
        print(f"\n[C1] sweep 1 closed = {sorted(first)}")
        print(f"[C1] updated_at before = {aged}")
        print(f"[C1] updated_at after  = {await _updated_at(store, session.id)}")
        print(f"[C1] stuck after 1     = {await _stuck(store, session.id)}")
        assert len(first) == 2
        # The cause is gone: the session's silence columns are exactly as the
        # connector left them, so the cap is the only thing pacing the sweep.
        assert await _updated_at(store, session.id) == aged

        # Sweeps 2 and 3 as the 600s loop runs them: no re-aging, no operator.
        second = await janitor.run_once()
        third = await janitor.run_once()
        print(f"[C1] sweep 2 closed = {sorted(second)}")
        print(f"[C1] sweep 3 closed = {sorted(third)}")
        assert len(second) == 2
        assert len(third) == 1
        assert await janitor.run_once() == []
        assert sorted(first + second + third) == [f"t{i}" for i in range(5)]
        assert await _stuck(store, session.id) == []
    finally:
        await store.close()


@pytest.mark.anyio
async def test_C2_global_cap_drains_both_sessions_without_starving_either(
    tmp_path,
) -> None:
    """600 stale rows across 2 sessions in ONE database with the shipped cap.

    Production is a single Postgres database, so `stale_running_tool_candidates`
    draws one global 500-row window ordered by (item_time, id). A backlog above
    that window is split across sessions; both tails must then drain on their
    own, and no session may sit untouched while the other one is swept.
    """

    store, session_a = await _store(tmp_path, tag="sA")
    try:
        session_b = await create_session_with_project(
            store,
            connector_id=session_a.connectorId,
            runtime="claude",
            external_session_id="claude_ext_sB",
        )
        per_session = 300
        for session, prefix in ((session_a, "a"), (session_b, "b")):
            await store.sync_timeline_items(
                session_id=session.id,
                items=[
                    tool_row(
                        f"{prefix}{i:04d}",
                        session_id=session.id,
                        order_seq=i + 1,
                    )
                    for i in range(per_session)
                ],
            )
            await _age(store, session.id)

        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        assert janitor._candidate_limit == DEFAULT_CANDIDATE_LIMIT

        first = await janitor.run_once()
        print(
            f"\n[C2] sweep 1 closed={len(first)} of {2 * per_session} "
            f"(global cap {DEFAULT_CANDIDATE_LIMIT})"
        )
        stuck_a = await _stuck(store, session_a.id)
        stuck_b = await _stuck(store, session_b.id)
        print(f"[C2] stuck after sweep 1: A={len(stuck_a)} B={len(stuck_b)}")
        assert len(first) == DEFAULT_CANDIDATE_LIMIT
        # The window straddles both sessions, so the cap splits the backlog
        # without starving either one.
        assert len(stuck_a) < per_session
        assert len(stuck_b) < per_session

        # Later sweeps, as the 600s loop runs them, until the backlog is gone.
        previous = {"A": len(stuck_a), "B": len(stuck_b)}
        for cycle in range(2, 6):
            more = await janitor.run_once()
            now_a = len(await _stuck(store, session_a.id))
            now_b = len(await _stuck(store, session_b.id))
            print(f"[C2] cycle {cycle}: closed {len(more)} stuck A={now_a} B={now_b}")
            for label, remaining in (("A", now_a), ("B", now_b)):
                assert remaining <= previous[label], (
                    f"session {label} went backwards while the loop kept sweeping"
                )
            previous = {"A": now_a, "B": now_b}
            if not more:
                break

        assert previous == {"A": 0, "B": 0}, (
            f"600 rows must finish draining across cycles, left {previous}"
        )
    finally:
        await store.close()


@pytest.mark.anyio
async def test_C3_repeated_sweeps_keep_healing_instead_of_stranding(tmp_path) -> None:
    """Many cycles on one capped session: no permanent tail, then quiet."""

    store, session = await _store(tmp_path, tag="c3")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i}", session_id=session.id, order_seq=i + 1)
                for i in range(4)
            ],
        )
        await _age(store, session.id)
        janitor = TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=2
        )
        closed: list[str] = []
        for cycle in range(6):
            closed.extend(await janitor.run_once())
            stuck = await _stuck(store, session.id)
            print(f"[C3] cycle {cycle}: stuck = {stuck}")
            if not stuck:
                break
        assert sorted(closed) == [f"t{i}" for i in range(4)]
        assert await _stuck(store, session.id) == []
        # Healed, and the loop goes quiet instead of churning.
        assert await janitor.run_once() == []
    finally:
        await store.close()