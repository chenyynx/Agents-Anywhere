from __future__ import annotations

import asyncio
from typing import Any

import pytest

from connector.runtime_protocol import RuntimeContextUsage, RuntimeIdentity
from connector.runtimes.claude.domain.context_usage import context_usage_from_control
from connector.runtimes.claude.sdk.client import (
    client_supports_context_usage,
    get_context_usage_client,
    sdk_supports_context_usage,
)
from connector.runtimes.codex.domain.context_usage import (
    context_usage_from_notification,
)
from connector.server.runtime_rpc import RuntimeRpcHandler
from connector.server.runtime_rpc_params import SessionContextUsageParams
from connector.server.runtime_rpc_payloads import context_usage_payload

_CLAUDE_PAYLOAD = {
    "model": "claude-opus-5-5",
    "totalTokens": 84_200,
    "maxTokens": 190_000,
    "rawMaxTokens": 200_000,
    "percentage": 42,
    "categories": [
        {"name": "System prompt", "tokens": 1_200, "kind": "used"},
        {"name": "Free space", "tokens": 9_000, "kind": "free"},
    ],
    "mcpTools": [
        {"name": "create_issue", "serverName": "linear", "tokens": 300, "isLoaded": True}
    ],
    "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 800}],
    "agents": [{"agentType": "reviewer", "source": "userSettings", "tokens": 120}],
    "skills": {
        "skillFrontmatter": [
            {"name": "commit", "source": "projectSettings", "tokens": 40}
        ]
    },
}


def test_claude_control_payload_maps_full_breakdown() -> None:
    usage = context_usage_from_control(
        _CLAUDE_PAYLOAD,
        detail="full",
        measured_at="2026-11-12T00:00:00Z",
    )

    assert usage.runtime == "claude"
    assert usage.model == "claude-opus-5-5"
    assert usage.total_tokens == 84_200
    # rawMaxTokens is the model window; maxTokens may be reduced by the
    # autocompact buffer, so the raw side wins when both are present.
    assert usage.max_tokens == 200_000
    assert usage.percentage == 42.0
    assert usage.detail == "full"
    assert usage.measured_at == "2026-11-12T00:00:00Z"
    assert [category.name for category in usage.categories] == [
        "System prompt",
        "Free space",
    ]
    assert [category.kind for category in usage.categories] == ["used", "free"]
    assert usage.mcp_tools[0].server_name == "linear"
    assert usage.memory_files[0].path == "/repo/CLAUDE.md"
    assert usage.agents[0].agent_type == "reviewer"
    assert usage.skills[0].plugin_name is None


def test_claude_mapping_derives_percentage_and_keeps_missing_breakdown_empty() -> None:
    usage = context_usage_from_control(
        {
            "totalTokens": 50_000,
            "maxTokens": 200_000,
            "model": "m",
        },
        detail="summary",
        measured_at=None,
    )

    assert usage.percentage == 25.0
    assert usage.categories == ()
    assert usage.mcp_tools == ()
    assert usage.memory_files == ()
    assert usage.agents == ()
    assert usage.skills == ()


def test_codex_notification_prefers_last_turn_tokens() -> None:
    snapshot = context_usage_from_notification(
        {
            "tokenUsage": {
                "total": {"totalTokens": 55_000},
                "last": {"totalTokens": 9_500},
                "modelContextWindow": 200_000,
            }
        },
        measured_at="2026-11-12T00:00:00Z",
    )

    assert snapshot is not None
    assert snapshot.used_tokens == 9_500
    assert snapshot.max_tokens == 200_000


def test_codex_notification_falls_back_to_total_and_snake_case() -> None:
    snapshot = context_usage_from_notification(
        {
            "token_usage": {
                "total": {"total_tokens": 12_000},
                "model_context_window": 128_000,
            }
        },
        measured_at="t",
    )

    assert snapshot is not None
    assert snapshot.used_tokens == 12_000
    assert snapshot.max_tokens == 128_000


def test_codex_notification_without_usage_is_ignored() -> None:
    assert context_usage_from_notification({}, measured_at="t") is None
    assert (
        context_usage_from_notification(
            {"tokenUsage": {"last": {}, "total": {}}},
            measured_at="t",
        )
        is None
    )


def test_context_usage_params_parse_and_validate_detail() -> None:
    parsed = SessionContextUsageParams.parse({"sessionId": "s1"})
    assert parsed.detail == "summary"
    parsed = SessionContextUsageParams.parse({"sessionId": "s1", "detail": "full"})
    assert parsed.detail == "full"
    with pytest.raises(ValueError):
        SessionContextUsageParams.parse({"sessionId": "s1", "detail": "all"})


