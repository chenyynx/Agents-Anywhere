"""Tests for the connector fs.resolvePath pass-through endpoint.

Unlike ``fs/list``, the server must forward the *raw* root and path to the
connector so it can perform workspace disambiguation itself (see
``.local-dev/aa-inline-file-resolution-tasks.md`` §4 layer A / T2).
"""

from __future__ import annotations

import asyncio

from test_backend_mvp import (
    FakeLocalRpc,
    auth_headers,
    create_connector_and_session,
    make_client,
)


def resolve_client(tmp_path):
    client = make_client(tmp_path)
    connector_id, _, _, headers = create_connector_and_session(client)
    fake_rpc = FakeLocalRpc()
    client.app.state.rpc = fake_rpc
    asyncio.run(client.app.state.store.set_connector_status(connector_id, "online"))
    return client, connector_id, headers, fake_rpc


def test_connector_fs_resolve_path_forwards_raw_root_and_path(tmp_path):
    client, connector_id, headers, fake_rpc = resolve_client(tmp_path)

    response = client.post(
        f"/connectors/{connector_id}/fs/resolve-path?root=/repo",
        headers=headers,
        json={"path": "src/index.ts"},
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"] is True
    # The connector's raw response is passed through unchanged.
    assert body["result"] == {
        "method": "fs.resolvePath",
        "params": {
            "sessionId": f"browse_{connector_id}",
            "root": "/repo",
            "path": "src/index.ts",
        },
    }
    assert fake_rpc.requests == [
        (
            connector_id,
            "fs.resolvePath",
            {
                "sessionId": f"browse_{connector_id}",
                # raw root + raw path: NOT pre-joined by the server.
                "root": "/repo",
                "path": "src/index.ts",
            },
            30,
        )
    ]


def test_connector_fs_resolve_path_accepts_root_in_body(tmp_path):
    client, connector_id, headers, fake_rpc = resolve_client(tmp_path)

    response = client.post(
        f"/connectors/{connector_id}/fs/resolve-path",
        headers=headers,
        json={"root": "~/work", "path": "README.md"},
    )

    assert response.status_code == 200, response.text
    assert fake_rpc.requests[-1] == (
        connector_id,
        "fs.resolvePath",
        {
            "sessionId": f"browse_{connector_id}",
            "root": "~/work",
            "path": "README.md",
        },
        30,
    )


def test_connector_fs_resolve_path_requires_root(tmp_path):
    client, connector_id, headers, _ = resolve_client(tmp_path)

    missing_root = client.post(
        f"/connectors/{connector_id}/fs/resolve-path",
        headers=headers,
        json={"path": "index.ts"},
    )
    blank_root = client.post(
        f"/connectors/{connector_id}/fs/resolve-path?root=%20",
        headers=headers,
        json={"path": "index.ts"},
    )

    assert missing_root.status_code == 422
    assert blank_root.status_code == 422


def test_connector_fs_resolve_path_requires_string_path(tmp_path):
    client, connector_id, headers, _ = resolve_client(tmp_path)

    response = client.post(
        f"/connectors/{connector_id}/fs/resolve-path?root=/repo",
        headers=headers,
        json={"path": 123},
    )

    assert response.status_code == 422


def test_connector_fs_resolve_path_rejects_non_owner(tmp_path):
    client, connector_id, _, _ = resolve_client(tmp_path)
    # A second, unrelated user owns no connectors → must not reach the RPC.
    other_headers = auth_headers(client, user_id="user2")

    response = client.post(
        f"/connectors/{connector_id}/fs/resolve-path?root=/repo",
        headers=other_headers,
        json={"path": "index.ts"},
    )

    assert response.status_code == 404


def test_connector_fs_resolve_path_rejects_offline_connector(tmp_path):
    class OfflineRpc(FakeLocalRpc):
        async def is_online(self, connector_id: str) -> bool:
            return False

    client = make_client(tmp_path)
    connector_id, _, _, headers = create_connector_and_session(client)
    offline_rpc = OfflineRpc()
    client.app.state.rpc = offline_rpc
    asyncio.run(client.app.state.store.set_connector_status(connector_id, "offline"))

    response = client.post(
        f"/connectors/{connector_id}/fs/resolve-path?root=/repo",
        headers=headers,
        json={"path": "index.ts"},
    )

    assert response.status_code == 409
    assert offline_rpc.requests == []
