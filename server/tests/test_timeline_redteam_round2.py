"""The second-round red-team findings on the live/history identity + order fix.

The first round pinned the *semantics* of the fix (a deletion is stated, a twin
never takes part, an in-batch slot is never reused). This round pins the three
things the second review found still open:

1. The in-batch corrector became *over*-blocking: ``extra_occupied`` was not
   reduced by the group's own slots, so an in-batch broken group could never be
   repaired in place and was pushed to the end of the session instead.
2. A failed ``CREATE INDEX CONCURRENTLY`` leaves an index that ``pg_indexes``
   reports as present but the planner ignores; the migration's idempotency
   check must not treat it as "already built".
3. The runtime backfill must stay cheap (only NULL rows) and must survive a
   payload that is not JSON.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from loguru import logger as loguru_logger
from sqlalchemy import text
from test_timeline_intra_message_order_paths import (
    _store_with_session,
    _to_stored,
    message_input,
    reasoning_input,
)
from test_timeline_message_identity import _rows_by_id, _seed_row

from agent_server.core.timeline import TimelineBatchWriteResult
from agent_server.infra.repositories.timeline import (
    TimelineRepositoryMixin,
    _intra_message_kind,
)

# ---------------------------------------------------------------------------
# Finding ③: an in-batch broken group is repaired IN PLACE.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_in_batch_broken_group_is_repaired_in_place(tmp_path) -> None:
    """A dense session must not push a corrected group to the end.

    The live path writes a message's body row and then its reasoning row, so a
    broken group routinely arrives entirely inside one flush. Its two slots are
    free for it to reuse — nothing else holds them — so the correction must
    swap the two rows in place rather than relocate the message to the tail of
    the conversation (the pre-round-2 behaviour: ``extra_occupied`` blocked the
    group's own in-batch slots, the in-place run was unreachable, and every
    such group fell back to a fresh block above the session's high-water mark).
    """

    store, session = await _store_with_session(tmp_path)
    try:
        # A dense prefix: slots 1..6 taken by unrelated, healthy messages.
        for index in range(1, 7):
            await _seed_row(
                store,
                session.id,
                message_input(
                    session.id, f"old_{index}", native_item_id=f"old_{index}",
                    order_seq=0,
                ),
                order_seq=index,
                updated_seq=index,
            )
        before_high_water = max(
            row.orderSeq for row in await store.timeline.read(session.id)
        )
        assert before_high_water == 6

        # One flush carries both rows of a broken group: body first, reasoning
        # second — exactly the shape the live writer produces.
        body = _to_stored(
            store,
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=0),
            order_seq=7,
            updated_seq=7,
        )
        reason = _to_stored(
            store,
            reasoning_input(session.id, "tl_reason", native_item_id="n1", order_seq=0),
            order_seq=8,
            updated_seq=8,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[body, reason],
        )

        rows = await _rows_by_id(store, session.id)
        assert rows["tl_reason"].orderSeq < rows["tl_msg"].orderSeq
        # In place: the group reused its own two slots, so the session's
        # high-water mark did not move.
        assert rows["tl_msg"].orderSeq == 8
        assert rows["tl_reason"].orderSeq == 7
        assert max(row.orderSeq for row in rows.values()) == 8
    finally:
        await store.close()


@pytest.mark.anyio
async def test_in_batch_group_never_lands_on_an_unrelated_in_batch_slot(
    tmp_path,
) -> None:
    """The other half of the same fix: a FOREIGN in-batch slot stays blocked.

    Subtracting the group's own slots from ``extra_occupied`` must not hand an
    unrelated row's slot to a corrected group — that is the collision the term
    exists to prevent. Here the group's own slots are non-adjacent, so the
    in-place run fails and the fallback block must still avoid the unrelated
    row sitting between them.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        for index in (1, 4):
            await _seed_row(
                store,
                session.id,
                message_input(
                    session.id, f"old_{index}", native_item_id=f"old_{index}",
                    order_seq=0,
                ),
                order_seq=index,
                updated_seq=index,
            )
        # One flush: the broken group straddles the unrelated new row (2 and 5,
        # with n2's body allocated the slot in between).
        body = _to_stored(
            store,
            message_input(session.id, "tl_msg", native_item_id="n1", order_seq=0),
            order_seq=2,
            updated_seq=2,
        )
        unrelated = _to_stored(
            store,
            message_input(session.id, "tl_other", native_item_id="n2", order_seq=0),
            order_seq=3,
            updated_seq=3,
        )
        reason = _to_stored(
            store,
            reasoning_input(session.id, "tl_reason", native_item_id="n1", order_seq=0),
            order_seq=5,
            updated_seq=5,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[body, unrelated, reason],
        )
        rows = await store.timeline.read(session.id)
        slots = [row.orderSeq for row in rows]
        assert len(slots) == len(set(slots)), f"duplicate order_seq: {sorted(slots)}"
        by_id = {row.id: row for row in rows}
        assert by_id["tl_reason"].orderSeq < by_id["tl_msg"].orderSeq
        assert by_id["tl_other"].orderSeq == 3  # untouched, not borrowed
    finally:
        await store.close()


def test_free_slot_run_refuses_a_run_above_its_ceiling() -> None:
    """The bound is on the RESULT, not on how far the scan walks.

    ``occupation`` empty and ``ceiling == start`` means the requested run would
    end past the highest slot in play; the helper must decline rather than
    return a run that collides with an in-flight row the caller did not put in
    ``occupation``.
    """

    assert TimelineRepositoryMixin._free_slot_run(
        start=9, count=2, occupation=set(), ceiling=9
    ) is None
    assert TimelineRepositoryMixin._free_slot_run(
        start=9, count=2, occupation=set(), ceiling=10
    ) == [9, 10]
    # A gap below the ceiling is still usable.
    assert TimelineRepositoryMixin._free_slot_run(
        start=2, count=2, occupation={3}, ceiling=5
    ) == [4, 5]
    assert TimelineRepositoryMixin._free_slot_run(
        start=0, count=2, occupation=set(), ceiling=5
    ) is None


# ---------------------------------------------------------------------------
# Finding ①: a huge deletion degrades to refetch instead of a giant envelope.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_large_incremental_deletion_is_a_refetch_not_a_payload(tmp_path) -> None:
    """An incremental (non-snapshot) writer that removed thousands of rows must
    not list every id — the envelope states the refetch signal instead."""

    from test_timeline_write_buffer import create_buffer

    store, broker, buffer, _connector, session = await create_buffer(tmp_path)
    payloads: list[dict[str, Any]] = []

    async def record(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = record  # type: ignore[method-assign]
    try:
        big = tuple(f"row_{index}" for index in range(201))
        await buffer.publish_revision_result(
            session.id,
            operation="sync_timeline_items",
            result=TimelineBatchWriteResult(items=(), changed=True, deleted=big),
        )
        assert payloads
        envelope = payloads[-1]
        assert envelope.get("refetch") is True
        assert "deleted" not in envelope
    finally:
        await buffer.close()
        await store.close()


@pytest.mark.anyio
async def test_snapshot_replacement_carries_the_new_timeline_not_deletions(
    tmp_path,
) -> None:
    """A ``replace_timeline_snapshot`` envelope states the complete new
    timeline (``timelineReset`` + ``items``, empty included) — never a bare
    ``refetch`` derived from the rows the new snapshot omits. Downgrading that
    to refetch would strand the client on the refetch path and suppress the
    empty ``timeline.snapshot`` it needs to clear the view (a regression this
    test pins)."""

    from test_timeline_write_buffer import create_buffer

    store, broker, buffer, _connector, session = await create_buffer(tmp_path)
    payloads: list[dict[str, Any]] = []

    async def record(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = record  # type: ignore[method-assign]
    try:
        # An empty snapshot that removed the whole session.
        await buffer.publish_revision_result(
            session.id,
            operation="replace_timeline_snapshot",
            result=TimelineBatchWriteResult(
                items=(), changed=True, deleted=("old_1", "old_2")
            ),
        )
        assert payloads
        envelope = payloads[-1]
        assert envelope.get("timelineReset") is True
        assert envelope.get("items") == []
        assert "refetch" not in envelope
        assert "deleted" not in envelope
    finally:
        await buffer.close()
        await store.close()


# ---------------------------------------------------------------------------
# Finding ⑤: the runtime backfill is cheap and total.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_runtime_backfill_only_scans_null_rows(tmp_path) -> None:
    """A payload with no itemId or invalid JSON must not abort the pass, an
    already-filled row must not be rewritten, and only NULL rows are read."""

    store, session = await _store_with_session(tmp_path)
    try:
        async with store.engine.begin() as conn:
            await conn.execute(
                text(
                    "INSERT INTO timeline_items "
                    "(session_id, id, type, status, role, order_seq, updated_seq, "
                    " native_item_id, payload_json) VALUES "
                    "(:s, 'ok', 'message', 'done', 'assistant', 1, 1, NULL, "
                    " '{\"source\":{\"itemId\":\"N-ok\"}}'), "
                    "(:s, 'missing', 'message', 'done', 'assistant', 2, 2, NULL, "
                    " '{\"source\":{}}'), "
                    "(:s, 'broken', 'message', 'done', 'assistant', 3, 3, NULL, "
                    " 'not json at all'), "
                    "(:s, 'kept', 'message', 'done', 'assistant', 4, 4, 'N-kept', "
                    " '{\"source\":{\"itemId\":\"N-other\"}}')"
                ),
                {"s": session.id},
            )

        assert await store.backfill_native_item_ids() == 1

        async with store.engine.connect() as conn:
            values = {
                row[0]: row[1]
                for row in (
                    await conn.execute(
                        text(
                            "SELECT id, native_item_id FROM timeline_items "
                            "WHERE session_id = :s"
                        ),
                        {"s": session.id},
                    )
                ).all()
            }
        assert values["ok"] == "N-ok"
        assert values["missing"] is None  # no itemId -> stays NULL, no crash
        assert values["broken"] is None  # invalid JSON -> stays NULL, no crash
        assert values["kept"] == "N-kept"  # filled row untouched
        # Idempotent: nothing left to do.
        assert await store.backfill_native_item_ids() == 0
    finally:
        await store.close()


@pytest.mark.anyio
async def test_role_tripwire_warns_without_touching_the_rows(tmp_path) -> None:
    """One native id under two roles is a Runtime anomaly: it is surfaced, and
    the role-aware key deliberately keeps both rows rather than merging them."""

    store, session = await _store_with_session(tmp_path)
    captured: list[str] = []
    sink_id = loguru_logger.add(
        lambda message: captured.append(str(message)), level="WARNING"
    )
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "reply", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        user_turn = message_input(session.id, "prompt", native_item_id="X", order_seq=2)
        await _seed_row(
            store,
            session.id,
            user_turn.model_copy(update={"role": "user"}),
            order_seq=2,
            updated_seq=2,
        )

        await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "reply", native_item_id="X", order_seq=1)],
        )

        assert any("spans multiple roles" in message for message in captured), captured
        rows = await _rows_by_id(store, session.id)
        assert {"reply", "prompt"} <= set(rows)
    finally:
        loguru_logger.remove(sink_id)
        await store.close()


