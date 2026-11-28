from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, WebSocket, WebSocketDisconnect
from starlette.requests import HTTPConnection

from agent_server.core.auth import create_signed_token, verify_signed_token
from agent_server.core.protocol import (
    ProtocolPhoneBridgeRequest,
    ProtocolPhoneBridgeResponse,
    ProtocolPhoneDevice,
    ProtocolPhoneDeviceList,
)
from agent_server.deps import current_user_id, get_store
from agent_server.infra.phone_bridge_broker import (
    BRIDGE_TOKEN_TTL_SECONDS,
    PhoneBridgeBroker,
    PhoneBridgeError,
)
from agent_server.infra.repositories.facade import Store

router = APIRouter(tags=["phone-bridge"])

PHONE_BRIDGE_TOKEN_KIND = "phone-bridge"


def get_phone_bridge_broker(conn: HTTPConnection) -> PhoneBridgeBroker:
    return conn.app.state.phone_bridge_broker


def _broker(websocket: WebSocket) -> PhoneBridgeBroker:
    return websocket.app.state.phone_bridge_broker


def _require_available(broker: PhoneBridgeBroker) -> None:
    if broker.multi_worker:
        raise HTTPException(
            status_code=503,
            detail="phone bridge requires a single server worker",
        )


async def _authenticate_connector(
    authorization: str | None,
    db: Store,
    *,
    expected_connector_id: str | None = None,
) -> tuple[str, str, str]:
    prefix = "Bearer "
    if authorization is None or not authorization.startswith(prefix):
        raise HTTPException(status_code=401, detail="missing connector access token")
    connector_id = await db.authenticate_connector_access(authorization[len(prefix) :])
    if connector_id is None:
        raise HTTPException(status_code=401, detail="invalid connector access token")
    if expected_connector_id is not None and connector_id != expected_connector_id:
        raise HTTPException(status_code=403, detail="connector mismatch")
    try:
        connector = await db.get_connector(connector_id)
    except KeyError:
        raise HTTPException(status_code=401, detail="connector no longer exists") from None
    return connector.id, connector.userId, connector.name


@router.post(
    "/connectors/{connector_id}/phone/bridges",
    response_model=ProtocolPhoneBridgeResponse,
)
async def create_phone_bridge(
    connector_id: str,
    payload: ProtocolPhoneBridgeRequest,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    db: Store = Depends(get_store),
    broker: PhoneBridgeBroker = Depends(get_phone_bridge_broker),
) -> ProtocolPhoneBridgeResponse:
    authenticated_id, user_id, connector_name = await _authenticate_connector(
        authorization, db, expected_connector_id=connector_id
    )
    _require_available(broker)
    device_id = payload.deviceId
    if device_id is None:
        devices = [
            device
            for device in await broker.list_devices(user_id)
            if device.get("online") is True
        ]
        if not devices:
            raise HTTPException(status_code=409, detail="phone is offline")
        if len(devices) > 1:
            raise HTTPException(status_code=409, detail="deviceId is required")
        device_id = devices[0]["deviceId"]
    try:
        bridge = await broker.create_bridge(
            user_id=user_id,
            device_id=device_id,
            connector_id=authenticated_id,
            connector_name=connector_name,
            port=payload.port,
        )
    except PhoneBridgeError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc
    relay_token = create_signed_token(
        PHONE_BRIDGE_TOKEN_KIND,
        {
            "bridgeId": bridge.id,
            "connectorId": authenticated_id,
            "userId": user_id,
        },
        int(BRIDGE_TOKEN_TTL_SECONDS),
    )
    expires_at = (datetime.now(UTC) + timedelta(seconds=BRIDGE_TOKEN_TTL_SECONDS)).isoformat()
    return ProtocolPhoneBridgeResponse(
        bridgeId=bridge.id,
        deviceId=bridge.device_id,
        connectorId=authenticated_id,
        port=bridge.port,
        relayToken=relay_token,
        expiresAt=expires_at.replace("+00:00", "Z"),
    )


