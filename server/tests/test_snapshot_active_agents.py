"""Snapshot active-Agent carry (``activeAgents``, session open coverage P1).

A session snapshot ships the session's non-terminal Agent cards beside the
timeline page, so a client learns about in-flight subagents even when their
cards sit outside the (100-item / 2MB) timeline window and no live frame has
arrived to announce them. These tests pin the server half of the contract:

- only ``type='tool'`` rows whose ``content.kind == 'agent_call'`` qualify;
- a terminal card never rides the snapshot (no matter its task entries);
- an active card does, even when it sits outside the timeline page;
- the list is capped at 20, keeping the newest by ``order_seq``;
- the wire field is ``activeAgents``, defaulting to an empty list.
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from test_backend_mvp import create_connector_and_session, make_client

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store


def _timeline_input(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    status: str,
    content: dict[str, Any],
    item_type: str = "tool",
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": item_type,
            "status": status,
            "role": "tool" if item_type == "tool" else "assistant",
            "content": content,
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            # Status is part of the state identity here (the store skips
            # updates whose contentHash is unchanged), so a status flip is a
            # real write, as the connector's re-publishes are.
            "contentHash": f"sha256:{item_id}:{status}",
        }
    )


def agent_card_input(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    status: str = "running",
    tasks: dict[str, Any] | None = None,
) -> TimelineItemIn:
    return _timeline_input(
        item_id,
        session_id=session_id,
        order_seq=order_seq,
        status=status,
        content={
            "kind": "agent_call",
            "action": "invoke",
            "description": item_id,
            "agents": (
                tasks if tasks is not None else {"task_a": {"status": "running"}}
            ),
        },
    )


def plain_tool_input(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    status: str = "running",
) -> TimelineItemIn:
    return _timeline_input(
        item_id,
        session_id=session_id,
        order_seq=order_seq,
        status=status,
        content={"kind": "bash", "toolName": "Bash"},
    )


async def _store_with_session(tmp_path: Any) -> tuple[Store, Any]:
    db_path = tmp_path / "snapshot-active-agents.sqlite3"
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


@pytest.mark.anyio
async def test_list_active_agent_cards_selects_only_live_agent_cards(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                agent_card_input("card_running", session_id=session.id, order_seq=1),
                # An active tool row that is not an Agent card.
                plain_tool_input("tool_running", session_id=session.id, order_seq=2),
                # Terminal cards never ride along.
                agent_card_input(
                    "card_done", session_id=session.id, order_seq=3, status="done"
                ),
                agent_card_input(
                    "card_interrupted",
                    session_id=session.id,
                    order_seq=4,
                    status="interrupted",
                ),
                agent_card_input(
                    "card_waiting",
                    session_id=session.id,
                    order_seq=5,
                    status="waiting_approval",
                ),
                agent_card_input(
                    "card_pending", session_id=session.id, order_seq=6, status="pending"
                ),
                # An active non-tool row: only tool rows are Agent cards.
                _timeline_input(
                    "message_running",
                    session_id=session.id,
                    order_seq=7,
                    status="running",
                    content={"text": "hello"},
                    item_type="message",
                ),
            ],
        )

        cards = await store.list_active_agent_cards(session_id=session.id)

        assert [card.id for card in cards] == [
            "card_running",
            "card_waiting",
            "card_pending",
        ]
        # The card payload survives the read whole: the client folds the very
        # row it would have received as a timeline item.
        first = cards[0]
        assert first.status == "running"
        assert first.content["kind"] == "agent_call"
        assert first.content["agents"] == {"task_a": {"status": "running"}}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_list_active_agent_cards_is_empty_without_active_cards(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                agent_card_input(
                    "card_done", session_id=session.id, order_seq=1, status="done"
                ),
                agent_card_input(
                    "card_failed", session_id=session.id, order_seq=2, status="failed"
                ),
                agent_card_input(
                    "card_cancelled",
                    session_id=session.id,
                    order_seq=3,
                    status="cancelled",
                ),
                plain_tool_input(
                    "tool_running", session_id=session.id, order_seq=4
                ),
            ],
        )

        cards = await store.list_active_agent_cards(session_id=session.id)

        assert cards == []
    finally:
        await store.close()


@pytest.mark.anyio
async def test_list_active_agent_cards_caps_at_the_newest(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                # Two cards older than a crowd of active non-agent tool rows:
                # the cap counts cards, so neither may be crowded out.
                agent_card_input("card_old_1", session_id=session.id, order_seq=1),
                agent_card_input("card_old_2", session_id=session.id, order_seq=2),
                *[
                    plain_tool_input(
                        f"tool_{index:03d}", session_id=session.id, order_seq=100 + index
                    )
                    for index in range(1, 31)
                ],
                *[
                    agent_card_input(
                        f"card_{index:02d}", session_id=session.id, order_seq=200 + index
                    )
                    for index in range(1, 26)
                ],
            ],
        )

        cards = await store.list_active_agent_cards(session_id=session.id)

        # The newest 20 cards by order_seq, oldest first — exactly the cards
        # the default cap keeps, with the older pair past the cap.
        assert [card.id for card in cards] == [
            f"card_{index:02d}" for index in range(6, 26)
        ]

        narrowed = await store.list_active_agent_cards(
            session_id=session.id, limit=3
        )
        assert [card.id for card in narrowed] == ["card_23", "card_24", "card_25"]

        # With only the two old cards left active, the 30 non-agent rows do
        # not consume the budget.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                agent_card_input(
                    f"card_{index:02d}",
                    session_id=session.id,
                    order_seq=200 + index,
                    status="done",
                )
                for index in range(1, 26)
            ],
        )
        remaining = await store.list_active_agent_cards(session_id=session.id)
        assert [card.id for card in remaining] == ["card_old_1", "card_old_2"]
    finally:
        await store.close()


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
    assert response.json()["rejected"] == []


def _claude_card_payload(
    session_id: str, card_id: str, *, status: str, order_seq: int
) -> dict[str, Any]:
    return {
        "id": card_id,
        "sessionId": session_id,
        "type": "tool",
        "status": status,
        "role": "tool",
        "content": {
            "kind": "agent_call",
            "action": "invoke",
            "description": card_id,
            "agents": {"task_" + card_id: {"status": "running"}},
        },
        "source": {
            "runtime": "claude",
            "sessionId": "claude_ext_1",
            "itemId": card_id,
            "itemType": "toolUse",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{card_id}",
    }


def test_snapshot_response_carries_active_agents_outside_the_timeline_window(
    tmp_path,
) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _claude_card_payload(
                session_id, "claude_tool_running", status="running", order_seq=1
            ),
            _claude_card_payload(
                session_id, "claude_tool_done", status="done", order_seq=2
            ),
            _claude_card_payload(
                session_id, "claude_tool_failed", status="failed", order_seq=3
            ),
        ],
    )

    response = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"limit": 1},
    )
    assert response.status_code == 200, response.text
    snapshot = response.json()

    # The wire field is `activeAgents` (camelCase), never snake_case.
    assert "activeAgents" in snapshot
    assert "active_agents" not in snapshot
    active = snapshot["activeAgents"]
    assert [item["id"] for item in active] == ["claude_tool_running"]
    # The card rides whole, with its live task map, so the client can fold it
    # through the same path a live frame would take.
    assert active[0]["content"]["kind"] == "agent_call"
    assert active[0]["content"]["agents"] == {"task_claude_tool_running": {"status": "running"}}
    assert active[0]["status"] == "running"
    # The client matches the carried cards to the open session by sessionId.
    assert active[0]["sessionId"] == session_id
    # ...and it proves the independent carry: with limit=1 the running card is
    # older than the page and absent from the timeline window.
    page_ids = [item["id"] for item in snapshot["timeline"]["items"]]
    assert page_ids == ["claude_tool_failed"]
    assert "claude_tool_running" not in page_ids


def test_snapshot_active_agents_defaults_to_empty_array(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _claude_card_payload(
                session_id, "claude_tool_done", status="done", order_seq=1
            )
        ],
    )

    response = client.get(f"/sessions/{session_id}/snapshot", headers=headers)
    assert response.status_code == 200, response.text
    snapshot = response.json()

    assert snapshot["activeAgents"] == []
