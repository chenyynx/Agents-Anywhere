from __future__ import annotations

import asyncio
import inspect
from collections.abc import AsyncIterator, Callable, Mapping, Sequence
from typing import Any

from connector.runtimes.claude.domain.models import model_selection_from_selection_id
from connector.runtimes.claude.domain.permissions import (
    permission_mode_from_selection_id,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.stop_affordance import (
    install_per_task_stop_declaration,
    mark_declared_client,
)
from connector.runtimes.model_gateway import model_gateway_from_config

SdkLoader = Callable[[], Any]
ClaudeClientFactory = Callable[[Any, Any], Any]

# Claude CLI repeats image Read result base64 in both message and toolUseResult.
# 80 MiB covers a 25 MiB attachment appearing twice plus JSON overhead.
CLAUDE_SDK_MAX_BUFFER_SIZE = 80 * 1024 * 1024


def load_sdk(sdk_loader: SdkLoader | None) -> Any:
    if sdk_loader is None:
        raise RuntimeError("Claude SDK loader is not configured")
    return sdk_loader()


def new_sdk_client(
    sdk: Any,
    config_values: Mapping[str, Any],
    session: ClaudeSession,
    client_factory: ClaudeClientFactory | None = None,
    can_use_tool: Any | None = None,
    stderr: Callable[[str], None] | None = None,
    settings_path: str | None = None,
    cli_models: Sequence[Mapping[str, Any]] = (),
    on_tool_result: Any | None = None,
    before_tool: Any | None = None,
    title_control: Any | None = None,
) -> Any:
    # Every connection this process opens declares AA's per-task stop control,
    # so a CLI interrupt spares running background work (kill-switch:
    # `perTaskStopAffordance`, default on; see sdk/stop_affordance.py). The
    # install's return value is the connection-level fact the stop path reads
    # (red team F-A/F-C): it is recorded on the client here and copied onto
    # the `ClaudeConnection` at build time.
    declared = install_per_task_stop_declaration(
        sdk,
        declare=bool(config_values.get("perTaskStopAffordance", True)),
    )
    options = build_sdk_options(
        sdk,
        config_values,
        session,
        can_use_tool=can_use_tool,
        stderr=stderr,
        settings_path=settings_path,
        cli_models=cli_models,
        on_tool_result=on_tool_result,
        before_tool=before_tool,
        title_control=title_control,
    )
    if client_factory is not None:
        client = client_factory(sdk, options)
    else:
        client_cls = getattr(sdk, "ClaudeSDKClient", None)
        if client_cls is None:
            raise RuntimeError("ClaudeSDKClient is not available")
        try:
            client = client_cls(options=options)
        except TypeError:
            client = client_cls(options)
    mark_declared_client(client, declared)
    return client


def build_sdk_options(
    sdk: Any,
    config_values: Mapping[str, Any],
    session: ClaudeSession,
    can_use_tool: Any | None = None,
    stderr: Callable[[str], None] | None = None,
    settings_path: str | None = None,
    cli_models: Sequence[Mapping[str, Any]] = (),
    on_tool_result: Any | None = None,
    before_tool: Any | None = None,
    title_control: Any | None = None,
) -> Any:
    values = dict(config_values)
    kwargs: dict[str, Any] = {
        "include_partial_messages": True,
        "extra_args": {"replay-user-messages": None},
        "max_buffer_size": CLAUDE_SDK_MAX_BUFFER_SIZE,
    }
    if session.cwd:
        kwargs["cwd"] = session.cwd
    if session.external_session_id:
        kwargs["resume"] = session.external_session_id
    model_selection = model_selection_from_selection_id(
        session.selections.get("model"),
        values.get("customModels"),
        cli_models,
    )
    if model_selection is not None:
        if model_selection.cli_model is not None:
            kwargs["model"] = model_selection.cli_model
        if model_selection.effort_id is not None:
            kwargs["effort"] = model_selection.effort_id
    permission_mode = permission_mode_from_selection_id(
        session.selections.get("permission")
    )
    if permission_mode is not None:
        kwargs["permission_mode"] = permission_mode
    executable_path = values.get("executablePath")
    if isinstance(executable_path, str) and executable_path:
        kwargs["cli_path"] = executable_path
    environment = claude_sdk_environment(values)
    if environment:
        kwargs["env"] = environment
    if can_use_tool is not None:
        kwargs["can_use_tool"] = can_use_tool
    if stderr is not None:
        kwargs["stderr"] = stderr
    if settings_path is not None:
        kwargs["settings"] = settings_path
    hooks = _permission_hooks(sdk, on_tool_result, before_tool)
    if hooks is not None:
        kwargs["hooks"] = hooks
    if title_control is not None:
        # Agent-set session titles (see sdk/title_tool.py): inject the
        # in-process change_title MCP server and extend Claude Code's own
        # system prompt. The preset form is the SDK's supported way to extend
        # the default prompt; callers passing no control keep options exactly
        # as they were (the model-discovery path in catalogs/discovery.py).
        kwargs["mcp_servers"] = {title_control.server_name: title_control.server}
        kwargs["system_prompt"] = {
            "type": "preset",
            "preset": "claude_code",
            "append": title_control.system_prompt,
        }
    options_cls = getattr(sdk, "ClaudeAgentOptions", None) or getattr(
        sdk,
        "ClaudeCodeOptions",
        None,
    )
    if options_cls is None:
        return kwargs
    return options_cls(**kwargs)


def claude_sdk_environment(config_values: Mapping[str, Any]) -> dict[str, str]:
    """Build explicit environment overrides for one Claude SDK subprocess."""

    configured_environment = config_values.get("environment")
    environment = (
        dict(configured_environment)
        if isinstance(configured_environment, Mapping)
        else {}
    )
    model_gateway = model_gateway_from_config(config_values.get("modelGateway"))
    if model_gateway is not None:
        environment["ANTHROPIC_BASE_URL"] = model_gateway.base_url
        environment["ANTHROPIC_AUTH_TOKEN"] = model_gateway.api_key
        environment["ANTHROPIC_API_KEY"] = ""
    return environment


async def connect_client(client: Any) -> None:
    connect = getattr(client, "connect", None)
    if callable(connect):
        await maybe_await(connect())


async def disconnect_client(client: Any) -> None:
    disconnect = getattr(client, "disconnect", None)
    if callable(disconnect):
        await maybe_await(disconnect())


# The authoritative stop is the `task.cancel()` that follows this call; the
# SDK's `interrupt()` only asks the CLI to stop and waits for it to answer.
# A CLI that hangs mid-turn (the 2026-10-05 shape) would otherwise hold the
# whole stop path until the server's 30 s RPC timeout, so the wait is bounded
# here: on timeout the stop proceeds to the cancel exactly as it does today
# when `interrupt()` raises (the caller already logs and drops that error).
CLAUDE_INTERRUPT_TIMEOUT_SECONDS = 2.0


async def interrupt_client(
    client: Any,
    timeout: float = CLAUDE_INTERRUPT_TIMEOUT_SECONDS,
) -> bool:
    interrupt = getattr(client, "interrupt", None)
    if not callable(interrupt):
        return False
    result = interrupt()
    if inspect.isawaitable(result):
        await asyncio.wait_for(result, timeout=timeout)
    return True


async def query_client(client: Any, content: str) -> None:
    query = getattr(client, "query", None)
    if not callable(query):
        raise RuntimeError("ClaudeSDKClient.query is unavailable")  # noqa: TRY004
    await maybe_await(query(content))


async def receive_response_messages(client: Any) -> AsyncIterator[Any]:
    receive_response = getattr(client, "receive_messages", None) or getattr(
        client, "receive_response", None
    )
    if not callable(receive_response):
        return
    response = receive_response()
    if hasattr(response, "__aiter__"):
        async for message in response:
            yield message
        return
    messages = await maybe_await(response)
    if messages is None:
        return
    for message in messages:
        yield message


async def maybe_await(value: Any) -> Any:
    if inspect.isawaitable(value):
        return await value
    return value


def _permission_hooks(
    sdk: Any, on_tool_result: Any | None = None, before_tool: Any | None = None
) -> dict[str, Any] | None:
    hook_matcher = _optional_attr(sdk, "HookMatcher", "types.HookMatcher")
    if hook_matcher is None:
        return None

    async def keep_permission_stream_open(
        _input_data: Any,
        _tool_use_id: Any = None,
        _context: Any = None,
    ) -> dict[str, Any]:
        if before_tool is not None:
            result = await before_tool(_input_data)
            if result:
                return result
        return {"continue_": True}

    hooks = {
        "PreToolUse": [hook_matcher(matcher=None, hooks=[keep_permission_stream_open])]
    }
    if on_tool_result is not None:
        hooks["PostToolUse"] = [
            hook_matcher(matcher="^Cron(Create|Delete|List)$", hooks=[on_tool_result])
        ]
    return hooks


def _optional_attr(root: Any, *paths: str) -> Any:
    for path in paths:
        current = root
        for part in path.split("."):
            current = getattr(current, part, None)
            if current is None:
                break
        if current is not None:
            return current
    return None