@router.get(
    "/connectors/{connector_id}/phone/devices",
    response_model=ProtocolPhoneDeviceList,
)
async def list_connector_phone_devices(
    connector_id: str,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    db: Store = Depends(get_store),
    broker: PhoneBridgeBroker = Depends(get_phone_bridge_broker),
) -> ProtocolPhoneDeviceList:
    _authenticated_id, user_id, _connector_name = await _authenticate_connector(
        authorization, db, expected_connector_id=connector_id
    )
    _require_available(broker)
    devices = await broker.list_devices(user_id)
    return ProtocolPhoneDeviceList(
        devices=[ProtocolPhoneDevice(**device) for device in devices]
    )


@router.get("/phone/devices", response_model=ProtocolPhoneDeviceList)
async def list_phone_devices(
    user_id: str = Depends(current_user_id),
    broker: PhoneBridgeBroker = Depends(get_phone_bridge_broker),
) -> ProtocolPhoneDeviceList:
    _require_available(broker)
    devices = await broker.list_devices(user_id)
    return ProtocolPhoneDeviceList(
        devices=[ProtocolPhoneDevice(**device) for device in devices]
    )


@router.websocket("/phone/ws")
async def phone_websocket(websocket: WebSocket) -> None:
    # Accept before the auth close so the peer receives a WebSocket close code
    # (4401) instead of uvicorn's HTTP 403 handshake rejection.
    await websocket.accept()
    ticket = websocket.query_params.get("ticket")
    if not ticket:
        await websocket.close(code=4401)
        return
    tickets = websocket.app.state.ws_tickets
    record = await tickets.consume_scope(ticket, scope="phone")
    if record is None:
        await websocket.close(code=4401)
        return
    user_id = record.user_id
    broker = _broker(websocket)
    if broker.multi_worker:
        await websocket.send_json(
            {
                "type": "error",
                "code": "server_unavailable",
                "message": "phone bridge requires a single server worker",
            }
        )
        await websocket.close(
            code=1013, reason="phone bridge requires a single server worker"
        )
        return
    device_id: str | None = None
    try:
        hello = await websocket.receive_json()
        if not isinstance(hello, dict) or hello.get("type") != "hello":
            await websocket.close(code=4400, reason="hello is required")
            return
        device_id = hello.get("deviceId")
        if not isinstance(device_id, str) or not device_id:
            await websocket.close(code=4400, reason="deviceId is required")
            return
        if len(device_id) > 128:
            await websocket.close(code=4400, reason="deviceId is too long")
            return
        name = hello.get("name") or device_id
        if not isinstance(name, str) or len(name) > 128:
            await websocket.close(code=4400, reason="name is too long")
            return
        app_version = _optional_str(hello.get("appVersion"))
        bridge_version = _optional_str(hello.get("bridgeVersion"))
        if (app_version is not None and len(app_version) > 64) or (
            bridge_version is not None and len(bridge_version) > 16
        ):
            await websocket.close(code=4400, reason="version is too long")
            return
        await broker.register_phone(
            user_id=user_id,
            device_id=device_id,
            name=name,
            app_version=app_version,
            bridge_version=bridge_version,
            websocket=websocket,
        )
        await websocket.send_json({"type": "registered", "deviceId": device_id})

        while True:
            frame = await websocket.receive_json()
            if not isinstance(frame, dict):
                continue
            await broker.touch_phone(
                user_id=user_id,
                device_id=device_id,
                websocket=websocket,
            )
            frame_type = frame.get("type")
            if frame_type == "ready":
                bridge_id = _bridge_id(frame)
                if bridge_id is None:
                    continue
                await broker.phone_ready(bridge_id=bridge_id, websocket=websocket)
            elif frame_type == "data":
                bridge_id = _bridge_id(frame)
                seq = frame.get("seq")
                data = frame.get("data")
                if bridge_id is None or not isinstance(seq, int) or not isinstance(data, str):
                    await _send_error(websocket, frame, "bad_frame", "invalid data frame")
                    continue
                try:
                    await broker.phone_data(
                        bridge_id=bridge_id,
                        websocket=websocket,
                        seq=seq,
                        data=data,
                    )
                except PhoneBridgeError as exc:
                    await _send_error(websocket, frame, "bad_frame", exc.detail)
            elif frame_type == "error":
                bridge_id = _bridge_id(frame)
                if bridge_id is None:
                    continue
                await broker.phone_error(
                    bridge_id=bridge_id,
                    websocket=websocket,
                    code=str(frame.get("code") or "phone_error"),
                    message=str(frame.get("message") or ""),
                )
            elif frame_type == "close":
                bridge_id = _bridge_id(frame)
                if bridge_id is not None:
                    await broker.close_bridge(bridge_id, reason="eof")
            elif frame_type == "ping":
                await websocket.send_json({"type": "pong"})
    except (WebSocketDisconnect, ValueError):
        pass
    finally:
        if device_id is not None:
            await broker.unregister_phone(
                user_id=user_id,
                device_id=device_id,
                websocket=websocket,
            )


