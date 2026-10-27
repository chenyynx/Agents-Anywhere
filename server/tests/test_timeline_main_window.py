"""Main timeline window (``excludeAgentChildren``) and Agent-card child pages.

A session's newest timeline window can be made up entirely of subagent child
rows. iOS hides those rows in the main timeline (L2.1: any row whose
``content.parentItemId`` is non-empty renders only inside its parent card), so
opening such a session shows a blank page even though it has content. The
server-side answer is opt-in: a main-only window that excludes child rows, and
a query that pages one card's child rows on demand. These tests pin that
surface:

- the store filters child rows in SQL *before* LIMIT when ``main_only=True``;
- the default readers return exactly the rows they returned before the column;
- ``list_children`` pages one card's rows newest-last, with ``hasMore``;
- both endpoints default to the old behavior and only exclude when asked;
- ``mode=children`` requires ``parentItemId`` and does not claim the flag;
- ``mode=changes`` ignores the flag (export/recovery semantics are unchanged);
- the write path mirrors ``content.parentItemId`` into ``parent_item_id``.
"""

from __future__ import annotations

from typing import Any

import pytest
from conftest import TEST_DATABASE_URL
from session_fixtures import create_session_with_project
from test_backend_mvp import create_connector_and_session, make_client

from agent_server.api.sessions import SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV
from agent_server.core.models import TimelineItemIn
from agent_server.infra.repositories.facade import Store


async def _parent_item_column(session_id: str) -> dict[str, str | None]:
    """Read the mirrored column straight from the table.

    The point of the write-path test is the *column*, not the payload the
    public readers return, so it deliberately bypasses the store.
    """

    import asyncpg

    connection = await asyncpg.connect(
        TEST_DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://", 1)
    )
    try:
        rows = await connection.fetch(
            "SELECT id, parent_item_id FROM timeline_items WHERE session_id = $1",
            session_id,
        )
    finally:
        await connection.close()
    return {row["id"]: row["parent_item_id"] for row in rows}


def _item_payload(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    parent_item_id: Any = None,
    content_hash: str | None = None,
) -> dict[str, Any]:
    content: dict[str, Any] = {"text": f"text of {item_id}", "format": "markdown"}
    if parent_item_id is not None:
        content["parentItemId"] = parent_item_id
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "message",
        "status": "done",
        "role": "assistant",
        "content": content,
        "source": {
            "runtime": "claude",
            "sessionId": "claude_ext_1",
            "itemId": item_id,
            "itemType": "agentMessage",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": content_hash or f"sha256:{item_id}",
    }


def _timeline_input(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    parent_item_id: Any = None,
    content_hash: str | None = None,
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        _item_payload(
            session_id,
            item_id,
            order_seq=order_seq,
            parent_item_id=parent_item_id,
            content_hash=content_hash,
        )
    )


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name="P-main-window",
    )
    return store, session


def _post_sync(
    client: Any,
    access_token: str,
    session_id: str,
    items: list[dict[str, Any]],
) -> None:
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "notifications": [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "complete": False,
                        "items": items,
                    },
                }
            ]
        },
    )
    assert response.status_code == 200, response.text


def _ids(items: list[dict[str, Any]]) -> list[str]:
    return [item["id"] for item in items]


