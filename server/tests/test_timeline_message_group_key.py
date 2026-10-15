"""``timeline_message_group_key``: one assistant message, one group key.

A message's rows carry two Runtime-native identities depending on the write
path: a tool row declares the enclosing message id (``nativeMessageId``), while
a body/reasoning row carries the message id as its own ``itemId``
(``native_item_id``, the v2_42 grouping column). The grouping helper must map
both onto the same key — the assistant message they belong to — and never invent
a key for a row that declares neither id.
"""

from __future__ import annotations

from agent_server.core.timeline import timeline_message_group_key


def test_group_key_uses_native_message_id_for_a_tool_row() -> None:
    # A tool row: its own itemId is the call id and must not be the key.
    assert timeline_message_group_key("msg-A", None) == "msg-A"


def test_group_key_falls_back_to_native_item_id_for_a_body_row() -> None:
    # A body/reasoning row: no nativeMessageId, so its itemId is the message key.
    assert timeline_message_group_key(None, "native-A") == "native-A"


def test_group_key_prefers_native_message_id_when_both_are_present() -> None:
    # When the row declares its enclosing message id, that wins over its own.
    assert timeline_message_group_key("msg-A", "call-A") == "msg-A"


def test_group_key_is_none_when_neither_id_is_present() -> None:
    # A row that belongs to no message group stays out of every group; the
    # helper must never guess one.
    assert timeline_message_group_key(None, None) is None