def test_context_usage_payload_omits_absent_detail_lists() -> None:
    summary = context_usage_payload(
        RuntimeContextUsage(runtime="codex", total_tokens=10, detail="summary")
    )
    assert summary["totalTokens"] == 10
    assert "categories" not in summary
    assert "mcpTools" not in summary

    full = context_usage_payload(
        context_usage_from_control(
            _CLAUDE_PAYLOAD,
            detail="full",
            measured_at=None,
        )
    )
    assert full["categories"][0]["name"] == "System prompt"
    assert full["mcpTools"][0]["serverName"] == "linear"
    assert full["memoryFiles"][0]["path"] == "/repo/CLAUDE.md"
    assert full["agents"][0]["agentType"] == "reviewer"
    assert full["skills"][0]["source"] == "projectSettings"


def test_client_support_and_sdk_support_detection() -> None:
    class _Client:
        async def get_context_usage(self) -> dict[str, Any]:
            return {"totalTokens": 1}

    class _NoSeam:
        pass

    class _Sdk:
        ClaudeSDKClient = _Client

    class _OldSdk:
        ClaudeSDKClient = _NoSeam

    assert client_supports_context_usage(_Client()) is True
    assert client_supports_context_usage(_NoSeam()) is False
    assert sdk_supports_context_usage(_Sdk()) is True
    assert sdk_supports_context_usage(_OldSdk()) is False


def test_get_context_usage_client_prefers_detail_capable_sender() -> None:
    class _Query:
        def __init__(self) -> None:
            self.requests: list[dict[str, Any]] = []

        async def _send_control_request(self, request: dict[str, Any]) -> Any:
            self.requests.append(request)
            return {"totalTokens": 7}

    class _Client:
        def __init__(self) -> None:
            self._query = _Query()

    async def run() -> None:
        client = _Client()
        assert await get_context_usage_client(client, detail="full") == {
            "totalTokens": 7
        }
        assert client._query.requests == [
            {"subtype": "get_context_usage", "detail": "full"}
        ]

        # Fallback: a client exposing only the public method still answers
        # (the CLI default detail), and a timeout is a soft None.
        class _Public:
            async def get_context_usage(self) -> dict[str, Any]:
                return {"totalTokens": 3}

        assert await get_context_usage_client(_Public()) == {"totalTokens": 3}

        class _Silent:
            async def get_context_usage(self) -> dict[str, Any]:
                await asyncio.Event().wait()
                return {}

        assert (
            await get_context_usage_client(_Silent(), timeout=0.01) is None
        )

    asyncio.run(run())


class _ContextRuntime:
    @property
    def identity(self) -> RuntimeIdentity:
        return RuntimeIdentity(runtime="claude", runtime_version="native-0")

    async def get_session_context_usage(
        self, session_id: str, detail: str = "summary"
    ) -> RuntimeContextUsage:
        return RuntimeContextUsage(
            runtime="claude",
            total_tokens=100,
            max_tokens=200,
            percentage=50.0,
            detail=detail,
        )


class _Supervisor:
    def __init__(self, runtime: Any) -> None:
        self._runtime = runtime

    def resolve_runtime(self, runtime_id: str, runtime_type: str | None = None) -> Any:
        return self._runtime


class _Host:
    @property
    def connector_id(self) -> str:
        return "connector-1"


def test_rpc_dispatches_session_context_usage() -> None:
    async def run() -> None:
        handler = RuntimeRpcHandler(  # type: ignore[arg-type]
            _Supervisor(_ContextRuntime()),
            _Host(),  # type: ignore[arg-type]
        )
        result = await handler.dispatch(
            "session.contextUsage",
            {
                "runtime": "claude",
                "runtimeId": "claude",
                "sessionId": "sess-1",
                "detail": "full",
            },
        )

        assert result["usage"]["totalTokens"] == 100
        assert result["usage"]["detail"] == "full"
        assert result["runtime"] == "claude"

    asyncio.run(run())


