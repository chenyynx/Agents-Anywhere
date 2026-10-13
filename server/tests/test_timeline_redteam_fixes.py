"""The red-team findings on the live/history identity + order fix.

Each test pins one finding so the fix cannot silently regress:

1. A converged duplicate removal must be *stated*, not silent — the writer
   bumps the session and returns the removed ids.
2. The set a writer publishes must never contain a row it just removed, and a
   removed twin must never be moved by the order corrective.
3. A broken group corrected in the same batch as an unrelated new row must not
   be handed that row's ``order_seq`` (keyset pagination would then drop a row).
4. (migration transaction/locking — exercised by test_database_migrations.)
5. A row whose ``native_item_id`` was not carried by the migration is refilled
   by the runtime backfill, and the classifier covers the shipped Runtime
   shapes.
"""

from __future__ import annotations

from typing import Any

import pytest
from sqlalchemy import text
from test_timeline_message_identity import (
    _rows_by_id,
    _seed_row,
    _store_with_session,
    message_input,
    reasoning_input,
)

from agent_server.core.timeline import native_item_id_from_payload
from agent_server.infra.repositories.timeline import _intra_message_kind

# ---------------------------------------------------------------------------
# Fix 1 + 3c: a pure heal (unchanged content, twin removed) is delivered.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_pure_heal_removes_twin_bumps_session_and_reports_deletion(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # A canonical live row and a stored twin, byte-identical content, so the
        # incoming write is the "unchanged" fast path.
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
        before_seq = await store.get_session_seq(session.id)
        before = await _rows_by_id(store, session.id)
        assert set(before) == {"live_1", "hist_1"}

        result = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "hist_1", native_item_id="X", order_seq=2),
        )

        after = await _rows_by_id(store, session.id)
        assert set(after) == {"live_1"}
        # The deletion is stated on the result (the publisher turns it into a
        # `deleted` field), and the session advanced so a refetch reaches a
        # client holding the removed id.
        assert result.deleted == ("hist_1",)
        assert await store.get_session_seq(session.id) > before_seq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_sync_pure_heal_reports_deletion(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
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
        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "hist_1", native_item_id="X", order_seq=2)],
        )
        assert result.deleted == ("hist_1",)
        assert set(await _rows_by_id(store, session.id)) == {"live_1"}
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Fix 2 + 3a/3b: a removed twin is never ordered, moved, or published.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_twin_is_not_moved_or_published(tmp_path) -> None:
    """A broken group plus its own duplicate: the twin takes no part.

    The group is reasoning@3 / body@2 (broken). A stored twin of the body
    (different id, same itemId) must not be counted as a second body row, moved
    to a fresh slot, or returned to the publisher.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id="X", order_seq=2),
            order_seq=2,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(session.id, "rsn", native_item_id="X", order_seq=3),
            order_seq=3,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "twin", native_item_id="X", order_seq=9),
            order_seq=9,
            updated_seq=3,
        )

        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "body", native_item_id="X", order_seq=2, text="b2"),
                reasoning_input(
                    session.id, "rsn", native_item_id="X", order_seq=3, text="r2"
                ),
            ],
        )
        after = await _rows_by_id(store, session.id)
        assert "twin" not in after  # removed
        assert "twin" not in {item.id for item in result.items}  # not published
        assert "twin" in result.deleted
        rows = list(after.values())
        reasoning = [i for i in rows if i.type == "system"]
        bodies = [i for i in rows if i.type == "message"]
        assert reasoning and bodies
        assert max(i.orderSeq for i in reasoning) < min(i.orderSeq for i in bodies)
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Fix 2: an unrelated in-batch row's slot is never handed to a corrected group.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_batch_new_row_slot_is_not_reused_by_a_corrected_group(
    tmp_path,
) -> None:
    """A brand-new unrelated row is allocated the next slot in the same batch;
    a broken group corrected in that batch must not land on it.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        # A dense neighbourhood: slots 1..2 taken, the broken group at 1/2.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(session.id, "rsn", native_item_id="X", order_seq=2),
            order_seq=2,
            updated_seq=2,
        )
        # One batch: correct the group AND add a brand-new unrelated message.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "body", native_item_id="X", order_seq=1, text="b2"),
                reasoning_input(session.id, "rsn", native_item_id="X", order_seq=2, text="r2"),
                message_input(session.id, "new", native_item_id="Y", order_seq=3),
            ],
        )
        rows = await store.timeline.read(session.id)
        slots = [i.orderSeq for i in rows]
        assert len(slots) == len(set(slots)), f"duplicate order_seq: {sorted(slots)}"
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Fix 5: NULL native_item_id backfill, role tripwire, classifier coverage.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_runtime_backfill_refills_null_rows(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Insert a row with native_item_id left NULL, as an older worker would.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "m1", native_item_id="N1", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        async with store.engine.begin() as conn:
            await conn.execute(
                text(
                    "UPDATE timeline_items SET native_item_id = NULL "
                    "WHERE session_id = :s AND id = 'm1'"
                ),
                {"s": session.id},
            )
        refilled = await store.backfill_native_item_ids()
        assert refilled == 1
        async with store.engine.connect() as conn:
            value = (
                await conn.execute(
                    text(
                        "SELECT native_item_id FROM timeline_items "
                        "WHERE session_id = :s AND id = 'm1'"
                    ),
                    {"s": session.id},
                )
            ).scalar()
        assert value == "N1"
    finally:
        await store.close()


def test_payload_parser_is_total() -> None:
    assert native_item_id_from_payload('{"source":{"itemId":"A"}}') == "A"
    assert native_item_id_from_payload("not json") is None
    assert native_item_id_from_payload("[]") is None
    assert native_item_id_from_payload('{"source":null}') is None
    assert native_item_id_from_payload('{"source":{"itemId":123}}') is None
    assert native_item_id_from_payload('{"source":{"itemId":""}}') is None


def test_classifier_covers_shipped_runtime_shapes() -> None:
    # Claude and Codex both store reasoning as system + kind=reasoning.
    assert _intra_message_kind("system", {"kind": "reasoning"}) == "reasoning"
    # A body row is a message row.
    assert _intra_message_kind("message", {"kind": "markdown"}) == "message"
    # Other system kinds / tools are out of scope.
    assert _intra_message_kind("system", {"kind": "notice"}) is None
    assert _intra_message_kind("tool", {"kind": "tool_result"}) is None
    assert _intra_message_kind("marker", {"kind": "compact"}) is None


# ---------------------------------------------------------------------------
# Fix 1 (delivery): a deletion reaches the client envelope.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_deletion_is_stated_in_the_published_envelope(tmp_path) -> None:
    """A removal with no surviving item must be published as ``deleted`` (and,
    for a deletion-only result, force a refetch) — otherwise a client holding
    the removed id keeps rendering the duplicate.
    """

    import json

    from test_timeline_write_buffer import create_buffer

    from agent_server.core.timeline import TimelineBatchWriteResult

    store, broker, buffer, _connector, session = await create_buffer(tmp_path)
    payloads: list[dict[str, Any]] = []

    async def record(_session_id: str, message: str) -> None:
        payloads.append(json.loads(message))

    broker.publish_message = record  # type: ignore[method-assign]
    try:
        await buffer.publish_revision_result(
            session.id,
            operation="sync_timeline_items",
            result=TimelineBatchWriteResult(
                items=(), changed=True, deleted=("ghost_row",)
            ),
        )
        assert payloads, "a deletion must publish something"
        envelope = payloads[-1]
        assert envelope["deleted"] == ["ghost_row"]
        assert envelope.get("refetch") is True
    finally:
        await buffer.close()
        await store.close()


@pytest.mark.anyio
async def test_startup_dedup_removes_existing_duplicate_groups(tmp_path) -> None:
    """A duplicate group never written again is still healed by the one-time
    sweep (the fix's write-path convergence would otherwise never see it)."""

    store, session = await _store_with_session(tmp_path)
    try:
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
        # A distinct message with its own id must survive.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "other", native_item_id="Y", order_seq=3),
            order_seq=3,
            updated_seq=3,
        )
        removed = await store.deduplicate_message_identities()
        assert removed == 1
        rows = await _rows_by_id(store, session.id)
        assert set(rows) == {"live_1", "other"}  # first-written kept
        # Idempotent.
        assert await store.deduplicate_message_identities() == 0
    finally:
        await store.close()
