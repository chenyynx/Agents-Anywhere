"""The deferred-activity window must keep the conversation anchor.

A heavy turn adds hundreds of tool/reasoning rows after the last message. The
window used to decline in that shape (``applied=False``), and the snapshot fell
back to the plain newest reader, which returned activity rows only — the first
screen had no message at all. These tests pin the extended window that keeps
the anchor and the byte budget that still bounds the response.
"""

from __future__ import annotations

import asyncio

from agent_server.core.models import TimelineItemIn
from test_backend_mvp import create_connector_and_session, make_client

WINDOW_PARAMS = {
    "limit": 100,
    "excludeAgentChildren": "true",
    "deferActivity": "true",
}


def _message(session_id: str, order_seq: int) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": f"msg_{order_seq}",
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": f"message {order_seq}", "format": "markdown"},
            "source": {
                "runtime": "codex",
                "sessionId": "thr_1",
                "itemId": f"item_msg_{order_seq}",
                "itemType": "agentMessage",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:msg_{order_seq}",
        }
    )


def _tool(session_id: str, order_seq: int, *, output: str = "") -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": f"tool_{order_seq}",
            "sessionId": session_id,
            "type": "tool",
            "status": "done",
            "role": "tool",
            "content": {"kind": "command", "command": "ls", "output": output},
            "source": {
                "runtime": "codex",
                "sessionId": "thr_1",
                "itemId": f"item_tool_{order_seq}",
                "itemType": "tool_result",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:tool_{order_seq}",
        }
    )


def _reasoning(session_id: str, order_seq: int) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": f"think_{order_seq}",
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "content": {"kind": "reasoning", "text": f"thinking {order_seq}"},
            "source": {
                "runtime": "codex",
                "sessionId": "thr_1",
                "itemId": f"item_think_{order_seq}",
                "itemType": "reasoning",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:think_{order_seq}",
        }
    )


def _item_bytes(item: dict) -> int:
    import json

    return len(
        json.dumps({"item": item}, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
    )


def _seed(client, session_id: str, items: list[TimelineItemIn]) -> None:
    async def seed() -> None:
        for item in items:
            await client.app.state.store.upsert_timeline_item(
                session_id=session_id, item=item
            )

    asyncio.run(seed())


def _snapshot(client, session_id: str, headers: dict[str, str]) -> dict:
    response = client.get(
        f"/sessions/{session_id}/snapshot", params=WINDOW_PARAMS, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()["timeline"]


def test_heavy_activity_tail_keeps_the_message_anchor(tmp_path):
    """350 tool rows after the last message must not push it out of the window."""
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    items = [_message(session_id, 1)] + [_tool(session_id, order_seq) for order_seq in range(2, 352)]
    _seed(client, session_id, items)

    timeline = _snapshot(client, session_id, headers)

    ids = [item["id"] for item in timeline["items"]]
    assert "msg_1" in ids, "the first screen lost its conversation anchor"
    assert len(ids) == 351
    assert timeline["hasMore"] is False


def test_heavy_reasoning_tail_keeps_the_message_anchor(tmp_path):
    """Reasoning rows are activity too; a long thinking tail has the same shape."""
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    items = [_message(session_id, 1)] + [_reasoning(session_id, order_seq) for order_seq in range(2, 322)]
    _seed(client, session_id, items)

    timeline = _snapshot(client, session_id, headers)

    ids = [item["id"] for item in timeline["items"]]
    assert "msg_1" in ids
    assert len(ids) == 321


def test_activity_only_window_still_falls_back(tmp_path):
    """No display row in reach: the plain newest reader keeps its old behavior."""
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    _seed(client, session_id, [_tool(session_id, order_seq) for order_seq in range(1, 201)])

    timeline = _snapshot(client, session_id, headers)

    assert len(timeline["items"]) == 100, "the fallback reader keeps its 100-row page"
    assert all(item["type"] == "tool" for item in timeline["items"])


def test_short_conversation_keeps_the_normal_window(tmp_path):
    """Under the row span the window is unchanged: every row comes back."""
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    items = [_message(session_id, 1)] + [_tool(session_id, order_seq) for order_seq in range(2, 12)]
    _seed(client, session_id, items)

    timeline = _snapshot(client, session_id, headers)

    ids = [item["id"] for item in timeline["items"]]
    assert ids[0] == "msg_1"
    assert len(ids) == 11
    assert timeline["hasMore"] is False


def test_extended_window_is_bounded_by_the_byte_budget(tmp_path):
    """Extending for the anchor must not smuggle an unbounded payload out.

    Eight hundred 4 KB tool rows are ~3.2 MB of payload. The trim summarises
    the oldest tail rows (they stay in the window as their collapsed line), so
    the response still fits the 2 MB snapshot budget while keeping the anchor.
    """
    from agent_server.api.sessions import SNAPSHOT_TIMELINE_BYTE_BUDGET

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    items = [_message(session_id, 1)] + [
        _tool(session_id, order_seq, output="x" * 4000)
        for order_seq in range(2, 802)
    ]
    _seed(client, session_id, items)

    timeline = _snapshot(client, session_id, headers)

    ids = [item["id"] for item in timeline["items"]]
    assert "msg_1" in ids, "the byte trim must never drop the newest display row"
    assert len(ids) == 801, "summarising keeps the rows; only payloads shrink"
    total = sum(_item_bytes(item) for item in timeline["items"])
    assert total <= SNAPSHOT_TIMELINE_BYTE_BUDGET, total
    assert timeline["hasMore"] is False
