"""Server-side age-bounded closure of stale ``running`` tool rows (T3).

The janitor is the floor for residue no connector-side rebuild can ever reach
(a wiped /tmp workspace, a rotated transcript). These tests pin the exact
guard set — age, session silence, absence of an active run, and the
status/type scope — plus unread preservation, the kill-switch, idempotence,
in-fence re-validation, and spelling robustness for stored timestamps.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta, timezone
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import select, update
from test_backend_mvp import make_client

from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import timeline_item_content_hash
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store
from agent_server.services.timeline_janitor import (
    CLOSED_BY_EVIDENCE,
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


async def _store_with_session(tmp_path: Any) -> tuple[Store, Any]:
    db_path = tmp_path / "timeline-janitor.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    return store, session


async def _age_session(
    store: Store,
    session_id: str,
    *,
    updated_at_hours: float = 50.0,
    last_activity_hours: float | None = None,
) -> None:
    """Backdate the session's own activity timestamps (writes bump them)."""

    values: dict[str, Any] = {"updated_at": _ago(updated_at_hours)}
    if last_activity_hours is not None:
        values["last_activity_at"] = _ago(last_activity_hours)
    async with store.engine.begin() as conn:
        await conn.execute(
            update(sessions_t).where(sessions_t.c.id == session_id).values(**values)
        )


def _janitor(store: Store, **kwargs: Any) -> TimelineJanitor:
    kwargs.setdefault("max_age_seconds", MAX_AGE_SECONDS)
    return TimelineJanitor(store, **kwargs)


