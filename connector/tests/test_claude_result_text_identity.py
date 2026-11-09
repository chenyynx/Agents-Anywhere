from __future__ import annotations

from types import SimpleNamespace

from connector.runtimes.claude.history.syncer import _rekey_turn_result_text
from connector.runtime_protocol import RuntimeTimelineItem
from connector.runtimes.claude.timeline.messages import (
    stable_message_item_id,
    stable_turn_result_item_id,
)


def _session(external: str = "ext-1", session_id: str = "sess-1") -> SimpleNamespace:
    return SimpleNamespace(external_session_id=external, session_id=session_id)


def _body(item_id: str, turn_id: str, order: int, *, session_id: str = "sess-1"):
    return RuntimeTimelineItem(
        id=item_id,
        session_id=session_id,
        type="message",
        status="done",
        order_seq=order,
        content_hash="h-" + item_id,
        role="assistant",
        turn_id=turn_id,
        content={},
        source={},
    )


def _tool(item_id: str, turn_id: str, order: int, *, session_id: str = "sess-1"):
    return RuntimeTimelineItem(
        id=item_id,
        session_id=session_id,
        type="tool",
        status="done",
        order_seq=order,
        content_hash="h-" + item_id,
        role="tool",
        turn_id=turn_id,
        content={},
        source={},
    )


class TestTurnResultItemId:
    def test_is_scoped_to_the_turn_and_not_to_a_message(self) -> None:
        session = _session()
        first = stable_turn_result_item_id(session, "turn-a")
        second = stable_turn_result_item_id(session, "turn-b")
        assert first != second
        # The fallback text has no native message id, so its id must not
        # collide with any message-derived id — in particular not with the
        # tool message it used to borrow (2026-11-10).
        borrowed = stable_message_item_id(session, "msg_tool")
        assert first != borrowed

    def test_is_deterministic(self) -> None:
        session = _session()
        assert stable_turn_result_item_id(session, "turn-a") == (
            stable_turn_result_item_id(session, "turn-a")
        )


class TestRekeyTurnResultText:
    def test_rekeys_the_last_assistant_body_of_the_bound_turn(self) -> None:
        items = (
            _body("claude_msg_live", "turn-a", 1),
            _body("claude_msg_early", "turn-a", 2),
            _tool("claude_tool_1", "turn-a", 3),
            _body("claude_msg_other", "turn-b", 4),
        )
        rekeyed = _rekey_turn_result_text(
            items, {("sess-1", "turn-a"): "claude_msg_turn_result"}, "sess-1"
        )
        ids = [item.id for item in rekeyed]
        # Only the LAST assistant body of the bound turn is the result text.
        assert ids == [
            "claude_msg_live",
            "claude_msg_turn_result",
            "claude_tool_1",
            "claude_msg_other",
        ]

    def test_leaves_other_sessions_untouched(self) -> None:
        items = (_body("claude_msg_live", "turn-a", 1, session_id="sess-2"),)
        rekeyed = _rekey_turn_result_text(
            items, {("sess-1", "turn-a"): "claude_msg_turn_result"}, "sess-1"
        )
        assert rekeyed == items

    def test_no_binding_is_a_no_op(self) -> None:
        items = (_body("claude_msg_live", "turn-a", 1),)
        assert _rekey_turn_result_text(items, {}, "sess-1") == items

    def test_a_turn_without_a_rebuilt_body_is_a_no_op(self) -> None:
        items = (_tool("claude_tool_1", "turn-a", 1),)
        rekeyed = _rekey_turn_result_text(
            items, {("sess-1", "turn-a"): "claude_msg_turn_result"}, "sess-1"
        )
        assert rekeyed == items

    def test_a_second_pass_changes_nothing(self) -> None:
        items = (_body("claude_msg_live", "turn-a", 1),)
        once = _rekey_turn_result_text(
            items, {("sess-1", "turn-a"): "claude_msg_turn_result"}, "sess-1"
        )
        twice = _rekey_turn_result_text(
            once, {("sess-1", "turn-a"): "claude_msg_turn_result"}, "sess-1"
        )
        assert twice == once
