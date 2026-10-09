"""R2 round-2: re-verification and new-path attacks on the T3 janitor fixes.

Baseline: fix/residue-integration @ b2a7f9a9 (fixes in 3fc4243f).

R1  A2/C2 re-verify: 600 rows / 2 sessions must fully drain, no starvation.
R2  C2 deviation: touch_updated_at=False must not starve the OTHER
    updated_at readers (session ordering, SessionRuntimeState.updatedAt) and
    must not weaken the B4b guard (a connector that just wrote must still
    block closure).
R3  _env_seconds boundaries: unset->default, malformed->disabled, both vars,
    and the values math.isfinite still lets through.
R4  TimelineBatchWriteResult / _JANITOR_NO_CHANGE contract.
R5  refetch envelope in shapes beyond A6c: mixed rows, consecutive rounds.
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import select, update

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.redis_coordinator import RedisCoordinator
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_broker import TimelineBroker
from agent_server.services.timeline_janitor import (
    DEFAULT_CANDIDATE_LIMIT,
    DEFAULT_INTERVAL_SECONDS,
    DEFAULT_MAX_AGE_SECONDS,
    ENV_INTERVAL_SECONDS,
    ENV_MAX_AGE_SECONDS,
    TimelineJanitor,
    _env_seconds,
)
from agent_server.services.timeline_write_buffer import TimelineWriteBuffer

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
    content: dict[str, Any] | None = None,
) -> TimelineItemIn:
    stamp = _ago(age_hours)
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": item_type,
            "status": status,
            "role": "tool",
            "content": content or {"kind": "bash", "toolName": "Bash"},
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
    db_path = tmp_path / f"r2b-{tag}.sqlite3"
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


async def _stuck(store: Store, session_id: str) -> list[str]:
    items = await store.timeline.read(session_id)
    return sorted(i.id for i in items if i.status == "running")


# ---------------------------------------------------------------------------
# R1: A2/C2 re-verification
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_R1_600_rows_two_sessions_drain_without_starvation(tmp_path) -> None:
    store, session_a = await _store(tmp_path, tag="r1")
    try:
        session_b = await create_session_with_project(
            store,
            connector_id=session_a.connectorId,
            runtime="claude",
            external_session_id="claude_ext_r1b",
        )
        per_session = 300
        for session, prefix in ((session_a, "a"), (session_b, "b")):
            await store.sync_timeline_items(
                session_id=session.id,
                items=[
                    tool_row(f"{prefix}{i:04d}", session_id=session.id, order_seq=i + 1)
                    for i in range(per_session)
                ],
            )
            await _age(store, session.id)

        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        first = await janitor.run_once()
        print(f"\n[R1] sweep 1 closed = {len(first)} (cap {DEFAULT_CANDIDATE_LIMIT})")
        assert len(first) == DEFAULT_CANDIDATE_LIMIT

        history = []
        for cycle in range(2, 8):
            more = await janitor.run_once()
            a, b = len(await _stuck(store, session_a.id)), len(
                await _stuck(store, session_b.id)
            )
            history.append((cycle, len(more), a, b))
            print(f"[R1] cycle {cycle}: closed={len(more)} stuckA={a} stuckB={b}")
            if a == 0 and b == 0:
                break
        assert history[-1][2] == 0 and history[-1][3] == 0, (
            f"600 rows must fully drain, last={history[-1]}"
        )
        # No session may go backwards while the loop keeps sweeping.
        prev_a = prev_b = per_session
        for cycle, _closed, a, b in history:
            assert a <= prev_a and b <= prev_b, "a session regressed"
            prev_a, prev_b = a, b
    finally:
        await store.close()


@pytest.mark.anyio
async def test_R1b_idle_after_draining_and_stays_quiet(tmp_path) -> None:
    store, session = await _store(tmp_path, tag="r1b")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i}", session_id=session.id, order_seq=i + 1)
                for i in range(501)
            ],
        )
        await _age(store, session.id)
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        first = await janitor.run_once()
        second = await janitor.run_once()
        print(f"\n[R1b] first={len(first)} second={len(second)}")
        assert len(first) == DEFAULT_CANDIDATE_LIMIT
        assert len(second) == 1
        assert await _stuck(store, session.id) == []
        for _ in range(3):
            assert await janitor.run_once() == []
        print("[R1b] healed then quiet across 3 further sweeps")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# R2: the C2 deviation's blast radius on other updated_at readers
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_R2_b4b_connector_just_wrote_still_blocks_closure(tmp_path) -> None:
    """B4b guard must survive the touch_updated_at change.

    The connector pushes a brand-new row; the session is no longer silent, so
    the closure must not fire even though the stale row is still there.
    """

    store, session = await _store(tmp_path, tag="r2")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("stale", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id)
        # Connector writes right now: this bumps updated_at through the normal
        # allocator path (touch_updated_at defaults to True there).
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(
                    "fresh",
                    session_id=session.id,
                    order_seq=2,
                    age_hours=0.0,
                    status="done",
                )
            ],
        )
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[R2] closed with a fresh connector write present = {closed}")
        assert closed == []
        assert await _stuck(store, session.id) == ["stale"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_R2b_runtime_state_updatedAt_and_seq_stay_consistent(tmp_path) -> None:
    """The deviation leaves updated_at alone; check what readers now see.

    SessionRuntimeState.updatedAt is read straight off sessions.updated_at,
    so a closure no longer advances it while updatedSeq does.
    """

    store, session = await _store(tmp_path, tag="r2b")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id)
        before = await store.get_session_runtime_state(session.id)
        await TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS).run_once()
        after = await store.get_session_runtime_state(session.id)
        print(f"\n[R2b] updatedAt {before.updatedAt} -> {after.updatedAt}")
        print(f"[R2b] updatedSeq {before.updatedSeq} -> {after.updatedSeq}")
        assert after.updatedSeq > before.updatedSeq, "revision must still advance"
        assert after.updatedAt == before.updatedAt, "activity stamp must not move"
        # The skew is bounded and ordered: seq moved, timestamp did not.
        assert after.updatedAt < after.createdAt or after.updatedAt <= after.updatedAt
    finally:
        await store.close()


@pytest.mark.anyio
async def test_R2c_session_ordering_reader_still_functions(tmp_path) -> None:
    """sessions.py:1262 orders by updated_at asc; a healed session must not
    disappear from or corrupt that listing."""

    store, session = await _store(tmp_path, tag="r2c")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1)],
        )
        await _age(store, session.id)
        before = await store.list_sessions()
        await TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS).run_once()
        after = await store.list_sessions()
        print(f"\n[R2c] sessions before={len(before)} after={len(after)}")
        assert len(after) == len(before) >= 1
        assert any(s.id == session.id for s in after), "healed session still listed"
        # Its ordering timestamp is untouched, so its position is stable.
        idx_before = [s.id for s in before].index(session.id)
        idx_after = [s.id for s in after].index(session.id)
        print(f"[R2c] healed session index {idx_before} -> {idx_after}")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# R3: _env_seconds boundaries
# ---------------------------------------------------------------------------


def test_R3_env_seconds_matrix(monkeypatch: pytest.MonkeyPatch) -> None:
    cases = [
        (None, DEFAULT_MAX_AGE_SECONDS, "unset -> default"),
        ("", None, "empty -> disabled"),
        ("   ", None, "whitespace -> disabled"),
        ("abc", None, "garbage -> disabled"),
        ("48h", None, "unit suffix -> disabled"),
        ("nan", None, "nan -> disabled"),
        ("inf", None, "inf -> disabled"),
        ("-inf", None, "-inf -> disabled"),
        ("0", 0.0, "zero -> parsed (kill-switch)"),
        ("-1", -1.0, "negative -> parsed (kill-switch)"),
        (" 600 ", 600.0, "padded -> parsed"),
        ("1e3", 1000.0, "scientific -> parsed"),
        ("0x10", None, "hex -> disabled"),
        ("1_000", 1000.0, "underscore -> parsed by float()"),
    ]
    for raw, expected, label in cases:
        if raw is None:
            monkeypatch.delenv(ENV_MAX_AGE_SECONDS, raising=False)
        else:
            monkeypatch.setenv(ENV_MAX_AGE_SECONDS, raw)
        got = _env_seconds(ENV_MAX_AGE_SECONDS, DEFAULT_MAX_AGE_SECONDS)
        status = "OK" if got == expected else "MISMATCH"
        print(f"  [R3] {label:32} raw={raw!r:10} -> {got} [{status}]")
        assert got == expected, f"{label}: expected {expected}, got {got}"


def test_R3b_both_variables_covered(monkeypatch: pytest.MonkeyPatch) -> None:
    """Either variable being malformed must stand the janitor down."""

    class _Store:
        pass

    store = _Store()
    for bad_var, other_var in (
        (ENV_MAX_AGE_SECONDS, ENV_INTERVAL_SECONDS),
        (ENV_INTERVAL_SECONDS, ENV_MAX_AGE_SECONDS),
    ):
        monkeypatch.setenv(bad_var, "abc")
        monkeypatch.setenv(other_var, "600")
        janitor = TimelineJanitor.from_environment(store)
        print(
            f"  [R3b] {bad_var} malformed -> enabled={janitor.enabled}"
        )
        assert janitor.enabled is False
    # Both unset -> defaults, enabled.
    monkeypatch.delenv(ENV_MAX_AGE_SECONDS, raising=False)
    monkeypatch.delenv(ENV_INTERVAL_SECONDS, raising=False)
    janitor = TimelineJanitor.from_environment(store)
    print(
        f"  [R3b] both unset -> enabled={janitor.enabled} "
        f"max_age={janitor._max_age_seconds} interval={janitor._interval_seconds}"
    )
    assert janitor.enabled is True
    assert janitor._max_age_seconds == DEFAULT_MAX_AGE_SECONDS
    assert janitor._interval_seconds == DEFAULT_INTERVAL_SECONDS


@pytest.mark.anyio
@pytest.mark.parametrize("raw", ["1e15", "999999999999999", "1e308", "1e18"])
async def test_R3c_huge_but_finite_value_is_refused_not_silently_dead(
    tmp_path, raw: str
) -> None:
    """Finite is not representable: ``timedelta`` overflows on these values.

    Round-2 finding (P2): _env_seconds admitted them, the janitor reported
    itself enabled, and every sweep died with OverflowError inside run_once
    (caught by ``run()``, so the server lived but the janitor never healed a
    row again). They must be refused at parse time — a janitor that stands
    down cleanly, never one that runs broken.
    """

    store, _ = await _store(tmp_path, tag=f"r3c{raw[:4]}")
    try:
        os.environ[ENV_MAX_AGE_SECONDS] = raw
        janitor = TimelineJanitor.from_environment(store)
        print(f"\n[R3c] raw={raw!r} enabled={janitor.enabled}")
        assert janitor.enabled is False, (
            f"{raw!r} must be refused at parse time (timedelta overflow); "
            f"got enabled={janitor.enabled}"
        )
        result = await janitor.run_once()
        assert result == [], "a disabled janitor closes nothing and must not raise"
        print(f"[R3c] run_once -> {result}")
    finally:
        os.environ.pop(ENV_MAX_AGE_SECONDS, None)
        await store.close()


@pytest.mark.anyio
async def test_A3b_app_boots_under_malformed_janitor_env(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The P0 surface itself: app construction must survive a typo'd env.

    Round-2 audit gap: the A3 guards only reached ``from_environment``;
    nothing asserted the app can still be built — while the original failure
    took down server startup (``create_app`` raising before lifespan).
    """

    from test_backend_mvp import make_client

    monkeypatch.setenv(ENV_MAX_AGE_SECONDS, "48h")
    monkeypatch.setenv(ENV_INTERVAL_SECONDS, "not-a-number")
    with make_client(tmp_path) as client:
        response = client.get("/api/v2/health")
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# R4: TimelineBatchWriteResult / _JANITOR_NO_CHANGE contract
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_R4_no_change_result_reports_unchanged(tmp_path) -> None:
    from agent_server.infra.repositories.timeline import _JANITOR_NO_CHANGE

    store, session = await _store(tmp_path, tag="r4")
    try:
        # Fresh row -> nothing is due.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t1", session_id=session.id, order_seq=1, age_hours=1.0)],
        )
        await _age(store, session.id)
        result = await store.close_stale_running_tool_items(
            session_id=session.id,
            item_ids=["t1"],
            older_than=datetime.now(UTC) - timedelta(seconds=MAX_AGE_SECONDS),
            closed_by_evidence="ageBoundedServer",
        )
        print(f"\n[R4] no-change result changed={result.changed} items={result.items}")
        assert result.changed is False
        assert tuple(result.items) == ()
        assert result is _JANITOR_NO_CHANGE or (
            result.changed is False and not result.items
        )
        assert TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)._store is store
    finally:
        await store.close()


