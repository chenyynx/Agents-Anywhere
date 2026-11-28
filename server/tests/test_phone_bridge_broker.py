from __future__ import annotations

import asyncio
import base64
import time

import pytest

from agent_server.infra.phone_bridge_broker import (
    MAX_BRIDGES_PER_DEVICE,
    MAX_FRAME_BYTES,
    PhoneBridgeBroker,
    PhoneBridgeError,
)


class Socket:
    def __init__(self):
        self.sent: asyncio.Queue[dict] = asyncio.Queue()
        self.closed = False

    async def send_json(self, payload):
        await self.sent.put(payload)

    async def close(self, **_kwargs):
        self.closed = True

    async def receive(self):
        return await asyncio.wait_for(self.sent.get(), timeout=1)


async def register(broker: PhoneBridgeBroker, socket: Socket, device_id="phone-1"):
    return await broker.register_phone(
        user_id="u1",
        device_id=device_id,
        name="pp 的 iPhone",
        app_version="1.98.16",
        bridge_version="1",
        websocket=socket,
    )


def test_create_requires_online_phone_and_port_allowlist():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            with pytest.raises(PhoneBridgeError) as offline:
                await broker.create_bridge(
                    user_id="u1",
                    device_id="phone-1",
                    connector_id="c1",
                    port=8200,
                )
            assert offline.value.status_code == 409

            phone = Socket()
            await register(broker, phone)
            with pytest.raises(PhoneBridgeError) as forbidden:
                await broker.create_bridge(
                    user_id="u1",
                    device_id="phone-1",
                    connector_id="c1",
                    port=22,
                )
            assert forbidden.value.status_code == 403

            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            assert await phone.receive() == {
                "type": "open",
                "bridgeId": bridge.id,
                "port": 8200,
            }
        finally:
            await broker.close()

    asyncio.run(run())


def test_bridge_forwards_both_directions_and_closes_on_unregister():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            await register(broker, phone)
            connector = Socket()
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await phone.receive()  # open
            await broker.attach_connector(
                bridge_id=bridge.id,
                user_id="u1",
                connector_id="c1",
                websocket=connector,
            )
            await broker.phone_ready(bridge_id=bridge.id, websocket=phone)
            assert await connector.receive() == {
                "type": "ready",
                "bridgeId": bridge.id,
                "port": 8200,
            }

            request = base64.b64encode(b"GET /skill HTTP/1.1\r\n\r\n").decode()
            await broker.phone_data(
                bridge_id=bridge.id,
                websocket=phone,
                seq=1,
                data=request,
            )
            assert await connector.receive() == {
                "type": "data",
                "seq": 1,
                "data": request,
            }

            response = base64.b64encode(b"HTTP/1.1 200 OK\r\n\r\n").decode()
            await broker.connector_data(
                bridge_id=bridge.id,
                websocket=connector,
                seq=1,
                data=response,
            )
            assert await phone.receive() == {
                "type": "data",
                "bridgeId": bridge.id,
                "seq": 1,
                "data": response,
            }

            await broker.unregister_phone(
                user_id="u1",
                device_id="phone-1",
                websocket=phone,
            )
            assert await connector.receive() == {
                "type": "close",
                "reason": "revoked",
            }
        finally:
            await broker.close()

    asyncio.run(run())


def test_frame_limit_and_bridge_cap():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            await register(broker, phone)
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await phone.receive()
            too_large = base64.b64encode(b"x" * (MAX_FRAME_BYTES + 1)).decode()
            with pytest.raises(PhoneBridgeError) as error:
                await broker.phone_data(
                    bridge_id=bridge.id,
                    websocket=phone,
                    seq=1,
                    data=too_large,
                )
            assert error.value.status_code == 413

            for _ in range(MAX_BRIDGES_PER_DEVICE - 1):
                await broker.create_bridge(
                    user_id="u1",
                    device_id="phone-1",
                    connector_id="c1",
                    port=8200,
                )
                await phone.receive()
            with pytest.raises(PhoneBridgeError) as capped:
                await broker.create_bridge(
                    user_id="u1",
                    device_id="phone-1",
                    connector_id="c1",
                    port=8200,
                )
            assert capped.value.status_code == 429
        finally:
            await broker.close()

    asyncio.run(run())


def test_another_user_cannot_attach_or_see_the_phone():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            await register(broker, phone)
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await phone.receive()
            with pytest.raises(PhoneBridgeError) as error:
                await broker.attach_connector(
                    bridge_id=bridge.id,
                    user_id="u2",
                    connector_id="c1",
                    websocket=Socket(),
                )
            assert error.value.status_code == 404
            assert await broker.list_devices("u2") == []
            assert len(await broker.list_devices("u1")) == 1
        finally:
            await broker.close()

    asyncio.run(run())


def test_phone_reconnect_revokes_old_bridges_and_old_socket():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            old_phone = Socket()
            await register(broker, old_phone)
            connector = Socket()
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await old_phone.receive()
            await broker.attach_connector(
                bridge_id=bridge.id,
                user_id="u1",
                connector_id="c1",
                websocket=connector,
            )
            new_phone = Socket()
            await register(broker, new_phone)
            assert old_phone.closed is True
            assert await connector.receive() == {
                "type": "close",
                "reason": "revoked",
            }
            with pytest.raises(PhoneBridgeError):
                await broker.attach_connector(
                    bridge_id=bridge.id,
                    user_id="u1",
                    connector_id="c1",
                    websocket=Socket(),
                )
        finally:
            await broker.close()

    asyncio.run(run())


def test_another_connector_cannot_attach_the_same_bridge():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            await register(broker, phone)
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await phone.receive()
            with pytest.raises(PhoneBridgeError) as error:
                await broker.attach_connector(
                    bridge_id=bridge.id,
                    user_id="u1",
                    connector_id="c2",
                    websocket=Socket(),
                )
            assert error.value.status_code == 404
        finally:
            await broker.close()

    asyncio.run(run())


def test_stale_phone_cannot_create_a_bridge():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            connection = await register(broker, phone)
            connection.last_seen_monotonic -= 100
            with pytest.raises(PhoneBridgeError) as error:
                await broker.create_bridge(
                    user_id="u1",
                    device_id="phone-1",
                    connector_id="c1",
                    port=8200,
                )
            assert error.value.status_code == 409
            devices = await broker.list_devices("u1")
            assert devices[0]["online"] is False
        finally:
            await broker.close()

    asyncio.run(run())


def test_expired_attach_window_returns_410():
    async def run():
        broker = PhoneBridgeBroker()
        try:
            phone = Socket()
            await register(broker, phone)
            bridge = await broker.create_bridge(
                user_id="u1",
                device_id="phone-1",
                connector_id="c1",
                port=8200,
            )
            await phone.receive()
            bridge.expires_at = time.monotonic() - 1
            with pytest.raises(PhoneBridgeError) as error:
                await broker.attach_connector(
                    bridge_id=bridge.id,
                    user_id="u1",
                    connector_id="c1",
                    websocket=Socket(),
                )
            assert error.value.status_code == 410
        finally:
            await broker.close()

    asyncio.run(run())
