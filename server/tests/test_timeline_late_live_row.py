"""A live row that arrives late must land inside its own message group.

2026-11-10 production audit: eight sessions held one ``tool_result`` row whose
``order_seq`` was unique and positive but sat after later user messages (seven
of them were the session's last row). The row reached the Server through the
single-item live writer after its message had already been stored; that writer
assigns ``max(order_seq) + 1`` to every new row, so the late sibling was
appended to the tail instead of the message it belongs to. Seven of the eight
were verified against the source transcript: the ``tool_result`` record follows
its ``tool_use`` within a few lines, with no user message in between.

These tests pin the intended behaviour at the Server API (real app + real
PostgreSQL):

- a late tool row for a stored message lands between that message's body and
  the next user message;
- a normal streaming row for a brand-new message still appends (no behaviour
  change on the hot path);
- replaying the same live upsert is idempotent (no second move).
"""

from __future__ import annotations

from typing import Any

from test_backend_mvp import (
    create_connector_and_session,
    make_client,
    session_view_for_assertions,
    wait_for,
)

MESSAGE_ID = "msg_late_live_1"
MESSAGE_2_ID = "msg_late_live_2"
USER_1 = "late_live_user_1"
USER_2 = "late_live_user_2"
BODY_1 = "late_live_body_1"
REASONING_1 = "late_live_reasoning_1"
TOOL_1 = "late_live_tool_1"
BODY_2 = "late_live_body_2"


def _source(
    item_id: str,
    *,
    item_type: str,
    native_message_id: str | None = None,
    block_index: int | None = None,
) -> dict[str, Any]:
    source: dict[str, Any] = {
        "runtime": "claude",
        "itemId": item_id,
        "itemType": item_type,
    }
    if native_message_id is not None:
        source["nativeMessageId"] = native_message_id
    if block_index is not None:
        source["blockIndex"] = block_index
    return source


def _item(
    item_id: str,
    *,
    type_: str,
    role: str | None,
    content: dict[str, Any],
    source: dict[str, Any],
    order_seq: int,
    content_hash: str,
) -> dict[str, Any]:
    return {
        "id": item_id,
        "sessionId": "",  # filled with the created session id before sending
        "type": type_,
        "status": "done",
        "role": role,
        "content": content,
        "source": source,
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": content_hash,
    }


def _send_sync(ws: Any, session_id: str, items: list[dict[str, Any]]) -> None:
    for item in items:
        item["sessionId"] = session_id
    ws.send_json(
        {
            "type": "notification",
            "method": "timeline.sync",
            "params": {
                "sessionId": session_id,
                "items": items,
                "metadata": {"windowOrder": True},
            },
        }
    )


def _user_item(item_id: str, text: str, order_seq: int) -> dict[str, Any]:
    return _item(
        item_id,
        type_="message",
        role="user",
        content={"text": text, "format": "markdown"},
        source=_source(item_id, item_type="user"),
        order_seq=order_seq,
        content_hash=f"sha256:{item_id}",
    )


def _assistant_item(
    item_id: str, text: str, order_seq: int, message_id: str
) -> dict[str, Any]:
    return _item(
        item_id,
        type_="message",
        role="assistant",
        content={"text": text, "format": "markdown"},
        source=_source(message_id, item_type="assistant"),
        order_seq=order_seq,
        content_hash=f"sha256:{item_id}",
    )


def _reasoning_item(order_seq: int) -> dict[str, Any]:
    return _item(
        REASONING_1,
        type_="system",
        role="system",
        content={"kind": "reasoning", "blockType": "thinking", "text": "think"},
        source=_source(MESSAGE_ID, item_type="thinking"),
        order_seq=order_seq,
        content_hash="sha256:reasoning",
    )


def _late_tool_item() -> dict[str, Any]:
    return _item(
        TOOL_1,
        type_="tool",
        role="tool",
        content={"kind": "command", "command": "ls", "output": "ok"},
        source=_source(
            "call_late_1",
            item_type="tool_result",
            native_message_id=MESSAGE_ID,
            block_index=0,
        ),
        # A live item carries its local store's number, which is below the
        # Server's current max in a long session — the writer appends it.
        order_seq=2,
        content_hash="sha256:tool",
    )


def _wait_for_item(client, session_id: str, headers: dict[str, str], item_id: str):
    def read_state():
        body = session_view_for_assertions(client, session_id, headers)
        return body if any(item["id"] == item_id for item in body["items"]) else None

    return wait_for(read_state)


def _orders(state: dict[str, Any]) -> dict[str, int]:
    return {item["id"]: item["orderSeq"] for item in state["items"]}


def test_late_live_tool_row_lands_inside_its_message_group(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        # The early turn is already stored: user, reasoning, assistant body.
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_1, "first", 1),
                _reasoning_item(2),
                _assistant_item(BODY_1, "early reply", 3, MESSAGE_ID),
            ],
        )
        # Later turns arrive before the early turn's tool result does.
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_2, "later", 4),
                _assistant_item(BODY_2, "later reply", 5, MESSAGE_2_ID),
            ],
        )
        state = _wait_for_item(client, session_id, headers, BODY_2)
        assert state is not None

        # The tool result for the early message reaches the live single-item
        # writer only now.
        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {**_late_tool_item(), "sessionId": session_id},
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, TOOL_1)
        assert state is not None, "the late tool row was never stored"

    orders = _orders(state)
    body_order = orders[BODY_1]
    user_order = orders[USER_2]
    tool_order = orders[TOOL_1]

    # The bug: max(order_seq)+1 puts the tool row after the later user turn.
    assert body_order < tool_order < user_order, (
        f"late tool row is outside its message: body={body_order} "
        f"tool={tool_order} next_user={user_order}"
    )