# ---------------------------------------------------------------------------
# Store readers
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_list_latest_main_only_filters_children_before_the_limit(
    tmp_path,
) -> None:
    """The newest rows are all child rows; the main-only page must still be
    filled with main rows, which is only possible if the filter runs in SQL
    before the LIMIT (filtering the default page afterwards would be empty)."""

    store, session = await _store_with_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(session.id, "m1", order_seq=1),
                _timeline_input(session.id, "m2", order_seq=2),
                _timeline_input(session.id, "m3", order_seq=3),
                _timeline_input(session.id, "c1", order_seq=4, parent_item_id="card-A"),
                _timeline_input(session.id, "c2", order_seq=5, parent_item_id="card-A"),
                _timeline_input(session.id, "c3", order_seq=6, parent_item_id="card-B"),
            ],
        )

        # Default behavior is untouched: the newest rows, child rows included.
        items, has_more = await store.list_timeline_latest(
            session_id=session.id, limit=3
        )
        assert [item.id for item in items] == ["c1", "c2", "c3"]
        assert has_more is True

        # Main-only: filter before LIMIT, so the page is full of main rows.
        items, has_more = await store.list_timeline_latest(
            session_id=session.id, limit=3, main_only=True
        )
        assert [item.id for item in items] == ["m1", "m2", "m3"]
        assert has_more is False

        # The cursor and hasMore still follow the *filtered* stream.
        items, has_more = await store.list_timeline_latest(
            session_id=session.id, limit=2, main_only=True
        )
        assert [item.id for item in items] == ["m2", "m3"]
        assert has_more is True
    finally:
        await store.close()


@pytest.mark.anyio
async def test_list_before_order_seq_main_only_pages_main_rows(tmp_path) -> None:
    store, session = await _store_with_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(session.id, "m1", order_seq=1),
                _timeline_input(session.id, "c1", order_seq=2, parent_item_id="card-A"),
                _timeline_input(session.id, "m2", order_seq=3),
                _timeline_input(session.id, "c2", order_seq=4, parent_item_id="card-A"),
                _timeline_input(session.id, "m3", order_seq=5),
                _timeline_input(session.id, "c3", order_seq=6, parent_item_id="card-B"),
            ],
        )

        items, has_more = await store.list_timeline_before_order_seq(
            session_id=session.id,
            before_order_seq=7,
            limit=10,
            main_only=True,
        )
        assert [item.id for item in items] == ["m1", "m2", "m3"]
        assert has_more is False

        items, has_more = await store.list_timeline_before_order_seq(
            session_id=session.id,
            before_order_seq=7,
            limit=2,
            main_only=True,
        )
        assert [item.id for item in items] == ["m2", "m3"]
        assert has_more is True

        items, has_more = await store.list_timeline_before_order_seq(
            session_id=session.id,
            before_order_seq=3,
            limit=2,
            main_only=True,
        )
        assert [item.id for item in items] == ["m1"]
        assert has_more is False

        # Default behavior is untouched: child rows still page through.
        items, has_more = await store.list_timeline_before_order_seq(
            session_id=session.id,
            before_order_seq=7,
            limit=2,
        )
        assert [item.id for item in items] == ["m3", "c3"]
        assert has_more is True
    finally:
        await store.close()


