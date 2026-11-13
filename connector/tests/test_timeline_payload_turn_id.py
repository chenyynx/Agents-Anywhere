"""The host payload must keep the turn boundary a Runtime declared.

The server model (`TimelineSource.turnId`) and the iOS decoder both read
`source.turnId`: the interrupted-turn marker dedupes by turn id, and a
scheduled turn's boundary has no user row to recover it from. This pins the
connector side of that contract — the serializer used to filter the field out.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

from connector.runtime_protocol import RuntimeTimelineItem
from connector.server import client as client_module
from connector.server.runtime_host import (
    ConnectorRuntimeHost,
    _timeline_item_payload,
)
from connector.server.runtime_rpc_payloads import (
    DeferredServerPayload,
    server_notification_payload,
    server_payload_without_turn_data,
    server_timeline_payload,
)


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


def _timeline_notification() -> dict:
    return {
        "sessionId": "sess_1",
        "runtime": "claude",
        "items": [
            {
                "id": "item_1",
                "type": "message",
                "status": "done",
                "role": "assistant",
                "content": {"blocks": [{"text": "hi", "turnId": "business"}]},
                "source": {"runtime": "claude", "turnId": "turn_1"},
            }
        ],
    }


def test_timeline_projection_keeps_source_turn_id_only() -> None:
    projected = server_timeline_payload(_timeline_notification())
    item = projected["items"][0]
    assert item["source"]["turnId"] == "turn_1"
    # Business metadata still walks the turn-data ban.
    assert item["content"]["blocks"][0] == {"text": "hi"}


def test_non_timeline_projection_still_drops_source_turn_id() -> None:
    projected = server_payload_without_turn_data(_timeline_notification())
    assert "turnId" not in projected["items"][0]["source"]


def test_method_picks_the_timeline_contract() -> None:
    kept = server_notification_payload("timeline.itemUpsert", _timeline_notification())
    dropped = server_notification_payload("session.state.updated", _timeline_notification())
    assert kept["items"][0]["source"]["turnId"] == "turn_1"
    assert "turnId" not in dropped["items"][0]["source"]


def test_deferred_projection_keeps_the_timeline_source_turn_id() -> None:
    async def exercise() -> None:
        sent: list[tuple[str, dict]] = []

        async def enqueue(method: str, params: dict) -> None:
            sent.append((method, params))

        transport = SimpleNamespace(
            _rpc=SimpleNamespace(connected=False),
            _ingest=SimpleNamespace(enqueue=enqueue),
        )
        await client_module.BackendRpcClient._send_backend_notification_now(
            transport,
            "timeline.itemUpsert",
            DeferredServerPayload(
                {"sessionId": "sess_1", "item": _timeline_notification()["items"][0]}
            ),
        )
        assert sent[0][1]["item"]["source"]["turnId"] == "turn_1"
        assert "turnId" not in sent[0][1]["item"]["content"]["blocks"][0]

    asyncio.run(exercise())


def test_batched_runtime_notifications_keep_the_timeline_turn_id() -> None:
    async def exercise() -> None:
        sent: list[dict] = []

        async def ingest(notifications: list[dict], **_kwargs) -> None:
            sent.extend(notifications)

        async def download(*_args):
            raise AssertionError("unexpected download")

        async def notifier(*_args):
            raise AssertionError("unexpected notifier")

        host = ConnectorRuntimeHost(
            "connector", notifier, download, ingest_notifications=ingest
        )
        await host.publish_runtime_notifications(
            "dsh",
            [
                {
                    "method": "timeline.sync",
                    "params": _timeline_notification(),
                },
                {
                    "method": "session.state.updated",
                    "params": {"sessionId": "sess_1", "turnId": "runtime_turn"},
                },
            ],
        )
        assert sent[0]["params"]["items"][0]["source"]["turnId"] == "turn_1"
        assert "turnId" not in sent[1]["params"]

    asyncio.run(exercise())