@router.websocket("/connectors/{connector_id}/phone/{bridge_id}/relay")
async def connector_phone_relay(
    websocket: WebSocket,
    connector_id: str,
    bridge_id: str,
) -> None:
    relay_token = websocket.query_params.get("token")
    auth_header = websocket.headers.get("authorization")
    await websocket.accept()
    access_token = (
        auth_header[len("Bearer ") :]
        if auth_header and auth_header.startswith("Bearer ")
        else None
    )
    if not access_token or not relay_token:
        await websocket.close(code=4401)
        return
    db: Store = websocket.app.state.store
    try:
        authenticated_id, user_id, _connector_name = await _authenticate_connector(
            f"Bearer {access_token}", db, expected_connector_id=connector_id
        )
    except HTTPException:
        await websocket.close(code=4401)
        return
    payload = verify_signed_token(PHONE_BRIDGE_TOKEN_KIND, relay_token)
    if (
        payload is None
        or payload.get("bridgeId") != bridge_id
        or payload.get("connectorId") != authenticated_id
        or payload.get("userId") != user_id
    ):
        await websocket.close(code=4401)
        return
    broker = _broker(websocket)
    if broker.multi_worker:
        await websocket.send_json(
            {
                "type": "error",
                "code": "server_unavailable",
                "message": "phone bridge requires a single server worker",
            }
        )
        await websocket.close(
            code=1013, reason="phone bridge requires a single server worker"
        )
        return
    try:
        await broker.attach_connector(
            bridge_id=bridge_id,
            user_id=user_id,
            connector_id=authenticated_id,
            websocket=websocket,
        )
    except PhoneBridgeError:
        await websocket.close(code=4404)
        return
    try:
        while True:
            frame = await websocket.receive_json()
            if not isinstance(frame, dict):
                continue
            frame_type = frame.get("type")
            if frame_type == "data":
                seq = frame.get("seq")
                data = frame.get("data")
                if not isinstance(seq, int) or not isinstance(data, str):
                    await websocket.send_json(
                        {"type": "error", "code": "bad_frame", "message": "invalid data frame"}
                    )
                    continue
                try:
                    await broker.connector_data(
                        bridge_id=bridge_id,
                        websocket=websocket,
                        seq=seq,
                        data=data,
                    )
                except PhoneBridgeError as exc:
                    await websocket.send_json(
                        {"type": "error", "code": "bad_frame", "message": exc.detail}
                    )
            elif frame_type == "close":
                await broker.close_bridge(bridge_id, reason="eof")
                return
            elif frame_type == "ping":
                await websocket.send_json({"type": "pong"})
    except (WebSocketDisconnect, ValueError):
        pass
    finally:
        await broker.detach_connector(bridge_id=bridge_id, websocket=websocket)


def _bridge_id(frame: dict[str, Any]) -> str | None:
    value = frame.get("bridgeId")
    return value if isinstance(value, str) and value else None


def _optional_str(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


async def _send_error(
    websocket: WebSocket,
    frame: dict[str, Any],
    code: str,
    message: str,
) -> None:
    payload: dict[str, Any] = {"type": "error", "code": code, "message": message}
    bridge_id = _bridge_id(frame)
    if bridge_id is not None:
        payload["bridgeId"] = bridge_id
    try:
        await websocket.send_json(payload)
    except Exception:  # noqa: BLE001 - the socket is already gone
        pass
