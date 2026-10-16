"""Repack vs. keyset pagination: a reorder must not make a history page drop
or duplicate a row.

The history pager (``list_before_order_seq``) filters on ``order_seq <
before_order_seq``, where the client passes the OLDEST ``order_seq`` of the
page it just received. A repack assigns a group's rows *new* ``order_seq``
values inside the group's slot run. If a repack runs while a client holds a
cursor taken before it, a row can cross the cursor and make the paged result
set inconsistent: the client can miss a row entirely or see one twice.

This file pins the target behaviour. It is written RED today (the hazard is
real) so the eventual fix has a regression guard. Rows are seeded verbatim
(bypassing the corrector) so the inverted group genuinely exists on disk.
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


def _message(sid: str, item_id: str, *, native_item_id: str, order_seq: int, text: str | None = None) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": sid,
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


def _tool(sid: str, item_id: str, *, native_message_id: str, block_index: int, order_seq: int) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": sid,
            "type": "tool",
            "status": "done",
            "role": "tool",
            "content": {"kind": "command", "command": item_id},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "tool_result",
                "nativeMessageId": native_message_id,
                "blockIndex": block_index,
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


async def _store(tmp_path: Any) -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name="P-repack",
    )
    return store, session


async def _seed(store: Store, sid: str, item: TimelineItemIn, order_seq: int, updated_seq: int) -> None:
    stored = timeline_item_from_runtime_input(
        item, updated_seq=updated_seq, now="2026-10-12T00:00:00Z", order_seq=order_seq
    )
    async with store.engine.begin() as conn:
        await conn.execute(insert(timeline_items_t), [store.timeline._row_values(stored)])
        row = (
            await conn.execute(
                select(sessions_t.c.seq, sessions_t.c.seq_allocated_high).where(
                    sessions_t.c.id == sid
                )
            )
        ).first()
        if row is not None:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == sid)
                .values(
                    seq=max(int(row[0]), updated_seq),
                    seq_allocated_high=max(int(row[1]), updated_seq),
                )
            )


@pytest.mark.xfail(
    reason=(
        "KNOWN PRE-EXISTING BUG (not introduced by the tool-row work): a repack "
        "that changes a row's order_seq across a client's history-paging cursor "
        "makes the paged result set inconsistent — a row stranded on the cursor "
        "is LOST (order_seq < cursor excludes it) and a row that moved up is "
        "REPEATED. The same hazard exists for the reasoning/body repack since "
        "v2_42 (verified). See .local-dev/tool-order-inversion-tasks.md §11."
    ),
    strict=True,
)
@pytest.mark.anyio
async def test_paging_self_consistent_across_repack(tmp_path) -> None:
    store, session = await _store(tmp_path)
    sid = session.id

    # Group m1 stored INVERTED: body@10, tool_b(blockIndex 1)@11, tool_a(blockIndex 0)@12.
    # A filler row above the group so the first page has content.
    await _seed(store, sid, _message(sid, "msg_body", native_item_id="m1", order_seq=10), 10, 10)
    await _seed(store, sid, _tool(sid, "tool_b", native_message_id="m1", block_index=1, order_seq=11), 11, 11)
    await _seed(store, sid, _tool(sid, "tool_a", native_message_id="m1", block_index=0, order_seq=12), 12, 12)
    await _seed(store, sid, _message(sid, "filler", native_item_id="m2", order_seq=20), 20, 20)

    # Client page 1: newest 2 rows. Yields filler@20, tool_a@12; cursor = 12.
    page1, _ = await store.list_timeline_before_order_seq(session_id=sid, before_order_seq=9999, limit=2)
    ids1 = [i.id for i in page1]
    assert "tool_a" in ids1, ids1
    cursor = min(i.orderSeq for i in page1)
    assert cursor == 12, cursor

    # A repack runs (a real content write to the group's body triggers the
    # corrector). It swaps the tools in place: tool_a@11, tool_b@12.
    await store.sync_timeline_items(
        session_id=sid,
        items=[_message(sid, "msg_body", native_item_id="m1", order_seq=10, text="edited")],
    )
    after = {i.id: i.orderSeq for i in await store.timeline.read(sid)}
    assert after["tool_a"] == 11 and after["tool_b"] == 12, f"repack did not run: {after}"

    # Client page 2 from the cursor it holds.
    page2, _ = await store.list_timeline_before_order_seq(session_id=sid, before_order_seq=cursor, limit=2)
    ids2 = [i.id for i in page2]

    seen = ids1[:-1] + ids2  # 'seen' = everything the client now holds
    missing = {"msg_body", "tool_a", "tool_b"} - set(seen)
    duplicated = {i for i in seen if seen.count(i) > 1}
    assert not missing, f"repack+paging dropped rows: {sorted(missing)} (page1={ids1} page2={ids2})"
    assert not duplicated, f"repack+paging duplicated rows: {sorted(duplicated)} (page1={ids1} page2={ids2})"
