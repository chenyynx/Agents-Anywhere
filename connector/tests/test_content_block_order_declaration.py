"""Rows declare the message's real block order — from the request ledger only.

The transcript writes one content block per assistant line (thinking / tool_use
/ text lines sharing one message id), in block COMPLETION order. On the
OpenAI-format model channel a tool call completes before the text it follows,
so deriving the absolute index from line order inverted every text+tool message
and the server moved the tool row above the body (pp 2026-11-20).

The message's real order only exists in the CLI's request ledger
(``api-request-blob`` lines, the assembled ``content`` array). These tests pin:

- the index comes from the ledger, even when line order disagrees (T1);
- the ``[thinking, tool, trailing text]`` shape still declares 0/1/2;
- a message without a ledger declares NOTHING — no guess (T4);
- conflicting ledgers declare nothing (T6);
- the declaration carries ``contentBlockIndexSource = "message"``.
"""

from __future__ import annotations

import json
from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.timeline.block_order import (
    MessageBlockOrder,
    blob_ledgers,
    resolve_message_orders,
)
from connector.server.runtime_host import _timeline_source_payload

SESSION = "block-order-declaration"


def _session() -> ClaudeSession:
    return ClaudeSession(session_id=SESSION, external_session_id=SESSION)


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _line(block: dict[str, Any], uuid: str) -> Any:
    """One production transcript line: one block, sharing the message id."""

    return _parse(
        {
            "type": "assistant",
            "message": {
                "id": "msg-order-1",
                "role": "assistant",
                "model": "deepseek-v4.1-flash",
                "content": [block],
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": uuid,
        }
    )


def _blob_line(content: list[dict[str, Any]]) -> str:
    """The CLI's request ledger entry for one assembled assistant message."""

    return json.dumps(
        {
            "type": "api-request-blob",
            "sessionId": SESSION,
            "hash": "h",
            "message": {"role": "assistant", "content": content},
        }
    )


def _by_kind(items: tuple[Any, ...]) -> dict[str, Any]:
    rows: dict[str, Any] = {}
    for item in items:
        if item.type == "tool":
            rows["tool"] = item
        elif item.type == "system":
            rows["reasoning"] = item
        elif item.type == "message" and item.role == "assistant":
            rows["body"] = item
    return rows


THINKING = {"type": "thinking", "thinking": "think", "signature": "s"}
TOOL = {"type": "tool_use", "id": "call_1", "name": "Bash", "input": {}}
TEXT = {"type": "text", "text": "lead-in"}


def test_line_completion_order_does_not_decide_the_index() -> None:
    """T1: tool line completes first, but the message is [text, tool_use].

    The production failure (pp 2026-11-20): lines arrive tool → text, the
    assembled message is text → tool. The declared indexes must follow the
    ledger: body 0, tool 1 — never the line order.
    """

    messages = (
        _line(TOOL, "line-tool"),
        _line(TEXT, "line-text"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(_blob_line([TEXT, TOOL]),),
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    assert rows["body"].source.get("contentBlockIndex") == 0
    assert rows["body"].source.get("contentBlockIndexSource") == "message"
    assert rows["tool"].source.get("contentBlockIndex") == 1
    assert rows["tool"].source.get("contentBlockIndexSource") == "message"
    # The legacy tool ordinal is still declared separately.
    assert rows["tool"].source.get("blockIndex") == 0


def test_thinking_tool_trailing_text_keeps_its_real_order() -> None:
    """The 2026-11-19 shape: [thinking, tool_use, trailing text] → 0/1/2."""

    messages = (
        _line(THINKING, "line-thinking"),
        _line(TOOL, "line-tool"),
        _line({"type": "text", "text": "trailing text"}, "line-text"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(_blob_line([THINKING, TOOL, {"type": "text", "text": "trailing text"}]),),
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    assert rows["reasoning"].source.get("contentBlockIndex") == 0
    assert rows["tool"].source.get("contentBlockIndex") == 1
    assert rows["body"].source.get("contentBlockIndex") == 2
    for row in rows.values():
        assert row.source.get("contentBlockIndexSource") == "message"


def test_the_body_index_is_the_first_text_block() -> None:
    """A message with two text blocks places its body row at the first one."""

    second_text = {"type": "text", "text": "closing"}
    messages = (
        _line(THINKING, "line-thinking"),
        _line(TEXT, "line-text-1"),
        _line(TOOL, "line-tool"),
        _line(second_text, "line-text-2"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(_blob_line([THINKING, TEXT, TOOL, second_text]),),
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    assert rows["body"].source.get("contentBlockIndex") == 1
    assert rows["tool"].source.get("contentBlockIndex") == 2


def test_without_a_ledger_nothing_is_declared() -> None:
    """T4: no request ledger (older CLI builds) → no index, never a guess."""

    messages = (
        _line(TOOL, "line-tool"),
        _line(TEXT, "line-text"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    for row in rows.values():
        assert row.source.get("contentBlockIndex") is None
        assert "contentBlockIndexSource" not in row.source


def test_conflicting_ledgers_declare_nothing() -> None:
    """T6: two different ledgers for one message are broken truth → no order."""

    messages = (
        _line(TOOL, "line-tool"),
        _line(TEXT, "line-text"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(
            _blob_line([TEXT, TOOL]),
            _blob_line([TOOL, TEXT]),
        ),
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    for row in rows.values():
        assert row.source.get("contentBlockIndex") is None


def test_a_ledger_of_another_message_is_not_attributed() -> None:
    """A ledger whose anchors belong to no projected message declares nothing."""

    other_tool = {"type": "tool_use", "id": "call_other", "name": "Bash", "input": {}}
    other_text = {"type": "text", "text": "other"}
    messages = (
        _line(TOOL, "line-tool"),
        _line(TEXT, "line-text"),
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(_blob_line([other_text, other_tool]),),
        turn_ids={"msg-order-1": "turn-1"},
    )
    rows = _by_kind(items)
    for row in rows.values():
        assert row.source.get("contentBlockIndex") is None


def test_the_wire_source_payload_carries_the_source() -> None:
    messages = (_line(TOOL, "line-tool"), _line(TEXT, "line-text"))
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=(_blob_line([TEXT, TOOL]),),
        turn_ids={"msg-order-1": "turn-1"},
    )
    payload = _timeline_source_payload(_by_kind(items)["tool"])
    assert payload["contentBlockIndex"] == 1
    assert payload["contentBlockIndexSource"] == "message"


def test_blob_ledgers_and_resolution_are_pure() -> None:
    """The resolver itself: attribution by anchor, conflicts dropped."""

    ledgers = blob_ledgers(
        (
            _blob_line([TEXT, TOOL]),
            _blob_line([{"type": "tool_use", "id": "call_x", "name": "Bash", "input": {}}]),
        )
    )
    assert len(ledgers) == 2
    orders = resolve_message_orders(
        {("tool", "call_1"): "msg-a"},
        ledgers,
    )
    order = orders["msg-a"]
    assert isinstance(order, MessageBlockOrder)
    assert order.first_text_index == 0
    assert order.index_for("tool", "call_1") == 1
    # The second ledger has no anchor of ours: it is not attributed anywhere.
    assert "msg-b" not in orders
