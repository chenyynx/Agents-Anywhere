"""Ephemeral relay between an AA Connector and a paired iPhone.

The phone runs iCTRL on ``127.0.0.1:8200`` and dials the AA Server over a
WebSocket. The connector dials the Server over a second WebSocket, so neither
side needs an inbound address. This broker pairs the two sockets and forwards
opaque bytes; iCTRL's own pairing and HMAC envelope remain end-to-end between
the connector's iCTRL client and the phone runner.

State is intentionally in-process for v1. The Server deployment is a single
process; a future multi-instance broker must move the bridge registry to Redis
and route frames by owner instance (see ``TerminalBroker`` for the pattern).
"""

from __future__ import annotations

import asyncio
import base64
import secrets
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from fastapi import WebSocket
from loguru import logger

PORT_ALLOWLIST = frozenset({8200})
MAX_FRAME_BYTES = 1024 * 1024
BRIDGE_TTL_SECONDS = 300.0
BRIDGE_TOKEN_TTL_SECONDS = 60.0
MAX_BRIDGES_PER_DEVICE = 4
MAX_BRIDGES_PER_USER = 8
PHONE_LIVENESS_SECONDS = 90.0


class PhoneBridgeError(RuntimeError):
    def __init__(self, detail: str, status_code: int = 409) -> None:
        super().__init__(detail)
        self.detail = detail
        self.status_code = status_code


@dataclass(slots=True)
class PhoneConnection:
    user_id: str
    device_id: str
    name: str
    app_version: str | None
    bridge_version: str | None
    websocket: WebSocket
    connected_at: float = field(default_factory=time.monotonic)
    # Wall clock for display; monotonic for liveness so an NTP step cannot
    # turn a live phone offline (or a dead one online).
    last_seen: float = field(default_factory=time.time)
    last_seen_monotonic: float = field(default_factory=time.monotonic)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def view(self) -> dict[str, Any]:
        return {
            "deviceId": self.device_id,
            "name": self.name,
            "appVersion": self.app_version,
            "bridgeVersion": self.bridge_version,
            "online": time.monotonic() - self.last_seen_monotonic < PHONE_LIVENESS_SECONDS,
            "lastSeen": _iso(self.last_seen),
        }


@dataclass(slots=True)
class PhoneBridge:
    id: str
    user_id: str
    device_id: str
    connector_id: str
    connector_name: str | None
    port: int
    created_at: float = field(default_factory=time.monotonic)
    # Deadline for the connector relay to attach. Once attached, the bridge
    # lives until it is idle for BRIDGE_TTL_SECONDS.
    expires_at: float = field(
        default_factory=lambda: time.monotonic() + BRIDGE_TOKEN_TTL_SECONDS
    )
    last_activity: float = field(default_factory=time.monotonic)
    phone_ready: bool = False
    connector_ws: WebSocket | None = None
    connector_attached: bool = False
    connector_send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    closed: bool = False

    def attach_expired(self) -> bool:
        return self.connector_ws is None and time.monotonic() > self.expires_at

    def idle_expired(self) -> bool:
        return (
            self.connector_ws is not None
            and time.monotonic() - self.last_activity > BRIDGE_TTL_SECONDS
        )

    def touch(self) -> None:
        self.last_activity = time.monotonic()


