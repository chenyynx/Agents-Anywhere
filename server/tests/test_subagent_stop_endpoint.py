"""The per-task subagent stop endpoint (A3 batch, station A).

`POST /sessions/{session_id}/runtime/subagent/stop` mirrors the interrupt
shape — takeover, live capability gate, connector RPC, existing error mapping
— with three differences this file pins:

* the gate is `session.subagent_control`, whose availability is connection
  based and deliberately NOT turn based (an idle session with background
  work must be admitted);
* the request body is `{"taskId": "..."}` (camelCase, like interrupt's
  `preserveBackground`);
* the connector's answer is factual: an unknown id, a refused stop and a
  timed-out stop all come back as HTTP 200 with `{"stopped": false}` — never
  an error the client would have to interpret.
"""

from __future__ import annotations

import asyncio
from typing import Any

from test_backend_mvp import (
    FakeLocalRpc,
    _create_claude_session,
    create_connector_and_session,
    make_client,
)

TASK_ID = "af869d8d7ce9675fd"


class FakeSubagentRpc(FakeLocalRpc):
    """FakeLocalRpc plus the subagent control bit and stopSubagent answers."""

    def __init__(self, control: dict[str, Any] | None = None) -> None:
        super().__init__()
        self.control = (
            control
            if control is not None
            else {"supported": True, "available": True, "allowed": True}
        )
        self.stop_result: dict[str, Any] = {"stopped": True}

    async def request(
        self,
        connector_id: str,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float = 30,
    ) -> Any:
        result = await super().request(
            connector_id, method, params, timeout=timeout
        )
        if method == "session.capabilities":
            result["capabilitySet"]["capabilities"].append(
                {
                    "capabilityId": "session.subagent_control",
                    "version": "1",
                    "scope": "session",
                    "runtime": params["runtime"],
                    "sessionId": params["sessionId"],
                    "parameters": {},
                    **self.control,
                }
            )
        if method == "session.stopSubagent":
            return dict(self.stop_result)
        return result


def _stop_requests(fake_rpc: FakeLocalRpc) -> list[dict[str, Any]]:
    return [
        params
        for _, method, params, _ in fake_rpc.requests
        if method == "session.stopSubagent"
    ]


def _claude_session_with_rpc(
    client: Any, control: dict[str, Any] | None = None
) -> tuple[FakeSubagentRpc, str, dict[str, str]]:
    connector_id, _, _, headers = create_connector_and_session(client)
    fake_rpc = FakeSubagentRpc(control)
    client.app.state.rpc = fake_rpc
    session_id = _create_claude_session(client, connector_id, headers, fake_rpc)
    fake_rpc.runtime_states[session_id] = {"status": "running"}
    return fake_rpc, session_id, headers


def test_subagent_stop_requires_authentication(tmp_path) -> None:
    client = make_client(tmp_path)
    fake_rpc, session_id, _ = _claude_session_with_rpc(client)

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 401
    assert _stop_requests(fake_rpc) == []


def test_subagent_stop_requires_takeover(tmp_path) -> None:
    client = make_client(tmp_path)
    connector_id, _, _, headers = create_connector_and_session(client)
    fake_rpc = FakeSubagentRpc()
    client.app.state.rpc = fake_rpc
    # A claude session *without* takeover: the helper's takeover is the last
    # step, so seed the session by hand instead.
    store = client.app.state.store

    async def seed() -> str:
        session = await store.upsert_connector_session(
            connector_id=connector_id,
            session_id="sess_subagent_no_takeover",
            runtime="claude",
            external_session_id="uuid-claude-demo",
            title="Claude",
            cwd="/repo",
            status="idle",
        )
        await store.set_connector_status(connector_id, "online")
        return session.id

    session_id = asyncio.run(seed())

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "session is read-only until takeover is enabled"
    assert _stop_requests(fake_rpc) == []


def test_subagent_stop_requires_the_capability_bit(tmp_path) -> None:
    client = make_client(tmp_path)
    # supported but not available: the session's runtime connection is gone.
    fake_rpc, session_id, headers = _claude_session_with_rpc(
        client, {"supported": True, "available": False, "allowed": True}
    )

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 409
    assert (
        response.json()["detail"]
        == "session capability is unavailable: session.subagent_control"
    )
    assert _stop_requests(fake_rpc) == []


def test_subagent_stop_forwards_the_task_and_reports_stopped(tmp_path) -> None:
    client = make_client(tmp_path)
    fake_rpc, session_id, headers = _claude_session_with_rpc(client)

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True
    assert response.json()["result"] == {"stopped": True}
    params = _stop_requests(fake_rpc)
    assert params == [
        {
            "sessionId": session_id,
            "runtime": "claude",
            "runtimeId": "claude",
            "taskId": TASK_ID,
        }
    ]


def test_subagent_stop_false_is_a_fact_not_an_error(tmp_path) -> None:
    """Unknown id, refused stop, timed-out stop: all 200 + stopped=false."""

    client = make_client(tmp_path)
    fake_rpc, session_id, headers = _claude_session_with_rpc(client)
    fake_rpc.stop_result = {"stopped": False}

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": "t_unknown"},
    )

    assert response.status_code == 200, response.text
    assert response.json()["ok"] is True
    assert response.json()["result"] == {"stopped": False}


def test_subagent_stop_maps_connector_errors(tmp_path) -> None:
    client = make_client(tmp_path)
    fake_rpc, session_id, headers = _claude_session_with_rpc(client)
    fake_rpc.fail = True

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 502
    assert "request gone" in response.json()["detail"]


def test_subagent_stop_capability_read_timeout_is_504(tmp_path) -> None:
    client = make_client(tmp_path)
    fake_rpc, session_id, headers = _claude_session_with_rpc(client)
    fake_rpc.timeout_session_methods = {"session.capabilities"}

    response = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID},
    )

    assert response.status_code == 504
    assert _stop_requests(fake_rpc) == []


def test_subagent_stop_rejects_a_missing_or_unknown_body(tmp_path) -> None:
    client = make_client(tmp_path)
    _, session_id, headers = _claude_session_with_rpc(client)

    missing = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={},
    )
    extra = client.post(
        f"/sessions/{session_id}/runtime/subagent/stop",
        headers=headers,
        json={"taskId": TASK_ID, "preserveBackground": True},
    )

    assert missing.status_code == 422
    assert extra.status_code == 422