def test_claude_real_cli_payload_regression() -> None:
    """Golden shape captured live from the bundled CLI (2.1.321, 2026-11-12).

    The categories carry the CLI's own names and the derived kinds; `skills`
    arrives nested under `skillFrontmatter` with plugin/path extras that the
    mapper drops. Keeping this exact shape here is the guard against a CLI
    field rename silently emptying the sheet.
    """

    payload = {
        "model": "wb/deepseek-v4.1-flash",
        "totalTokens": 29_794,
        "maxTokens": 1_000_000,
        "rawMaxTokens": 1_000_000,
        "percentage": 3,
        "autocompactSource": "model-default",
        "categories": [
            {"name": "MCP tools", "tokens": 4_282, "kind": "used"},
            {"name": "MCP tools (deferred)", "tokens": 17_967, "kind": "deferred"},
            {"name": "Custom agents", "tokens": 90, "kind": "used"},
            {"name": "Memory files", "tokens": 7_919, "kind": "used"},
            {"name": "Skills", "tokens": 9_949, "kind": "used"},
            {"name": "Messages", "tokens": 6_758, "kind": "used"},
            {"name": "Autocompact buffer", "tokens": 33_000, "kind": "buffer"},
            {"name": "Free space", "tokens": 937_206, "kind": "free"},
        ],
        "mcpTools": [
            {"name": "create_issue", "serverName": "linear", "tokens": 300,
             "isLoaded": True},
        ],
        "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 7_919}],
        "agents": [{"agentType": "reviewer", "source": "userSettings", "tokens": 90}],
        "skills": {
            "totalSkills": 200,
            "includedSkills": 168,
            "tokens": 9_949,
            "skillFrontmatter": [
                {"name": "commit", "source": "projectSettings", "tokens": 40,
                 "path": "/repo/.claude/skills/commit.md", "pluginId": "p1"},
            ],
        },
        "slashCommands": {"totalCommands": 10, "includedCommands": 9, "tokens": 12},
        "apiUsage": {"input_tokens": 1, "output_tokens": 2,
                     "cache_creation_input_tokens": 3,
                     "cache_read_input_tokens": 4},
    }

    usage = context_usage_from_control(
        payload, detail="summary", measured_at="2026-11-12T00:00:00Z"
    )

    assert usage.total_tokens == 29_794
    assert usage.max_tokens == 1_000_000
    assert usage.percentage == 3.0
    kinds = {category.name: category.kind for category in usage.categories}
    assert kinds["Free space"] == "free"
    assert kinds["Autocompact buffer"] == "buffer"
    assert kinds["MCP tools (deferred)"] == "deferred"
    assert usage.skills[0].name == "commit"
    assert usage.skills[0].tokens == 40
    assert usage.mcp_tools[0].server_name == "linear"


class _CacheHost:
    def __init__(self) -> None:
        self.data: dict[str, Any] = {}

    async def sync_state_read(self, key: str) -> Any:
        return self.data.get(key)

    async def sync_state_write(self, key: str, value: Any) -> None:
        self.data[key] = dict(value)


def test_context_usage_cache_round_trip_marks_cached() -> None:
    from connector.runtimes.context_usage_cache import ContextUsageCache

    async def run() -> None:
        host = _CacheHost()
        cache = ContextUsageCache(host, "claude")  # type: ignore[arg-type]
        usage = RuntimeContextUsage(
            runtime="claude",
            total_tokens=100,
            model="m",
            max_tokens=200,
            percentage=50.0,
            detail="full",
            source="claude.control",
            measured_at="2026-11-12T00:00:00Z",
        )
        await cache.write("s1", usage)

        # The durable key is runtime-namespaced (the host parses its first
        # segment as the runtime).
        assert "claude/context_usage/s1" in host.data

        cached = await cache.read("s1")

        assert cached is not None
        assert cached.total_tokens == 100
        assert cached.max_tokens == 200
        assert cached.percentage == 50.0
        assert cached.detail == "cached"
        assert cached.source == "claude.control.cache"
        assert cached.measured_at == "2026-11-12T00:00:00Z"
        assert cached.categories == ()

    asyncio.run(run())


def test_context_usage_cache_ignores_missing_and_malformed_values() -> None:
    from connector.runtimes.context_usage_cache import ContextUsageCache

    async def run() -> None:
        host = _CacheHost()
        cache = ContextUsageCache(host, "codex")  # type: ignore[arg-type]
        assert await cache.read("missing") is None

        host.data["codex/context_usage/bad"] = "not-a-mapping"
        assert await cache.read("bad") is None

        host.data["codex/context_usage/no-total"] = {"maxTokens": 5}
        assert await cache.read("no-total") is None

    asyncio.run(run())


def test_context_usage_cache_write_failure_is_soft() -> None:
    from connector.runtimes.context_usage_cache import ContextUsageCache

    class _FailingHost(_CacheHost):
        async def sync_state_write(self, key: str, value: Any) -> None:
            raise OSError("disk full")

    async def run() -> None:
        cache = ContextUsageCache(_FailingHost(), "claude")  # type: ignore[arg-type]
        await cache.write(
            "s1",
            RuntimeContextUsage(runtime="claude", total_tokens=1),
        )
        # No exception escaped; the live answer is unaffected.

    asyncio.run(run())