class PhoneBridgeBroker:
    def __init__(self) -> None:
        # Set by the app from AGENT_SERVER_WORKERS. The registry is in-process,
        # so a multi-worker deployment cannot route a phone socket and a
        # connector relay to the same broker. Fail loudly at the edge instead
        # of returning a misleading "phone is offline".
        self.multi_worker = False
        self._phones: dict[tuple[str, str], PhoneConnection] = {}
        self._bridges: dict[str, PhoneBridge] = {}
        self._lock = asyncio.Lock()
        self._cleanup_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if self._cleanup_task is None:
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def close(self) -> None:
        task = self._cleanup_task
        self._cleanup_task = None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        async with self._lock:
            bridges = list(self._bridges.values())
            phones = list(self._phones.values())
            self._bridges.clear()
            self._phones.clear()
        for bridge in bridges:
            await self._send_close(bridge, "revoked")
        for phone in phones:
            await _safe_close(phone.websocket)

    # ------------------------------------------------------------------ phones

    async def register_phone(
        self,
        *,
        user_id: str,
        device_id: str,
        name: str,
        app_version: str | None,
        bridge_version: str | None,
        websocket: WebSocket,
    ) -> PhoneConnection:
        if not device_id:
            raise PhoneBridgeError("deviceId is required", status_code=422)
        key = (user_id, device_id)
        async with self._lock:
            previous = self._phones.get(key)
            phone = PhoneConnection(
                user_id=user_id,
                device_id=device_id,
                name=name or device_id,
                app_version=app_version,
                bridge_version=bridge_version,
                websocket=websocket,
                last_seen=time.time(),
                last_seen_monotonic=time.monotonic(),
            )
            self._phones[key] = phone
            bridges = [
                bridge
                for bridge in self._bridges.values()
                if bridge.user_id == user_id and bridge.device_id == device_id
            ]
            for bridge in bridges:
                self._bridges.pop(bridge.id, None)
                bridge.closed = True
        if previous is not None and previous.websocket is not websocket:
            await _safe_close(previous.websocket)
        for bridge in bridges:
            await self._send_close(bridge, "revoked")
        logger.info(
            "phone bridge device registered user_id={} device_id={} version={}",
            user_id,
            device_id,
            bridge_version,
        )
        return phone

    async def unregister_phone(
        self,
        *,
        user_id: str,
        device_id: str,
        websocket: WebSocket,
    ) -> None:
        key = (user_id, device_id)
        async with self._lock:
            phone = self._phones.get(key)
            if phone is None or phone.websocket is not websocket:
                return
            self._phones.pop(key, None)
            bridges = [
                bridge
                for bridge in self._bridges.values()
                if bridge.user_id == user_id and bridge.device_id == device_id
            ]
            for bridge in bridges:
                self._bridges.pop(bridge.id, None)
                bridge.closed = True
        for bridge in bridges:
            await self._send_close(bridge, "revoked")
        logger.info(
            "phone bridge device unregistered user_id={} device_id={}",
            user_id,
            device_id,
        )

    async def list_devices(self, user_id: str) -> list[dict[str, Any]]:
        async with self._lock:
            return [
                phone.view()
                for (owner, _device_id), phone in self._phones.items()
                if owner == user_id
            ]

    async def touch_phone(
        self,
        *,
        user_id: str,
        device_id: str,
        websocket: WebSocket,
    ) -> None:
        async with self._lock:
            phone = self._phones.get((user_id, device_id))
            if phone is not None and phone.websocket is websocket:
                phone.last_seen = time.time()
                phone.last_seen_monotonic = time.monotonic()

    async def get_phone(self, *, user_id: str, device_id: str) -> PhoneConnection | None:
        async with self._lock:
            return self._phones.get((user_id, device_id))

    # ----------------------------------------------------------------- bridges

    async def create_bridge(
        self,
        *,
        user_id: str,
        device_id: str,
        connector_id: str,
        connector_name: str | None = None,
        port: int,
    ) -> PhoneBridge:
        if port not in PORT_ALLOWLIST:
            raise PhoneBridgeError("port is not allowed", status_code=403)
        async with self._lock:
            phone = self._phones.get((user_id, device_id))
            if (
                phone is None
                or time.monotonic() - phone.last_seen_monotonic > PHONE_LIVENESS_SECONDS
            ):
                raise PhoneBridgeError("phone is offline", status_code=409)
            user_bridges = [b for b in self._bridges.values() if b.user_id == user_id]
            if len(user_bridges) >= MAX_BRIDGES_PER_USER:
                raise PhoneBridgeError("too many phone bridges", status_code=429)
            device_bridges = [
                b for b in user_bridges if b.device_id == device_id
            ]
            if len(device_bridges) >= MAX_BRIDGES_PER_DEVICE:
                raise PhoneBridgeError("too many phone bridges", status_code=429)
            bridge = PhoneBridge(
                id=f"pb_{secrets.token_urlsafe(12)}",
                user_id=user_id,
                device_id=device_id,
                connector_id=connector_id,
                connector_name=connector_name,
                port=port,
            )
            self._bridges[bridge.id] = bridge
        open_frame: dict[str, Any] = {
            "type": "open",
            "bridgeId": bridge.id,
            "port": port,
        }
        if connector_name:
            open_frame["connectorName"] = connector_name
        sent = await self._send_to_phone(phone, open_frame)
        if not sent:
            async with self._lock:
                self._bridges.pop(bridge.id, None)
                bridge.closed = True
            raise PhoneBridgeError("phone is offline", status_code=409)
        logger.info(
            "phone bridge created bridge_id={} user_id={} device_id={} connector_id={}",
            bridge.id,
            user_id,
            device_id,
            connector_id,
        )
        return bridge

    async def attach_connector(
        self,
        *,
        bridge_id: str,
        user_id: str,
        connector_id: str,
        websocket: WebSocket,
    ) -> PhoneBridge:
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.closed:
                raise PhoneBridgeError("bridge not found", status_code=404)
            if bridge.user_id != user_id or bridge.connector_id != connector_id:
                raise PhoneBridgeError("bridge not found", status_code=404)
            if bridge.attach_expired():
                self._bridges.pop(bridge_id, None)
                bridge.closed = True
                raise PhoneBridgeError("bridge expired", status_code=410)
            if bridge.connector_attached:
                raise PhoneBridgeError("bridge already attached", status_code=409)
            bridge.connector_ws = websocket
            bridge.connector_attached = True
            ready = bridge.phone_ready
            bridge.touch()
            state = bridge
        if ready:
            await self._send_to_connector(
                state, {"type": "ready", "bridgeId": state.id, "port": state.port}
            )
        return state

    async def phone_ready(self, *, bridge_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.closed:
                return
            phone = self._phones.get((bridge.user_id, bridge.device_id))
            if phone is None or phone.websocket is not websocket:
                return
            bridge.phone_ready = True
            bridge.touch()
            connector_ws = bridge.connector_ws
            ready = connector_ws is not None
            state = bridge
        if ready:
            await self._send_to_connector(
                state, {"type": "ready", "bridgeId": state.id, "port": state.port}
            )

    async def phone_data(
        self,
        *,
        bridge_id: str,
        websocket: WebSocket,
        seq: int,
        data: str,
    ) -> None:
        decoded = _decode_data(data)
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.closed:
                return
            phone = self._phones.get((bridge.user_id, bridge.device_id))
            if phone is None or phone.websocket is not websocket:
                return
            bridge.touch()
            state = bridge
        await self._send_to_connector(
            state,
            {"type": "data", "seq": seq, "data": base64.b64encode(decoded).decode("ascii")},
        )

    async def connector_data(
        self,
        *,
        bridge_id: str,
        websocket: WebSocket,
        seq: int,
        data: str,
    ) -> None:
        decoded = _decode_data(data)
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.closed:
                return
            if bridge.connector_ws is not websocket:
                return
            phone = self._phones.get((bridge.user_id, bridge.device_id))
            if phone is None:
                return
            bridge.touch()
            state = bridge
            target = phone
        await self._send_to_phone(
            target,
            {
                "type": "data",
                "bridgeId": state.id,
                "seq": seq,
                "data": base64.b64encode(decoded).decode("ascii"),
            },
        )

    async def phone_error(
        self,
        *,
        bridge_id: str,
        websocket: WebSocket,
        code: str,
        message: str,
    ) -> None:
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.closed:
                return
            phone = self._phones.get((bridge.user_id, bridge.device_id))
            if phone is None or phone.websocket is not websocket:
                return
            bridge.closed = True
            self._bridges.pop(bridge_id, None)
            state = bridge
        await self._send_to_connector(
            state, {"type": "error", "code": code, "message": message}
        )
        await self._send_close(state, "error")

    async def detach_connector(self, *, bridge_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            bridge = self._bridges.get(bridge_id)
            if bridge is None or bridge.connector_ws is not websocket:
                return
            self._bridges.pop(bridge_id, None)
            bridge.closed = True
        await self._send_close(bridge, "eof")

    async def close_bridge(self, bridge_id: str, reason: str = "revoked") -> None:
        async with self._lock:
            bridge = self._bridges.pop(bridge_id, None)
            if bridge is None:
                return
            bridge.closed = True
        await self._send_close(bridge, reason)

    # ----------------------------------------------------------------- internal

    async def _send_to_phone(self, phone: PhoneConnection, frame: dict[str, Any]) -> bool:
        async with phone.send_lock:
            try:
                await phone.websocket.send_json(frame)
                return True
            except Exception as exc:  # noqa: BLE001 - a dead socket is not fatal
                logger.debug(
                    "phone bridge phone send failed device_id={} error={}",
                    phone.device_id,
                    exc,
                )
                return False

    async def _send_to_connector(self, bridge: PhoneBridge, frame: dict[str, Any]) -> bool:
        websocket = bridge.connector_ws
        if websocket is None:
            return False
        async with bridge.connector_send_lock:
            try:
                await websocket.send_json(frame)
                return True
            except Exception as exc:  # noqa: BLE001 - a dead socket is not fatal
                logger.debug(
                    "phone bridge connector send failed bridge_id={} error={}",
                    bridge.id,
                    exc,
                )
                return False

    async def _send_close(self, bridge: PhoneBridge, reason: str) -> None:
        phone = await self.get_phone(user_id=bridge.user_id, device_id=bridge.device_id)
        if phone is not None:
            await self._send_to_phone(
                phone,
                {"type": "close", "bridgeId": bridge.id, "reason": reason},
            )
        await self._send_to_connector(
            bridge, {"type": "close", "reason": reason}
        )

    async def _cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(5)
            stale: list[PhoneBridge] = []
            async with self._lock:
                for bridge_id, bridge in list(self._bridges.items()):
                    if bridge.attach_expired() or bridge.idle_expired():
                        self._bridges.pop(bridge_id, None)
                        bridge.closed = True
                        stale.append(bridge)
            for bridge in stale:
                await self._send_close(bridge, "timeout")


def _decode_data(data: str) -> bytes:
    try:
        decoded = base64.b64decode(data, validate=True)
    except (ValueError, TypeError) as exc:
        raise PhoneBridgeError("invalid data frame", status_code=422) from exc
    if len(decoded) > MAX_FRAME_BYTES:
        raise PhoneBridgeError("frame too large", status_code=413)
    return decoded


def _iso(timestamp: float) -> str:
    return (
        datetime.fromtimestamp(timestamp, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


async def _safe_close(websocket: WebSocket) -> None:
    try:
        await websocket.close()
    except Exception:  # noqa: BLE001 - already closed is fine
        pass
