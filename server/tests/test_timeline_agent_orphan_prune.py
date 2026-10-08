"""Full-rebuild agent-call orphan pruning (alias durability T3b).

A history rebuild supersedes the stored agent-call cards: a same-task card the
rebuilt batch does not cover is a leftover of an older projection generation
(the restart-race alias twins, 2026-10-09). These tests pin the narrow
server-side cleanup that runs when a rebased rebuild arrives:

- only agent-call rows are ever touched;
- a leftover is pruned only when every task it names is covered by the batch
  itself (a compaction rebase cannot reach pre-compaction cards, so those
  stay);
- rows outside the session fence are never candidates;
- non-rebased syncs and merges never prune.
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from test_backend_mvp import (
    create_connector_and_session,
    make_client,
    session_view_for_assertions,
)

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store


def agent_card_input(
    item_id: str,
    *,
    tasks: dict[str, Any],
    order_seq: int,
    session_id: str,
    status: str = "done",
    content_hash: str | None = None,
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": status,
            "role": "tool",
            "content": {
                "kind": "agent_call",
                "action": "invoke",
                "agents": tasks,
            },
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": content_hash or f"sha256:{item_id}",
        }
    )


def plain_tool_input(item_id: str, *, order_seq: int, session_id: str) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": "done",
            "role": "tool",
            "content": {"kind": "bash", "toolName": "Bash"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


async def _store_with_session(tmp_path: Any) -> tuple[Store, Any]:
    db_path = tmp_path / "timeline-agent-prune.sqlite3"
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
async def test_rebuild_prune_removes_same_task_leftovers(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        canonical = agent_card_input(
            "card_task_a",
            tasks={"task_a": {"status": "completed"}},
            order_seq=1,
            session_id=session.id,
        )
        twin = agent_card_input(
            "card_task_a_resume",
            tasks={"task_a": {"status": "completed"}},
            order_seq=2,
            session_id=session.id,
        )
        legacy = agent_card_input(
            "card_task_old",
            tasks={"task_old": {"status": "completed"}},
            order_seq=3,
            session_id=session.id,
        )
        plain = plain_tool_input("tool_bash", order_seq=4, session_id=session.id)
        await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical, twin, legacy, plain],
        )

        await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical],
            prune_orphan_agent_calls=True,
        )

        rows = {item.id for item in await store.timeline.read(session.id)}
        # The covered card stays; the same-task leftover is gone; a card whose
        # task the batch does not cover keeps its row; non-agent rows are
        # never candidates.
        assert rows == {"card_task_a", "card_task_old", "tool_bash"}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_rebuild_prune_runs_when_batch_has_no_changes(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        canonical = agent_card_input(
            "card_task_a",
            tasks={"task_a": {"status": "completed"}},
            order_seq=1,
            session_id=session.id,
        )
        twin = agent_card_input(
            "card_task_a_resume",
            tasks={"task_a": {"status": "completed"}},
            order_seq=2,
            session_id=session.id,
        )
        await store.sync_timeline_items(session_id=session.id, items=[canonical, twin])
        before_seq = await store.get_session_seq(session.id)

        result = await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical],
            prune_orphan_agent_calls=True,
        )

        assert result.changed is False
        rows = {item.id for item in await store.timeline.read(session.id)}
        assert rows == {"card_task_a"}
        # A deletion with no item write of its own still advances the session
        # so clients holding the removed row refetch.
        assert await store.get_session_seq(session.id) > before_seq
    finally:
        await store.close()


@pytest.mark.anyio
async def test_rebuild_prune_keeps_cards_with_uncovered_tasks(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        canonical = agent_card_input(
            "card_task_a",
            tasks={"task_a": {"status": "completed"}},
            order_seq=1,
            session_id=session.id,
        )
        multi = agent_card_input(
            "card_tasks_mixed",
            tasks={"task_a": {"status": "completed"}, "task_old": {"status": "completed"}},
            order_seq=2,
            session_id=session.id,
        )
        empty_agents = agent_card_input(
            "card_no_agents",
            tasks={},
            order_seq=3,
            session_id=session.id,
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical, multi, empty_agents],
        )

        await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical],
            prune_orphan_agent_calls=True,
        )

        rows = {item.id for item in await store.timeline.read(session.id)}
        # A card is pruned only when EVERY task it names is covered: `task_old`
        # is untouched by this batch, so both mixed and empty cards stay.
        assert rows == {"card_task_a", "card_tasks_mixed", "card_no_agents"}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_rebuild_prune_is_noop_without_covered_tasks(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        old_card = agent_card_input(
            "card_task_old",
            tasks={"task_old": {"status": "completed"}},
            order_seq=1,
            session_id=session.id,
        )
        plain = plain_tool_input("tool_bash", order_seq=2, session_id=session.id)
        await store.sync_timeline_items(session_id=session.id, items=[old_card, plain])

        await store.sync_timeline_items(
            session_id=session.id,
            items=[plain],
            prune_orphan_agent_calls=True,
        )

        rows = {item.id for item in await store.timeline.read(session.id)}
        assert rows == {"card_task_old", "tool_bash"}
    finally:
        await store.close()


@pytest.mark.anyio
async def test_rebuild_prune_is_idempotent(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        canonical = agent_card_input(
            "card_task_a",
            tasks={"task_a": {"status": "completed"}},
            order_seq=1,
            session_id=session.id,
        )
        twin = agent_card_input(
            "card_task_a_resume",
            tasks={"task_a": {"status": "completed"}},
            order_seq=2,
            session_id=session.id,
        )
        await store.sync_timeline_items(session_id=session.id, items=[canonical, twin])

        first = await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical],
            prune_orphan_agent_calls=True,
        )
        rows_after_first = {item.id for item in await store.timeline.read(session.id)}
        second = await store.sync_timeline_items(
            session_id=session.id,
            items=[canonical],
            prune_orphan_agent_calls=True,
        )
        rows_after_second = {item.id for item in await store.timeline.read(session.id)}

        assert first.changed is False and second.changed is False
        assert rows_after_first == rows_after_second == {"card_task_a"}
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Notification-path tests: the prune is armed by the rebuild flag, not by
# ordinary merges, and a complete snapshot keeps its full-replace behavior.
# ---------------------------------------------------------------------------


def _claude_card(
    session_id: str,
    card_id: str,
    task_id: str,
    order_seq: int,
) -> dict[str, Any]:
    return {
        "id": card_id,
        "sessionId": session_id,
        "type": "tool",
        "status": "done",
        "role": "tool",
        "content": {
            "kind": "agent_call",
            "action": "invoke",
            "agents": {task_id: {"status": "completed"}},
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


def _post_sync(
    client: Any,
    access_token: str,
    session_id: str,
    items: list[dict[str, Any]],
    *,
    metadata: dict[str, Any] | None = None,
    complete: bool = False,
) -> None:
    params: dict[str, Any] = {
        "sessionId": session_id,
        "complete": complete,
        "items": items,
    }
    if metadata is not None:
        params["metadata"] = metadata
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={"notifications": [{"method": "timeline.sync", "params": params}]},
    )
    assert response.status_code == 200, response.text


def _session_item_ids(client: Any, session_id: str, headers: dict[str, str]) -> set[str]:
    state = session_view_for_assertions(client, session_id, headers)
    return {item["id"] for item in state["items"]}


def test_rebased_history_sync_prunes_orphan_agent_cards(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _claude_card(session_id, "claude_tool_card_a", "task_a", 1),
            _claude_card(session_id, "claude_tool_card_a_resume", "task_a", 2),
            _claude_card(session_id, "claude_tool_card_old", "task_old", 3),
        ],
    )
    assert {
        "claude_tool_card_a",
        "claude_tool_card_a_resume",
        "claude_tool_card_old",
    } <= _session_item_ids(client, session_id, headers)

    _post_sync(
        client,
        access_token,
        session_id,
        [_claude_card(session_id, "claude_tool_card_a", "task_a", 1)],
        metadata={"source": "claude.history.sync", "rebased": True},
    )

    ids = _session_item_ids(client, session_id, headers)
    assert "claude_tool_card_a" in ids
    assert "claude_tool_card_a_resume" not in ids
    # The rebuild does not cover `task_old`, so its card is not a leftover of
    # this rebuild and keeps its row.
    assert "claude_tool_card_old" in ids


def test_plain_merge_sync_keeps_orphan_agent_cards(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _claude_card(session_id, "claude_tool_card_a", "task_a", 1),
            _claude_card(session_id, "claude_tool_card_a_resume", "task_a", 2),
        ],
    )

    _post_sync(
        client,
        access_token,
        session_id,
        [_claude_card(session_id, "claude_tool_card_a", "task_a", 1)],
        metadata={"source": "claude.history.sync", "rebased": False},
    )

    ids = _session_item_ids(client, session_id, headers)
    assert ids >= {"claude_tool_card_a", "claude_tool_card_a_resume"}


def test_complete_snapshot_sync_removes_orphan_agent_cards(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _claude_card(session_id, "claude_tool_card_a", "task_a", 1),
            _claude_card(session_id, "claude_tool_card_a_resume", "task_a", 2),
        ],
    )

    _post_sync(
        client,
        access_token,
        session_id,
        [_claude_card(session_id, "claude_tool_card_a", "task_a", 1)],
        metadata={"source": "claude.history.sync", "rebased": True},
        complete=True,
    )

    ids = _session_item_ids(client, session_id, headers)
    assert ids == {"claude_tool_card_a"}