def test_classifier_is_protocol_shaped_not_provider_named() -> None:
    """The reasoning classifier keys on the protocol shape, so a Runtime that
    spells its thinking rows the same way is covered without a code change."""

    assert _intra_message_kind("system", {"kind": "reasoning"}) == "reasoning"
    assert _intra_message_kind("system", {"kind": "thinking"}) is None
    assert _intra_message_kind("message", None) == "message"


# ---------------------------------------------------------------------------
# Finding C-R2: the startup pass repairs stored order with NO write to trigger.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_startup_pass_repairs_stored_order_without_a_write(tmp_path) -> None:
    """A group already stored body-first, never written again, is healed by the
    startup sweep alone — the write-path corrector can never reach it."""

    store, session = await _store_with_session(tmp_path)
    try:
        # Stored broken: body@5, reasoning@6 (both durable, no in-flight write).
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id="X", order_seq=5),
            order_seq=5,
            updated_seq=5,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(session.id, "rsn", native_item_id="X", order_seq=6),
            order_seq=6,
            updated_seq=6,
        )
        rows = await _rows_by_id(store, session.id)
        assert rows["rsn"].orderSeq > rows["body"].orderSeq  # broken to start

        moved = await store.repair_intra_message_order()

        assert moved > 0
        rows = await _rows_by_id(store, session.id)
        assert rows["rsn"].orderSeq < rows["body"].orderSeq
        # Idempotent: a healthy session is untouched and moves nothing.
        assert await store.repair_intra_message_order() == 0
    finally:
        await store.close()


