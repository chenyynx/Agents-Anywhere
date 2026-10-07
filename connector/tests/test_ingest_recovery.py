from __future__ import annotations

import asyncio
from typing import Self

import httpx
import pytest
from connector.logging import logger
from connector.server.auth import ConnectorAuthenticationError
from connector.server.ingest import (
    ConnectorIngestClient,
    ConnectorIngestRejectedError,
)
from connector.server.rpc import ConnectorRpcChannel


class _CapturedWarnings:
    """Collect connector WARNING lines around a block."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self._sink: int | None = None

    def __enter__(self) -> Self:
        self._sink = logger.add(
            lambda message: self.lines.append(str(message)), level="WARNING"
        )
        return self

    def __exit__(self, *_exc: object) -> None:
        assert self._sink is not None
        logger.remove(self._sink)

    def joined(self) -> str:
        return "\n".join(self.lines)


def test_network_failure_and_server_503_keep_fifo_for_recovery():
    async def run():
        attempts = []
        delivered = asyncio.Event()

        async def token(force):
            return "token"

        async def transport(request):
            import json

            batch = json.loads(request.content)["notifications"]
            attempts.append(batch)
            if len(attempts) == 1:
                raise httpx.ConnectError("offline", request=request)
            if len(attempts) == 2:
                return httpx.Response(503)
            delivered.set()
            return httpx.Response(200, json={"accepted": len(batch), "rejected": []})

        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
            ingest = ConnectorIngestClient(
                "https://server.test", token, lambda: http, lambda timeout: http
            )
            ingest._retry_delay = 0.001
            await ingest.enqueue("session.state.updated", {"status": "running"})
            await ingest.enqueue("session.state.updated", {"status": "idle"})
            task = asyncio.create_task(ingest.flush_loop())
            await asyncio.wait_for(delivered.wait(), 1)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            assert attempts[0] == attempts[1] == attempts[2]
            assert [row["params"]["status"] for row in attempts[2]] == [
                "running",
                "idle",
            ]
            assert not ingest.has_pending

    asyncio.run(run())


def test_cancelled_http_batch_survives_flush_worker_restart():
    async def run():
        started = asyncio.Event()
        delivered = asyncio.Event()
        calls = []

        async def token(force):
            return "token"

        async def transport(request):
            calls.append(request.content)
            if len(calls) == 1:
                started.set()
                await asyncio.Event().wait()
            delivered.set()
            return httpx.Response(200, json={"accepted": 1, "rejected": []})

        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
            ingest = ConnectorIngestClient(
                "https://server.test", token, lambda: http, lambda timeout: http
            )
            await ingest.enqueue("timeline.sync", {"sessionId": "session", "items": []})
            task = asyncio.create_task(ingest.flush_loop())
            await started.wait()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            assert ingest.has_pending
            task = asyncio.create_task(ingest.flush_loop())
            await asyncio.wait_for(delivered.wait(), 1)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            assert calls[0] == calls[1]

    asyncio.run(run())


def test_revoked_credentials_stop_retry_and_reject_new_admission():
    async def run():
        async def token(force):
            raise ConnectorAuthenticationError("revoked")

        ingest = ConnectorIngestClient(
            "https://server.test", token, lambda: None, lambda timeout: None
        )
        await ingest.enqueue("connector.heartbeat", {})
        with pytest.raises(ConnectorAuthenticationError):
            await asyncio.wait_for(ingest.flush_loop(), 1)
        with pytest.raises(ConnectorAuthenticationError):
            await ingest.enqueue("connector.heartbeat", {})

    asyncio.run(run())


def test_http_400_detail_is_logged_with_batch_summary():
    async def run():
        async def token(force):
            return "token"

        async def transport(request):
            return httpx.Response(
                400,
                json={
                    "detail": {
                        "code": "unsupported_timeline_marker",
                        "message": "turn lifecycle markers must use dedicated session notifications",
                    }
                },
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
            ingest = ConnectorIngestClient(
                "https://server.test", token, lambda: http, lambda timeout: http
            )
            with _CapturedWarnings() as captured, pytest.raises(httpx.HTTPStatusError):
                await ingest.ingest_notifications(
                    [
                        {
                            "method": "timeline.itemUpsert",
                            "params": {"sessionId": "sess_1", "item": {"id": "i1"}},
                        },
                        {
                            "method": "timeline.itemUpsert",
                            "params": {"sessionId": "sess_1", "item": {"id": "i2"}},
                        },
                        {"method": "connector.heartbeat", "params": {}},
                    ]
                )
            log = captured.joined()
            assert "connector ingest batch rejected status=400" in log, log
            assert "count=3" in log, log
            assert "methods=connector.heartbeat:1,timeline.itemUpsert:2" in log, log
            assert "first=method=timeline.itemUpsert session_id=sess_1" in log, log
            assert "code=unsupported_timeline_marker" in log, log
            assert (
                "message=turn lifecycle markers must use dedicated session notifications"
                in log
            ), log

    asyncio.run(run())


def test_http_400_still_drops_the_batch_without_retry():
    """Compatibility with an old server: a 400 remains a permanent rejection."""

    async def run():
        attempts = []
        delivered = asyncio.Event()

        async def token(force):
            return "token"

        async def transport(request):
            import json

            attempts.append(json.loads(request.content)["notifications"])
            delivered.set()
            return httpx.Response(400, json={"detail": "bad batch"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
            ingest = ConnectorIngestClient(
                "https://server.test", token, lambda: http, lambda timeout: http
            )
            await ingest.enqueue("timeline.itemUpsert", {"sessionId": "sess_1"})
            task = asyncio.create_task(ingest.flush_loop())
            await asyncio.wait_for(delivered.wait(), 1)
            for _ in range(100):
                if not ingest.has_pending:
                    break
                await asyncio.sleep(0.01)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            assert not ingest.has_pending
            assert len(attempts) == 1

    asyncio.run(run())


def test_http_200_rejected_raises_with_code_histogram_logged():
    async def run():
        async def token(force):
            return "token"

        async def transport(request):
            return httpx.Response(
                200,
                json={
                    "accepted": 1,
                    "rejected": [
                        {
                            "index": 1,
                            "method": "session.updated",
                            "code": "unsupported_legacy_selection_fields",
                            "message": "legacy selection fields are not supported",
                        },
                        {
                            "index": 2,
                            "method": "timeline.itemUpsert",
                            "code": "unsupported_legacy_selection_fields",
                            "message": "legacy selection fields are not supported",
                        },
                        {
                            "index": 3,
                            "method": "timeline.itemUpsert",
                            "code": "unsupported_timeline_marker",
                            "message": "turn lifecycle markers must use dedicated session notifications",
                        },
                    ],
                },
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as http:
            ingest = ConnectorIngestClient(
                "https://server.test", token, lambda: http, lambda timeout: http
            )
            with _CapturedWarnings() as captured, pytest.raises(
                ConnectorIngestRejectedError
            ) as excinfo:
                await ingest.ingest_notifications(
                    [{"method": "timeline.itemUpsert", "params": {}} for _ in range(4)]
                )
            assert "rejected 3 notification(s)" in str(excinfo.value)
            assert "first method=session.updated code=unsupported_legacy_selection_fields" in str(
                excinfo.value
            )
            log = captured.joined()
            assert "connector ingest notifications rejected count=3" in log, log
            assert (
                "codes=unsupported_legacy_selection_fields:2,unsupported_timeline_marker:1"
                in log
            ), log

    asyncio.run(run())


def test_old_rpc_completion_cannot_reply_on_replacement_socket():
    async def run():
        class Socket:
            def __init__(self):
                self.frames = []

            async def send(self, payload):
                self.frames.append(payload)

        entered, release = asyncio.Event(), asyncio.Event()
        channel = ConnectorRpcChannel()
        old, new = Socket(), Socket()
        channel.set_connection(old)

        async def dispatch(method, params):
            entered.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                # Some runtime operations finish cleanup despite cancellation.
                await release.wait()
            return {"status": "stopped"}

        channel.start_request(
            {"type": "request", "id": "old", "method": "runtime.stop"}, dispatch
        )
        await entered.wait()
        old_tasks = list(channel._request_tasks)
        channel.set_connection(new)
        release.set()
        await asyncio.gather(*old_tasks)
        assert not old.frames and not new.frames
        await channel.close_connection()

    asyncio.run(run())


def test_failed_websocket_sender_stops_admission_instead_of_hanging_next_send():
    async def run():
        class Socket:
            async def send(self, payload):
                raise ConnectionError("link lost")

        channel = ConnectorRpcChannel()
        channel.set_connection(Socket())
        with pytest.raises(ConnectionError):
            await channel.send_notification("connector.heartbeat", {})
        assert not channel.connected
        with pytest.raises(RuntimeError, match="not connected"):
            await asyncio.wait_for(
                channel.send_notification("connector.heartbeat", {}), 1
            )
        await channel.close_connection()

    asyncio.run(run())
