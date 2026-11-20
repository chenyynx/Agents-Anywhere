"""Intra-message order: the message's real block order wins over RBT.

pp 2026-11-19 production case: one assistant message emitted
``[thinking, Bash tool_use, trailing text]``. The v2_43 RBT invariant moved the
tool row below the body, the client's step-group rule broke at the body and the
Bash row rendered as a lone group above the next turn.

The server now keeps the declared absolute ``source.contentBlockIndex`` order
when every orderable row of the message carries it, and falls back to RBT when
any row omits it (old connectors/rows). These tests pin both levels plus the
strict-corrector behaviour (idempotent, no writes on a healthy group).
"""

from __future__ import annotations

from typing import Any

import pytest
from sqlalchemy import insert, select, update

from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import timeline_item_from_runtime_input
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.repositories.facade import Store
from session_fixtures import create_session_with_project

MESSAGE_ID = "msg_block_order_1"
TURN_ID = "turn_1"
EXTERNAL = "claude_ext_1"


def _source(**extra: Any) -> dict[str, Any]:
    source: dict[str, Any] = {
        "runtime": "claude",
        "sessionId": EXTERNAL,
        "turnId": TURN_ID,
    }
    source.update(extra)
    return source


def message_input(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    content_block_index: int | None,
    text: str | None = None,
    cbi_source: str | None = "message",
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
            "source": _source(
                itemId=MESSAGE_ID,
                itemType="assistant",
                contentBlockIndex=content_block_index,
                contentBlockIndexSource=cbi_source,
            ),
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


def reasoning_input(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    content_block_index: int | None,
    text: str | None = None,
    cbi_source: str | None = "message",
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "role": "system",
            "content": {"kind": "reasoning", "summaries": [{"index": 0, "text": text}]},
            "source": _source(
                itemId=MESSAGE_ID,
                itemType="thinking",
                contentBlockIndex=content_block_index,
                contentBlockIndexSource=cbi_source,
            ),
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


def tool_input(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    tool_block_index: int | None,
    content_block_index: int | None,
    text: str | None = None,
    cbi_source: str | None = "message",
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": "done",
            "role": "tool",
            "content": {"kind": "command", "outputText": text},
            "source": _source(
                itemId=f"call_{item_id}",
                itemType="tool_result",
                nativeMessageId=MESSAGE_ID,
                blockIndex=tool_block_index,
                contentBlockIndex=content_block_index,
                contentBlockIndexSource=cbi_source,
            ),
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id=EXTERNAL,
        project_name="P-block-order",
    )
    return store, session


def _stored(item: TimelineItemIn, *, order_seq: int, updated_seq: int):
    return timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-11-19T00:00:00Z",
        order_seq=order_seq,
    )


async def _seed_row(
    store: Store,
    session_id: str,
    item: TimelineItemIn,
    *,
    order_seq: int,
    updated_seq: int,
) -> None:
    """Insert one row verbatim (a pre-corrector row), advancing the seq."""

    stored = timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-11-19T00:00:00Z",
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


async def _order_by_id(store: Store, session_id: str) -> dict[str, int]:
    rows = await store.timeline.read(session_id)
    return {row.id: row.orderSeq for row in rows}


@pytest.mark.anyio
async def test_real_block_order_wins_over_rbt() -> None:
    """[thinking(0), tool(1), text(2)] stays in that order."""

    store, session = await _store_with_session()
    try:
        reasoning = _stored(
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0
            ),
            order_seq=1,
            updated_seq=1,
        )
        tool = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=1,
            ),
            order_seq=2,
            updated_seq=2,
        )
        body = _stored(
            message_input(
                session.id, "m", order_seq=2, content_block_index=2
            ),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[reasoning, tool, body]
        )
        order = await _order_by_id(store, session.id)
        assert order["r"] < order["t"] < order["m"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_missing_content_index_falls_back_to_rbt() -> None:
    """One row without contentBlockIndex keeps the legacy reasoning→body→tool."""

    store, session = await _store_with_session()
    try:
        reasoning = _stored(
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0
            ),
            order_seq=1,
            updated_seq=1,
        )
        tool = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=None,
            ),
            order_seq=2,
            updated_seq=2,
        )
        body = _stored(
            message_input(
                session.id, "m", order_seq=2, content_block_index=2
            ),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[reasoning, tool, body]
        )
        order = await _order_by_id(store, session.id)
        assert order["r"] < order["m"] < order["t"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_a_rewrite_without_the_index_keeps_the_stored_one() -> None:
    """A live frame rewrite must not strip the index history declared."""

    store, session = await _store_with_session()
    try:
        with_index = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=1,
            ),
            order_seq=1,
            updated_seq=1,
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=TimelineItemIn.model_validate(with_index.model_dump()),
        )
        without = tool_input(
            session.id,
            "t",
            order_seq=1,
            tool_block_index=0,
            content_block_index=None,
            text="live rewrite",
        )
        await store.upsert_timeline_item(session_id=session.id, item=without)
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndex == 1
        assert stored.source.contentBlockIndexSource == "message"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_true_order_group_is_idempotent() -> None:
    """A second flush writes nothing: the strict corrector leaves it alone."""

    store, session = await _store_with_session()
    try:
        reasoning = _stored(
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0
            ),
            order_seq=1,
            updated_seq=1,
        )
        tool = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=1,
            ),
            order_seq=2,
            updated_seq=2,
        )
        body = _stored(
            message_input(
                session.id, "m", order_seq=2, content_block_index=2
            ),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[reasoning, tool, body]
        )
        first = {
            row.id: (row.orderSeq, row.updatedSeq, row.revision)
            for row in await store.timeline.read(session.id)
        }
        # Re-persist with a fresh revision so the batch is NOT filtered as
        # unchanged and the corrector actually runs (a same-revision replay
        # returns before it, which proves nothing).
        again = [
            _stored(
                reasoning_input(
                    session.id, "r", order_seq=0, content_block_index=0
                ),
                order_seq=1,
                updated_seq=10,
            ),
            _stored(
                tool_input(
                    session.id,
                    "t",
                    order_seq=1,
                    tool_block_index=0,
                    content_block_index=1,
                ),
                order_seq=2,
                updated_seq=11,
            ),
            _stored(
                message_input(
                    session.id, "m", order_seq=2, content_block_index=2
                ),
                order_seq=3,
                updated_seq=12,
            ),
        ]
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=again
        )
        second = {
            row.id: row.orderSeq for row in await store.timeline.read(session.id)
        }
        assert second == {row_id: value[0] for row_id, value in first.items()}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_a_history_rebuild_backfills_the_index_on_unchanged_content() -> None:
    """Same contentHash, but now declaring the index → the row is rewritten.

    Without this, a stored live row could never gain the truth history later
    declares (its content is identical), and the session would keep the RBT
    order forever (red-team B, pp 2026-11-19).
    """

    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=None,
                text="same",
            ),
        )
        with_index = tool_input(
            session.id,
            "t",
            order_seq=1,
            tool_block_index=0,
            content_block_index=1,
            text="same",
        )
        await store.sync_timeline_items(
            session_id=session.id, items=[with_index]
        )
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndex == 1
        assert stored.source.contentBlockIndexSource == "message"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_a_live_buffer_rewrite_keeps_the_stored_index() -> None:
    """The write-buffer path must preserve an index the row already declared."""

    store, session = await _store_with_session()
    try:
        first = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=1,
                text="first",
            ),
            order_seq=1,
            updated_seq=1,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[first]
        )
        rewrite = _stored(
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=None,
                text="live rewrite",
            ),
            order_seq=1,
            updated_seq=5,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[rewrite]
        )
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndex == 1
        assert "live rewrite" in str(stored.content)
    finally:
        await store.close()


