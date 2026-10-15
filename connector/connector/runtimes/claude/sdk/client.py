from __future__ import annotations

import asyncio
import inspect
import json
import os
from collections.abc import AsyncIterator, Callable, Mapping, Sequence
from typing import Any

from connector.logging import logger
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


# A runtime selection change (model / permission) can be applied to the live
# CLI process instead of rebuilding it. The SDK exposes that as the
# `set_model` / `set_permission_mode` control requests (client.py:341/314,
# _internal/query.py 805/796; the earlier 10-05 recon that "the model is a
# launch argument" predates them). Measured against CLI 2.1.285/2.1.296 on
# 2026-10-15: acceptance settles in ~1.6-2.7 s, and a refusal arrives near the
# CLI's own 15 s model-validation deadline — `set_model` first spends a 1-token
# `model_validation` probe request against the API, and answers "Couldn't
# confirm model…" (`retryable: true`) when that probe stalls.
#
# So the bound here must sit ABOVE that 15 s deadline: a shorter wait would cut
# off a validation that was about to succeed, leaving this process's belief
# (`False`) and the CLI's (`applied`) disagreeing. The upstream
# `_send_control_request` default is 60 s, which would hold the selection-change
# path on a silent CLI for a full minute; 20 s keeps the headroom over the CLI
# deadline while staying inside the server's 30 s RPC budget for THIS call.
# (The budget is per call, not per PATCH: a PATCH that changes both halves runs
# this and `set_permission_mode_client` CONCURRENTLY — see the runner's
# `_apply_selection_in_process` — so one PATCH stays inside a single 20 s
# window rather than stacking two.)
CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS = 20.0


def client_supports_set_model(client: Any) -> bool:
    """Whether this connection can change model in place.

    Checked on the attribute (the capability), never by version number: the
    request only exists where the client object actually carries the method
    (the shape of `sdk/stop_affordance.sdk_supports_stop_task`).
    """

    return callable(getattr(client, "set_model", None))


def client_supports_set_permission_mode(client: Any) -> bool:
    """Whether this connection can change permission mode in place."""

    return callable(getattr(client, "set_permission_mode", None))


async def set_model_client(client: Any, model: str | None) -> bool:
    """Apply `model` to the live connection; True when the CLI accepted it.

    `model=None` is forwarded verbatim (the SDK reads it as "use the CLI
    default"), so the caller can express the same reset the launch argument
    would. Fail-soft: a missing seam, a refusal, or a silent CLI is a False —
    never an exception into the turn — and the failure is logged so the
    fallback is observable. Log text carries the target value only, never a
    credential.
    """

    return await _apply_selection_control(
        client,
        "set_model",
        model,
        model,
        timeout=CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS,
    )


async def set_permission_mode_client(client: Any, mode: str) -> bool:
    """Apply `mode` to the live connection; True when the CLI accepted it.

    Same fail-soft contract as `set_model_client`: refusal/timeout/missing
    seam return False with a warning, so the caller can fall back to the
    rebuild path.
    """

    return await _apply_selection_control(
        client,
        "set_permission_mode",
        mode,
        mode,
        timeout=CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS,
    )


async def _apply_selection_control(
    client: Any,
    method_name: str,
    argument: Any,
    failure_value: Any,
    *,
    timeout: float,
) -> bool:
    method = getattr(client, method_name, None)
    if not callable(method):
        logger.warning(
            "Claude {} unavailable: client has no {} seam; falling back",
            method_name,
            method_name,
        )
        return False
    try:
        result = method(argument)
        if inspect.isawaitable(result):
            await asyncio.wait_for(result, timeout=timeout)
    except TimeoutError:
        # asyncio.TimeoutError is TimeoutError (3.11+); named explicitly so
        # the bounded-wait failure is distinguishable from an upstream refusal.
        logger.warning(
            "Claude {} timed out after {}s for {}; falling back",
            method_name,
            timeout,
            failure_value,
        )
        return False
    except Exception as exc:  # noqa: BLE001 - fail-soft by contract
        logger.warning(
            "Claude {} failed for {}: {}: {}; falling back",
            method_name,
            failure_value,
            type(exc).__name__,
            exc,
        )
        return False
    return True


async def query_client(client: Any, content: str) -> None:
    query = getattr(client, "query", None)
    if not callable(query):
        raise RuntimeError("ClaudeSDKClient.query is unavailable")  # noqa: TRY004
    await maybe_await(query(content))


def _raw_frame_dump_path() -> str | None:
    """Diagnostic switch (default OFF): dump every raw CLI frame to a file.

    Set ``AA_RAW_FRAME_DUMP`` to a path to capture the exact frame sequence the
    CLI emits (one JSON object per line). Used to pin the real trigger shape of
    the subagent-attribution bug; costs one frame-sized write per frame.
    """

    path = os.environ.get("AA_RAW_FRAME_DUMP")
    return path or None


def _dump_raw_frame(path: str, message: Any) -> None:
    try:
        record = {
            "cls": type(message).__name__,
            "parent_tool_use_id": getattr(message, "parent_tool_use_id", None),
            "session_id": getattr(message, "session_id", None),
            "uuid": getattr(message, "uuid", None),
        }
        event = getattr(message, "event", None)
        if isinstance(event, Mapping):
            record["event"] = event
        else:
            nested = getattr(message, "message", None)
            if isinstance(nested, Mapping):
                record["message_id"] = nested.get("id")
                record["role"] = nested.get("role")
                content = nested.get("content")
                if isinstance(content, list):
                    record["blocks"] = [
                        {
                            "type": (b.get("type") if isinstance(b, Mapping) else None),
                            "id": (b.get("id") if isinstance(b, Mapping) else None),
                        }
                        for b in content
                    ]
            record["type"] = getattr(message, "type", None)
            record["result"] = type(message).__name__ == "ResultMessage"
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except Exception:  # noqa: BLE001, S110
        pass  # a diagnostic dump must never break the stream


async def receive_response_messages(client: Any) -> AsyncIterator[Any]:
    receive_response = getattr(client, "receive_messages", None) or getattr(
        client, "receive_response", None
    )
    if not callable(receive_response):
        return
    dump_path = _raw_frame_dump_path()
    response = receive_response()
    if hasattr(response, "__aiter__"):
        async for message in response:
            if dump_path is not None:
                _dump_raw_frame(dump_path, message)
            yield message
        return
    messages = await maybe_await(response)
    if messages is None:
        return
    for message in messages:
        if dump_path is not None:
            _dump_raw_frame(dump_path, message)
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
