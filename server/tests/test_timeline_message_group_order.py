"""The message-group order invariant, ``RBT`` = reasoning, body, tools.

One assistant message can store three kinds of rows:

- **reasoning** — ``type == "system"`` with ``content.kind == "reasoning"``;
- **body** — ``type == "message"``;
- **tool** — ``type == "tool"``, one per ``tool_use`` block, each declaring the
  enclosing message id (``source.nativeMessageId``) and its index inside that
  message's content (``source.blockIndex``).

The stored ``order_seq`` is what a client keyset-paginates and renders by, and
the correct order (measured on 274/274 real messages) is ``RBT``: every
reasoning row, then the body, then the tool rows by ascending ``blockIndex``.
The pre-v2_42 corrector only guaranteed "reasoning before body"; this file pins
the extension that also places tool rows after the body and orders them by
their declared block index.

Hard rules these tests exercise:

- **strict / in-place** — a healthy group is byte-identical after any later
  write and re-applying the corrector is a no-op;
- **宁缺勿假 (never guess)** — a group with a tool row that declares no
  ``blockIndex`` is left byte-identical (zero writes): the target order is
  unknown and the corrector refuses to order by the untrustworthy arrival seq;
- **old rows untouched** — rows whose ``native_message_id`` is NULL (written
  before the connector declared it) behave exactly as they did before;
- **all four write paths + the startup scan** — single-row upsert, sync batch,
  the live buffer flush, the snapshot replace, and ``repair_intra_message_order``.
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
from agent_server.infra.repositories.facade import Store

MESSAGE_ID = "native_msg_1"


def message_input(
    session_id: str,
    item_id: str,
    *,
    native_item_id: str | None,
    order_seq: int,
    text: str | None = None,
) -> TimelineItemIn:
    """A body row. Its ``itemId`` *is* the message id (no ``nativeMessageId``)."""

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
    """A reasoning row. Its ``itemId`` *is* the message id."""

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


def tool_input(
    session_id: str,
    item_id: str,
    *,
    call_id: str,
    native_message_id: str | None,
    block_index: int | None,
    order_seq: int,
    status: str = "done",
    text: str | None = None,
) -> TimelineItemIn:
    """A tool row. Its ``itemId`` is the *call* id; the message id is separate."""

    text = text or item_id
    source: dict[str, Any] = {
        "runtime": "claude",
        "sessionId": "claude_ext_1",
        "itemId": call_id,
        "itemType": "tool_use",
    }
    if native_message_id is not None:
        source["nativeMessageId"] = native_message_id
    if block_index is not None:
        source["blockIndex"] = block_index
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": status,
            "role": "tool",
            "content": {
                "kind": "tool_result",
                "toolUseId": call_id,
                "text": text,
            },
            "source": source,
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
    """Insert one row verbatim (bypassing the corrector), advancing the counter."""

    stored = timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-10-14T00:00:00Z",
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


def _assert_rbt(
    rows: dict[str, Any],
    *,
    reasoning_ids: list[str],
    body_id: str,
    tool_ids_by_block: list[str],
) -> None:
    """Every reasoning row < the body < every tool row, tools by block index."""

    ordered = sorted(rows.values(), key=lambda item: item.orderSeq)
    kinds = [
        (
            "reason" if item.id in reasoning_ids
            else "body" if item.id == body_id
            else "tool"
        )
        for item in ordered
    ]
    assert kinds == ["reason"] * len(reasoning_ids) + ["body"] + ["tool"] * len(
        tool_ids_by_block
    ), [(item.id, item.orderSeq) for item in ordered]
    tool_order = [item.id for item in ordered if item.id in set(tool_ids_by_block)]
    assert tool_order == tool_ids_by_block, tool_order


# ---------------------------------------------------------------------------
# 1. RBT target order: reasoning + body + 2 tools, tools reversed on disk.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_tools_after_body_and_by_block_index(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Stored broken: body first, then the tool rows with blockIndex 1 and 0
        # in arrival order (blockIndex 1 lands before blockIndex 0).
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "reason", native_item_id=MESSAGE_ID, order_seq=0
            ),
            order_seq=5,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id,
                "tool_b1",
                call_id="call_b1",
                native_message_id=MESSAGE_ID,
                block_index=1,
                order_seq=0,
            ),
            order_seq=2,
            updated_seq=3,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id,
                "tool_b0",
                call_id="call_b0",
                native_message_id=MESSAGE_ID,
                block_index=0,
                order_seq=0,
            ),
            order_seq=3,
            updated_seq=4,
        )
        before = await _rows_by_id(store, session.id)
        assert before["body"].orderSeq < before["tool_b1"].orderSeq  # broken

        # A correcting write of the body (a new state, so not the no-op path).
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(
                session.id, "body", native_item_id=MESSAGE_ID, order_seq=0, text="v2"
            ),
        )

        rows = await _rows_by_id(store, session.id)
        _assert_rbt(
            rows,
            reasoning_ids=["reason"],
            body_id="body",
            tool_ids_by_block=["tool_b0", "tool_b1"],
        )
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 2a. Five calls stored in whole-group descending order (production shape).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_five_tool_calls_stored_descending_are_sorted_ascending(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # A body plus five tools whose stored order_seq puts call_04 first and
        # call_01 last, exactly the history-rebuild shape (481=call_04…).
        body_order = 100
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=body_order,
            updated_seq=1,
        )
        # blockIndex i -> item name tool_0i; stored in descending order 481..484+.
        for offset, block_index in enumerate([4, 3, 2, 1, 0]):
            await _seed_row(
                store,
                session.id,
                tool_input(
                    session.id,
                    f"tool_{block_index}",
                    call_id=f"call_{block_index}",
                    native_message_id=MESSAGE_ID,
                    block_index=block_index,
                    order_seq=0,
                ),
                order_seq=481 + offset,
                updated_seq=10 + offset,
            )

        moved = await store.repair_intra_message_order()
        assert moved > 0
        rows = await _rows_by_id(store, session.id)
        _assert_rbt(
            rows,
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_0", "tool_1", "tool_2", "tool_3", "tool_4"],
        )
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 2b. A pairwise inversion: call_00 stored after call_01.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_pairwise_inversion_is_swapped(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        # call_01 (blockIndex 1) stored BEFORE call_00 (blockIndex 0): inverted.
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id,
                "tool_01",
                call_id="call_01",
                native_message_id=MESSAGE_ID,
                block_index=1,
                order_seq=0,
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id,
                "tool_00",
                call_id="call_00",
                native_message_id=MESSAGE_ID,
                block_index=0,
                order_seq=0,
            ),
            order_seq=3,
            updated_seq=3,
        )

        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(
                    session.id, "body", native_item_id=MESSAGE_ID, order_seq=0, text="v2"
                )
            ],
        )

        rows = await _rows_by_id(store, session.id)
        _assert_rbt(
            rows,
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_00", "tool_01"],
        )
        # In place: the group reused its own slots [1..3].
        assert max(item.orderSeq for item in rows.values()) == 3
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 3. A tool row created only by its "done" frame (no running row ever stored).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_done_only_tool_rows_are_ordered_by_block_index(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # The running frames of these calls never landed; only the finished
        # rows exist, appended in completion order that reverses blockIndex.
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "done_2", call_id="c2",
                native_message_id=MESSAGE_ID, block_index=2, order_seq=0,
                status="done",
            ),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "done_1", call_id="c1",
                native_message_id=MESSAGE_ID, block_index=1, order_seq=0,
                status="done",
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "done_0", call_id="c0",
                native_message_id=MESSAGE_ID, block_index=0, order_seq=0,
                status="done",
            ),
            order_seq=3,
            updated_seq=3,
        )

        await store.repair_intra_message_order()

        rows = await _rows_by_id(store, session.id)
        assert [
            item.id
            for item in sorted(rows.values(), key=lambda i: i.orderSeq)
        ] == ["done_0", "done_1", "done_2"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 4. 宁缺勿假: a tool row missing blockIndex leaves the whole group untouched.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_group_with_a_tool_missing_block_index_is_left_byte_identical(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # A group that IS broken by RBT (its two declared tools are inverted:
        # blockIndex 1 before blockIndex 0), but one tool row declares no
        # blockIndex -> the target order is unknowable, so nothing may move.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_b1", call_id="c_b1",
                native_message_id=MESSAGE_ID, block_index=1, order_seq=0,
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_b0", call_id="c_b0",
                native_message_id=MESSAGE_ID, block_index=0, order_seq=0,
            ),
            order_seq=3,
            updated_seq=3,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_noindex", call_id="c_noindex",
                native_message_id=MESSAGE_ID, block_index=None, order_seq=0,
            ),
            order_seq=4,
            updated_seq=4,
        )
        before = {
            i: _fingerprint(v) for i, v in (await _rows_by_id(store, session.id)).items()
        }
        # The inversion among the declared tools is real: the group would be
        # reordered but for the undeclared sibling.
        assert before["tool_b1"][0] < before["tool_b0"][0]

        # Both corrector entry points must refuse to reorder the group. The
        # body row is the incoming write, so only its order stands; the tool
        # siblings must be fully byte-identical (no sibling was rewritten).
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(
                session.id, "body", native_item_id=MESSAGE_ID, order_seq=0, text="v2"
            ),
        )
        assert await store.repair_intra_message_order() == 0

        after = await _rows_by_id(store, session.id)
        assert after["body"].orderSeq == before["body"][0]
        for item_id in ("tool_b1", "tool_b0", "tool_noindex"):
            assert _fingerprint(after[item_id]) == before[item_id], item_id
        # Nothing was moved: the stored order is exactly what was seeded.
        assert [
            item.id for item in sorted(after.values(), key=lambda i: i.orderSeq)
        ] == ["body", "tool_b1", "tool_b0", "tool_noindex"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 5. Idempotent: repair once, then re-run is a no-op.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_correction_is_idempotent(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_1", call_id="c1",
                native_message_id=MESSAGE_ID, block_index=1, order_seq=0,
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_0", call_id="c0",
                native_message_id=MESSAGE_ID, block_index=0, order_seq=0,
            ),
            order_seq=3,
            updated_seq=3,
        )

        moved = await store.repair_intra_message_order()
        assert moved > 0
        first = {
            i: v.orderSeq for i, v in (await _rows_by_id(store, session.id)).items()
        }

        # Re-run: the strict corrector finds nothing broken.
        assert await store.repair_intra_message_order() == 0
        second = {
            i: v.orderSeq for i, v in (await _rows_by_id(store, session.id)).items()
        }
        assert first == second
        _assert_rbt(
            await _rows_by_id(store, session.id),
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_0", "tool_1"],
        )
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 6. A healthy group (with a tool row) is byte-identical after a later write.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_healthy_group_with_tool_is_byte_identical_after_unrelated_write(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                reasoning_input(
                    session.id, "reason", native_item_id=MESSAGE_ID, order_seq=1
                ),
                message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=2),
                tool_input(
                    session.id, "tool_0", call_id="c0",
                    native_message_id=MESSAGE_ID, block_index=0, order_seq=3,
                ),
                tool_input(
                    session.id, "tool_1", call_id="c1",
                    native_message_id=MESSAGE_ID, block_index=1, order_seq=4,
                ),
            ],
        )
        before = {
            i: _fingerprint(v) for i, v in (await _rows_by_id(store, session.id)).items()
        }

        # An unrelated write must not perturb the healthy group.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(
                session.id, "tl_other", native_item_id="native_other", order_seq=50
            ),
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_input(
                    session.id, "tl_new", call_id="cnew",
                    native_message_id="native_other", block_index=0, order_seq=51,
                )
            ],
        )

        after = await _rows_by_id(store, session.id)
        for item_id, fingerprint in before.items():
            assert _fingerprint(after[item_id]) == fingerprint, item_id
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 7. Old rows (native_message_id all NULL) behave exactly as before.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_legacy_rows_without_native_message_id_are_untouched(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Legacy tool rows: no nativeMessageId, so they resolve to their own
        # call id and form singleton groups — the RBT orderer never groups them
        # with the body, exactly as before this change.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "body", native_item_id=None, order_seq=1),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "legacy_tool", call_id="legacy_call",
                native_message_id=None, block_index=0, order_seq=2,
            ),
        )

        rows = await _rows_by_id(store, session.id)
        assert rows["body"].orderSeq == 1
        assert rows["legacy_tool"].orderSeq == 2
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# 8. All write paths + the startup scan.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_live_buffer_flush_orders_tools(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        body = timeline_item_from_runtime_input(
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            updated_seq=1,
            now="2026-10-14T00:00:00Z",
            order_seq=1,
        )
        tool_1 = timeline_item_from_runtime_input(
            tool_input(
                session.id, "tool_1", call_id="c1",
                native_message_id=MESSAGE_ID, block_index=1, order_seq=0,
            ),
            updated_seq=2,
            now="2026-10-14T00:00:00Z",
            order_seq=2,
        )
        tool_0 = timeline_item_from_runtime_input(
            tool_input(
                session.id, "tool_0", call_id="c0",
                native_message_id=MESSAGE_ID, block_index=0, order_seq=0,
            ),
            updated_seq=3,
            now="2026-10-14T00:00:00Z",
            order_seq=3,
        )
        result = await store.persist_buffered_timeline_items(
            session_id=session.id, items=[body, tool_1, tool_0]
        )
        _assert_rbt(
            await _rows_by_id(store, session.id),
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_0", "tool_1"],
        )
        published = {i.id: i for i in result.items}
        assert published["tool_0"].orderSeq < published["tool_1"].orderSeq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_snapshot_replace_orders_tools(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.replace_timeline_snapshot(
            session_id=session.id,
            items=[
                tool_input(
                    session.id, "tool_1", call_id="c1",
                    native_message_id=MESSAGE_ID, block_index=1, order_seq=1,
                ),
                message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=2),
                tool_input(
                    session.id, "tool_0", call_id="c0",
                    native_message_id=MESSAGE_ID, block_index=0, order_seq=3,
                ),
            ],
        )
        _assert_rbt(
            await _rows_by_id(store, session.id),
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_0", "tool_1"],
        )
    finally:
        await store.close()


@pytest.mark.anyio
async def test_startup_scan_orders_stored_tool_rows_without_a_write(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Stored out of order and never written again: only the sweep can heal it.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id=MESSAGE_ID, order_seq=0),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_1", call_id="c1",
                native_message_id=MESSAGE_ID, block_index=1, order_seq=0,
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "tool_0", call_id="c0",
                native_message_id=MESSAGE_ID, block_index=0, order_seq=0,
            ),
            order_seq=3,
            updated_seq=3,
        )

        moved = await store.repair_intra_message_order()
        assert moved > 0
        _assert_rbt(
            await _rows_by_id(store, session.id),
            reasoning_ids=[],
            body_id="body",
            tool_ids_by_block=["tool_0", "tool_1"],
        )
        # Idempotent.
        assert await store.repair_intra_message_order() == 0
    finally:
        await store.close()
