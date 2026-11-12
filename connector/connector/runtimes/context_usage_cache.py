"""Durable last-known context usage, per runtime.

The ring must not vanish because a transport went away: connector restarts,
connection rebuilds and cold page opens all happen while the user still
expects the last measured figure. This cache keeps the last successful
measurement in the runtime's durable key-value store (the same
``sync_state_*`` seam session bindings use) and serves it — marked as cached —
when the live answer is unavailable.

The summary is always persisted. The per-category breakdown is persisted too
when the runtime has answered a ``full`` read: the CLI's payload contains the
category rows, MCP tools, memory files, agents and skills, so losing them on a
transport drop makes the Usage page look half-empty even though the user was
just looking at it. A later summary write updates the scalar figures but keeps
the previous breakdown until the next full read replaces it.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from connector.runtime_protocol import (
    RuntimeContextUsage,
    RuntimeContextUsageAgent,
    RuntimeContextUsageCategory,
    RuntimeContextUsageMcpTool,
    RuntimeContextUsageMemoryFile,
    RuntimeContextUsageSkill,
)
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


def _rows(value: Any) -> list[Mapping[str, Any]]:
    if not isinstance(value, (list, tuple)):
        return []
    return [row for row in value if isinstance(row, Mapping)]


def _categories(value: Any) -> tuple[RuntimeContextUsageCategory, ...]:
    rows: list[RuntimeContextUsageCategory] = []
    for row in _rows(value):
        name = _str(row.get("name"))
        tokens = _int(row.get("tokens"))
        if name is None or tokens is None:
            continue
        rows.append(
            RuntimeContextUsageCategory(
                name=name, tokens=tokens, kind=_str(row.get("kind"))
            )
        )
    return tuple(rows)


def _mcp_tools(value: Any) -> tuple[RuntimeContextUsageMcpTool, ...]:
    rows: list[RuntimeContextUsageMcpTool] = []
    for row in _rows(value):
        name = _str(row.get("name"))
        server_name = _str(row.get("serverName"))
        tokens = _int(row.get("tokens"))
        if name is None or server_name is None or tokens is None:
            continue
        rows.append(
            RuntimeContextUsageMcpTool(
                name=name, server_name=server_name, tokens=tokens
            )
        )
    return tuple(rows)


def _memory_files(value: Any) -> tuple[RuntimeContextUsageMemoryFile, ...]:
    rows: list[RuntimeContextUsageMemoryFile] = []
    for row in _rows(value):
        path = _str(row.get("path"))
        tokens = _int(row.get("tokens"))
        if path is None or tokens is None:
            continue
        rows.append(
            RuntimeContextUsageMemoryFile(
                path=path, tokens=tokens, type=_str(row.get("type"))
            )
        )
    return tuple(rows)


def _agents(value: Any) -> tuple[RuntimeContextUsageAgent, ...]:
    rows: list[RuntimeContextUsageAgent] = []
    for row in _rows(value):
        agent_type = _str(row.get("agentType"))
        tokens = _int(row.get("tokens"))
        if agent_type is None or tokens is None:
            continue
        rows.append(
            RuntimeContextUsageAgent(
                agent_type=agent_type, tokens=tokens, source=_str(row.get("source"))
            )
        )
    return tuple(rows)


def _skills(value: Any) -> tuple[RuntimeContextUsageSkill, ...]:
    rows: list[RuntimeContextUsageSkill] = []
    for row in _rows(value):
        name = _str(row.get("name"))
        tokens = _int(row.get("tokens"))
        if name is None or tokens is None:
            continue
        rows.append(
            RuntimeContextUsageSkill(
                name=name,
                tokens=tokens,
                source=_str(row.get("source")),
                plugin_name=_str(row.get("pluginName")),
            )
        )
    return tuple(rows)


def _serialize_categories(
    values: tuple[RuntimeContextUsageCategory, ...],
) -> list[dict[str, Any]]:
    return [
        {"name": value.name, "tokens": value.tokens, **(
            {"kind": value.kind} if value.kind is not None else {}
        )}
        for value in values
    ]


def _serialize_mcp_tools(
    values: tuple[RuntimeContextUsageMcpTool, ...],
) -> list[dict[str, Any]]:
    return [
        {
            "name": value.name,
            "serverName": value.server_name,
            "tokens": value.tokens,
        }
        for value in values
    ]


def _serialize_memory_files(
    values: tuple[RuntimeContextUsageMemoryFile, ...],
) -> list[dict[str, Any]]:
    return [
        {
            "path": value.path,
            "tokens": value.tokens,
            **({"type": value.type} if value.type is not None else {}),
        }
        for value in values
    ]


def _serialize_agents(
    values: tuple[RuntimeContextUsageAgent, ...],
) -> list[dict[str, Any]]:
    return [
        {
            "agentType": value.agent_type,
            "tokens": value.tokens,
            **({"source": value.source} if value.source is not None else {}),
        }
        for value in values
    ]


def _serialize_skills(
    values: tuple[RuntimeContextUsageSkill, ...],
) -> list[dict[str, Any]]:
    return [
        {
            "name": value.name,
            "tokens": value.tokens,
            **({"source": value.source} if value.source is not None else {}),
            **(
                {"pluginName": value.plugin_name}
                if value.plugin_name is not None
                else {}
            ),
        }
        for value in values
    ]


class ContextUsageCache:
    """Last-known context-usage summary and breakdown for one runtime."""

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
            categories=_categories(value.get("categories")),
            mcp_tools=_mcp_tools(value.get("mcpTools")),
            memory_files=_memory_files(value.get("memoryFiles")),
            agents=_agents(value.get("agents")),
            skills=_skills(value.get("skills")),
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

        categories = usage.categories
        mcp_tools = usage.mcp_tools
        memory_files = usage.memory_files
        agents = usage.agents
        skills = usage.skills
        if usage.detail != "full":
            # A summary read refreshes the figures but carries no breakdown.
            # Keep the last full answer until a new full read replaces it, so
            # opening the sheet after a turn does not erase its own detail.
            previous = await self.read(session_id)
            if previous is not None:
                categories = categories or previous.categories
                mcp_tools = mcp_tools or previous.mcp_tools
                memory_files = memory_files or previous.memory_files
                agents = agents or previous.agents
                skills = skills or previous.skills

        if categories:
            payload["categories"] = _serialize_categories(categories)
        if mcp_tools:
            payload["mcpTools"] = _serialize_mcp_tools(mcp_tools)
        if memory_files:
            payload["memoryFiles"] = _serialize_memory_files(memory_files)
        if agents:
            payload["agents"] = _serialize_agents(agents)
        if skills:
            payload["skills"] = _serialize_skills(skills)
        try:
            await self._host.sync_state_write(self._key(session_id), payload)
        except Exception:  # noqa: BLE001 - best effort; the memory answer stands
            return
