from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import httpx
import pytest

from connector.runtime_protocol import timeline_content_hash
from connector.runtimes.dsh.bridge.sync import SyncRelay
from connector.server.errors import ConnectorNetworkError
from connector.server.ingest import ConnectorIngestRejectedError


def item(item_id="one", session_id="session"):
    content = {"text": "hello", "format": "markdown"}
    return {"id": item_id, "sessionId": session_id, "type": "message", "role": "assistant",
            "status": "done", "orderSeq": 1, "revision": 1, "content": content,
            "source": {"runtime": "dsh"},
            "contentHash": timeline_content_hash("message", "done", "assistant", content)}


def operation(kind, **values):
    return {"kind": kind, "sessionId": "session", "snapshotId": "capture", **values}


def checkpoint(through_seq=12):
    return {"version": 1, "projectionVersion": 3, "throughSeq": through_seq, "historyHash": "a" * 64, "settled": True}


def http_error(status: int) -> httpx.HTTPStatusError:
    request = httpx.Request("POST", "http://server/api/v2/connector/ingest")
    return httpx.HTTPStatusError(f"HTTP {status}", request=request, response=httpx.Response(status, request=request))


class Harness:
    def __init__(self, *, failure: Exception | None):
        self.failure = failure
        self.requests: list[tuple[str, dict | None]] = []
        self.snapshots: list[str] = []
        self.receiver = SimpleNamespace(
            connector_id="test",
            publish_runtime_notifications=AsyncMock(),
            sync_state_write=AsyncMock(),
            runtime_health_update=AsyncMock(),
            timeline_item_upsert=AsyncMock(),
            session_source_update=AsyncMock(),
        )
        self.receiver.publish_runtime_snapshot = self.snapshot

        async def request(method, params=None):
            self.requests.append((method, params))
            return {"ok": True}

        self.client = SimpleNamespace(request=request, writer=Mock(), connected=True)
        self.relay = SyncRelay(self.client, self.receiver, quarantine_retry_delay=0.01, quarantine_too_large_retry_delay=0.02)
        self.relay.durable_checkpoints = True

    async def snapshot(self, runtime, session_id, meta, items, **kwargs):
        list(items)
        if self.failure is not None:
            raise self.failure
        self.snapshots.append(session_id)

    async def capture(self, through_seq=12):
        meta = {"externalSessionId": "native", "sourceState": {"availability": "available"}}
        await self.relay.operation(operation("snapshot.begin", throughSeq=through_seq, meta=meta))
        await self.relay.operation(operation("snapshot.items", items=[item()]))
        await self.relay.operation(operation("snapshot.commit", totalItems=1, throughSeq=through_seq))

    def published(self) -> list[dict]:
        return [n for call in self.receiver.publish_runtime_notifications.await_args_list for n in call.args[1]]


def test_a_refused_snapshot_quarantines_only_that_session_and_recovers_on_a_fresh_capture():
    async def exercise():
        harness = Harness(failure=http_error(413))
        relay, receiver = harness.relay, harness.receiver
        try:
            await harness.capture()  # acknowledged: no exception, so the feed moves on
            record = relay.quarantined["session"]
            assert record.reason == "history_too_large" and record.attempts == 1
            source = harness.published()[-1]
            assert source["method"] == "session.source.updated"
            assert source["params"]["availability"] == "unavailable" and source["params"]["reason"] == "history_too_large"
            assert source["params"]["externalSessionId"] == "native"

            # The plugin believes its capture landed; its checkpoint must not be saved. Others still are.
            await relay.operation({"kind": "checkpoint.save", "externalSessionId": "native", "checkpoint": checkpoint()})
            receiver.sync_state_write.assert_not_awaited()
            await relay.operation({"kind": "checkpoint.save", "externalSessionId": "other-native", "checkpoint": checkpoint()})
            receiver.sync_state_write.assert_awaited_once()

            # Live history for the quarantined session is withheld, other sessions flow, the
            # inventory reports it unavailable and the runtime still becomes healthy.
            receiver.publish_runtime_notifications.reset_mock()
            await relay.operation({"kind": "notifications", "notifications": [
                {"method": "timeline.itemUpsert", "params": {"sessionId": "session", "item": item()}},
                {"method": "timeline.itemUpsert", "params": {"sessionId": "other", "item": item("x", "other")}},
                {"method": "session.source.updated", "params": {"sessionId": "session", "externalSessionId": "native", "availability": "available"}},
                {"method": "session.meta.upsert", "params": {"sessionId": "session", "externalSessionId": "native", "sourceState": {"availability": "available"}}},
                {"method": "session.inventory.complete", "params": {"complete": True, "sessions": [
                    {"sessionId": "session", "sourceState": {"availability": "available"}}, {"sessionId": "other"}]}},
            ]})
            delivered = harness.published()
            assert [n["method"] for n in delivered] == ["timeline.itemUpsert", "session.meta.upsert", "session.inventory.complete"]
            assert delivered[0]["params"]["sessionId"] == "other"
            assert delivered[1]["params"]["sourceState"]["availability"] == "unavailable"
            sessions = delivered[2]["params"]["sessions"]
            assert sessions[0]["sourceState"]["reason"] == "history_too_large" and "sourceState" not in sessions[1]
            assert record.stale is True
            receiver.runtime_health_update.assert_awaited_with("running")

            # A fresh capture is requested after the (shortened) delay.
            for _ in range(100):
                if harness.requests:
                    break
                await asyncio.sleep(0.01)
            assert harness.requests == [("runtime.sync.refresh", {"sessionId": "session", "externalSessionId": "native"})]

            # The next accepted capture releases the quarantine and restates availability.
            harness.failure = None
            receiver.publish_runtime_notifications.reset_mock()
            await harness.capture(through_seq=20)
            assert relay.quarantined == {} and harness.snapshots == ["session"]
            restated = harness.published()[-1]
            assert restated["method"] == "session.source.updated" and restated["params"]["availability"] == "available"
            await relay.operation({"kind": "checkpoint.save", "externalSessionId": "native", "checkpoint": checkpoint(20)})
            assert receiver.sync_state_write.await_count == 2
        finally:
            await relay.close()
    asyncio.run(exercise())


def test_a_rejected_notification_is_quarantined_with_its_own_reason_and_counts_attempts():
    async def exercise():
        harness = Harness(failure=ConnectorIngestRejectedError("backend ingest rejected 1 notification(s)"))
        relay = harness.relay
        try:
            await harness.capture()
            assert relay.quarantined["session"].reason == "history_rejected"
            await harness.capture()
            assert relay.quarantined["session"].attempts == 2
            assert harness.published()[-1]["params"]["reason"] == "history_rejected"
        finally:
            await relay.close()
    asyncio.run(exercise())


@pytest.mark.parametrize("failure", [ConnectorNetworkError("backend down"), http_error(503)])
def test_transient_failures_still_fail_the_subscription_instead_of_quarantining(failure):
    async def exercise():
        harness = Harness(failure=failure)
        relay = harness.relay
        try:
            with pytest.raises(type(failure)):
                await harness.capture()
            assert relay.quarantined == {}
            assert all(n["method"] != "session.source.updated" for n in harness.published())
        finally:
            await relay.close()
    asyncio.run(exercise())
