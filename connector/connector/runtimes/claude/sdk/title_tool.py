"""Agent-driven session titles via an in-process ``change_title`` tool.

Reference cohort
----------------
HappyCoder ships ``mcp__happy__change_title`` (an MCP tool the model calls to
name its session); the Claudio bridge implemented the same shape in
``bridge/src/change-title.ts`` (commits a6f51829 + fd75e182). This module is
the AA connector's take, with one upgrade: the accepted title is written back
into Claude Code itself through the SDK's official ``rename_session`` (it
appends a ``custom-title`` entry to the session transcript — last write wins,
repeated calls are safe), making the Claude Code session the single source of
truth. The title additionally publishes immediately through the existing
``session.meta.upsert`` path, and the periodic inventory sync re-reads
``custom_title`` (top priority in ``sessions/reader.py``) afterwards — so no
connector-side state has to survive restarts, cache loss, or a connector swap.

Guards mirror Claudio's ``shouldApplyModelTitle``: empty → duplicate →
throttle. "Never override a user rename" is enforced server-side by
``sessions.title_source == "user"``, so this layer never needs to know how a
title was produced.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any

from connector.logging import logger

TITLE_SERVER_NAME = "change-title"
TITLE_TOOL_NAME = "change_title"
TITLE_TOOL_PREFIX = f"mcp__{TITLE_SERVER_NAME}__"
# The name the model actually sees in its tool list. Weak models that are told
# the bare ``change_title`` invent a wire name instead and call a tool that does
# not exist, so the prompt and the tool description both carry this form.
TITLE_TOOL_WIRE_NAME = f"{TITLE_TOOL_PREFIX}{TITLE_TOOL_NAME}"
TITLE_THROTTLE_SECONDS = 8.0

TITLE_SYSTEM_PROMPT = (
    "When you start a new conversation, you MUST call the "
    f"`{TITLE_TOOL_WIRE_NAME}` tool to set a concise title for this session. "
    "Call the tool again if the topic shifts significantly or the current "
    "title can be made more specific. Write a natural, specific noun phrase — "
    "2-8 words. Output only the title as the tool argument: no quotes, no "
    "markdown, no explanation. Match the primary language of the user's first "
    "message; never translate it. If that tool is not in your tool list, skip "
    "the title and answer the user normally. Never tell the user about titles "
    "or about a title tool failing, whatever happens."
)


def is_title_tool_name(tool_name: str | None) -> bool:
    """Match the tool's wire form (``mcp__change-title__change_title``).

    Prefix match on the server namespace, never a short-name comparison: the
    Claudio bridge's fix commit fd75e182 is the lesson — matching
    ``change_title`` alone let the prefixed wire name through and the tool
    card leaked into the client stream.
    """

    return bool(tool_name) and tool_name.startswith(TITLE_TOOL_PREFIX)


def should_apply_model_title(
    current_title: str | None,
    new_title: str,
    *,
    last_change_at: float | None,
    now: float,
    throttle_seconds: float = TITLE_THROTTLE_SECONDS,
) -> bool:
    """Guard order: empty → duplicate → throttle (Claudio parity)."""

    trimmed = new_title.strip()
    if not trimmed:
        return False
    if current_title is not None and current_title.strip() == trimmed:
        return False
    if last_change_at is not None and now - last_change_at < throttle_seconds:
        return False
    return True


@dataclass(frozen=True, slots=True)
class ChangeTitleControl:
    """What ``build_change_title_tool`` hands to the SDK options builder."""

    server_name: str
    server: Any
    system_prompt: str
    handler: Callable[[Mapping[str, Any]], Awaitable[dict[str, Any]]]


_unavailable_logged = False


def _log_unavailable_once() -> None:
    global _unavailable_logged
    if not _unavailable_logged:
        _unavailable_logged = True
        logger.warning(
            "Claude agent titles disabled — installed claude-agent-sdk lacks "
            "rename_session support; the change_title tool is not injected"
        )


def _tool_text(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}]}


def build_change_title_tool(
    sdk: Any,
    *,
    session_id: str,
    current_title: Callable[[], str | None],
    external_session_id: Callable[[], str | None],
    cwd: Callable[[], str | None],
    on_applied: Callable[[str], Awaitable[None]],
    rename: Callable[..., None] | None = None,
    clock: Callable[[], float] = time.monotonic,
    throttle_seconds: float = TITLE_THROTTLE_SECONDS,
) -> ChangeTitleControl | None:
    """Build the in-process MCP server, or None when the SDK cannot rename.

    All-or-nothing: without the official rename surface neither the tool nor
    the system-prompt append is injected, so the model is never pointed at a
    tool that cannot work (old-SDK installs simply lack the feature).
    """

    create_server = getattr(sdk, "create_sdk_mcp_server", None)
    tool_decorator = getattr(sdk, "tool", None)
    rename_fn = rename if rename is not None else getattr(sdk, "rename_session", None)
    if create_server is None or tool_decorator is None or rename_fn is None:
        _log_unavailable_once()
        return None

    state: dict[str, float | None] = {"last_change_at": None}

    async def change_title(args: Mapping[str, Any]) -> dict[str, Any]:
        raw = args.get("title")
        title = raw.strip() if isinstance(raw, str) else ""
        now = clock()
        if not should_apply_model_title(
            current_title(),
            title,
            last_change_at=state["last_change_at"],
            now=now,
            throttle_seconds=throttle_seconds,
        ):
            if not title:
                return _tool_text("No title provided; nothing changed.")
            if (current_title() or "").strip() == title:
                return _tool_text(f'Title is already "{title}"; nothing changed.')
            return _tool_text("The title changed just now; skipping this update.")
        session_uuid = external_session_id()
        if not session_uuid:
            # Called before the Claude Code session id is bound (extremely
            # early first turn). A later turn can title the session instead.
            logger.warning(
                "Claude change_title deferred — no external session id yet session_id={}",
                session_id,
            )
            return _tool_text(
                "This session cannot be titled yet; try again in a later turn."
            )
        try:
            rename_fn(session_uuid, title, directory=cwd())
        except Exception as exc:  # noqa: BLE001 — the turn must never break
            logger.warning(
                "Claude change_title failed session_id={} error={}",
                session_id,
                exc,
            )
            return _tool_text(f"Setting the title failed: {exc}")
        state["last_change_at"] = now
        try:
            await on_applied(title)
        except Exception:  # noqa: BLE001 — publish is best-effort
            # The rename is already durable in the Claude Code session file;
            # the periodic inventory sync re-reads it even if this publish
            # dropped (and the guard still throttles follow-up calls).
            logger.exception(
                "Claude change_title publish failed session_id={}", session_id
            )
        logger.info(
            "Claude agent title set session_id={} title={!r}",
            session_id,
            title,
        )
        return _tool_text(f'Title set to "{title}".')

    tool_def = tool_decorator(
        TITLE_TOOL_NAME,
        "Set or update the display title for this session. Call it when a "
        "conversation starts, and again if the topic shifts significantly. "
        f"Call it by its exact name, {TITLE_TOOL_WIRE_NAME}.",
        {"title": str},
    )(change_title)
    server = create_server(name=TITLE_SERVER_NAME, version="1.0.0", tools=[tool_def])
    return ChangeTitleControl(
        server_name=TITLE_SERVER_NAME,
        server=server,
        system_prompt=TITLE_SYSTEM_PROMPT,
        handler=change_title,
    )
