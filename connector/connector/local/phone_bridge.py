"""Loopback-only TCP listener for the Phone Bridge.

The iCTRL client points at this listener instead of the phone. Each accepted
TCP connection becomes one Server bridge, so HTTP keep-alive and the iCTRL
client's normal connection reuse work unchanged.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

from connector.logging import logger

LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})

ConnectionHandler = Callable[
    [asyncio.StreamReader, asyncio.StreamWriter], Awaitable[None]
]


class PhoneBridgeLocalServer:
    def __init__(self, *, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self._server: asyncio.AbstractServer | None = None

    async def start(self, handler: ConnectionHandler) -> bool:
        if self.host not in LOOPBACK_HOSTS:
            logger.error(
                "phone bridge listener refused non-loopback host={}", self.host
            )
            return False
        try:
            self._server = await asyncio.start_server(
                handler,
                host=self.host,
                port=self.port,
                limit=2 * 1024 * 1024,
            )
        except OSError as exc:
            logger.error(
                "phone bridge listener failed host={} port={} error={}",
                self.host,
                self.port,
                exc,
            )
            return False
        sockets = self._server.sockets or []
        address = sockets[0].getsockname() if sockets else (self.host, self.port)
        logger.info("phone bridge listener ready address={}", address)
        return True

    async def stop(self) -> None:
        server = self._server
        self._server = None
        if server is None:
            return
        server.close()
        try:
            await server.wait_closed()
        except Exception:  # noqa: BLE001 - shutdown is best effort
            pass
