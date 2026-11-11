"""Session runtime context-usage endpoint: forwarding, validation, failures."""

from test_runtime_config import _create_project, _make_client, _runtime_url

from agent_server.infra.connector_rpc import ConnectorRpcError
from agent_server.services.device_runtimes import DeviceRuntimeService

_DEFAULT_OUTCOME = object()

_USAGE = {
    "usage": {
        "runtime": "codex",
        "model": "gpt-5",
        "totalTokens": 84_000,
        "maxTokens": 200_000,
        "percentage": 42.0,
        "detail": "summary",
        "source": "codex.event",
        "measuredAt": "2026-11-12T00:00:00Z",
    }
}


def context_usage_client(tmp_path, outcome=_DEFAULT_OUTCOME):
    client, base_rpc, connector_id, headers = _make_client(tmp_path)

    from test_runtime_config import FakeRpc

    class Rpc(FakeRpc):
        usage_calls = 0

        async def request(self, connector_id, method, params, **kwargs):
            if method == "session.contextUsage":
                self.usage_calls += 1
                self.requests.append((connector_id, method, params))
                if isinstance(outcome, Exception):
                    raise outcome
                if outcome is not _DEFAULT_OUTCOME:
                    return outcome
                return _USAGE
            return await super().request(connector_id, method, params, **kwargs)

    rpc = Rpc(base_rpc.inventory)
    client.app.state.rpc = rpc
    client.app.state.device_runtime_service = DeviceRuntimeService(
        client.app.state.store,
        rpc,
    )
    project_id = _create_project(client, connector_id, headers)
    runtime_url = _runtime_url(connector_id)
    client.put(
        f"{runtime_url}/config",
        headers=headers,
        json={"config": {}},
    ).raise_for_status()
    client.put(
        f"{runtime_url}/active",
        headers=headers,
        json={"active": True},
    ).raise_for_status()
    session_response = client.post(
        "/sessions",
        headers=headers,
        json={
            "connectorId": connector_id,
            "projectId": project_id,
            "runtime": "codex",
            "externalSessionId": "thr_context",
            "title": "Context",
            "cwd": "/repo",
        },
    )
    assert session_response.status_code == 200, session_response.text
    session_id = session_response.json()["session"]["id"]
    return client, f"/sessions/{session_id}/runtime/context-usage", headers, rpc


def test_context_usage_forwards_summary_and_returns_usage(tmp_path):
    client, url, headers, rpc = context_usage_client(tmp_path)

    response = client.get(url, headers=headers)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["usage"]["runtime"] == "codex"
    assert body["usage"]["totalTokens"] == 84_000
    assert body["usage"]["maxTokens"] == 200_000
    assert body["usage"]["percentage"] == 42.0
    assert body["serverTime"]
    assert rpc.usage_calls == 1
    _connector_id, method, params, *_ = rpc.requests[-1]
    assert method == "session.contextUsage"
    assert params["detail"] == "summary"
    assert params["sessionId"]
    assert params["runtime"] == "codex"


def test_context_usage_forwards_full_detail(tmp_path):
    client, url, headers, rpc = context_usage_client(tmp_path)

    response = client.get(url, headers=headers, params={"detail": "full"})

    assert response.status_code == 200, response.text
    assert rpc.requests[-1][2]["detail"] == "full"


def test_context_usage_rejects_unknown_detail(tmp_path):
    client, url, headers, rpc = context_usage_client(tmp_path)

    response = client.get(url, headers=headers, params={"detail": "everything"})

    assert response.status_code == 422
    assert rpc.usage_calls == 0


def test_context_usage_maps_connector_error_to_502(tmp_path):
    client, url, headers, _ = context_usage_client(
        tmp_path,
        ConnectorRpcError("unsupported", "not implemented"),
    )

    response = client.get(url, headers=headers)

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "unsupported"


def test_context_usage_rejects_malformed_runtime_payload(tmp_path):
    client, url, headers, _ = context_usage_client(tmp_path, {"usage": "nope"})

    response = client.get(url, headers=headers)

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "invalid_runtime_context_usage"


def test_context_usage_requires_usage_field(tmp_path):
    client, url, headers, _ = context_usage_client(tmp_path, {})

    response = client.get(url, headers=headers)

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "invalid_runtime_context_usage"
