"""``source.turnId`` rides through the server into the stored payload.

The connector has always declared ``turnId`` on every Runtime-owned item
(``connector/connector/runtime_protocol/timeline.py``), but ``TimelineSource``
did not model it, so Pydantic's default ``extra="ignore"`` dropped it before
``_row_values`` dumped the payload. A client therefore could not see a turn
boundary that publishes no user row — a scheduled turn.

These tests pin the additive contract:

- a source that declares ``turnId`` stores it under ``payload_json.source``;
- a source that does not declare it stores no ``turnId`` key at all, so old
  payloads and old decoders stay unchanged.
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
