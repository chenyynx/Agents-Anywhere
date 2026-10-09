"""R2 red-team suite for the server-side age janitor (T3), now a guard suite.

Read-only against product code: every test here constructs its own throwaway
sqlite database under tmp_path and drives the shipped implementation.

The R2 round found three defects (A1/A2 self-stranding, A3 env fragility,
A6 unreachability). They are fixed, and the tests that demonstrated them now
pin the fixed behaviour instead — the same attack, re-run, must stay green:

  A1 a closure leaves the session's own silence-guard columns untouched
  A2 the candidate cap paces a session across sweeps instead of stranding it
  A3 unreadable env values stand the janitor down, never the server
  A4 timezone spellings and the 15h margin boundary, both directions
  A5 item_time NULL
  A6 reachability: what a connected client can actually learn
  A7 concurrency / idempotence
  A8 statuses that must never be touched, at 48h+
  A9 unread ledger interaction
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, timezone
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import update

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store
from agent_server.services.timeline_janitor import (
    DEFAULT_CANDIDATE_LIMIT,
    TimelineJanitor,
)

MAX_AGE_SECONDS = 48 * 60 * 60.0


def _ago(hours: float, *, tz: Any = UTC, z_suffix: bool = True) -> str:
    stamp = (datetime.now(UTC) - timedelta(hours=hours)).astimezone(tz)
    spelled = stamp.isoformat()
    return spelled.replace("+00:00", "Z") if z_suffix else spelled


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
    tz: Any = UTC,
    z_suffix: bool = True,
) -> TimelineItemIn:
    stamp = _ago(age_hours, tz=tz, z_suffix=z_suffix)
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


async def _store_with_session(tmp_path: Any, *, tag: str = "main") -> tuple[Store, Any]:
    db_path = tmp_path / f"r2-janitor-{tag}.sqlite3"
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


async def _age_session(
    store: Store,
    session_id: str,
    *,
    updated_at_hours: float = 50.0,
    last_activity_hours: float | None = None,
) -> None:
    values: dict[str, Any] = {"updated_at": _ago(updated_at_hours)}
    if last_activity_hours is not None:
        values["last_activity_at"] = _ago(last_activity_hours)
    async with store.engine.begin() as conn:
        await conn.execute(
            update(sessions_t).where(sessions_t.c.id == session_id).values(**values)
        )


async def _session_updated_at(store: Store, session_id: str) -> str:
    async with store.engine.connect() as conn:
        row = (
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == session_id)
                .values(updated_at=_ago(50.0))
                .returning(sessions_t.c.updated_at)
            )
        ).first()
    assert row is not None
    return str(row.updated_at)


# ---------------------------------------------------------------------------
# A1: does a janitor closure refresh the very field its own guard reads?
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A1_closure_leaves_its_own_guard_columns_untouched(tmp_path) -> None:
    """The janitor's seq bump must not stamp the columns its guard reads.

    `close_stale_running_tool_items` requires `sessions.updated_at` to be
    older than the bound, so a bump that set it to `now` re-armed the session
    as "recently active" for the next 48h. The revision watermark must still
    advance — that is how clients learn — but the activity timestamp belongs
    to the connector, not to this maintenance writer.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        before = await _session_row(store, session.id)

        assert await TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS).run_once() == [
            "t1"
        ]

        after = await _session_row(store, session.id)
        print(f"\n[A1] sessions.updated_at before closure = {before['updated_at']}")
        print(f"[A1] sessions.updated_at after  closure = {after['updated_at']}")
        print(f"[A1] sessions.seq {before['seq']} -> {after['seq']}")
        assert after["updated_at"] == before["updated_at"], (
            "the closure must not refresh the session's own silence guard"
        )
        assert after["last_activity_at"] == before["last_activity_at"] is None
        assert after["seq"] > before["seq"], "the revision must still advance"
    finally:
        await store.close()