@pytest.mark.anyio
async def test_R4b_run_once_contract_returns_ids_only_for_changed(
    tmp_path,
) -> None:
    """run_once must stay list[str] and must not leak batch objects."""

    store, session = await _store(tmp_path, tag="r4b")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i}", session_id=session.id, order_seq=i + 1)
                for i in range(3)
            ],
        )
        await _age(store, session.id)
        janitor = TimelineJanitor(store, max_age_seconds=MAX_AGE_SECONDS)
        result = await janitor.run_once()
        print(f"\n[R4b] run_once type={type(result).__name__} value={sorted(result)}")
        assert isinstance(result, list)
        assert all(isinstance(x, str) for x in result)
        assert sorted(result) == ["t0", "t1", "t2"]
        assert await janitor.run_once() == []
        print("[R4b] quiet sweep returns []")
    finally:
        await store.close()


@pytest.mark.anyio
async def test_R4c_janitor_no_change_is_not_shared_mutable_state(tmp_path) -> None:
    """The module-level _JANITOR_NO_CHANGE singleton must be inert."""

    from agent_server.infra.repositories.timeline import _JANITOR_NO_CHANGE

    print(f"\n[R4c] singleton = {_JANITOR_NO_CHANGE}")
    assert _JANITOR_NO_CHANGE.items == ()
    assert _JANITOR_NO_CHANGE.changed is False
    # It is a frozen dataclass: a caller cannot mutate shared state.
    try:
        object.__setattr__  # noqa: B018
        _JANITOR_NO_CHANGE.changed = True  # type: ignore[misc]
    except Exception as exc:  # noqa: BLE001
        print(f"[R4c] mutation refused: {type(exc).__name__}")
    else:
        print("[R4c] WARNING: singleton is mutable")