@pytest.mark.anyio
async def test_list_children_pages_one_cards_rows(tmp_path) -> None:
    store, session = await _store_with_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(session.id, "m1", order_seq=1),
                _timeline_input(session.id, "a1", order_seq=2, parent_item_id="card-A"),
                _timeline_input(session.id, "m2", order_seq=3),
                _timeline_input(session.id, "a2", order_seq=4, parent_item_id="card-A"),
                _timeline_input(session.id, "b1", order_seq=5, parent_item_id="card-B"),
                _timeline_input(session.id, "a3", order_seq=6, parent_item_id="card-A"),
            ],
        )

        items, has_more = await store.list_agent_children(
            session_id=session.id, parent_item_id="card-A", limit=2
        )
        assert [item.id for item in items] == ["a2", "a3"]
        assert has_more is True

        items, has_more = await store.list_agent_children(
            session_id=session.id,
            parent_item_id="card-A",
            before_order_seq=4,
            limit=2,
        )
        assert [item.id for item in items] == ["a1"]
        assert has_more is False

        items, has_more = await store.list_agent_children(
            session_id=session.id, parent_item_id="card-B", limit=10
        )
        assert [item.id for item in items] == ["b1"]
        assert has_more is False

        items, has_more = await store.list_agent_children(
            session_id=session.id, parent_item_id="missing", limit=10
        )
        assert items == []
        assert has_more is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_default_readers_return_the_unchanged_row_set(tmp_path) -> None:
    """Without ``main_only`` the readers are byte-for-byte the pre-v2_47
    readers: every row, child rows included, in the same order."""

    all_ids = ["m1", "c1", "m2", "c2", "m3", "c3"]
    store, session = await _store_with_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(session.id, "m1", order_seq=1),
                _timeline_input(session.id, "c1", order_seq=2, parent_item_id="card-A"),
                _timeline_input(session.id, "m2", order_seq=3),
                _timeline_input(session.id, "c2", order_seq=4, parent_item_id="card-A"),
                _timeline_input(session.id, "m3", order_seq=5),
                _timeline_input(session.id, "c3", order_seq=6, parent_item_id="card-A"),
            ],
        )

        latest, latest_has_more = await store.list_timeline_latest(
            session_id=session.id, limit=10
        )
        assert [item.id for item in latest] == all_ids
        assert latest_has_more is False

        history, history_has_more = await store.list_timeline_before_order_seq(
            session_id=session.id, before_order_seq=7, limit=10
        )
        assert [item.id for item in history] == all_ids
        assert history_has_more is False
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Write path
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_upsert_mirrors_parent_item_id_into_the_column(tmp_path) -> None:
    store, session = await _store_with_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(session.id, "child", order_seq=1, parent_item_id="card-A"),
                _timeline_input(session.id, "main", order_seq=2),
                _timeline_input(session.id, "empty", order_seq=3, parent_item_id=""),
                _timeline_input(session.id, "numeric", order_seq=4, parent_item_id=42),
            ],
        )

        assert await _parent_item_column(session.id) == {
            "child": "card-A",
            "main": None,
            "empty": None,
            "numeric": None,
        }

        # An update that drops the field must clear the column, not keep the
        # stale parent: the column mirrors the payload, it is not first-write
        # sticky.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_input(
                    session.id,
                    "child",
                    order_seq=1,
                    content_hash="sha256:child-without-parent",
                )
            ],
        )
        assert (await _parent_item_column(session.id))["child"] is None
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


def _seed_window(
    client: Any, access_token: str, session_id: str
) -> None:
    """Two main rows then two child rows: the default page's newest rows are
    child rows, which is exactly the blank-page setup."""

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _item_payload(session_id, "m1", order_seq=1),
            _item_payload(session_id, "m2", order_seq=2),
            _item_payload(session_id, "c1", order_seq=3, parent_item_id="card-A"),
            _item_payload(session_id, "c2", order_seq=4, parent_item_id="card-A"),
        ],
    )


def test_timeline_defaults_include_agent_children(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_window(client, access_token, session_id)

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "latest", "limit": 2},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert _ids(body["items"]) == ["c1", "c2"]
    assert body["excludesAgentChildren"] is False

    snapshot = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"limit": 2},
    )
    assert snapshot.status_code == 200, snapshot.text
    snapshot_body = snapshot.json()
    assert _ids(snapshot_body["timeline"]["items"]) == ["c1", "c2"]
    assert snapshot_body["excludesAgentChildren"] is False


def test_exclude_agent_children_returns_the_main_window(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_window(client, access_token, session_id)

    latest = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "latest", "limit": 2, "excludeAgentChildren": True},
    )
    assert latest.status_code == 200, latest.text
    latest_body = latest.json()
    assert _ids(latest_body["items"]) == ["m1", "m2"]
    assert latest_body["excludesAgentChildren"] is True

    history = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "history",
            "beforeOrderSeq": 5,
            "limit": 2,
            "excludeAgentChildren": True,
        },
    )
    assert history.status_code == 200, history.text
    history_body = history.json()
    assert _ids(history_body["items"]) == ["m1", "m2"]
    assert history_body["excludesAgentChildren"] is True

    snapshot = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"limit": 2, "excludeAgentChildren": True},
    )
    assert snapshot.status_code == 200, snapshot.text
    snapshot_body = snapshot.json()
    assert _ids(snapshot_body["timeline"]["items"]) == ["m1", "m2"]
    assert snapshot_body["excludesAgentChildren"] is True


