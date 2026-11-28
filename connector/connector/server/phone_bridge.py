"""Connector-side Phone Bridge relay.

For every TCP connection accepted on the loopback listener, create one Server
bridge and pipe bytes between the local iCTRL client and the phone's bridge
WebSocket. iCTRL's own encrypted JSON-RPC envelope stays end-to-end; this module
never parses it.
"""

from __future__ import annotations

import asyncio
import base64
import json
from contextlib import suppress
from typing import Any
from urllib.parse import quote

import httpx
import websockets
from websockets.exceptions import ConnectionClosed

from connector.core.config import ConnectorConfig
from connector.local.phone_bridge import PhoneBridgeLocalServer
from connector.logging import logger
from connector.server.urls import api_v2_path, api_v2_url, is_loopback_url
from connector.server.urls import ws_url as build_ws_url

LOCAL_CHUNK_BYTES = 64 * 1024
WS_MAX_FRAME_BYTES = 4 * 1024 * 1024
BRIDGE_CREATE_TIMEOUT_SECONDS = 15.0
BRIDGE_READY_TIMEOUT_SECONDS = 10.0


class PhoneBridgeRelayError(RuntimeError):
    pass


class PhoneBridgeRunner:
    def __init__(
        self,
        *,
        config: ConnectorConfig,
        access_token_provider: Any,
    ) -> None:
        self.config = config
        self._access_token_provider = access_token_provider
        self._http: httpx.AsyncClient | None = None
        self._local = PhoneBridgeLocalServer(
            host=config.phone_bridge_listen_host,
            port=config.phone_bridge_listen_port,
        )
        self._tasks: set[asyncio.Task[None]] = set()
        self._started = False

    async def start(self) -> None:
        if self._started:
            return
        if not self.config.phone_bridge_enabled:
            logger.info("phone bridge disabled")
            return
        self._http = httpx.AsyncClient(
            timeout=BRIDGE_CREATE_TIMEOUT_SECONDS,
            trust_env=not is_loopback_url(self.config.server_url),
        )
        started = await self._local.start(self._handle_connection)
        if not started:
            await self._close_http()
            return
        self._started = True

    async def stop(self) -> None:
        self._started = False
        await self._local.stop()
        tasks = tuple(self._tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._tasks.clear()
        await self._close_http()

    async def _handle_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        task = asyncio.current_task()
        if task is not None:
            self._tasks.add(task)
        try:
            await self._bridge_connection(reader, writer)
        except PhoneBridgeRelayError as exc:
            logger.warning("phone bridge rejected: {}", exc)
            await self._write_gateway_error(writer, str(exc))
        except Exception:  # noqa: BLE001 - one connection must not stop the listener
            logger.exception("phone bridge connection failed")
        finally:
            if task is not None:
                self._tasks.discard(task)
            writer.close()
            with suppress(Exception):
                await writer.wait_closed()

    async def _bridge_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        bridge, access_token = await self._create_bridge()
        relay_url = self._relay_url(
            bridge_id=str(bridge["bridgeId"]),
            relay_token=str(bridge["relayToken"]),
        )
        async with websockets.connect(
            relay_url,
            additional_headers={"Authorization": f"Bearer {access_token}"},
            proxy=None if is_loopback_url(self.config.server_url) else True,
            max_size=WS_MAX_FRAME_BYTES,
        ) as ws:
            try:
                first = json.loads(
                    await asyncio.wait_for(
                        ws.recv(), timeout=BRIDGE_READY_TIMEOUT_SECONDS
                    )
                )
            except (TimeoutError, ValueError) as exc:
                raise PhoneBridgeRelayError(
                    "bridge did not become ready"
                ) from exc
            if not isinstance(first, dict):
                raise PhoneBridgeRelayError("bridge did not become ready")
            if first.get("type") == "error":
                raise PhoneBridgeRelayError(
                    f"bridge failed: {first.get('code')}: {first.get('message')}"
                )
            if first.get("type") != "ready":
                raise PhoneBridgeRelayError("bridge did not become ready")
            logger.info(
                "phone bridge relay open bridge_id={} device_id={}",
                bridge["bridgeId"],
                bridge.get("deviceId"),
            )
            tcp_to_ws = asyncio.create_task(self._pump_tcp_to_ws(reader, ws))
            ws_to_tcp = asyncio.create_task(self._pump_ws_to_tcp(ws, writer))
            done, pending = await asyncio.wait(
                {tcp_to_ws, ws_to_tcp},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                with suppress(ConnectionClosed, PhoneBridgeRelayError):
                    task.result()
            logger.info(
                "phone bridge relay closed bridge_id={}",
                bridge["bridgeId"],
            )

    @property
    def enabled(self) -> bool:
        return bool(self.config.phone_bridge_enabled) and self._started

    @property
    def local_base_url(self) -> str:
        host = self.config.phone_bridge_listen_host
        if host in {"0.0.0.0", "::"}:
            host = "127.0.0.1"
        elif ":" in host and not host.startswith("["):
            host = f"[{host}]"
        return f"http://{host}:{self.config.phone_bridge_listen_port}"

    async def list_devices(self) -> list[dict[str, Any]]:
        client = self._http
        if client is None:
            return []
        token = await self._access_token_provider()
        url = api_v2_url(
            self.config.server_url,
            f"/connectors/{self.config.connector_id}/phone/devices",
        )
        try:
            response = await client.get(
                url, headers={"Authorization": f"Bearer {token}"}
            )
        except httpx.HTTPError:
            return []
        if response.status_code != 200:
            return []
        try:
            payload = response.json()
        except ValueError:
            return []
        devices = payload.get("devices") if isinstance(payload, dict) else None
        return [item for item in devices if isinstance(item, dict)] if isinstance(devices, list) else []

    async def _write_gateway_error(
        self,
        writer: asyncio.StreamWriter,
        message: str,
    ) -> None:
        """Turn a pre-stream bridge failure into a readable HTTP 502."""
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32000, "message": f"phone bridge: {message}"},
            }
        ).encode()
        head = (
            "HTTP/1.1 502 Bad Gateway\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        with suppress(Exception):
            writer.write(head + body)
            await writer.drain()

    async def _create_bridge(self) -> tuple[dict[str, Any], str]:
        client = self._http
        if client is None:
            raise PhoneBridgeRelayError("phone bridge is not started")
        token = await self._access_token_provider()
        body: dict[str, Any] = {"port": self.config.phone_bridge_target_port}
        if self.config.phone_bridge_device_id:
            body["deviceId"] = self.config.phone_bridge_device_id
        url = api_v2_url(
            self.config.server_url,
            f"/connectors/{self.config.connector_id}/phone/bridges",
        )
        try:
            response = await client.post(
                url,
                json=body,
                headers={"Authorization": f"Bearer {token}"},
            )
        except httpx.HTTPError as exc:
            raise PhoneBridgeRelayError(f"bridge request failed: {exc}") from exc
        if response.status_code != 200:
            detail = _response_detail(response)
            raise PhoneBridgeRelayError(
                f"bridge request rejected status={response.status_code} detail={detail}"
            )
        try:
            payload = response.json()
        except ValueError as exc:
            raise PhoneBridgeRelayError("bridge response is not JSON") from exc
        if not isinstance(payload, dict):
            raise PhoneBridgeRelayError("bridge response is not an object")
        bridge_id = payload.get("bridgeId")
        relay_token = payload.get("relayToken")
        if not isinstance(bridge_id, str) or not isinstance(relay_token, str):
            raise PhoneBridgeRelayError("bridge response is missing fields")
        return payload, token

    def _relay_url(
        self,
        *,
        bridge_id: str,
        relay_token: str,
    ) -> str:
        path = api_v2_path(
            f"/connectors/{self.config.connector_id}/phone/{bridge_id}/relay"
        )
        base = build_ws_url(self.config.server_url, path)
        # The server checks both the connector access token and the signed
        # bridge token; neither is put in logs.
        # The connector access token rides the Authorization header so uvicorn
        # does not write it into the request line. The short-lived, single-use
        # bridge relay token stays in the query (and may appear in the request
        # line; it is useless without the connector access token).
        return f"{base}?token={quote(relay_token, safe='')}"

    async def _pump_tcp_to_ws(
        self,
        reader: asyncio.StreamReader,
        ws: Any,
    ) -> None:
        seq = 0
        while True:
            chunk = await reader.read(LOCAL_CHUNK_BYTES)
            if not chunk:
                await ws.send(json.dumps({"type": "close", "reason": "eof"}))
                return
            seq += 1
            await ws.send(
                json.dumps(
                    {
                        "type": "data",
                        "seq": seq,
                        "data": base64.b64encode(chunk).decode("ascii"),
                    }
                )
            )

    async def _pump_ws_to_tcp(
        self,
        ws: Any,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            async for raw in ws:
                frame = json.loads(raw)
                if not isinstance(frame, dict):
                    continue
                frame_type = frame.get("type")
                if frame_type == "data":
                    data = frame.get("data")
                    if not isinstance(data, str):
                        continue
                    try:
                        decoded = base64.b64decode(data, validate=True)
                    except (ValueError, TypeError):
                        continue
                    writer.write(decoded)
                    await writer.drain()
                elif frame_type in {"close", "error"}:
                    return
        except ConnectionClosed:
            return

    async def _close_http(self) -> None:
        http = self._http
        self._http = None
        if http is not None:
            with suppress(Exception):
                await http.aclose()


def _response_detail(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return response.text[:200]
    if isinstance(payload, dict) and isinstance(payload.get("detail"), str):
        return payload["detail"]
    return response.text[:200]
