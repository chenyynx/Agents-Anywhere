"""In-process MCP server for the AA Phone Bridge.

Five tools, not one per iCTRL method: ``phone_skill`` and ``phone_schema``
teach the model the device's current API, and ``phone_call`` is the single
execution surface. The iCTRL client is embedded, so a call does not spawn a
Python process per action (the reason this is MCP rather than a Bash CLI).
"""

from __future__ import annotations

import base64
import json
import uuid
from dataclasses import dataclass
from typing import Any

import httpx

from connector.logging import logger
from connector.paths import connector_data_dir
from connector.phone import ictrl_client
from connector.server.phone_bridge import PhoneBridgeRunner

PHONE_SERVER_NAME = "phone"
PHONE_TOOL_PREFIX = f"mcp__{PHONE_SERVER_NAME}__"
PHONE_SYSTEM_PROMPT = (
    "Phone control is available through "
    f"`{PHONE_TOOL_PREFIX}phone_call`. Before the first call, read the device's "
    f"manual with `{PHONE_TOOL_PREFIX}phone_skill`; use "
    f"`{PHONE_TOOL_PREFIX}phone_schema` when a method's parameters are unclear. "
    f"Call `{PHONE_TOOL_PREFIX}phone_pair` only when a call reports that no "
    "token exists. The manual may show CLI examples; in AA execute the same "
    "methods through phone_call instead of shell commands. Treat the manual's "
    "rules (no sleep, tap by ref, read once) as binding."
)


def is_phone_tool_name(tool_name: str | None) -> bool:
    """Match the wire form, never the bare tool name (same lesson as titles)."""
    return bool(tool_name) and tool_name.startswith(PHONE_TOOL_PREFIX)


@dataclass(frozen=True, slots=True)
class PhoneControl:
    server_name: str
    server: Any
    system_prompt: str
    handler: Any


def _tool_text(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}]}


def _json_text(value: Any) -> dict[str, Any]:
    return _tool_text(json.dumps(value, ensure_ascii=False))


def build_phone_tool(
    sdk: Any,
    runner: PhoneBridgeRunner | None,
) -> PhoneControl | None:
    """Build the MCP server, or None when the bridge is disabled/unavailable."""
    create_server = getattr(sdk, "create_sdk_mcp_server", None)
    tool_decorator = getattr(sdk, "tool", None)
    if create_server is None or tool_decorator is None:
        return None
    if runner is None or not runner.enabled:
        return None

    base_url = runner.local_base_url
    token_path = ictrl_client.default_token_path()

    async def phone_devices(_args: dict[str, Any]) -> dict[str, Any]:
        try:
            devices = await runner.list_devices()
        except Exception as exc:  # noqa: BLE001 - tool errors are text, not crashes
            logger.warning("phone devices failed error={}", exc)
            return _tool_text(f"Listing phones failed: {exc}")
        if not devices:
            return _tool_text("No phone is online. Enable Phone Control on the phone.")
        return _json_text({"devices": devices})

    async def phone_pair(_args: dict[str, Any]) -> dict[str, Any]:
        try:
            result = await ictrl_client.pair(
                base_url,
                "AA Connector",
                token_path=token_path,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("phone pairing failed error={}", exc)
            return _tool_text(f"Pairing failed: {exc}")
        return _json_text(
            {
                "paired": True,
                "deviceId": result.get("deviceId"),
                "expires": result.get("expires"),
                "fingerprint": result.get("fingerprint"),
            }
        )

    async def phone_skill(_args: dict[str, Any]) -> dict[str, Any]:
        try:
            text = await ictrl_client.get_text(base_url, "/skill")
        except Exception as exc:  # noqa: BLE001
            return _tool_text(f"Reading the phone skill failed: {exc}")
        return _tool_text(text)

    async def phone_schema(args: dict[str, Any]) -> dict[str, Any]:
        method = args.get("method")
        try:
            if isinstance(method, str) and method:
                text = await ictrl_client.get_text(
                    base_url, f"/schema?method={method}"
                )
            else:
                text = await ictrl_client.get_text(base_url, "/schema")
        except Exception as exc:  # noqa: BLE001
            return _tool_text(f"Reading the phone schema failed: {exc}")
        return _tool_text(text)

    async def phone_call(args: dict[str, Any]) -> dict[str, Any]:
        method = args.get("method")
        params = args.get("params")
        if not isinstance(method, str) or not method:
            return _tool_text("phone_call requires a method.")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            return _tool_text("phone_call params must be an object.")
        try:
            result = await ictrl_client.call(
                base_url,
                method,
                params,
                token_path=token_path,
            )
        except ictrl_client.IctrlPairingRequired:
            return _tool_text(
                "No iCTRL token. Call phone_pair first, then approve the prompt "
                "on the phone."
            )
        except (httpx.ReadTimeout, TimeoutError):
            return _tool_text(
                "phone_call timed out. The action may still be running or may "
                "already have completed; call phone_call with method=logs and "
                "look for the method before retrying, especially for tap/type."
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("phone call failed method={} error={}", method, exc)
            return _tool_text(f"phone_call failed: {exc}")
        if method == "screenshot":
            saved = _save_screenshot(result)
            if saved is not None:
                return _json_text(saved)
        return _json_text(result)

    tool_devices = tool_decorator(
        "phone_devices",
        "List the user's online phones and their iCTRL/bridge versions.",
        {},
    )(phone_devices)
    tool_pair = tool_decorator(
        "phone_pair",
        "Pair this connector with the phone. The phone shows an Allow prompt. "
        "Call only when phone_call reports that no token exists.",
        {},
    )(phone_pair)
    tool_skill = tool_decorator(
        "phone_skill",
        "Read the phone's current iCTRL operating manual. Call this once before "
        "the first phone_call and follow its rules.",
        {},
    )(phone_skill)
    tool_schema = tool_decorator(
        "phone_schema",
        "Read the phone's iCTRL method schema. Pass method to narrow the result.",
        {"method": str},
    )(phone_schema)
    tool_call = tool_decorator(
        "phone_call",
        "Call one iCTRL JSON-RPC method on the phone. method is required; "
        "params is the method's parameter object (use {} when it has none).",
        {"method": str, "params": dict},
    )(phone_call)

    server = create_server(
        name=PHONE_SERVER_NAME,
        version="1.0.0",
        tools=[tool_devices, tool_pair, tool_skill, tool_schema, tool_call],
    )
    return PhoneControl(
        server_name=PHONE_SERVER_NAME,
        server=server,
        system_prompt=PHONE_SYSTEM_PROMPT,
        handler=phone_call,
    )


def _save_screenshot(result: dict[str, Any]) -> dict[str, Any] | None:
    """Screenshots are base64 images; a tool result/timeline must not carry
    them. Write the bytes once and return a path the agent can Read."""
    payload = result.get("result")
    if not isinstance(payload, dict):
        return None
    encoded = payload.get("data")
    if not isinstance(encoded, str) or not encoded:
        return None
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        return None
    suffix = "png" if payload.get("format") == "png" else "jpg"
    directory = connector_data_dir() / "phone-screenshots"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{uuid.uuid4().hex}.{suffix}"
    path.write_bytes(raw)
    path.chmod(0o600)
    return {
        "saved": str(path),
        "bytes": len(raw),
        "format": suffix,
        "hint": "Read the saved image with the file tool instead of re-calling screenshot.",
    }