def test_late_live_reasoning_row_lands_before_its_message_body(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_1, "first", 1),
                _assistant_item(BODY_1, "early reply", 2, MESSAGE_ID),
            ],
        )
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_2, "later", 3),
                _assistant_item(BODY_2, "later reply", 4, MESSAGE_2_ID),
            ],
        )
        assert _wait_for_item(client, session_id, headers, BODY_2) is not None

        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {**_reasoning_item(2), "sessionId": session_id},
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, REASONING_1)
        assert state is not None

    orders = _orders(state)
    assert orders[REASONING_1] < orders[BODY_1] < orders[USER_2], (
        f"late reasoning row is outside its message: reasoning="
        f"{orders[REASONING_1]} body={orders[BODY_1]} next_user={orders[USER_2]}"
    )


def test_streaming_tool_row_for_a_new_message_still_appends(tmp_path):
    """The hot path must not change: a new message's rows keep appending."""
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_1, "first", 1),
                _reasoning_item(2),
                _assistant_item(BODY_1, "early reply", 3, MESSAGE_ID),
            ],
        )
        state = _wait_for_item(client, session_id, headers, BODY_1)
        assert state is not None
        body_order = _orders(state)[BODY_1]

        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {**_late_tool_item(), "sessionId": session_id},
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, TOOL_1)
        assert state is not None

    orders = _orders(state)
    assert orders[TOOL_1] > body_order
    # Nothing was stored after the body, so the row is the newest one.
    assert orders[TOOL_1] == max(orders.values())


def test_replaying_the_late_upsert_does_not_move_the_row(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_1, "first", 1),
                _reasoning_item(2),
                _assistant_item(BODY_1, "early reply", 3, MESSAGE_ID),
            ],
        )
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_2, "later", 4),
                _assistant_item(BODY_2, "later reply", 5, MESSAGE_2_ID),
            ],
        )
        assert _wait_for_item(client, session_id, headers, BODY_2) is not None

        for _ in range(2):
            ws.send_json(
                {
                    "type": "notification",
                    "method": "timeline.itemUpsert",
                    "params": {
                    "sessionId": session_id,
                    "item": {**_late_tool_item(), "sessionId": session_id},
                },
                }
            )
            state = _wait_for_item(client, session_id, headers, TOOL_1)
            assert state is not None

    orders = _orders(state)
    assert orders[BODY_1] < orders[TOOL_1] < orders[USER_2]


def test_late_live_body_lands_between_reasoning_and_tools(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        # The early message stored its reasoning and tool rows; its body is
        # the row that arrives late.
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_1, "first", 1),
                _reasoning_item(2),
                _late_tool_item(),
            ],
        )
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_2, "later", 4),
                _assistant_item(BODY_2, "later reply", 5, MESSAGE_2_ID),
            ],
        )
        assert _wait_for_item(client, session_id, headers, BODY_2) is not None

        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {
                        **_assistant_item(BODY_1, "early reply", 2, MESSAGE_ID),
                        "sessionId": session_id,
                    },
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, BODY_1)
        assert state is not None

    orders = _orders(state)
    assert (
        orders[REASONING_1]
        < orders[BODY_1]
        < orders[TOOL_1]
        < orders[USER_2]
    ), (
        f"late body is outside its message: reasoning={orders[REASONING_1]} "
        f"body={orders[BODY_1]} tool={orders[TOOL_1]} "
        f"next_user={orders[USER_2]}"
    )


def test_late_live_body_with_only_reasoning_lands_before_the_next_turn(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        _send_sync(
            ws,
            session_id,
            [_user_item(USER_1, "first", 1), _reasoning_item(2)],
        )
        _send_sync(
            ws,
            session_id,
            [
                _user_item(USER_2, "later", 3),
                _assistant_item(BODY_2, "later reply", 4, MESSAGE_2_ID),
            ],
        )
        assert _wait_for_item(client, session_id, headers, BODY_2) is not None

        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {
                        **_assistant_item(BODY_1, "early reply", 2, MESSAGE_ID),
                        "sessionId": session_id,
                    },
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, BODY_1)
        assert state is not None

    orders = _orders(state)
    assert orders[REASONING_1] < orders[BODY_1] < orders[USER_2], (
        f"late body is outside its message: reasoning={orders[REASONING_1]} "
        f"body={orders[BODY_1]} next_user={orders[USER_2]}"
    )


def test_normal_body_still_appends_after_its_reasoning(tmp_path):
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    with client.websocket_connect(
        "/connector/ws",
        headers={"Authorization": f"Bearer {access_token}"},
    ) as ws:
        _send_sync(
            ws,
            session_id,
            [_user_item(USER_1, "first", 1), _reasoning_item(2)],
        )
        assert _wait_for_item(client, session_id, headers, REASONING_1) is not None

        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {
                        **_assistant_item(BODY_1, "early reply", 2, MESSAGE_ID),
                        "sessionId": session_id,
                    },
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, BODY_1)
        assert state is not None
        ws.send_json(
            {
                "type": "notification",
                "method": "timeline.itemUpsert",
                "params": {
                    "sessionId": session_id,
                    "item": {**_late_tool_item(), "sessionId": session_id},
                },
            }
        )
        state = _wait_for_item(client, session_id, headers, TOOL_1)
        assert state is not None

    orders = _orders(state)
    assert orders[REASONING_1] < orders[BODY_1] < orders[TOOL_1]
    assert orders[TOOL_1] == max(orders.values())
