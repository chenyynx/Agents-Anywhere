"""The real Connector history syncer re-publishes a missed row into place.

This is the 2026-11-10 chain end to end: the Connector's live store holds a
row the Server never received, the process restarts, and the first sync
re-publishes the store snapshot. ``c365aba5`` marks that snapshot
``windowOrder``; the Server's insert-only chain plan places the missed row
between its stored neighbours instead of appending it after newer rows.

Unlike the protocol-level tests, this drives the real
``ClaudeHistorySyncer`` (including its live-store retry decision) through the
real ``ConnectorRuntimeHost`` into the real Server app and PostgreSQL.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from types import SimpleNamespace

from test_backend_mvp import create_connector_and_session, make_client

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "connector"))

from connector.runtime_protocol import (
    MarkdownMessageContent,
    MessageTimelineItem,
    RuntimeConfig,
    RuntimeTimelineSnapshot,
    TimelineSource,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.history.state import ClaudeHistoryCursorStore
from connector.runtimes.claude.history.syncer import ClaudeHistorySyncer
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore
from connector.server.runtime_host import ConnectorRuntimeHost
from connector.server.runtime_rpc_payloads import server_payload_without_turn_data

SESSION_ID = "sess_connector_resend_e2e"
EXTERNAL_ID = "7449abb8-0000-0000-0000-000000000000"


def _item(item_id: str) -> MessageTimelineItem:
    return MessageTimelineItem(
        id=item_id,
        type="message",
        status="done",
        role="assistant",
        content=MarkdownMessageContent(text=f"body {item_id}"),
        source=TimelineSource(runtime="claude", native_item_id=f"native-{item_id}"),
    )


class _RetryStore:
    """A live store whose rows have not all reached the Server yet."""

    def __init__(self, items) -> None:
        self._items = tuple(items)

    def get(self, session_id: str, external_session_id: str | None = None):
        return SimpleNamespace(
            active_turn_id=None, timeline_revision=2, synced_revision=1
        )

    def snapshot(
        self, *, session_id: str, external_session_id: str | None = None
    ) -> RuntimeTimelineSnapshot:
        return RuntimeTimelineSnapshot(
            session_id=session_id,
            external_session_id=external_session_id,
            runtime="claude",
            items=self._items,
            complete=False,
            metadata={"source": "claude.session.local", "marker": "1"},
        )

    def mark_synced(
        self, session_id: str, external_session_id: str | None = None
    ) -> None:
        return None


class _ServerHost(RuntimeHostClient):
    """The syncer's host: in-memory sync state, real HTTP ingest for rows."""

    def __init__(self, send, download) -> None:
        self._server = ConnectorRuntimeHost(
            "test", send, download, defer_payload_projection=True
        )
        self._states: dict[str, dict] = {}

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def sync_state_read(self, key: str) -> dict | None:
        return self._states.get(key)

    async def sync_state_write(self, key: str, value: dict) -> None:
        self._states[key] = value

    async def timeline_sync(self, **kwargs) -> None:
        await self._server.timeline_sync(**kwargs)


def _ordered_ids(client, session_id: str, headers) -> list[str]:
    response = client.get(
        f"/sessions/{session_id}/snapshot?limit=100", headers=headers
    )
    assert response.status_code == 200, response.text
    items = response.json()["timeline"]["items"]
    return [item["id"] for item in sorted(items, key=lambda item: item["orderSeq"])]


def test_connector_live_store_retry_inserts_the_missed_row(tmp_path) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(
            client, runtime="claude"
        )
        connector_headers = {"Authorization": f"Bearer {access_token}"}

        async def send(method, params):
            if method != "session.turnEnded":
                params = server_payload_without_turn_data(params)
            response = client.post(
                "/connector/ingest",
                headers=connector_headers,
                json={"notifications": [{"method": method, "params": params}]},
            )
            assert response.status_code == 200, response.text
            assert response.json()["rejected"] == []

        async def download(*_args):
            raise AssertionError("the order test needs no file service")

        chain = [_item(f"m{i}") for i in range(1, 6)]

        def publish(items, order_seqs, metadata):
            host = ConnectorRuntimeHost(
                "test", send, download, defer_payload_projection=True
            )

            async def run():
                await host.timeline_sync(
                    session_id,
                    "claude",
                    tuple(
                        item.to_platform_item(session_id, order_seq)
                        for item, order_seq in zip(items, order_seqs, strict=True)
                    ),
                    metadata=metadata,
                )

            asyncio.run(run())

        # m3 never reaches the Server; the rest of the chain does.
        publish(
            [chain[0], chain[1], chain[3], chain[4]],
            [1, 2, 4, 5],
            {"source": "test.seed"},
        )
        assert _ordered_ids(client, session_id, headers) == ["m1", "m2", "m4", "m5"]

        host = _ServerHost(send, download)
        syncer = ClaudeHistorySyncer(
            config=RuntimeConfig(
                runtime="claude", revision=1, values={"environment": {}}
            ),
            host=host,
            session_store=_RetryStore(
                tuple(
                    item.to_platform_item(session_id, order_seq)
                    for order_seq, item in enumerate(chain, start=1)
                )
            ),
            sdk_loader=lambda: None,
            cursor_store=ClaudeHistoryCursorStore(host),
            sync_states=ClaudeSessionSyncStateStore(host),
            pending_messages=ClaudePendingClientMessageRegistry("conn_test"),
        )
        asyncio.run(syncer.sync_session_timeline(session_id, EXTERNAL_ID))

        assert _ordered_ids(client, session_id, headers) == [
            "m1",
            "m2",
            "m3",
            "m4",
            "m5",
        ]
