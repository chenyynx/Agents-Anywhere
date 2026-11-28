from __future__ import annotations

import os
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

os.environ.setdefault("AGENT_SERVER_SECRET", "test-secret")

from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from agent_server.api import phone_bridge
from agent_server.core.protocol import ProtocolWsTicketScope
from agent_server.deps import current_user_id, get_store
from agent_server.infra.phone_bridge_broker import PhoneBridgeBroker


class FakeStore:
    async def authenticate_connector_access(self, token: str) -> str | None:
        return "c1" if token == "connector-token" else None

    async def get_connector(self, connector_id: str):
        if connector_id != "c1":
            raise KeyError(connector_id)
        return SimpleNamespace(id="c1", userId="u1", name="MacBook-Pro")


class FakeTickets:
    async def consume_scope(self, token: str, *, scope: str):
        if token == "phone-ticket" and scope == "phone":
            return SimpleNamespace(user_id="u1")
        return None


def build_app() -> FastAPI:
    app = FastAPI()
    app.include_router(phone_bridge.router, prefix="/api/v2")
    app.state.phone_bridge_broker = PhoneBridgeBroker()
    app.state.ws_tickets = FakeTickets()
    app.state.store = FakeStore()
    app.dependency_overrides[get_store] = lambda: app.state.store
    app.dependency_overrides[current_user_id] = lambda: "u1"
    return app


def test_phone_websocket_registers_and_lists_device():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as ws:
            ws.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            assert ws.receive_json() == {
                "type": "registered",
                "deviceId": "phone-1",
            }
            devices = client.get("/api/v2/phone/devices")
            assert devices.status_code == 200
            assert devices.json()["devices"][0]["deviceId"] == "phone-1"
            assert devices.json()["devices"][0]["online"] is True
            assert not devices.json()["devices"][0]["lastSeen"].startswith("1970")


def test_connector_can_list_the_users_phones():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            phone.receive_json()
            devices = client.get(
                "/api/v2/connectors/c1/phone/devices",
                headers={"Authorization": "Bearer connector-token"},
            )
            assert devices.status_code == 200
            assert devices.json()["devices"][0]["deviceId"] == "phone-1"


def test_connector_bridge_relays_bytes_both_ways():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            assert phone.receive_json()["type"] == "registered"

            created = client.post(
                "/api/v2/connectors/c1/phone/bridges",
                json={"port": 8200},
                headers={"Authorization": "Bearer connector-token"},
            )
            assert created.status_code == 200
            bridge = created.json()
            assert bridge["deviceId"] == "phone-1"
            open_frame = phone.receive_json()
            assert open_frame == {
                "type": "open",
                "bridgeId": bridge["bridgeId"],
                "port": 8200,
                "connectorName": "MacBook-Pro",
            }

            relay_path = (
                f"/api/v2/connectors/c1/phone/{bridge['bridgeId']}/relay"
                f"?token={bridge['relayToken']}"
            )
            with client.websocket_connect(
                relay_path,
                headers={"Authorization": "Bearer connector-token"},
            ) as connector:
                phone.send_json(
                    {
                        "type": "ready",
                        "bridgeId": bridge["bridgeId"],
                        "port": 8200,
                    }
                )
                assert connector.receive_json() == {
                    "type": "ready",
                    "bridgeId": bridge["bridgeId"],
                    "port": 8200,
                }

                phone.send_json(
                    {
                        "type": "data",
                        "bridgeId": bridge["bridgeId"],
                        "seq": 1,
                        "data": "R0VUIC9za2lsbCBIVFRQLzEuMQ0KDQo=",
                    }
                )
                assert connector.receive_json()["data"] == (
                    "R0VUIC9za2lsbCBIVFRQLzEuMQ0KDQo="
                )

                connector.send_json(
                    {"type": "data", "seq": 1, "data": "SFRUUC8xLjEgMjAwIE9LDQoNCg=="}
                )
                assert phone.receive_json() == {
                    "type": "data",
                    "bridgeId": bridge["bridgeId"],
                    "seq": 1,
                    "data": "SFRUUC8xLjEgMjAwIE9LDQoNCg==",
                }