@pytest.mark.anyio
async def test_repair_reorders_a_stored_group_by_the_real_block_order() -> None:
    """The repair sweep reads the STORED index and repacks to true order."""

    store, session = await _store_with_session()
    try:
        # Seeded verbatim, in the legacy RBT order: reasoning, body, tool.
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0
            ),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "m", order_seq=2, content_block_index=2),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id,
                "t",
                order_seq=1,
                tool_block_index=0,
                content_block_index=1,
            ),
            order_seq=3,
            updated_seq=3,
        )
        order_before = await _order_by_id(store, session.id)
        assert order_before["r"] < order_before["m"] < order_before["t"]

        await store.repair_intra_message_order()
        order_after = await _order_by_id(store, session.id)
        assert order_after["r"] < order_after["t"] < order_after["m"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_legacy_derived_index_never_orders_the_group() -> None:
    """A derived (legacy) index must not reorder rows; RBT wins instead.

    Production 2026-11-20: the connector counted transcript lines (block
    completion order) as the absolute index. On the OpenAI-format channel the
    tool call completes before the text, so every text+tool message was
    declared as ``[tool(0), text(1)]`` although the assembled message is
    ``[text(0), tool(1)]`` — and the server moved the tool above the body.
    Here the rows are declared legacy with that inverted shape; the final
    order must be RBT (reasoning → body → tool), not the declared one.
    """

    store, session = await _store_with_session()
    try:
        reasoning = _stored(
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0,
                cbi_source="legacy",
            ),
            order_seq=1,
            updated_seq=1,
        )
        tool = _stored(
            tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=1, cbi_source="legacy",
            ),
            order_seq=2,
            updated_seq=2,
        )
        body = _stored(
            message_input(
                session.id, "m", order_seq=2, content_block_index=2,
                cbi_source="legacy",
            ),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[reasoning, tool, body]
        )
        order = await _order_by_id(store, session.id)
        assert order["r"] < order["m"] < order["t"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_duplicate_message_indexes_fall_back_to_rbt() -> None:
    """Colliding message-sourced indexes are broken truth: order by RBT.

    The declared shape here is ``[reasoning(0), tool(0), body(1)]`` — with the
    collision ignored the rows would sort ``r, t, m`` (the order they are
    seeded in, i.e. the inverted shape); RBT must win instead.
    """

    store, session = await _store_with_session()
    try:
        reasoning = _stored(
            reasoning_input(session.id, "r", order_seq=0, content_block_index=0),
            order_seq=1,
            updated_seq=1,
        )
        tool = _stored(
            tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=0,
            ),
            order_seq=2,
            updated_seq=2,
        )
        body = _stored(
            message_input(session.id, "m", order_seq=2, content_block_index=1),
            order_seq=3,
            updated_seq=3,
        )
        await store.persist_buffered_timeline_items(
            session_id=session.id, items=[reasoning, tool, body]
        )
        order = await _order_by_id(store, session.id)
        assert order["r"] < order["m"] < order["t"]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_legacy_write_cannot_downgrade_a_message_index() -> None:
    """A derived rewrite must not erase or downgrade a stored message truth."""

    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=1, text="same",
            ),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=0, text="same", cbi_source="legacy",
            ),
        )
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndex == 1
        assert stored.source.contentBlockIndexSource == "message"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_message_write_replaces_a_legacy_index() -> None:
    """The upgrade direction stays open: message truth replaces a legacy value."""

    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=1, text="same", cbi_source="legacy",
            ),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=2, text="same",
            ),
        )
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndex == 2
        assert stored.source.contentBlockIndexSource == "message"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_a_same_index_rebuild_upgrades_the_source() -> None:
    """Identical index, but now message-sourced → the row must be rewritten."""

    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=1, text="same", cbi_source="legacy",
            ),
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                tool_input(
                    session.id, "t", order_seq=1, tool_block_index=0,
                    content_block_index=1, text="same",
                )
            ],
        )
        stored = await store.timeline.read_one(session.id, "t")
        assert stored is not None
        assert stored.source.contentBlockIndexSource == "message"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_repair_sweep_orders_a_legacy_group_by_rbt() -> None:
    """The startup sweep must never move rows by a derived index."""

    store, session = await _store_with_session()
    try:
        await _seed_row(
            store,
            session.id,
            reasoning_input(
                session.id, "r", order_seq=0, content_block_index=0,
                cbi_source="legacy",
            ),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            tool_input(
                session.id, "t", order_seq=1, tool_block_index=0,
                content_block_index=1, cbi_source="legacy",
            ),
            order_seq=2,
            updated_seq=2,
        )
        await _seed_row(
            store,
            session.id,
            message_input(
                session.id, "m", order_seq=2, content_block_index=2,
                cbi_source="legacy",
            ),
            order_seq=3,
            updated_seq=3,
        )
        before = await _order_by_id(store, session.id)
        assert before["r"] < before["t"] < before["m"]
        await store.repair_intra_message_order()
        after = await _order_by_id(store, session.id)
        assert after["r"] < after["m"] < after["t"]
    finally:
        await store.close()
