"""The intra-message order invariant (v2_42).

A message's reasoning rows (``type == "system"`` with
``content.kind == "reasoning"``) and its body row (``type == "message"``)
share a Runtime native item id (``source.itemId``). They arrive from two
write paths and can end up stored with the body row sorting before its own
reasoning, so the client renders the reasoning below the answer. The server
enforces the fix in the *stored* order, at write time: every reasoning row of
a group sorts strictly before every message row of the same group.

These tests pin the repository-level corrector:

- it corrects both single-row upserts and one-shot sync batches;
- it is a strict corrector — an already-correct group is byte-identical after
  any later write, and re-applying it changes nothing;
- it never perturbs rows outside the corrected group and never leaves a
  duplicate ``order_seq`` in the session;
- rows with no native item id, and rows whose native item id has no sibling of
  the other kind, are untouched (codex lays out reasoning as its own item).
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import insert, select, update

from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import timeline_item_from_runtime_input
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.migrations import upgrade_database
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
            # The hash tracks the content, so a text edit is a real state
            # change and not the "unchanged" fast path.
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
                "itemType": "reasoning",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


async def _store_with_session(tmp_path: Any) -> tuple[Store, Any]:
    db_path = tmp_path / "timeline-intra-message.sqlite3"
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
    """Insert one row verbatim, bypassing the corrector (a pre-fix row).

    Also advances the session's revision high-water mark past ``updated_seq``.
    Production rows always take their ``updated_seq`` from the allocator
    (``_reserve_session_revisions``), which is monotonic; a raw insert that
    left the counter behind would let a later writer allocate a *lower*
    ``updated_seq`` than an existing row, and the upsert guard
    (``excluded.updated_seq >= existing.updated_seq``) would silently drop it.
    """

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


async def _assert_strict_reasoning_before_message(
    store: Store, session_id: str, native_item_id: str
) -> None:
    rows = [
        item
        for item in await store.timeline.read(session_id)
        if item.source.itemId == native_item_id
    ]
    reasoning = [
        item
        for item in rows
        if item.type == "system" and item.content.get("kind") == "reasoning"
    ]
    messages = [item for item in rows if item.type == "message"]
    assert reasoning and messages
    assert max(item.orderSeq for item in reasoning) < min(
        item.orderSeq for item in messages
    )


# ---------------------------------------------------------------------------
# D1 / D2: single-row writes, message first then reasoning, and the reverse.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_message_first_then_reasoning_sorts_reasoning_above(tmp_path) -> None:
    # D1
    store, session = await _store_with_session(tmp_path)
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(
                session.id, "tl_msg", native_item_id="native_1", order_seq=1
            ),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=2
            ),
        )

        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
    finally:
        await store.close()


@pytest.mark.anyio
async def test_reasoning_first_then_message_keeps_reasoning_above(tmp_path) -> None:
    # D2: the reverse insertion order is already correct and must stay correct.
    store, session = await _store_with_session(tmp_path)
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=1
            ),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(
                session.id, "tl_msg", native_item_id="native_1", order_seq=2
            ),
        )

        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D3: both rows in one sync batch (message listed first).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_single_sync_batch_message_listed_first_sorts_reasoning_above(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(
                    session.id, "tl_msg", native_item_id="native_1", order_seq=2
                ),
                reasoning_input(
                    session.id, "tl_reason", native_item_id="native_1", order_seq=1
                ),
            ],
        )

        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D4: the production broken shape, then a correcting write.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_correcting_write_repairs_pre_existing_broken_group(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # The production shape: the message row sorts before its own reasoning.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=0
            ),
            order_seq=5,
            updated_seq=2,
        )
        rows = await _rows_by_id(store, session.id)
        assert rows["tl_msg"].orderSeq < rows["tl_reason"].orderSeq

        # A correcting write of the reasoning row (a new state, so it is not
        # the unchanged fast path) must restore the invariant.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id,
                "tl_reason",
                native_item_id="native_1",
                order_seq=0,
                text="revised reasoning",
            ),
        )

        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D5: no collateral — unrelated rows keep their order, no duplicate order_seq.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_correction_does_not_touch_unrelated_rows(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=1),
                # An unrelated message with its own (correct) reasoning.
                message_input(session.id, "tl_other_msg", native_item_id="native_2", order_seq=2),
                reasoning_input(
                    session.id, "tl_other_reason", native_item_id="native_2", order_seq=3
                ),
            ],
        )
        before = await _rows_by_id(store, session.id)
        unrelated = {i: before[i] for i in ("tl_other_msg", "tl_other_reason")}
        unrelated_fingerprints = {
            i: _fingerprint(item) for i, item in unrelated.items()
        }

        # Break native_1 and correct it.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=0
            ),
        )
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")

        after = await _rows_by_id(store, session.id)
        # The unrelated group is byte-identical.
        for item_id, fingerprint in unrelated_fingerprints.items():
            assert _fingerprint(after[item_id]) == fingerprint
        # No session row shares an order_seq with another.
        order_seqs = [item.orderSeq for item in after.values()]
        assert len(order_seqs) == len(set(order_seqs))
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D6 / D8: singleton groups and rows without a native item id are untouched.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_singleton_groups_are_byte_identical(tmp_path) -> None:
    # D6
    store, session = await _store_with_session(tmp_path)
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=1),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_2", order_seq=2
            ),
        )
        before = {
            i: _fingerprint(item) for i, item in (await _rows_by_id(store, session.id)).items()
        }

        # An unrelated write must not touch either singleton.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_new", native_item_id="native_3", order_seq=3),
        )

        after = await _rows_by_id(store, session.id)
        assert _fingerprint(after["tl_msg"]) == before["tl_msg"]
        assert _fingerprint(after["tl_reason"]) == before["tl_reason"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_rows_without_native_item_id_are_untouched(tmp_path) -> None:
    # D8
    store, session = await _store_with_session(tmp_path)
    try:
        # The broken shape again (message before reasoning), but with no native
        # item id: the corrector has nothing to group on and must not fire, so
        # the broken order survives verbatim. Seeded with single-row upserts so
        # the sync loop's own order normalization does not interfere.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_msg", native_item_id=None, order_seq=1),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(session.id, "tl_reason", native_item_id=None, order_seq=2),
        )

        rows = await _rows_by_id(store, session.id)
        assert rows["tl_msg"].orderSeq == 1
        assert rows["tl_reason"].orderSeq == 2
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D7: two reasoning rows keep their relative order, both before the message.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_two_reasoning_blocks_keep_relative_order(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                # message at 1, reasoning blocks at 2 and 3: broken (max
                # reasoning 3 > message 1) even though the blocks are ordered.
                message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=1),
                reasoning_input(
                    session.id, "tl_r0", native_item_id="native_1", order_seq=2, block_index=0
                ),
                reasoning_input(
                    session.id, "tl_r1", native_item_id="native_1", order_seq=3, block_index=1
                ),
            ],
        )

        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        rows = await _rows_by_id(store, session.id)
        assert rows["tl_r0"].orderSeq < rows["tl_r1"].orderSeq
        assert rows["tl_r1"].orderSeq < rows["tl_msg"].orderSeq
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Constraint 1: strict corrector — a correct group is byte-identical after a
# later, unrelated write, and re-applying the correction is a no-op.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_correct_group_is_byte_identical_after_unrelated_write(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                reasoning_input(session.id, "tl_reason", native_item_id="native_1", order_seq=1),
                message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=2),
            ],
        )
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        before = {
            i: _fingerprint(item) for i, item in (await _rows_by_id(store, session.id)).items()
        }

        # An unrelated new item that touches the session must not perturb it.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_new", native_item_id="native_9", order_seq=50),
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "tl_new2", native_item_id="native_8", order_seq=51)],
        )

        after = await _rows_by_id(store, session.id)
        assert _fingerprint(after["tl_reason"]) == before["tl_reason"]
        assert _fingerprint(after["tl_msg"]) == before["tl_msg"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_correction_is_idempotent(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=1),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=2
            ),
        )
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        after_first = {
            i: _fingerprint(item) for i, item in (await _rows_by_id(store, session.id)).items()
        }

        # Re-run the corrector via a real state change of the reasoning row
        # (a new content, so it is not the unchanged fast path): the already
        # correct group must stay put and the message must not move.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=0, text="v2"
            ),
        )

        after_second = await _rows_by_id(store, session.id)
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        assert after_second["tl_msg"].orderSeq == after_first["tl_msg"][0]
        assert after_second["tl_reason"].orderSeq == after_first["tl_reason"][0]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Constraint 2: cross-runtime — codex lays reasoning out as its own native
# item, so no group with both kinds exists and nothing is ever reordered.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_cross_runtime_distinct_native_ids_are_untouched(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                reasoning_input(
                    session.id, "tl_reason", native_item_id="reason_native", order_seq=20
                ),
                message_input(
                    session.id, "tl_msg", native_item_id="message_native", order_seq=21
                ),
            ],
        )
        before = {
            i: _fingerprint(item) for i, item in (await _rows_by_id(store, session.id)).items()
        }
        # Distinct native ids: each is a singleton group, so the corrector never
        # fires and the original order is preserved verbatim.
        assert before["tl_reason"][0] == 20
        assert before["tl_msg"][0] == 21

        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "tl_new", native_item_id="other", order_seq=22),
        )

        after = await _rows_by_id(store, session.id)
        assert _fingerprint(after["tl_reason"]) == before["tl_reason"]
        assert _fingerprint(after["tl_msg"]) == before["tl_msg"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D9/D10/D11: the repack keeps the group IN PLACE when free slots exist at
# its own position, falls back to a fresh tail block when they do not, and
# every moved sibling carries a fresh updated_seq (the incremental stream
# must deliver the move).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_correction_keeps_group_in_place_when_slots_free(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Neighbourhood: 1,2 taken by an unrelated row; the broken group sits
        # at 3 (message) and 4 (reasoning); 5 is free so an in-place run
        # exists at the group's own position [4,5] -> reasoning 4, message 5.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_head", native_item_id="head", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=3),
            order_seq=3,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=4
            ),
            order_seq=4,
            updated_seq=3,
        )
        before = await _rows_by_id(store, session.id)

        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id,
                "tl_reason",
                native_item_id="native_1",
                order_seq=4,
                text="revised reasoning",
            ),
        )

        after = await _rows_by_id(store, session.id)
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        # IN PLACE: the group did not jump to the session tail. The free run
        # starts at the group's own lowest slot (3), so reasoning takes 3 and
        # the body takes 4 — the group keeps its neighbourhood rather than
        # being re-homed at 100+.
        assert after["tl_reason"].orderSeq == 3
        assert after["tl_msg"].orderSeq == 4
        assert after["tl_head"].orderSeq == before["tl_head"].orderSeq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_correction_falls_back_to_tail_block_when_no_gap(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # The broken group's two rows are NON-adjacent: message at 3, reasoning
        # at 6, with 4 and 5 held by unrelated rows. The group's own slots
        # {3,6} do not form a run, and 4/5 are taken, so no in-place run fits.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=3),
            order_seq=3,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_wall_1", native_item_id="w1", order_seq=4),
            order_seq=4,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_wall_2", native_item_id="w2", order_seq=5),
            order_seq=5,
            updated_seq=3,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id,
                "tl_reason",
                native_item_id="native_1",
                order_seq=6,
            ),
            order_seq=6,
            updated_seq=4,
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id,
                "tl_reason",
                native_item_id="native_1",
                order_seq=6,
                text="revised reasoning",
            ),
        )
        rows = await _rows_by_id(store, session.id)
        await _assert_strict_reasoning_before_message(store, session.id, "native_1")
        # FALLBACK: with no in-place run available the group lands above the
        # session's previous maximum (6) as a fresh contiguous block.
        assert rows["tl_reason"].orderSeq > 6
        assert rows["tl_msg"].orderSeq == rows["tl_reason"].orderSeq + 1
        assert rows["tl_wall_1"].orderSeq == 4
        assert rows["tl_wall_2"].orderSeq == 5
    finally:
        await store.close()


@pytest.mark.anyio
async def test_moved_sibling_gets_fresh_updated_seq(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "tl_msg", native_item_id="native_1", order_seq=3),
            order_seq=3,
            updated_seq=10,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "tl_reason", native_item_id="native_1", order_seq=4
            ),
            order_seq=4,
            updated_seq=11,
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=reasoning_input(
                session.id,
                "tl_reason",
                native_item_id="native_1",
                order_seq=4,
                text="revised reasoning",
            ),
        )
        rows = await _rows_by_id(store, session.id)
        # The moved message sibling must advance past its stored updated_seq
        # (10): the incremental stream (list_since) keys on updated_seq, so a
        # move written back with a stale seq would never reach online clients.
        assert rows["tl_msg"].updatedSeq > 10
        # And the correction must be visible through the since-stream itself.
        since_rows = await store.list_timeline_since(
            session_id=session.id, after_seq=11, limit=10
        )
        since_ids = {item.id for item in since_rows[0]}
        assert "tl_msg" in since_ids
    finally:
        await store.close()
