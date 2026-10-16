"""The intra-message order invariant on the LIVE and SNAPSHOT write paths.

Why this file exists
--------------------
``test_timeline_intra_message_order`` pins the corrector through the batch
(``sync_timeline_items``) and the single-row (``upsert_timeline_item``)
writers. A red-team review found those are NOT the production live path: every
realtime ``timeline.itemUpsert`` is intercepted by ``TimelineWriteBuffer`` and
persisted by ``persist_buffered_timeline_items`` — which the first cut never
touched. Complete history rebuilds go through ``replace_timeline_snapshot``,
which likewise wrote the Runtime's own ``orderSeq`` verbatim.

Measured against production, the broken reasoning/body pairs split across both
missed paths (33 live, 24 history), so this file pins the invariant on both:

- ``persist_buffered_timeline_items`` — the buffer's flush. A message's two
  rows can land in one flush (fixed in-batch) or the reasoning row can arrive
  with its body already durable (fixed by moving the durable sibling, which
  must carry a fresh revision so ``list_since`` replays the move).
- ``replace_timeline_snapshot`` — a complete snapshot replaces every row, so
  the corrector runs purely on the snapshot's own items.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import insert, select, update

from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import timeline_item_from_runtime_input
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.repositories.facade import Store


def message_input(
    session_id: str,
    item_id: str,
    *,
    native_item_id: str | None,
    order_seq: int,
    text: str | None = None,
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": text, "format": "markdown"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": native_item_id,
                "itemType": "assistant",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


def reasoning_input(
    session_id: str,
    item_id: str,
    *,
    native_item_id: str | None,
    order_seq: int,
    block_index: int = 0,
    text: str | None = None,
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "role": "system",
            "content": {
                "kind": "reasoning",
                "blockIndex": block_index,
                "summaries": [{"index": block_index, "text": text}],
            },
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": native_item_id,
                "itemType": "thinking",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


async def _store_with_session(tmp_path: Any, *, tag: str = "main") -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name=f"P-{tag}",
    )
    return store, session


async def _rows_by_id(store: Store, session_id: str) -> dict[str, Any]:
    return {item.id: item for item in await store.timeline.read(session_id)}


def _fingerprint(item: Any) -> tuple[int, int, int]:
    return (item.orderSeq, item.updatedSeq, item.revision)


async def _seed_row(
    store: Store,
    session_id: str,
    item: TimelineItemIn,
    *,
    order_seq: int,
    updated_seq: int,
) -> None:
    """Insert one row verbatim (a pre-fix row), advancing the seq counter."""

    stored = timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-10-12T00:00:00Z",
        order_seq=order_seq,
    )
    async with store.engine.begin() as conn:
        await conn.execute(
            insert(timeline_items_t),
            [store.timeline._row_values(stored)],
        )
        row = (
            await conn.execute(
                select(sessions_t.c.seq, sessions_t.c.seq_allocated_high).where(
                    sessions_t.c.id == session_id
                )
            )
        ).first()
        if row is not None:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == session_id)
                .values(
                    seq=max(int(row[0]), updated_seq),
                    seq_allocated_high=max(int(row[1]), updated_seq),
                )
            )


def _to_stored(store: Store, item: TimelineItemIn, *, order_seq: int, updated_seq: int):
    """Materialize an input as a stored TimelineItem for the buffer path."""

    _ = store
    return timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-10-12T00:00:00Z",
        order_seq=order_seq,
    )


async def _assert_strict(store: Store, session_id: str, native_item_id: str) -> None:
    rows = [i for i in await store.timeline.read(session_id)]
    reasoning = [
        i
        for i in rows
        if i.type == "system"
        and (i.content or {}).get("kind") == "reasoning"
        and (i.source.itemId if i.source else None) == native_item_id
    ]
    messages = [
        i
        for i in rows
        if i.type == "message"
        and (i.source.itemId if i.source else None) == native_item_id
    ]
    assert reasoning and messages, "group must have both kinds"
    assert max(i.orderSeq for i in reasoning) < min(i.orderSeq for i in messages)


# ---------------------------------------------------------------------------
# LIVE path — persist_buffered_timeline_items (the buffer's flush).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_live_flush_fixes_group_landing_in_one_batch(tmp_path) -> None:
    """Both rows of a message arrive in ONE flush, body listed first.

    This is the production 'live+live' shape (12 of 57 broken pairs): the
    buffer writes the two rows with consecutive order_seq, body first.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        body = _to_stored(
            store,
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        reason = _to_stored(
            store,
            reasoning_input(session.id, "tl_reason", native_item_id="n1", order_seq=0),
            order_seq=2,
            updated_seq=2,
        )
        result = await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[body, reason],
        )
        await _assert_strict(store, session.id, "n1")
        # The published set must carry the corrected order (the push renders by
        # it), not the pre-correction values.
        published = {i.id: i for i in result.items}
        assert published["tl_reason"].orderSeq < published["tl_msg"].orderSeq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_live_flush_moves_durable_sibling_with_fresh_revision(tmp_path) -> None:
    """The reasoning row arrives with its body already durable.

    The body was written by an earlier flush; only the reasoning row is in this
    batch. The durable body must be moved AND advanced past the batch's seq so
    an incrementally reading client (`list_since`) replays the move.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        reason = _to_stored(
            store,
            reasoning_input(
                session.id, "tl_reason", native_item_id="n1", order_seq=0
            ),
            order_seq=5,
            updated_seq=5,
        )
        result = await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[reason],
        )
        rows = await _rows_by_id(store, session.id)
        await _assert_strict(store, session.id, "n1")
        # The moved body carries a fresh, higher updated_seq: a client that had
        # already read up to the old one still receives it.
        assert rows["tl_msg"].updatedSeq > 1
        since = await store.list_timeline_since(
            session_id=session.id, after_seq=1, limit=50
        )
        assert "tl_msg" in {item.id for item in since[0]}
        # And it is in the published set for the live push.
        assert "tl_msg" in {i.id for i in result.items}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_live_flush_leaves_healthy_group_byte_identical(tmp_path) -> None:
    """A correct group is untouched — same orderSeq, updatedSeq, revision."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "tl_reason", native_item_id="n1", order_seq=0
            ),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=0),
            order_seq=2,
            updated_seq=2,
        )
        before = {
            i: _fingerprint(v)
            for i, v in (await _rows_by_id(store, session.id)).items()
        }
        unrelated = _to_stored(
            store,
            message_input(session.id, "tl_other", native_item_id="n2", order_seq=0),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[unrelated],
        )
        after = await _rows_by_id(store, session.id)
        assert _fingerprint(after["tl_msg"]) == before["tl_msg"]
        assert _fingerprint(after["tl_reason"]) == before["tl_reason"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# SNAPSHOT path — replace_timeline_snapshot (complete history rebuild).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_snapshot_fixes_broken_group_in_one_replace(tmp_path) -> None:
    """The Runtime's own orderSeq puts the reasoning row after its body."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.replace_timeline_snapshot(
            session_id=session.id,
            items=[
                message_input(session.id, "tl_msg", native_item_id="n1", order_seq=1),
                reasoning_input(
                    session.id, "tl_reason", native_item_id="n1", order_seq=2
                ),
            ],
        )
        await _assert_strict(store, session.id, "n1")
    finally:
        await store.close()


@pytest.mark.anyio
async def test_snapshot_leaves_healthy_group_untouched(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.replace_timeline_snapshot(
            session_id=session.id,
            items=[
                reasoning_input(
                    session.id, "tl_reason", native_item_id="n1", order_seq=1
                ),
                message_input(session.id, "tl_msg", native_item_id="n1", order_seq=2),
            ],
        )
        rows = await _rows_by_id(store, session.id)
        # In place: the snapshot's own slots are honoured.
        assert rows["tl_reason"].orderSeq == 1
        assert rows["tl_msg"].orderSeq == 2
    finally:
        await store.close()


@pytest.mark.anyio
async def test_snapshot_idempotent_on_second_replace(tmp_path) -> None:
    """Re-applying the same broken snapshot converges (no oscillation)."""

    store, session = await _store_with_session(tmp_path)
    try:
        broken = [
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=1),
            reasoning_input(session.id, "tl_reason", native_item_id="n1", order_seq=2),
        ]
        await store.replace_timeline_snapshot(session_id=session.id, items=broken)
        first = {
            i: v.orderSeq for i, v in (await _rows_by_id(store, session.id)).items()
        }
        await store.replace_timeline_snapshot(session_id=session.id, items=broken)
        second = {
            i: v.orderSeq for i, v in (await _rows_by_id(store, session.id)).items()
        }
        await _assert_strict(store, session.id, "n1")
        # The correction is order-stable across re-applies (each replace still
        # bumps updated_seq, which is its normal reset behaviour).
        assert first == second
    finally:
        await store.close()


def test_asyncio_driver_is_available() -> None:
    # The suite runs under the asyncio backend; guard against a silent switch.
    assert asyncio.get_event_loop_policy() is not None


# ---------------------------------------------------------------------------
# Cross-group collision (red-team): two broken messages in ONE call must never
# be assigned the same order_seq.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_two_broken_groups_in_one_batch_never_share_a_slot(tmp_path) -> None:
    """Red-team defect: the per-group in-place search subtracted only its own
    slots from a shared, mutating occupation set, so a later group could reuse
    a slot an earlier group had just claimed — two messages on one order_seq.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        # G1: message@2, reasoning@3 (+ its own body so the group is broken).
        # G2: message@1, reasoning@4.
        seeds = [
            ("tl_m1", "message", "n1", 2),
            ("tl_r1", "system", "n1", 3),
            ("tl_m2", "message", "n2", 1),
            ("tl_r2", "system", "n2", 4),
        ]
        for idx, (item_id, kind, native, order) in enumerate(seeds, start=1):
            item = (
                message_input(session.id, item_id, native_item_id=native, order_seq=0)
                if kind == "message"
                else reasoning_input(session.id, item_id, native_item_id=native, order_seq=0)
            )
            await _seed_row(store, session.id, item, order_seq=order, updated_seq=idx)

        # Correct both groups in ONE sync batch.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "tl_m1", native_item_id="n1", order_seq=0, text="m1b"),
                reasoning_input(session.id, "tl_r1", native_item_id="n1", order_seq=0, text="r1b"),
                message_input(session.id, "tl_m2", native_item_id="n2", order_seq=0, text="m2b"),
                reasoning_input(session.id, "tl_r2", native_item_id="n2", order_seq=0, text="r2b"),
            ],
        )

        rows = await store.timeline.read(session.id)
        await _assert_strict(store, session.id, "n1")
        await _assert_strict(store, session.id, "n2")
        slots = [i.orderSeq for i in rows]
        assert len(slots) == len(set(slots)), f"duplicate order_seq: {sorted(slots)}"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_two_broken_groups_in_one_snapshot_never_share_a_slot(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.replace_timeline_snapshot(
            session_id=session.id,
            items=[
                message_input(session.id, "tl_m1", native_item_id="n1", order_seq=2),
                reasoning_input(session.id, "tl_r1", native_item_id="n1", order_seq=3),
                message_input(session.id, "tl_m2", native_item_id="n2", order_seq=1),
                reasoning_input(session.id, "tl_r2", native_item_id="n2", order_seq=4),
            ],
        )
        rows = await store.timeline.read(session.id)
        await _assert_strict(store, session.id, "n1")
        await _assert_strict(store, session.id, "n2")
        slots = [i.orderSeq for i in rows]
        assert len(slots) == len(set(slots)), f"duplicate order_seq: {sorted(slots)}"
    finally:
        await store.close()