@pytest.mark.anyio
async def test_startup_pass_leaves_healthy_groups_untouched(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            reasoning_input(session.id, "rsn", native_item_id="X", order_seq=5),
            order_seq=5,
            updated_seq=5,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id="X", order_seq=6),
            order_seq=6,
            updated_seq=6,
        )
        before = {
            i: (v.orderSeq, v.updatedSeq)
            for i, v in (await _rows_by_id(store, session.id)).items()
        }
        assert await store.repair_intra_message_order() == 0
        after = {
            i: (v.orderSeq, v.updatedSeq)
            for i, v in (await _rows_by_id(store, session.id)).items()
        }
        assert after == before
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Finding A-1: a flush that removes a twin AND carries changed rows still
# advances the revision, so the publisher cannot skip the deletion envelope.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_buffered_delete_with_changed_rows_advances_the_revision(
    tmp_path,
) -> None:
    """The buffered write-buffer path's mixed case.

    The live accept path publishes a changed row at its own seq and marks that
    seq as ``published_through``; the durable session seq then equals the row's
    ``updatedSeq``. A later flush that converges a duplicate twin in the same
    batch computes ``accepted_watermark == row.seq`` (no change), so the ONLY
    thing that can move ``nextSeq`` past ``published_through`` is the deletion
    bump. Without it the publisher skips the whole envelope and the client never
    hears the deletion (no refetch, no gap). The unrelated new row is
    deliberately absent: this is the exact case the pure-heal bump must cover.
    """

    from test_timeline_intra_message_order_paths import _to_stored

    store, session = await _store_with_session(tmp_path)
    try:
        # Canonical live row for native X already published at the session's
        # durable seq, plus a stored twin of the same message.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "live_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "hist_1", native_item_id="X", order_seq=2),
            order_seq=2,
            updated_seq=2,
        )
        # The flush re-sends the canonical row at its already-published seq but
        # with changed content (a streaming update landing on the canonical id).
        # Equal updatedSeq + different content = a *changed* row whose
        # updatedSeq does NOT exceed the durable seq, so the accepted-watermark
        # write is a no-op and only the deletion bump can advance nextSeq.
        changed_row = _to_stored(
            store,
            message_input(
                session.id, "live_1", native_item_id="X", order_seq=1, text="v2"
            ),
            order_seq=1,
            updated_seq=1,
        )
        before_seq = await store.get_session_seq(session.id)

        result = await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[changed_row],
        )

        assert result.deleted == ("hist_1",)  # the twin was removed
        assert result.changed  # and a surviving row changed (the mixed case)
        # The changed row's own updatedSeq does NOT exceed the durable seq, so
        # the accepted-watermark write is a no-op — the only thing that can move
        # nextSeq is the deletion bump.
        assert max(item.updatedSeq for item in result.items) <= before_seq
        after_seq = await store.get_session_seq(session.id)
        # The deletion bump must move nextSeq past the changed rows' own seq —
        # otherwise the publisher's `nextSeq > published_through` gate stays shut.
        assert after_seq > before_seq
    finally:
        await store.close()