@pytest.mark.timeout(10)
def test_connector_cannot_use_another_connectors_bridge():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            phone.receive_json()
            created = client.post(
                "/api/v2/connectors/c1/phone/bridges",
                json={"deviceId": "phone-1", "port": 8200},
                headers={"Authorization": "Bearer connector-token"},
            )
            bridge = created.json()
            phone.receive_json()
            with pytest.raises(WebSocketDisconnect) as error:
                with client.websocket_connect(
                    f"/api/v2/connectors/c2/phone/{bridge['bridgeId']}/relay"
                    f"?token={bridge['relayToken']}",
                    headers={"Authorization": "Bearer connector-token"},
                ) as bad:
                    bad.receive_json()
            assert error.value.code == 4401


def test_phone_ticket_scope_is_exclusive():
    assert ProtocolWsTicketScope(phone=True).phone is True
    with pytest.raises(ValidationError):
        ProtocolWsTicketScope(phone=True, dashboard=True)


def test_multiworker_refuses_with_503_instead_of_phone_offline():
    app = build_app()
    app.state.phone_bridge_broker.multi_worker = True
    with TestClient(app) as client:
        response = client.post(
            "/api/v2/connectors/c1/phone/bridges",
            json={"port": 8200},
            headers={"Authorization": "Bearer connector-token"},
        )
        assert response.status_code == 503
        assert "single server worker" in response.json()["detail"]


@pytest.mark.timeout(10)
def test_relay_token_bound_to_another_connector_is_rejected():
    from agent_server.core.auth import create_signed_token

    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            phone.receive_json()
            created = client.post(
                "/api/v2/connectors/c1/phone/bridges",
                json={"port": 8200},
                headers={"Authorization": "Bearer connector-token"},
            )
            bridge = created.json()
            phone.receive_json()
            wrong = create_signed_token(
                "phone-bridge",
                {
                    "bridgeId": bridge["bridgeId"],
                    "connectorId": "c2",
                    "userId": "u1",
                },
                60,
            )
            with pytest.raises(WebSocketDisconnect) as error:
                with client.websocket_connect(
                    f"/api/v2/connectors/c1/phone/{bridge['bridgeId']}/relay"
                    f"?token={wrong}",
                    headers={"Authorization": "Bearer connector-token"},
                ) as bad:
                    bad.receive_json()
            assert error.value.code == 4401


def test_overlong_hello_is_rejected_instead_of_500():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "N" * 200,
                    "appVersion": "1",
                    "bridgeVersion": "1",
                }
            )
            with pytest.raises(WebSocketDisconnect) as error:
                phone.receive_json()
            assert error.value.code == 4400


@pytest.mark.timeout(10)
def test_connector_relay_requires_the_authorization_header():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            phone.receive_json()
            created = client.post(
                "/api/v2/connectors/c1/phone/bridges",
                json={"port": 8200},
                headers={"Authorization": "Bearer connector-token"},
            )
            bridge = created.json()
            phone.receive_json()
            with pytest.raises(WebSocketDisconnect) as error:
                with client.websocket_connect(
                    f"/api/v2/connectors/c1/phone/{bridge['bridgeId']}/relay"
                    f"?token={bridge['relayToken']}"
                ) as bad:
                    bad.receive_json()
            assert error.value.code == 4401


def test_multiworker_phone_socket_gets_a_readable_error():
    app = build_app()
    app.state.phone_bridge_broker.multi_worker = True
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            assert phone.receive_json() == {
                "type": "error",
                "code": "server_unavailable",
                "message": "phone bridge requires a single server worker",
            }


@pytest.mark.timeout(10)
def test_relay_token_cannot_attach_twice():
    app = build_app()
    with TestClient(app) as client:
        with client.websocket_connect("/api/v2/phone/ws?ticket=phone-ticket") as phone:
            phone.send_json(
                {
                    "type": "hello",
                    "deviceId": "phone-1",
                    "name": "pp 的 iPhone",
                    "appVersion": "1.98.16",
                    "bridgeVersion": "1",
                }
            )
            phone.receive_json()
            created = client.post(
                "/api/v2/connectors/c1/phone/bridges",
                json={"port": 8200},
                headers={"Authorization": "Bearer connector-token"},
            )
            bridge = created.json()
            phone.receive_json()
            path = (
                f"/api/v2/connectors/c1/phone/{bridge['bridgeId']}/relay"
                f"?token={bridge['relayToken']}"
            )
            with client.websocket_connect(
                path, headers={"Authorization": "Bearer connector-token"}
            ):
                with pytest.raises(WebSocketDisconnect) as error:
                    with client.websocket_connect(
                        path, headers={"Authorization": "Bearer connector-token"}
                    ) as second:
                        second.receive_json()
                assert error.value.code == 4404
