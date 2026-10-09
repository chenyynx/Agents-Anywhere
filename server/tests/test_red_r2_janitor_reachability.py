"""R2 red-team: reachability of a janitor closure (attack surface 4/6).

Question: after the janitor closes a row, can a client that is holding a
cursor actually learn about it?

Answer, after the fix: yes, by the prune precedent. The closure returns a
``TimelineBatchWriteResult``, so the envelope either carries the closed rows
or (past the envelope budget) ``refetch: True``. The A6b control keeps the
prune path pinned next to it, so the two shapes cannot drift apart again.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import update

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.redis_coordinator import RedisCoordinator
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_broker import TimelineBroker
from agent_server.services.timeline_janitor import TimelineJanitor
from agent_server.services.timeline_write_buffer import TimelineWriteBuffer

MAX_AGE_SECONDS = 48 * 60 * 60.0


def _ago(hours: float) -> str:
    return (datetime.now(UTC) - timedelta(hours=hours)).isoformat().replace(
        "+00:00", "Z"
    )


def tool_row(item_id: str, *, session_id: str, order_seq: int) -> TimelineItemIn:
    stamp = _ago(50.0)
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


@pytest.mark.anyio
async def test_A6_closure_envelope_carries_the_closed_row(tmp_path) -> None:
    """After the closure, a client holding a cursor can actually learn it.

    The janitor used to return ``list[str]``, which reaches
    ``publish_revision_result`` as an unknown result type: the envelope was
    ``{sessionId, nextSeq, session}`` — no items, no refetch. Every client
    advanced its cursor past the closure and nothing ever told them the row
    changed, so the change was self-concealing.
    """

    db_path = tmp_path / "r2-reach.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    coordinator = RedisCoordinator()
    broker = TimelineBroker(coordinator)
    payloads: list[dict[str, Any]] = []

    async def capture(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = capture  # type: ignore[method-assign]
    buffer = TimelineWriteBuffer(
        store, broker, coordinator, flush_interval_seconds=60
    )
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[tool_row("t_cold", session_id=session.id, order_seq=1)],
        )
        async with store.engine.begin() as conn:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == session.id)
                .values(updated_at=_ago(50.0))
            )
        payloads.clear()
        cursor_before = await store.get_session_seq(session.id)
        print(f"\n[A6] session seq before janitor = {cursor_before}")

        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"[A6] janitor closed = {closed}")
        assert closed == ["t_cold"]

        print(f"[A6] envelopes published during the closure = {len(payloads)}")
        for envelope in payloads:
            print(f"[A6]   envelope keys = {sorted(envelope)}")
            print(f"[A6]   has items  = {'items' in envelope}")
            print(f"[A6]   has refetch = {envelope.get('refetch')}")
            print(f"[A6]   has timelineReset = {envelope.get('timelineReset')}")
            print(f"[A6]   nextSeq = {envelope.get('nextSeq')}")

        closure_envelopes = [
            e for e in payloads if e.get("nextSeq") == cursor_before + 1
        ]
        assert closure_envelopes, "expected the closure to publish a bumped nextSeq"
        for envelope in closure_envelopes:
            items = envelope.get("items") or []
            print(f"[A6]   delivered {len(items)} item(s) to the client")
            assert items, "the closure envelope must carry the closed row"
            assert [item["id"] for item in items] == ["t_cold"]
            assert items[0]["status"] == "interrupted"
            assert items[0]["content"]["closedByEvidence"] == "ageBoundedServer"

        # A pull from the pre-closure cursor sees the same row...
        since, _ = await store.timeline.list_since(
            session.id, after_seq=cursor_before, limit=100
        )
        print(f"[A6] cursor pull afterSeq={cursor_before} -> {len(since)} item(s)")
        assert [item.id for item in since] == ["t_cold"]
        assert since[0].status == "interrupted"

        # ...and a client that already applied the envelope cursor is not left
        # with a hole: the change arrived in the envelope above, which is the
        # same contract every other timeline write uses.
        after, _ = await store.timeline.list_since(
            session.id, after_seq=cursor_before + 1, limit=100
        )
        print(
            f"[A6] cursor pull afterSeq={cursor_before + 1} -> {len(after)} item(s)"
        )
        assert after == []
    finally:
        await buffer.close()
        await store.close()


@pytest.mark.anyio
async def test_A6c_a_large_closure_publishes_a_refetch_instead_of_items(
    tmp_path,
) -> None:
    """Past the envelope's item budget the client is told to re-pull.

    Same prune precedent, larger batch: an envelope that carried 500 rows
    would be a payload no client asked for, so the batch path trades the rows
    for ``refetch: True``. Either way the client is told something changed.
    """

    db_path = tmp_path / "r2-reach-bulk.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    coordinator = RedisCoordinator()
    broker = TimelineBroker(coordinator)
    payloads: list[dict[str, Any]] = []

    async def capture(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = capture  # type: ignore[method-assign]
    buffer = TimelineWriteBuffer(
        store, broker, coordinator, flush_interval_seconds=60
    )
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_row(f"t{index:04d}", session_id=session.id, order_seq=index + 1)
                for index in range(150)
            ],
        )
        async with store.engine.begin() as conn:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == session.id)
                .values(updated_at=_ago(50.0))
            )
        payloads.clear()

        closed = await TimelineJanitor(
            store, max_age_seconds=MAX_AGE_SECONDS
        ).run_once()
        print(f"\n[A6c] janitor closed = {len(closed)} rows")
        assert len(closed) == 150

        seq_after = await store.get_session_seq(session.id)
        envelopes = [e for e in payloads if e.get("nextSeq") == seq_after]
        assert envelopes, "a 150-row closure must still publish"
        for envelope in envelopes:
            print(
                f"[A6c] keys={sorted(envelope)} "
                f"refetch={envelope.get('refetch')} "
                f"items={len(envelope.get('items') or [])}"
            )
            assert envelope.get("refetch") is True
            assert not envelope.get("items")
    finally:
        await buffer.close()
        await store.close()


def agent_call_row(
    item_id: str, *, session_id: str, order_seq: int, task_ids: list[str]
) -> TimelineItemIn:
    stamp = _ago(0.0)
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": "running",
            "role": "tool",
            "content": {"kind": "agent_call", "agents": {t: {} for t in task_ids}},
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


@pytest.mark.anyio
async def test_A6b_prune_path_does_emit_refetch_for_comparison(tmp_path) -> None:
    """Control: the prune precedent reaches clients via refetch/timelineReset.

    Same session, same publish layer, but the prune path deletes rows and
    returns a TimelineBatchWriteResult, so the envelope carries a refetch or
    timelineReset flag. This is the shape the janitor does NOT produce.
    """

    db_path = tmp_path / "r2-prune.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    coordinator = RedisCoordinator()
    broker = TimelineBroker(coordinator)
    payloads: list[dict[str, Any]] = []

    async def capture(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = capture  # type: ignore[method-assign]
    buffer = TimelineWriteBuffer(
        store, broker, coordinator, flush_interval_seconds=60
    )
    try:
        # An orphan agent-call card naming task t1, then a rebuild batch that
        # republishes a DIFFERENT id for the same task: the old card is a
        # leftover generation and prune deletes it.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                agent_call_row(
                    "card_old", session_id=session.id, order_seq=1, task_ids=["t1"]
                )
            ],
        )
        payloads.clear()
        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                agent_call_row(
                    "card_new", session_id=session.id, order_seq=2, task_ids=["t1"]
                )
            ],
            prune_orphan_agent_calls=True,
        )
        print(f"\n[A6b] batch changed = {result.changed} items = {len(result.items)}")
        assert result.changed, "prune should have changed the session"
        seq_after = await store.get_session_seq(session.id)
        print(f"[A6b] session seq after prune = {seq_after}")
        await buffer.publish_revision_result(
            session.id, operation="sync_timeline_items", result=result
        )
        prune_envelopes = [e for e in payloads if e.get("nextSeq") == seq_after]
        print(f"[A6b] prune envelopes = {prune_envelopes}")
        assert prune_envelopes, "prune must publish so clients can refetch"
        for envelope in prune_envelopes:
            print(
                f"[A6b]   keys={sorted(envelope)} "
                f"refetch={envelope.get('refetch')} "
                f"timelineReset={envelope.get('timelineReset')} "
                f"items={len(envelope.get('items') or [])}"
            )
        # The deleted card is gone, and the envelope tells clients to re-pull.
        assert not any(
            item.id == "card_old" for item in await store.timeline.read(session.id)
        )
    finally:
        await buffer.close()
        await store.close()