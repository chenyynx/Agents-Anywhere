"""Durable last-known context usage, per runtime.

The ring must not vanish because a transport went away: connector restarts,
connection rebuilds and cold page opens all happen while the user still
expects the last measured figure. This cache keeps the summary of the last
successful measurement in the runtime's durable key-value store (the same
`sync_state_*` seam session bindings use) and serves it — marked as cached —
when the live answer is unavailable.

Only the summary is persisted. The per-category breakdown can be large (a
single session can carry hundreds of skill rows) and is a live-only nicety; a
cached answer renders the summary without a breakdown section.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from connector.runtime_protocol import RuntimeContextUsage
from connector.runtime_protocol.host import RuntimeHostClient

_CACHE_SOURCE_SUFFIX = ".cache"


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    return None


def _str(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


class ContextUsageCache:
    """Last-known context-usage summary for one runtime's sessions."""

    def __init__(self, host: RuntimeHostClient, namespace: str) -> None:
        self._host = host
        self._namespace = namespace

    def _key(self, session_id: str) -> str:
        # The host namespaces durable keys as `<runtime>/...` and parses the
        # first segment as the runtime; a dotted key would raise there and the
        # cache would silently never persist.
        return f"{self._namespace}/context_usage/{session_id}"

    async def read(self, session_id: str) -> RuntimeContextUsage | None:
        try:
            value = await self._host.sync_state_read(self._key(session_id))
        except Exception:  # noqa: BLE001 - fail-soft by contract
            return None
        if not isinstance(value, Mapping):
            return None
        total = _int(value.get("totalTokens"))
        if total is None:
            return None
        source = _str(value.get("source")) or self._namespace
        if not source.endswith(_CACHE_SOURCE_SUFFIX):
            source = f"{source}{_CACHE_SOURCE_SUFFIX}"
        return RuntimeContextUsage(
            runtime=_str(value.get("runtime")) or self._namespace,
            total_tokens=total,
            model=_str(value.get("model")),
            max_tokens=_int(value.get("maxTokens")),
            percentage=(
                float(value["percentage"])
                if isinstance(value.get("percentage"), (int, float))
                and not isinstance(value.get("percentage"), bool)
                else None
            ),
            detail="cached",
            source=source,
            measured_at=_str(value.get("measuredAt")),
            runtime_id=_str(value.get("runtimeId")),
        )

    async def write(self, session_id: str, usage: RuntimeContextUsage) -> None:
        payload: dict[str, Any] = {
            "runtime": usage.runtime,
            "totalTokens": usage.total_tokens,
            "detail": usage.detail,
            "source": usage.source,
        }
        if usage.runtime_id is not None:
            payload["runtimeId"] = usage.runtime_id
        if usage.model is not None:
            payload["model"] = usage.model
        if usage.max_tokens is not None:
            payload["maxTokens"] = usage.max_tokens
        if usage.percentage is not None:
            payload["percentage"] = usage.percentage
        if usage.measured_at is not None:
            payload["measuredAt"] = usage.measured_at
        try:
            await self._host.sync_state_write(self._key(session_id), payload)
        except Exception:  # noqa: BLE001 - best effort; the memory answer stands
            return