def test_children_mode_requires_a_parent_item_id(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_window(client, access_token, session_id)

    missing = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "children"},
    )
    assert missing.status_code == 422, missing.text

    empty = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "children", "parentItemId": ""},
    )
    assert empty.status_code == 422, empty.text


def test_children_mode_pages_the_cards_rows(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _item_payload(session_id, "m1", order_seq=1),
            _item_payload(session_id, "a1", order_seq=2, parent_item_id="card-A"),
            _item_payload(session_id, "m2", order_seq=3),
            _item_payload(session_id, "a2", order_seq=4, parent_item_id="card-A"),
            _item_payload(session_id, "b1", order_seq=5, parent_item_id="card-B"),
            _item_payload(session_id, "a3", order_seq=6, parent_item_id="card-A"),
        ],
    )

    first = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "children",
            "parentItemId": "card-A",
            "limit": 2,
        },
    )
    assert first.status_code == 200, first.text
    first_body = first.json()
    assert _ids(first_body["items"]) == ["a2", "a3"]
    assert first_body["hasMore"] is True
    # ``children`` mode does not honor the main-only flag, so it must not
    # claim that it did.
    assert first_body["excludesAgentChildren"] is False

    second = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "children",
            "parentItemId": "card-A",
            "beforeOrderSeq": 4,
            "limit": 2,
        },
    )
    assert second.status_code == 200, second.text
    second_body = second.json()
    assert _ids(second_body["items"]) == ["a1"]
    assert second_body["hasMore"] is False

    other = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "children", "parentItemId": "card-B", "limit": 10},
    )
    assert other.status_code == 200, other.text
    assert _ids(other.json()["items"]) == ["b1"]


def test_children_mode_applies_the_serialized_byte_budget(tmp_path, monkeypatch) -> None:
    """A card's children get the same 2MB serialized-byte ceiling as the
    snapshot: past it, keep the newest rows and raise hasMore so the client
    pages the rest through beforeOrderSeq."""

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _item_payload(session_id, "a1", order_seq=1, parent_item_id="card-A"),
            _item_payload(session_id, "a2", order_seq=2, parent_item_id="card-A"),
            _item_payload(session_id, "a3", order_seq=3, parent_item_id="card-A"),
        ],
    )
    # A 1-byte budget forces truncation while still keeping one item.
    monkeypatch.setenv(SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV, "1")

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "children", "parentItemId": "card-A", "limit": 10},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert _ids(body["items"]) == ["a3"]
    assert body["hasMore"] is True

    # The truncated page is still walkable: beforeOrderSeq = the oldest row
    # kept, until the budget stops truncating.
    second = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "children",
            "parentItemId": "card-A",
            "beforeOrderSeq": 3,
            "limit": 10,
        },
    )
    assert second.status_code == 200, second.text
    second_body = second.json()
    assert _ids(second_body["items"]) == ["a2"]
    assert second_body["hasMore"] is True

    third = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "children",
            "parentItemId": "card-A",
            "beforeOrderSeq": 2,
            "limit": 10,
        },
    )
    assert third.status_code == 200, third.text
    third_body = third.json()
    assert _ids(third_body["items"]) == ["a1"]
    assert third_body["hasMore"] is False


def test_changes_mode_ignores_exclude_agent_children(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _item_payload(session_id, "m1", order_seq=1),
            _item_payload(session_id, "c1", order_seq=2, parent_item_id="card-A"),
        ],
    )

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "changes",
            "afterSeq": 0,
            "limit": 10,
            "excludeAgentChildren": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert _ids(body["items"]) == ["m1", "c1"]
    assert body["excludesAgentChildren"] is False
