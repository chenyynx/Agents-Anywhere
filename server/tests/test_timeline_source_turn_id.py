"""``source.turnId`` rides through the server into the stored payload.

The connector has always declared ``turnId`` on every Runtime-owned item
(``connector/connector/runtime_protocol/timeline.py``), but ``TimelineSource``
did not model it, so Pydantic's default ``extra="ignore"`` dropped it before
``_row_values`` dumped the payload. A client therefore could not see a turn
boundary that publishes no user row — a scheduled turn.

These tests pin the additive contract:

- a source that declares ``turnId`` stores it under ``payload_json.source``;
- a source that does not declare it stores no ``turnId`` key at all, so old
  payloads and old decoders stay unchanged;
- a row written before the server modelled ``turnId`` is rewritten once when
  a rebuild re-sends it with the new source field. ``contentHash`` covers
  type/status/role/content only, so without the forced rewrite the no-op fast
  path would leave the stored payload turn-less forever;
- a row whose declared ``turnId`` changes is rewritten as well: the older
  connector's window-derived history id is not stable, and freezing the first
  one would publish a false turn boundary.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import select

from agent_server.core.models import TimelineItemIn, TimelineSource
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.repositories.facade import Store


def message_input(
    session_id: str,
    item_id: str,
    *,
    turn_id: str | None,
    order_seq: int,
) -> TimelineItemIn:
    source: dict[str, Any] = {
        "runtime": "claude",
        "sessionId": "claude_ext_1",
        "itemId": f"native-{item_id}",
        "itemType": "assistant",
    }
    if turn_id is not None:
        source["turnId"] = turn_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": item_id, "format": "markdown"},
            "source": source,
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name="P-turn-id",
    )
    return store, session


async def _stored_sources(store: Store, session_id: str) -> dict[str, Any]:
    async with store.engine.connect() as conn:
        rows = (
            await conn.execute(
                select(
                    timeline_items_t.c.id,
                    timeline_items_t.c.payload_json,
                ).where(timeline_items_t.c.session_id == session_id)
            )
        ).all()
    return {row.id: json.loads(row.payload_json)["source"] for row in rows}


def test_timeline_source_accepts_the_connector_key_verbatim() -> None:
    # The connector serializes camelCase keys; the model declares the same
    # name, so no alias is involved (as with nativeMessageId / blockIndex).
    source = TimelineSource.model_validate({"runtime": "claude", "turnId": "turn_1"})
    assert source.turnId == "turn_1"

    legacy = TimelineSource.model_validate({"runtime": "claude"})
    assert legacy.turnId is None
    assert "turnId" not in legacy.model_dump(exclude_none=True)


@pytest.mark.anyio
async def test_turn_id_is_stored_in_payload_and_legacy_rows_are_unchanged() -> None:
    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "with_turn", turn_id="turn_1", order_seq=1),
        )
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "legacy", turn_id=None, order_seq=2),
        )

        sources = await _stored_sources(store, session.id)

        assert sources["with_turn"]["turnId"] == "turn_1"
        # ``exclude_none=True`` in ``_row_values``: a row whose Runtime does not
        # declare a turn stores no key, exactly like ``nativeMessageId``.
        assert "turnId" not in sources["legacy"]
    finally:
        await store.close()


async def _stored_item(store: Store, session_id: str, item_id: str) -> Any:
    item = await store.timeline.read_one(session_id, item_id)
    assert item is not None
    return item


@pytest.mark.anyio
async def test_legacy_row_gains_turn_id_on_an_otherwise_identical_write() -> None:
    """``contentHash`` ignores ``source``; the forced rewrite bridges that.

    A row written before the server modelled ``turnId`` has the same
    ``contentHash`` when a history rebuild re-sends it with the new source
    field. Without the forced write the early return would keep the payload
    turn-less forever (and the session's scheduled turns without a boundary).
    """

    store, session = await _store_with_session()
    try:
        first = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "legacy", turn_id=None, order_seq=1),
        )
        assert first.changed is True
        before = await _stored_item(store, session.id, "legacy")
        assert before.source.turnId is None

        second = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "legacy", turn_id="turn_1", order_seq=1),
        )
        assert second.changed is True

        after = await _stored_item(store, session.id, "legacy")
        assert after.source.turnId == "turn_1"
        assert after.revision > before.revision
        assert after.updatedSeq > before.updatedSeq
        sources = await _stored_sources(store, session.id)
        assert sources["legacy"]["turnId"] == "turn_1"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_repeated_turn_id_write_is_idempotent() -> None:
    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id=None, order_seq=1),
        )
        forced = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_1", order_seq=1),
        )
        assert forced.changed is True
        after_forced = await _stored_item(store, session.id, "row")

        repeat = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_1", order_seq=1),
        )
        assert repeat.changed is False

        after_repeat = await _stored_item(store, session.id, "row")
        assert after_repeat.revision == after_forced.revision
        assert after_repeat.updatedSeq == after_forced.updatedSeq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_write_without_turn_id_keeps_the_old_unchanged_behaviour() -> None:
    store, session = await _store_with_session()
    try:
        first = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id=None, order_seq=1),
        )
        assert first.changed is True

        repeat = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id=None, order_seq=1),
        )
        assert repeat.changed is False

        # The forced write only fills a missing turn id; it never clears one,
        # so a later turn-less write is unchanged as before.
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_1", order_seq=1),
        )
        turn_less = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id=None, order_seq=1),
        )
        assert turn_less.changed is False
        assert (await _stored_item(store, session.id, "row")).source.turnId == "turn_1"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_a_changed_turn_id_rewrites_the_row() -> None:
    """A different declared id is a real change, not a no-op.

    The older connector derives history turn ids from the sync window, so the
    same turn can arrive with a new id on the next sync. Freezing the first one
    would put a false turn boundary in the payload and split the client's row
    grouping. The write must therefore replace the stored id, and then settle
    (a repeat of the same id stays a no-op).
    """

    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_OLD", order_seq=1),
        )
        changed = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_NEW", order_seq=1),
        )
        assert changed.changed is True
        assert (await _stored_item(store, session.id, "row")).source.turnId == "turn_NEW"

        repeat = await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_NEW", order_seq=1),
        )
        assert repeat.changed is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_batch_sync_replaces_a_changed_turn_id() -> None:
    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id="turn_OLD", order_seq=1),
        )
        batch = await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "row", turn_id="turn_NEW", order_seq=1)],
        )
        assert batch.changed is True
        assert (await _stored_item(store, session.id, "row")).source.turnId == "turn_NEW"

        repeat = await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "row", turn_id="turn_NEW", order_seq=1)],
        )
        assert repeat.changed is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_batch_sync_forces_the_turn_id_rewrite() -> None:
    store, session = await _store_with_session()
    try:
        await store.upsert_timeline_item(
            session_id=session.id,
            item=message_input(session.id, "row", turn_id=None, order_seq=1),
        )
        before = await _stored_item(store, session.id, "row")

        batch = await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "row", turn_id="turn_1", order_seq=1)],
        )
        assert batch.changed is True
        after = await _stored_item(store, session.id, "row")
        assert after.source.turnId == "turn_1"
        assert after.updatedSeq > before.updatedSeq

        repeat = await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "row", turn_id="turn_1", order_seq=1)],
        )
        assert repeat.changed is False
    finally:
        await store.close()