@pytest.mark.anyio
async def test_closes_age_bounded_running_tool_row(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row("tool_old", session_id=session.id, order_seq=1, age_hours=50),
                tool_row(
                    "tool_done_neighbour",
                    session_id=session.id,
                    order_seq=2,
                    status="done",
                    age_hours=50,
                ),
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        seq_before = await store.get_session_seq(session.id)

        closed = await _janitor(store).run_once()

        assert closed == ["tool_old"]
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "interrupted"
        assert item.content["closedByEvidence"] == CLOSED_BY_EVIDENCE
        # Sibling content keys survive the stamp.
        assert item.content["kind"] == "bash"
        # The row carries the canonical hash of its new state, so a later
        # Runtime push of the old state reads as a change (not a no-op).
        assert item.contentHash == timeline_item_content_hash(
            item_type="tool",
            status="interrupted",
            role="tool",
            content=item.content,
        )
        assert item.revision == 2
        assert item.orderSeq == 1
        assert item.updatedSeq > seq_before
        assert await store.get_session_seq(session.id) > seq_before
        # The already-terminal neighbour is never a candidate.
        (neighbour,) = await store.timeline.read_many(
            session.id, {"tool_done_neighbour"}
        )
        assert neighbour.status == "done"
        assert "closedByEvidence" not in neighbour.content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_leaves_row_inside_the_age_bound(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_fresh", session_id=session.id, order_seq=1, age_hours=2)],
        )
        await _age_session(store, session.id, updated_at_hours=50)

        assert await _janitor(store).run_once() == []
        (item,) = await store.timeline.read_many(session.id, {"tool_fresh"})
        assert item.status == "running"
        assert "closedByEvidence" not in item.content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_active_run_blocks_closure_until_cleared(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        await store.start_active_run(
            session_id=session.id,
            runtime="claude",
            external_session_id="claude_ext_1",
        )

        assert await _janitor(store).run_once() == []
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "running"

        await store.clear_active_run(session.id)
        assert await _janitor(store).run_once() == ["tool_old"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_recent_session_activity_blocks_closure(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )

        # A write landed here / still lands here recently: the session is not
        # silent, so the row keeps its state even though the row looks old.
        await _age_session(store, session.id, updated_at_hours=1)
        assert await _janitor(store).run_once() == []

        # Old write, but activity was recorded recently (another surface of
        # the same session is still alive).
        await _age_session(
            store, session.id, updated_at_hours=50, last_activity_hours=1
        )
        assert await _janitor(store).run_once() == []

        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_never_touches_pending_waiting_approval_or_non_tool_rows(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row("tool_running", session_id=session.id, order_seq=1),
                tool_row(
                    "tool_waiting",
                    session_id=session.id,
                    order_seq=2,
                    status="waiting_approval",
                ),
                tool_row("tool_pending", session_id=session.id, order_seq=3, status="pending"),
                tool_row(
                    "message_pending",
                    session_id=session.id,
                    order_seq=4,
                    status="pending",
                    item_type="message",
                    role="user",
                    content={"text": "queued while offline"},
                ),
                tool_row(
                    "message_running",
                    session_id=session.id,
                    order_seq=5,
                    item_type="message",
                    role="assistant",
                ),
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)

        assert await _janitor(store).run_once() == ["tool_running"]

        items = {item.id: item for item in await store.timeline.read(session.id)}
        assert items["tool_running"].status == "interrupted"
        # Queued messages may legitimately sit across days; approvals may
        # legitimately hang. Only a running tool row has an age verdict.
        assert items["tool_waiting"].status == "waiting_approval"
        assert items["tool_pending"].status == "pending"
        assert items["message_pending"].status == "pending"
        assert items["message_running"].status == "running"
        for item_id in (
            "tool_waiting",
            "tool_pending",
            "message_pending",
            "message_running",
        ):
            assert "closedByEvidence" not in items[item_id].content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_closure_never_consumes_the_unread_badge(tmp_path) -> None:
    """A closure is not content the user has now seen (prune precedent, R2)."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await store.record_session_turn_end(session_id=session.id)
        await _age_session(store, session.id, updated_at_hours=50)

        before = await store.get_session(session.id)
        assert before.unread is True

        assert await _janitor(store).run_once() == ["tool_old"]

        after = await store.get_session(session.id)
        assert after.unread is True
        assert after.lastReadSeq == before.lastReadSeq
        assert after.latestTurnEndSeq == before.latestTurnEndSeq
        # The refetch bump still happened: clients holding the row hear about it.
        assert after.updatedSeq > before.updatedSeq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_kill_switch_disables_the_janitor(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        seq_before = await store.get_session_seq(session.id)

        disabled = TimelineJanitor(store, max_age_seconds=0)
        assert disabled.enabled is False
        assert await disabled.run_once() == []
        # ``run`` returns immediately instead of sweeping forever.
        await disabled.run()

        assert await store.get_session_seq(session.id) == seq_before
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_sweep_is_idempotent(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        janitor = _janitor(store)

        assert await janitor.run_once() == ["tool_old"]
        seq_after_first = await store.get_session_seq(session.id)

        assert await janitor.run_once() == []
        assert await store.get_session_seq(session.id) == seq_after_first
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "interrupted"
        assert item.revision == 2
    finally:
        await store.close()


@pytest.mark.anyio
async def test_close_revalidates_the_active_run_inside_the_fence(tmp_path) -> None:
    """A probe is only a hint: a turn that starts in between wins."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        older_than = datetime.now(UTC) - timedelta(seconds=MAX_AGE_SECONDS)

        candidates = await store.stale_running_tool_candidates(
            older_than=older_than,
            limit=100,
        )
        assert candidates == [(session.id, "tool_old")]

        # The turn starts after the probe but before the close.
        await store.start_active_run(
            session_id=session.id,
            runtime="claude",
            external_session_id="claude_ext_1",
        )
        closed = await store.close_stale_running_tool_items(
            session_id=session.id,
            item_ids=["tool_old"],
            older_than=older_than,
            closed_by_evidence=CLOSED_BY_EVIDENCE,
        )

        assert list(closed.items) == []
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_in_flight_rows_are_not_closed(tmp_path) -> None:
    """A row reserved above the session fence is a buffered write in progress."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("tool_old", session_id=session.id, order_seq=1)],
        )
        await _age_session(store, session.id, updated_at_hours=50)
        seq = await store.get_session_seq(session.id)
        async with store.engine.begin() as conn:
            await conn.execute(
                update(timeline_items_t)
                .where(
                    timeline_items_t.c.session_id == session.id,
                    timeline_items_t.c.id == "tool_old",
                )
                .values(updated_seq=seq + 10)
            )

        assert await _janitor(store).run_once() == []
        (item,) = await store.timeline.read_many(session.id, {"tool_old"})
        assert item.status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_closes_offset_spelled_timestamps(tmp_path) -> None:
    """Once-old rows are closed whatever ISO-8601 spelling stored them."""

    store, session = await _store_with_session(tmp_path)
    try:
        plus_zero = UTC
        plus_eight = timezone(timedelta(hours=8))
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(
                    "tool_z",
                    session_id=session.id,
                    order_seq=1,
                    age_hours=50,
                ),
                tool_row(
                    "tool_plus_zero",
                    session_id=session.id,
                    order_seq=2,
                    age_hours=50,
                    tz=plus_zero,
                    z_suffix=False,
                ),
                tool_row(
                    "tool_plus_eight",
                    session_id=session.id,
                    order_seq=3,
                    age_hours=50,
                    tz=plus_eight,
                ),
                # Inside the cutoff spelled in +08:00: its local clock reads
                # earlier than the cutoff while the instant is not yet old.
                # The probe may hand it over; the exact comparison must not.
                tool_row(
                    "tool_plus_eight_not_due",
                    session_id=session.id,
                    order_seq=4,
                    age_hours=45,
                    tz=plus_eight,
                ),
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)

        closed = await _janitor(store).run_once()

        assert sorted(closed) == ["tool_plus_eight", "tool_plus_zero", "tool_z"]
        items = {item.id: item for item in await store.timeline.read(session.id)}
        assert items["tool_z"].status == "interrupted"
        assert items["tool_plus_zero"].status == "interrupted"
        assert items["tool_plus_eight"].status == "interrupted"
        assert items["tool_plus_eight_not_due"].status == "running"
    finally:
        await store.close()


def test_from_environment_defaults_and_kill_switch(monkeypatch) -> None:
    monkeypatch.delenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", raising=False)
    monkeypatch.delenv("AGENT_SERVER_TIMELINE_JANITOR_INTERVAL_SECONDS", raising=False)
    assert TimelineJanitor.from_environment(object()).enabled is True

    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", "0")
    assert TimelineJanitor.from_environment(object()).enabled is False

    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", "-5")
    assert TimelineJanitor.from_environment(object()).enabled is False


def test_create_app_wires_the_janitor(tmp_path) -> None:
    client = make_client(tmp_path)
    janitor = client.app.state.timeline_janitor
    assert isinstance(janitor, TimelineJanitor)
    assert janitor.enabled is True


# ---------------------------------------------------------------------------
# Malformed configuration stands the janitor down instead of the server
# ---------------------------------------------------------------------------


def test_malformed_env_never_takes_the_server_down(monkeypatch) -> None:
    """A value that is not a finite number is not a crash, it is a config error.

    ``from_environment`` runs inside ``create_app``, so the old bare
    ``float(...)`` turned one bad env var into a server that cannot start.
    """

    for raw in ("", "   ", "abc", "48h", "nan", "inf", "-inf"):
        monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", raw)
        janitor = TimelineJanitor.from_environment(object())
        assert janitor.enabled is False, raw

    # A malformed period disables it too: same posture, both variables.
    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", "172800")
    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_INTERVAL_SECONDS", "10m")
    janitor = TimelineJanitor.from_environment(object())
    assert janitor.enabled is False
    # ...while the values it could not read fall back to the defaults, so a
    # later repair (unset the variable) is all it takes to come back.
    assert janitor._max_age_seconds == 48 * 60 * 60.0
    assert janitor._interval_seconds == 600.0


@pytest.mark.parametrize("raw", ["", "   ", "abc", "48h"])
def test_create_app_survives_a_malformed_janitor_env(monkeypatch, tmp_path, raw) -> None:
    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS", raw)
    client = make_client(tmp_path)
    janitor = client.app.state.timeline_janitor
    assert isinstance(janitor, TimelineJanitor)
    assert janitor.enabled is False


@pytest.mark.anyio
async def test_a_disabled_janitor_does_not_run(monkeypatch) -> None:
    """``run()`` returns instead of entering the sweep loop.

    The enabled path sleeps forever, so this also pins that the lifespan
    wiring skips a malformed janitor rather than starting a doomed task.
    """

    monkeypatch.setenv("AGENT_SERVER_TIMELINE_JANITOR_INTERVAL_SECONDS", "forever")
    janitor = TimelineJanitor.from_environment(object())
    assert await asyncio.wait_for(janitor.run(), timeout=5.0) is None
    assert await janitor.run_once() == []


# ---------------------------------------------------------------------------
# The closure must not re-arm the session it just healed
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_a_healed_session_stays_eligible_for_the_next_sweep(tmp_path) -> None:
    """The revision bump must not stamp the columns the silence guard reads.

    This method writes ``sessions.updated_at`` through the shared
    ``_reserve_session_revisions``; a janitor that stamped it with its own
    clock would re-arm every session it healed and strand the tail of any
    session whose rows exceed one sweep's candidate cap.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"tool{index}", session_id=session.id, order_seq=index + 1)
                for index in range(5)
            ],
        )
        await _age_session(store, session.id, updated_at_hours=50)

        capped = TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=2
        )
        first = await capped.run_once()
        assert len(first) == 2

        async with store.engine.connect() as conn:
            row = (
                await conn.execute(
                    select(
                        sessions_t.c.updated_at,
                        sessions_t.c.last_activity_at,
                        sessions_t.c.seq,
                    ).where(sessions_t.c.id == session.id)
                )
            ).first()
        assert row is not None
        # Silence columns untouched by the janitor's own write...
        assert _is_roughly_now(row.updated_at), row.updated_at
        assert row.last_activity_at is None
        # ...but the revision really did advance, so clients still learn.
        assert int(row.seq) >= 2

        # The next sweeps drain the rest with no operator intervention.
        second = await capped.run_once()
        third = await capped.run_once()
        assert len(second) == 2
        assert len(third) == 1
        assert await capped.run_once() == []
        items = {item.id: item for item in await store.timeline.read(session.id)}
        assert {item.status for item in items.values()} == {"interrupted"}
    finally:
        await store.close()


def _is_roughly_now(value: str | None) -> bool:
    """True when a stored timestamp is hours old, not just now."""

    assert value
    parsed = datetime.fromisoformat(value)
    delta = datetime.now(UTC) - parsed
    return timedelta(hours=49) < delta < timedelta(hours=51)