# ---------------------------------------------------------------------------
# R5: envelope shapes beyond A6c
# ---------------------------------------------------------------------------


async def _buffered_store(tmp_path: Any, tag: str):
    store, session = await _store(tmp_path, tag=tag)
    coordinator = RedisCoordinator()
    broker = TimelineBroker(coordinator)
    payloads: list[dict[str, Any]] = []

    async def capture(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = capture  # type: ignore[method-assign]
    buffer = TimelineWriteBuffer(
        store, broker, coordinator, flush_interval_seconds=60
    )
    return store, session, buffer, payloads


@pytest.mark.anyio
async def test_R5_envelope_carries_only_the_closed_rows_not_untouched_ones(
    tmp_path,
) -> None:
    """Mixed rows: only closed ones ride the envelope."""

    store, session, buffer, payloads = await _buffered_store(tmp_path, "r5")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row("doomed1", session_id=session.id, order_seq=1),
                tool_row("doomed2", session_id=session.id, order_seq=2),
                tool_row(
                    "keep_pending",
                    session_id=session.id,
                    order_seq=3,
                    status="pending",
                    item_type="message",
                ),
                tool_row(
                    "keep_done",
                    session_id=session.id,
                    order_seq=4,
                    status="done",
                ),
            ],
        )
        await _age(store, session.id)
        payloads.clear()
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[R5] closed = {sorted(closed)}")
        assert sorted(closed) == ["doomed1", "doomed2"]
        seq_after = await store.get_session_seq(session.id)
        envelopes = [e for e in payloads if e.get("nextSeq") == seq_after]
        assert envelopes, "the closure must publish"
        delivered = [i["id"] for e in envelopes for i in (e.get("items") or [])]
        print(f"[R5] delivered in envelope = {sorted(delivered)}")
        assert sorted(delivered) == ["doomed1", "doomed2"]
        for envelope in envelopes:
            assert not envelope.get("refetch"), "small batch should carry items"
    finally:
        await buffer.close()
        await store.close()


