"""A chain insert must not publish a new row into a slot still occupied.

Why this file exists
--------------------
``sync_timeline_items`` plans a batch's new rows against the stored chain and
renumbers the smallest stored block when the integers are dense. It then
reserves one revision per changed row and the publisher sends one
``timeline.item_created``/``timeline.item_updated`` event per row, in that
order. On 2026-11-20 18:37 the client received 4 new rows before the 10 stored
rows they displaced: for ~250 ms two rows shared an ``orderSeq``, every event
recomputed the chat grouping, and the step groups visibly split and merged
back (client log ``timeline.order.duplicate`` x10, ``timeline.grouping``
50→59→50).

The contract this file pins: applying the returned rows in publication order
never puts two rows on the same ``orderSeq``, so a client that renders each
event (iOS does) never draws a duplicated position. The stored rows must be
published highest-new-position first — each move lands in a slot the previous
move just vacated — and only then the batch's new rows fill the freed slots.
The sequence is the one the publisher really uses: events are emitted ordered
by ``updatedSeq`` (``events_from_invalidation``), so the tests assert that
order, not just the returned array order.

Two limits are deliberate: a row this write deletes (a converged live/history
twin) still occupies its slot on a client that has not refetched yet — the
envelope forces that refetch — and a pure permutation with no free slot (two
rows swapping) has no duplicate-free order at all.
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import insert, select, update

from agent_server.core.events import events_from_invalidation
from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import (
    chain_publication_order,
    timeline_item_from_runtime_input,
)
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.repositories.facade import Store


def _row_input(session_id: str, item_id: str, order_seq: int) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": item_id, "format": "markdown"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_chain",
                "itemId": f"native_{item_id}",
                "itemType": "assistant",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


def _reasoning_input(
    session_id: str, item_id: str, order_seq: int, *, native_item_id: str
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "content": {"kind": "reasoning", "text": item_id},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_chain",
                "itemId": native_item_id,
                "itemType": "thinking",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


def _body_input(
    session_id: str, item_id: str, order_seq: int, *, native_item_id: str, text: str
) -> TimelineItemIn:
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
                "sessionId": "claude_ext_chain",
                "itemId": native_item_id,
                "itemType": "assistant",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


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
        now="2026-11-21T00:00:00Z",
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


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_chain",
        project_name="P-chain-publish",
    )
    return store, session


def _apply_in_order(
    stored_orders: dict[str, int], items: tuple[Any, ...]
) -> list[int]:
    """Apply published rows one by one; return the duplicate collisions seen.

    A client merges each event into the window it already holds. The row's
    final ``orderSeq`` is what it writes; a row that is not held yet is an
    insert. Every intermediate window must keep unique ``orderSeq`` values.
    """

    orders = dict(stored_orders)
    duplicates: list[int] = []
    for item in items:
        orders[item.id] = item.orderSeq
        seen: set[int] = set()
        for value in orders.values():
            if value in seen:
                duplicates.append(value)
            seen.add(value)
    return duplicates


def _apply_plan(
    orders: dict[str, int],
    planned: dict[str, int],
    publication: list[str],
) -> list[int]:
    """Move rows in publication order; return orderSeq duplicates seen."""

    duplicates: list[int] = []
    for item_id in publication:
        orders[item_id] = planned[item_id]
        if len(set(orders.values())) != len(orders):
            duplicates.append(planned[item_id])
    return duplicates


def test_publication_order_waits_for_a_row_moving_down_into_a_held_slot() -> None:
    # ``_bounded_insert`` may move a block's lower rows down when space below
    # is free, so highest-target-first is not safe: c→3 is held by b until b
    # moves to 2, which is held by a until a moves to 1.
    stored = [("a", 2), ("b", 3), ("c", 4)]
    planned = {"a": 1, "b": 2, "c": 3}
    publication = chain_publication_order(
        stored_order=stored,
        planned_order=planned,
        published_ids=["a", "b", "c"],
    )
    assert publication == ["a", "b", "c"]
    assert _apply_plan(dict(stored), planned, publication) == []


def test_publication_order_lets_a_new_row_wait_for_its_freed_slot() -> None:
    stored = [("a", 1), ("b", 2)]
    planned = {"new": 1, "a": 3, "b": 4}
    publication = chain_publication_order(
        stored_order=stored,
        planned_order=planned,
        published_ids=["new", "a", "b"],
    )
    # b moves to a free slot, then a, then the new row takes slot 1.
    assert publication == ["b", "a", "new"]
    assert _apply_plan(dict(stored), planned, publication) == []


def test_publication_order_emits_a_cycle_once_instead_of_looping() -> None:
    stored = [("a", 1), ("b", 2)]
    planned = {"a": 2, "b": 1}
    publication = chain_publication_order(
        stored_order=stored,
        planned_order=planned,
        published_ids=["a", "b"],
    )
    assert sorted(publication) == ["a", "b"]


@pytest.mark.anyio
async def test_chain_insert_publishes_movers_before_the_rows_that_take_their_slots() -> None:
    store, session = await _store_with_session()
    try:
        stored_ids = [f"stored_{index}" for index in range(1, 13)]
        seeded = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _row_input(session.id, item_id, order_seq)
                for order_seq, item_id in enumerate(stored_ids, start=1)
            ],
        )
        assert seeded.changed
        stored_orders = {item.id: item.orderSeq for item in await store.timeline.read(session.id)}
        assert stored_orders == {
            item_id: order_seq
            for order_seq, item_id in enumerate(stored_ids, start=1)
        }

        # Four rows named before a dense stored block: the plan must renumber
        # the block (12 stored rows shift up by 4) and place the run at 1..4.
        new_ids = [f"new_{index}" for index in range(1, 5)]
        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                *[
                    _row_input(session.id, item_id, order_seq)
                    for order_seq, item_id in enumerate(new_ids, start=1)
                ],
                *[
                    _row_input(session.id, item_id, order_seq)
                    for order_seq, item_id in enumerate(stored_ids, start=1)
                ],
            ],
            reorder_from_batch=True,
        )
        assert result.changed

        duplicates = _apply_in_order(stored_orders, result.items)
        assert duplicates == [], (
            "a published row landed on an orderSeq another row still held: "
            f"{duplicates}"
        )

        published_ids = [item.id for item in result.items]
        assert sorted(published_ids) == sorted([*stored_ids, *new_ids])
        # The publisher emits one frame per item ordered by updatedSeq. A
        # fix that only reorders the returned array (leaving updatedSeq in
        # the old order) would pass the duplicate check above and still flash
        # on device, so pin the real wire order.
        first_seq = result.items[0].updatedSeq
        assert [item.updatedSeq for item in result.items] == list(
            range(first_seq, first_seq + len(result.items))
        )
        events = events_from_invalidation(
            {
                "sessionId": session.id,
                "nextSeq": result.items[-1].updatedSeq,
                "items": [
                    item.model_dump(mode="json") for item in result.items
                ],
            }
        )
        item_events = [
            event
            for event in events
            if event.type in {"timeline.item_created", "timeline.item_updated"}
        ]
        assert [
            (event.payload["item"]["id"], event.payload["item"]["orderSeq"])
            for event in item_events
        ] == [(item.id, item.orderSeq) for item in result.items]
        assert [event.sequence for event in item_events] == [
            item.updatedSeq for item in result.items
        ]

        final = {item.id: item.orderSeq for item in await store.timeline.read(session.id)}
        assert [final[item_id] for item_id in new_ids] == [1, 2, 3, 4]
        assert [final[item_id] for item_id in stored_ids] == list(range(5, 17))
    finally:
        await store.close()


@pytest.mark.anyio
async def test_uncovered_stored_rows_are_published_before_the_run_that_displaces_them() -> None:
    """The batch names only its anchor; the plan renumbers siblings it never sees.

    A rebased/window batch may carry one stored anchor and a run of new rows;
    the plan then renumbers stored rows the batch does not name. Those
    ``moved_rows`` publish first for the same reason as named movers.
    """

    store, session = await _store_with_session()
    try:
        stored_ids = [f"stored_{index}" for index in range(1, 13)]
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _row_input(session.id, item_id, order_seq)
                for order_seq, item_id in enumerate(stored_ids, start=1)
            ],
        )
        stored_orders = {
            item.id: item.orderSeq for item in await store.timeline.read(session.id)
        }

        new_ids = [f"new_{index}" for index in range(1, 5)]
        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                *[
                    _row_input(session.id, item_id, order_seq)
                    for order_seq, item_id in enumerate(new_ids, start=1)
                ],
                _row_input(session.id, stored_ids[0], 1),
            ],
            reorder_from_batch=True,
        )
        assert result.changed
        assert _apply_in_order(stored_orders, result.items) == []
        assert sorted(item.id for item in result.items) == sorted(
            [*stored_ids, *new_ids]
        )

        final = {item.id: item.orderSeq for item in await store.timeline.read(session.id)}
        assert [final[item_id] for item_id in new_ids] == [1, 2, 3, 4]
        assert [final[item_id] for item_id in stored_ids] == list(range(5, 17))
    finally:
        await store.close()


@pytest.mark.anyio
async def test_intra_message_repair_siblings_join_the_same_publication_graph() -> None:
    """A batch row must not take a slot a corrected on-disk sibling still holds.

    Red-team reproduction: a pre-fix message stored body before its reasoning
    rows (body@10, r1@11, r2@12). A batch rewrites the body and adds a new
    reasoning row. The corrector moves the body to 13 and the siblings to
    10..12; publishing the batch rows before the siblings lands the new
    reasoning row on r2's still-held slot 12.
    """

    store, session = await _store_with_session()
    try:
        native_id = "native_message_M"
        await _seed_row(
            store,
            session.id,
            _body_input(
                session.id, "m_body", 10, native_item_id=native_id, text="body"
            ),
            order_seq=10,
            updated_seq=10,
        )
        for order in (11, 12):
            row_id = f"m_reason_{order}"
            await _seed_row(
                store,
                session.id,
                _reasoning_input(
                    session.id, row_id, order, native_item_id=native_id
                ),
                order_seq=order,
                updated_seq=order,
            )
        stored_orders = {
            item.id: item.orderSeq for item in await store.timeline.read(session.id)
        }
        assert stored_orders == {"m_body": 10, "m_reason_11": 11, "m_reason_12": 12}

        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _body_input(
                    session.id, "m_body", 10, native_item_id=native_id, text="body2"
                ),
                _reasoning_input(
                    session.id, "m_reason_13", 13, native_item_id=native_id
                ),
            ],
        )
        assert result.changed
        assert _apply_in_order(stored_orders, result.items) == [], [
            (item.id, item.orderSeq, item.updatedSeq) for item in result.items
        ]

        final = {item.id: item.orderSeq for item in await store.timeline.read(session.id)}
        assert final == {
            "m_reason_11": 10,
            "m_reason_12": 11,
            "m_reason_13": 12,
            "m_body": 13,
        }
    finally:
        await store.close()
