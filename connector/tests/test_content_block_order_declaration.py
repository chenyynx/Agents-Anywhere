"""Rows declare the message's real block order (pp 2026-11-19).

One assistant message may emit a tool call before its trailing text
(``[thinking, tool_use, text]``). The legacy ``blockIndex`` only counts
``tool_use`` blocks, so the server's in-message invariant (RBT) moved the tool
row below the body and the client split the step group.

Each orderable row now declares ``source.contentBlockIndex`` — its absolute
index in the message's ``content`` array — computed wherever the projection
holds the full message (history/turn-end). The server keeps that real order
when every sibling declares it and falls back to RBT otherwise.
"""

from __future__ import annotations

from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    message_text_content_index,
)
from connector.server.runtime_host import _timeline_source_payload

SESSION = "block-order-declaration"


def _session() -> ClaudeSession:
    return ClaudeSession(session_id=SESSION, external_session_id=SESSION)


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _full_message(content: list[dict[str, Any]]) -> Any:
    """One assistant message whose content holds every block (history shape)."""

    return _parse(
        {
            "type": "assistant",
            "message": {
                "id": "msg-order-1",
                "role": "assistant",
                "model": "deepseek-v4.1-flash",
                "content": content,
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": "assistant-msg-order-1",
        }
    )


def _rows() -> tuple[Any, tuple[Any, ...], tuple[Any, ...]]:
    message = _full_message(
        [
            {"type": "thinking", "thinking": "think", "signature": "s"},
            {"type": "tool_use", "id": "call_1", "name": "Bash", "input": {}},
            {"type": "text", "text": "trailing text"},
        ]
    )
    projector = ClaudeMessageProjector()
    tools = projector.tool_items_for_message(
        session=_session(), turn_id="turn-1", message=message, full_content=True
    )
    systems = projector.system_items_for_message(
        session=_session(),
        turn_id="turn-1",
        message=message,
        event="claude.history.system",
        full_content=True,
    )
    return message, tools, systems


def test_rows_declare_the_real_content_block_index() -> None:
    _, tools, systems = _rows()
    assert len(tools) == 1 and len(systems) == 1
    assert systems[0].source.get("contentBlockIndex") == 0
    assert tools[0].source.get("contentBlockIndex") == 1
    # The legacy tool ordinal is still declared separately: this message has a
    # single tool_use, so it is 0 — not the absolute index 1.
    assert tools[0].source.get("blockIndex") == 0


def test_message_body_index_is_the_first_text_block() -> None:
    message, _, _ = _rows()
    assert message_text_content_index(message) == 2


def test_the_wire_source_payload_carries_the_field() -> None:
    _, tools, _ = _rows()
    payload = _timeline_source_payload(tools[0])
    assert payload["contentBlockIndex"] == 1


def test_history_projection_orders_tool_before_trailing_text() -> None:
    """The settled view (history republish) declares the real order."""

    message = _full_message(
        [
            {"type": "thinking", "thinking": "think", "signature": "s"},
            {"type": "tool_use", "id": "call_1", "name": "Bash", "input": {}},
            {"type": "text", "text": "trailing text"},
        ]
    )
    items = _history_items_from_messages(
        _session(),
        (message,),
        turn_ids={"msg-order-1": "turn-1"},
    )
    by_kind: dict[str, int | None] = {}
    for item in items:
        item_type = item.type
        if item_type == "tool":
            by_kind["tool"] = item.source.get("contentBlockIndex")
        elif item_type == "system":
            by_kind["reasoning"] = item.source.get("contentBlockIndex")
        elif item_type == "message" and item.role == "assistant":
            by_kind["body"] = item.source.get("contentBlockIndex")
    assert by_kind == {"reasoning": 0, "tool": 1, "body": 2}