async def _session_row(store: Store, session_id: str) -> dict[str, Any]:
    from sqlalchemy import select

    async with store.engine.connect() as conn:
        row = (
            await conn.execute(
                select(
                    sessions_t.c.seq,
                    sessions_t.c.updated_at,
                    sessions_t.c.last_activity_at,
                ).where(sessions_t.c.id == session_id)
            )
        ).first()
    assert row is not None
    return dict(row._mapping)


# ---------------------------------------------------------------------------
# A2: candidate cap splits one session -> the remainder is stranded forever
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A2_candidate_cap_drains_across_sweeps_without_stranding(
    tmp_path,
) -> None:
    """Cap the probe below the session's stale row count.

    Sweep 1 closes only the capped slice. Because the closure no longer
    refreshes the session's own silence guard, sweep 2 closes the next slice
    and the tail drains on its own — the cap paces the sweep, it does not
    decide which rows ever get healed.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        rows = [
            tool_row(f"t{index:03d}", session_id=session.id, order_seq=index + 1)
            for index in range(5)
        ]
        await store.sync_timeline_items(session_id=session.id, items=rows)
        await _age_session(store, session.id, updated_at_hours=50)

        capped = TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=2
        )
        first = await capped.run_once()
        print(f"\n[A2] sweep 1 (candidate_limit=2) closed = {sorted(first)}")
        assert len(first) == 2

        # Run sweeps 2 and 3 exactly as the 600s loop would, with no operator
        # action in between: the loop's own doing must not be the blocker.
        second = await capped.run_once()
        third = await capped.run_once()
        fourth = await capped.run_once()
        print(f"[A2] sweep 2 closed = {sorted(second)}")
        print(f"[A2] sweep 3 closed = {sorted(third)}")
        print(f"[A2] sweep 4 closed = {sorted(fourth)}")
        assert len(second) == 2
        assert len(third) == 1
        assert fourth == []

        items = {item.id: item for item in await store.timeline.read(session.id)}
        still_running = sorted(
            item_id for item_id, item in items.items() if item.status == "running"
        )
        print(f"[A2] rows still stuck at running = {still_running}")
        assert still_running == []

        # Control: a fresh, never-swept session with the same shape closes in
        # one sweep, so the multi-sweep path above is the cap pacing, not a
        # slower verdict.
        control_store, control_session = await _store_with_session(tmp_path, tag="ctl")
        try:
            await control_store.sync_timeline_items(
                session_id=control_session.id,
                items=[
                    tool_row(
                        f"u{index:03d}",
                        session_id=control_session.id,
                        order_seq=index + 1,
                    )
                    for index in range(5)
                ],
            )
            await _age_session(control_store, control_session.id, updated_at_hours=50)
            control = await TimelineJanitor(
                control_store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=500
            ).run_once()
            print(f"[A2] control (candidate_limit=500) closed = {len(control)}")
            assert len(control) == 5
        finally:
            await control_store.close()
    finally:
        await store.close()


@pytest.mark.anyio
async def test_A2b_production_cap_500_heals_the_501st_row_next_sweep(tmp_path) -> None:
    """Same shape at the shipped default cap, no test-only knob."""

    store, session = await _store_with_session(tmp_path)
    try:
        total = DEFAULT_CANDIDATE_LIMIT + 1
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"v{index:05d}", session_id=session.id, order_seq=index + 1)
                for index in range(total)
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)

        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        assert janitor._candidate_limit == DEFAULT_CANDIDATE_LIMIT
        first = await janitor.run_once()
        print(f"\n[A2b] first sweep closed = {len(first)} of {total}")
        second = await janitor.run_once()
        print(f"[A2b] second sweep closed = {len(second)}")

        items = {item.id: item for item in await store.timeline.read(session.id)}
        stuck = [i for i, it in items.items() if it.status == "running"]
        print(f"[A2b] stuck running after two sweeps = {len(stuck)}")
        assert len(first) == DEFAULT_CANDIDATE_LIMIT
        assert len(second) == 1
        assert stuck == []
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# A3: env parsing
# ---------------------------------------------------------------------------


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("raw", "label", "expected_enabled"),
    [
        ("", "empty string", False),
        ("   ", "whitespace", False),
        ("abc", "garbage", False),
        ("48h", "unit-suffixed", False),
        ("1e9", "scientific", True),
        ("nan", "nan", False),
        ("inf", "inf", False),
    ],
)
async def test_A3_env_parsing_stands_the_janitor_down(
    raw: str, label: str, expected_enabled: bool
) -> None:
    """A value this code cannot read as a finite number is not a crash.

    `from_environment` is called from `create_app`, so raising here took the
    whole server down rather than one sweep. The posture is the T1/T2 one:
    bad configuration does nothing, loudly, instead of doing something wrong.
    """

    from agent_server.services.timeline_janitor import (
        ENV_INTERVAL_SECONDS,
        ENV_MAX_AGE_SECONDS,
    )

    store, _ = await _store_with_session(Path_probe())
    try:
        import os

        os.environ[ENV_MAX_AGE_SECONDS] = raw
        os.environ[ENV_INTERVAL_SECONDS] = raw
        try:
            janitor = TimelineJanitor.from_environment(store)
        except Exception as exc:  # noqa: BLE001
            print(
                f"\n[A3] {label!r} ({raw!r}) -> {type(exc).__name__}: {exc}"
            )
            pytest.fail(
                f"from_environment({raw!r}) raised {type(exc).__name__}: {exc}"
            )
        else:
            print(
                f"\n[A3] {label!r} ({raw!r}) -> enabled={janitor.enabled} "
                f"max_age={janitor._max_age_seconds} interval={janitor._interval_seconds}"
            )
            assert janitor.enabled is expected_enabled
            assert await janitor.run_once() == []
        finally:
            os.environ.pop(ENV_MAX_AGE_SECONDS, None)
            os.environ.pop(ENV_INTERVAL_SECONDS, None)
    finally:
        await store.close()


def Path_probe():
    import tempfile
    from pathlib import Path

    return Path(tempfile.mkdtemp(prefix="r2-env-"))


# ---------------------------------------------------------------------------
# A4: timezone spellings + 15h margin, both directions
# ---------------------------------------------------------------------------


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("tz", "z_suffix", "age_hours", "should_close"),
    [
        (UTC, True, 50.0, True),
        (UTC, False, 50.0, True),
        (timezone(timedelta(hours=8)), False, 50.0, True),
        (timezone(timedelta(hours=-11)), False, 50.0, True),
        (timezone(timedelta(hours=14)), False, 50.0, True),
        (UTC, True, 47.9, False),
        (UTC, True, 48.1, True),
        (timezone(timedelta(hours=14)), False, 49.0, True),
        (timezone(timedelta(hours=-12)), False, 49.0, True),
    ],
)
async def test_A4_timezone_spellings_and_boundary(
    tmp_path, tz, z_suffix, age_hours, should_close
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(
                    "t1",
                    session_id=session.id,
                    order_seq=1,
                    age_hours=age_hours,
                    tz=tz,
                    z_suffix=z_suffix,
                )
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(
            f"\n[A4] tz={tz} Z={z_suffix} age={age_hours}h -> closed={closed} "
            f"(expected close={should_close})"
        )
        assert bool(closed) is should_close
        (item,) = await store.timeline.read_many(session.id, {"t1"})
        assert (item.status == "interrupted") is should_close
    finally:
        await store.close()


@pytest.mark.anyio
async def test_A4b_margin_band_rows_are_never_closed(tmp_path) -> None:
    """Rows between the bound and bound+15h ride the probe and must survive."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row("inside", session_id=session.id, order_seq=1, age_hours=47.0),
                tool_row("outside", session_id=session.id, order_seq=2, age_hours=60.0),
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[A4b] closed = {closed}")
        assert closed == ["outside"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# A5: item_time NULL
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A5_null_item_time_row_is_never_healed(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t_null", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        # Force the row's item_time to NULL the way a legacy/partial row would be.
        async with store.engine.begin() as conn:
            await conn.execute(
                update(timeline_items_t)
                .where(timeline_items_t.c.id == "t_null")
                .values(item_time=None)
            )
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[A5] closed with NULL item_time = {closed}")
        (item,) = await store.timeline.read_many(session.id, {"t_null"})
        print(f"[A5] status = {item.status}")
        assert closed == []
        assert item.status == "running"
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# A7: concurrency / idempotence
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A7_concurrent_sweeps_are_idempotent(tmp_path) -> None:
    import asyncio

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{index}", session_id=session.id, order_seq=index + 1)
                for index in range(4)
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        results = await asyncio.gather(
            janitor.run_once(), janitor.run_once(), janitor.run_once()
        )
        total = sum(len(r) for r in results)
        print(f"\n[A7] concurrent sweep results = {results} (total closed {total})")
        items = {item.id: item for item in await store.timeline.read(session.id)}
        interrupted = [i for i, it in items.items() if it.status == "interrupted"]
        print(f"[A7] interrupted rows = {len(interrupted)}")
        assert len(interrupted) == 4
        assert total == 4, "a row must not be closed twice"
        for item in items.values():
            if item.status == "interrupted":
                assert item.revision == 2, f"revision bumped twice: {item.revision}"
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# A8: statuses that must never be touched, at 48h+, plus real residue shapes
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A8_queued_and_approval_rows_survive_many_sweeps(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(
                    "queued_msg",
                    session_id=session.id,
                    order_seq=1,
                    status="pending",
                    item_type="message",
                    role="user",
                    content={"text": "queued 5 days ago"},
                    age_hours=120.0,
                ),
                tool_row(
                    "approval",
                    session_id=session.id,
                    order_seq=2,
                    status="waiting_approval",
                    age_hours=120.0,
                ),
                tool_row("resid", session_id=session.id, order_seq=3, age_hours=72.0),
            ],
        )
        await _age_session(store, session.id, updated_at_hours=100.0)
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        first = await janitor.run_once()
        print(f"\n[A8] sweep closed = {first}")
        assert first == ["resid"]
        items = {item.id: item for item in await store.timeline.read(session.id)}
        assert items["queued_msg"].status == "pending"
        assert items["approval"].status == "waiting_approval"
        for _ in range(3):
            assert await janitor.run_once() == []
        items = {item.id: item for item in await store.timeline.read(session.id)}
        assert items["queued_msg"].status == "pending"
        assert items["approval"].status == "waiting_approval"
        print("[A8] queued + approval survived 4 sweeps untouched")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# A9: unread ledger
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_A9_bump_leaves_unread_fields_alone(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{index}", session_id=session.id, order_seq=index + 1)
                for index in range(3)
            ],
        )
        from sqlalchemy import select

        async with store.engine.connect() as conn:
            before = (
                await conn.execute(
                    select(
                        sessions_t.c.last_read_seq,
                        sessions_t.c.latest_turn_end_seq,
                        sessions_t.c.timeline_reset_seq,
                    ).where(sessions_t.c.id == session.id)
                )
            ).first()
        await _age_session(store, session.id, updated_at_hours=50)
        await TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS).run_once()
        async with store.engine.connect() as conn:
            after = (
                await conn.execute(
                    select(
                        sessions_t.c.last_read_seq,
                        sessions_t.c.latest_turn_end_seq,
                        sessions_t.c.timeline_reset_seq,
                    ).where(sessions_t.c.id == session.id)
                )
            ).first()
        print(f"\n[A9] before={tuple(before)} after={tuple(after)}")
        assert tuple(before) == tuple(after)
    finally:
        await store.close()