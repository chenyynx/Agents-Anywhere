"""Tests for the connector fs.listFiles pass-through endpoint.

The server only forwards the raw ``root`` to the connector; the connector
builds the workspace file list itself (git ``ls-files`` or a bounded walk),
so the server must not pre-join or normalize any path here. See
``.local-dev/aa-file-list-resolution-plan.md`` §3.2 / T2.
"""

from __future__ import annotations

import asyncio

from test_backend_mvp import (
    FakeLocalRpc,
    auth_headers,
    create_connector_and_session,
    make_client,
)


def list_files_client(tmp_path):
    client = make_client(tmp_path)
    connector_id, _, _, headers = create_connector_and_session(client)
    fake_rpc = FakeLocalRpc()
    client.app.state.rpc = fake_rpc
    asyncio.run(client.app.state.store.set_connector_status(connector_id, "online"))
    return client, connector_id, headers, fake_rpc


def test_connector_fs_list_files_forwards_root_and_passes_result_through(tmp_path):
    client, connector_id, headers, fake_rpc = list_files_client(tmp_path)

    response = client.post(
        f"/connectors/{connector_id}/fs/list-files?root=/repo",
        headers=headers,
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"] is True
    # The connector's raw response (files/truncated/totalFiles) is passed
    # through unchanged by the server.
    assert body["result"] == {
        "method": "fs.listFiles",
        "params": {
            "sessionId": f"browse_{connector_id}",
            "root": "/repo",
        },
    }
    assert fake_rpc.requests == [
        (
            connector_id,
            "fs.listFiles",
            {
                "sessionId": f"browse_{connector_id}",
                # raw root: NOT pre-joined/normalized by the server.
                "root": "/repo",
            },
            30,
        )
    ]


def test_connector_fs_list_files_sends_only_root(tmp_path):
    client, connector_id, headers, fake_rpc = list_files_client(tmp_path)

    response = client.post(
        f"/connectors/{connector_id}/fs/list-files?root=~/work",
        headers=headers,
    )

    assert response.status_code == 200, response.text
    _, method, params, _ = fake_rpc.requests[-1]
    assert method == "fs.listFiles"
    # This endpoint has no `path`; only sessionId + root are forwarded.
    assert params == {"sessionId": f"browse_{connector_id}", "root": "~/work"}


def test_connector_fs_list_files_requires_root(tmp_path):
    client, connector_id, headers, _ = list_files_client(tmp_path)

    missing_root = client.post(
        f"/connectors/{connector_id}/fs/list-files",
        headers=headers,
    )
    blank_root = client.post(
        f"/connectors/{connector_id}/fs/list-files?root=%20",
        headers=headers,
    )

    assert missing_root.status_code == 422
    assert blank_root.status_code == 422


def test_connector_fs_list_files_rejects_non_owner(tmp_path):
    client, connector_id, _, _ = list_files_client(tmp_path)
    # A second, unrelated user owns no connectors → must not reach the RPC.
    other_headers = auth_headers(client, user_id="user2")

    response = client.post(
        f"/connectors/{connector_id}/fs/list-files?root=/repo",
        headers=other_headers,
    )

    assert response.status_code == 404


def test_connector_fs_list_files_rejects_offline_connector(tmp_path):
    class OfflineRpc(FakeLocalRpc):
        async def is_online(self, connector_id: str) -> bool:
            return False

    client = make_client(tmp_path)
    connector_id, _, _, headers = create_connector_and_session(client)
    offline_rpc = OfflineRpc()
    client.app.state.rpc = offline_rpc
    asyncio.run(client.app.state.store.set_connector_status(connector_id, "offline"))

    response = client.post(
        f"/connectors/{connector_id}/fs/list-files?root=/repo",
        headers=headers,
    )

    assert response.status_code == 409
    assert offline_rpc.requests == []
