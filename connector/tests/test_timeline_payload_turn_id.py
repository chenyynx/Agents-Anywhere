"""The host payload must keep the turn boundary a Runtime declared.

The server model (`TimelineSource.turnId`) and the iOS decoder both read
`source.turnId`: the interrupted-turn marker dedupes by turn id, and a
scheduled turn's boundary has no user row to recover it from. This pins the
connector side of that contract — the serializer used to filter the field out.
"""

from __future__ import annotations

from connector.runtime_protocol import RuntimeTimelineItem
from connector.server.runtime_host import _timeline_item_payload


def _item(source: dict[str, str]) -> RuntimeTimelineItem:
    return RuntimeTimelineItem(
        id="item_1",
        session_id="sess_1",
        type="message",
        status="done",
        order_seq=1,
        content_hash="sha256:test",
        role="user",
        turn_id=source.get("turnId"),
        content={"kind": "markdown", "format": "markdown", "text": "hi"},
        source={"runtime": "claude", "sessionId": "native_1", **source},
    )


def test_payload_carries_the_declared_turn_id() -> None:
    payload = _timeline_item_payload(_item({"turnId": "turn_1", "itemId": "msg_1"}))
    assert payload["source"]["turnId"] == "turn_1"


def test_payload_omits_a_missing_turn_id() -> None:
    payload = _timeline_item_payload(_item({"itemId": "msg_1"}))
    assert "turnId" not in payload["source"]