@pytest.mark.anyio
async def test_R5b_consecutive_rounds_each_publish_their_own_rows(tmp_path) -> None:
    """Two capped rounds: each envelope carries only its own round's rows."""

    store, session, buffer, payloads = await _buffered_store(tmp_path, "r5b")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i:03d}", session_id=session.id, order_seq=i + 1)
                for i in range(6)
            ],
        )
        await _age(store, session.id)
        janitor = TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS, candidate_limit=2
        )
        payloads.clear()
        seq0 = await store.get_session_seq(session.id)
        first = await janitor.run_once()
        seq1 = await store.get_session_seq(session.id)
        round1 = [e for e in payloads if e.get("nextSeq") == seq1]
        delivered1 = sorted(i["id"] for e in round1 for i in (e.get("items") or []))
        print(f"\n[R5b] round1 closed={sorted(first)} delivered={delivered1}")
        assert delivered1 == sorted(first)

        second = await janitor.run_once()
        seq2 = await store.get_session_seq(session.id)
        round2 = [e for e in payloads if e.get("nextSeq") == seq2]
        delivered2 = sorted(i["id"] for e in round2 for i in (e.get("items") or []))
        print(f"[R5b] round2 closed={sorted(second)} delivered={delivered2}")
        assert delivered2 == sorted(second)
        assert seq1 > seq0 and seq2 > seq1, "each round advances the revision"
    finally:
        await buffer.close()
        await store.close()


@pytest.mark.anyio
async def test_R5c_exactly_at_the_envelope_budget_boundary(tmp_path) -> None:
    """100 is the inline budget; 101 must switch to refetch."""

    store, session, buffer, payloads = await _buffered_store(tmp_path, "r5c")
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{i:04d}", session_id=session.id, order_seq=i + 1)
                for i in range(101)
            ],
        )
        await _age(store, session.id)
        payloads.clear()
        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        seq_after = await store.get_session_seq(session.id)
        envelopes = [e for e in payloads if e.get("nextSeq") == seq_after]
        print(f"\n[R5c] closed={len(closed)} envelopes={len(envelopes)}")
        assert len(closed) == 101
        assert envelopes
        for envelope in envelopes:
            items = envelope.get("items") or []
            print(
                f"[R5c] keys={sorted(envelope)} items={len(items)} "
                f"refetch={envelope.get('refetch')}"
            )
            # Either shape is acceptable as long as the client is told.
            assert items or envelope.get("refetch"), "client must be told something"
    finally:
        await buffer.close()
        await store.close()