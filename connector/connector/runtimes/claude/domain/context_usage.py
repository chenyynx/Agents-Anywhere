"""Map the Claude CLI's context-usage control payload onto the AA wire model.

The control (`get_context_usage`) answers from the CLI's own state with
camelCase keys; this module is the one place that knows their names, so the
RPC layer and the server contract never read CLI-shaped data directly. The
grouped detail lists are optional — a CLI that answers without them yields an
empty tuple, and clients hide that section rather than showing a zeroed one.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import Any

from connector.runtime_protocol import (
    RuntimeContextUsage,
    RuntimeContextUsageAgent,
    RuntimeContextUsageCategory,
    RuntimeContextUsageMcpTool,
    RuntimeContextUsageMemoryFile,
    RuntimeContextUsageSkill,
)


def _int(value: Any, default: int | None = None) -> int | None:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except ValueError:
            return default
    return default


def _str(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _mappings(value: Any) -> Sequence[Mapping[str, Any]]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        return ()
    return tuple(item for item in value if isinstance(item, Mapping))


def _categories(payload: Mapping[str, Any]) -> tuple[RuntimeContextUsageCategory, ...]:
    return tuple(
        RuntimeContextUsageCategory(
            name=_str(item.get("name")) or "",
            tokens=_int(item.get("tokens"), 0) or 0,
            kind=_str(item.get("kind")),
        )
        for item in _mappings(payload.get("categories"))
    )


def _mcp_tools(payload: Mapping[str, Any]) -> tuple[RuntimeContextUsageMcpTool, ...]:
    return tuple(
        RuntimeContextUsageMcpTool(
            name=_str(item.get("name")) or "",
            server_name=_str(item.get("serverName")) or "",
            tokens=_int(item.get("tokens"), 0) or 0,
        )
        for item in _mappings(payload.get("mcpTools"))
    )


def _memory_files(
    payload: Mapping[str, Any],
) -> tuple[RuntimeContextUsageMemoryFile, ...]:
    return tuple(
        RuntimeContextUsageMemoryFile(
            path=_str(item.get("path")) or "",
            type=_str(item.get("type")),
            tokens=_int(item.get("tokens"), 0) or 0,
        )
        for item in _mappings(payload.get("memoryFiles"))
    )


def _agents(payload: Mapping[str, Any]) -> tuple[RuntimeContextUsageAgent, ...]:
    return tuple(
        RuntimeContextUsageAgent(
            agent_type=_str(item.get("agentType")) or "",
            source=_str(item.get("source")),
            tokens=_int(item.get("tokens"), 0) or 0,
        )
        for item in _mappings(payload.get("agents"))
    )


def _skills(payload: Mapping[str, Any]) -> tuple[RuntimeContextUsageSkill, ...]:
    # The CLI nests the per-skill rows under `skills.skillFrontmatter`; a
    # flattened `skills` list is accepted too for older/newer answer shapes.
    skills = payload.get("skills")
    rows: Sequence[Mapping[str, Any]]
    if isinstance(skills, Mapping):
        rows = _mappings(skills.get("skillFrontmatter"))
    else:
        rows = _mappings(skills)
    return tuple(
        RuntimeContextUsageSkill(
            name=_str(item.get("name")) or "",
            source=_str(item.get("source")),
            plugin_name=_str(item.get("pluginName")),
            tokens=_int(item.get("tokens"), 0) or 0,
        )
        for item in rows
    )


def context_usage_from_control(
    payload: Mapping[str, Any],
    *,
    detail: str,
    measured_at: str | None,
) -> RuntimeContextUsage:
    """One control response -> `RuntimeContextUsage`.

    `percentage` is preferred from the CLI (it rounds to whole percent); when
    absent it is derived from used/max so a client never has to guess. Both
    token sides stay integers; a missing max is `None`, never zero.
    """

    total = _int(payload.get("totalTokens"), 0) or 0
    maximum = _int(payload.get("rawMaxTokens"))
    if maximum is None:
        maximum = _int(payload.get("maxTokens"))
    percentage = payload.get("percentage")
    if not isinstance(percentage, (int, float)) or isinstance(percentage, bool):
        percentage = (total / maximum * 100.0) if maximum else None
    return RuntimeContextUsage(
        runtime="claude",
        model=_str(payload.get("model")),
        total_tokens=total,
        max_tokens=maximum,
        percentage=float(percentage) if percentage is not None else None,
        detail=detail,
        source="claude.control",
        measured_at=measured_at,
        categories=_categories(payload),
        mcp_tools=_mcp_tools(payload),
        memory_files=_memory_files(payload),
        agents=_agents(payload),
        skills=_skills(payload),
    )
