from __future__ import annotations

import asyncio
import base64
import json

from connector.core.config import ConnectorConfig, apply_phone_bridge_env
from connector.core.control_config import config_from_params, config_to_payload
from connector.local.phone_bridge import PhoneBridgeLocalServer
from connector.server.phone_bridge import PhoneBridgeRunner


def config(**overrides) -> ConnectorConfig:
    values = {
        "server_url": "https://aa.example.com",
        "connector_id": "c1",
        "connector_token": "connector-token",
        "phone_bridge_enabled": True,
        "phone_bridge_device_id": "phone-1",
    }
    values.update(overrides)
    return ConnectorConfig(**values)


class FakeResponse:
    status_code = 200

    def json(self):
        return {
            "bridgeId": "pb_test",
            "deviceId": "phone-1",
            "connectorId": "c1",
            "port": 8200,
            "relayToken": "relay token/+",
            "expiresAt": "2026-11-28T12:00:00Z",
        }


class FakeHttp:
    def __init__(self):
        self.calls = []

    async def post(self, url, *, json, headers):
        self.calls.append((url, json, headers))
        return FakeResponse()


class FakeReader:
    def __init__(self, chunks):
        self.chunks = list(chunks)

    async def read(self, _size):
        return self.chunks.pop(0) if self.chunks else b""


class FakeWriter:
    def __init__(self):
        self.data = bytearray()
        self.drained = 0

    def write(self, data):
        self.data.extend(data)

    async def drain(self):
        self.drained += 1


class FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, payload):
        self.sent.append(json.loads(payload))


def test_create_bridge_posts_device_and_returns_token():
    async def run():
        runner = PhoneBridgeRunner(
            config=config(),
            access_token_provider=lambda: _token("access-token"),
        )
        http = FakeHttp()
        runner._http = http
        try:
            bridge, token = await runner._create_bridge()
            assert token == "access-token"
            assert bridge["bridgeId"] == "pb_test"
            url, body, headers = http.calls[0]
            assert url.endswith("/api/v2/connectors/c1/phone/bridges")
            assert body == {"port": 8200, "deviceId": "phone-1"}
            assert headers == {"Authorization": "Bearer access-token"}
        finally:
            await runner.stop()

    asyncio.run(run())


async def _token(value: str) -> str:
    return value


def test_relay_url_keeps_only_the_bridge_token_in_query():
    runner = PhoneBridgeRunner(
        config=config(),
        access_token_provider=lambda: _token("access-token"),
    )
    url = runner._relay_url(
        bridge_id="pb_test",
        relay_token="relay token/+",
    )
    assert url.startswith("wss://aa.example.com/api/v2/connectors/c1/phone/pb_test/relay?")
    assert "token=relay%20token%2F%2B" in url
    # The connector access token is sent as an Authorization header, never in
    # the request line (uvicorn logs WebSocket request lines at INFO).
    assert "access_token" not in url


def test_local_listener_refuses_non_loopback_host():
    async def run():
        listener = PhoneBridgeLocalServer(host="0.0.0.0", port=0)
        assert not await listener.start(lambda reader, writer: None)
        await listener.stop()

    asyncio.run(run())


def test_tcp_to_ws_pumps_data_and_eof():
    async def run():
        runner = PhoneBridgeRunner(
            config=config(),
            access_token_provider=lambda: _token("access-token"),
        )
        ws = FakeWs()
        reader = FakeReader([b"GET /skill\r\n", b"\r\n"])
        await runner._pump_tcp_to_ws(reader, ws)
        assert ws.sent == [
            {
                "type": "data",
                "seq": 1,
                "data": base64.b64encode(b"GET /skill\r\n").decode(),
            },
            {
                "type": "data",
                "seq": 2,
                "data": base64.b64encode(b"\r\n").decode(),
            },
            {"type": "close", "reason": "eof"},
        ]
        await runner.stop()

    asyncio.run(run())


def test_ws_to_tcp_writes_bytes_and_stops_on_close():
    async def run():
        runner = PhoneBridgeRunner(
            config=config(),
            access_token_provider=lambda: _token("access-token"),
        )
        writer = FakeWriter()
        frames = [
            json.dumps({"type": "data", "data": base64.b64encode(b"HTTP/1.1 200 OK\r\n").decode()}),
            json.dumps({"type": "close", "reason": "eof"}),
        ]

        async def iterate():
            for frame in frames:
                yield frame

        class Ws:
            def __aiter__(self):
                return iterate()

        await runner._pump_ws_to_tcp(Ws(), writer)
        assert bytes(writer.data) == b"HTTP/1.1 200 OK\r\n"
        assert writer.drained == 1
        await runner.stop()

    asyncio.run(run())


def test_phone_bridge_env_overlay(monkeypatch):
    monkeypatch.setenv("AGENT_CONNECTOR_PHONE_BRIDGE_ENABLED", "1")
    monkeypatch.setenv("AGENT_CONNECTOR_PHONE_BRIDGE_PORT", "19000")
    monkeypatch.setenv("AGENT_CONNECTOR_PHONE_BRIDGE_DEVICE", "phone-9")
    updated = apply_phone_bridge_env(config(phone_bridge_enabled=False))
    assert updated.phone_bridge_enabled is True
    assert updated.phone_bridge_listen_port == 19000
    assert updated.phone_bridge_device_id == "phone-9"


def test_control_config_round_trips_and_preserves_phone_fields():
    original = config(
        phone_bridge_enabled=True,
        phone_bridge_listen_port=19001,
        phone_bridge_device_id="phone-9",
    )
    payload = config_to_payload(original)
    assert payload["phoneBridgeEnabled"] is True
    assert config_from_params(payload).phone_bridge_listen_port == 19001
    # A desktop save that does not know the new fields must not wipe them.
    merged = config_from_params(
        {
            "serverUrl": original.server_url,
            "connectorId": original.connector_id,
            "connectorToken": original.connector_token,
        },
        existing=original,
    )
    assert merged.phone_bridge_enabled is True
    assert merged.phone_bridge_device_id == "phone-9"


def test_ipv6_loopback_base_url_is_bracketed():
    runner = PhoneBridgeRunner(
        config=config(phone_bridge_listen_host="::1"),
        access_token_provider=lambda: _token("access-token"),
    )
    assert runner.local_base_url == "http://[::1]:18200"


def test_gateway_error_writes_a_readable_502():
    async def run():
        runner = PhoneBridgeRunner(
            config=config(),
            access_token_provider=lambda: _token("access-token"),
        )
        writer = FakeWriter()
        await runner._write_gateway_error(writer, "phone is offline")
        raw = bytes(writer.data)
        assert raw.startswith(b"HTTP/1.1 502 Bad Gateway")
        assert b"phone is offline" in raw
        await runner.stop()

    asyncio.run(run())
