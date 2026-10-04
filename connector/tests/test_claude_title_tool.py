"""Agent-driven session titles (``change_title``) — HappyCoder/Claudio parity.

Why this file exists
--------------------
pp asked (2026-10-03) for agent self-naming, mirroring HappyCoder's
``mcp__happy__change_title`` and the Claudio bridge implementation
(``bridge/src/change-title.ts``, commits a6f51829 + fd75e182). The connector
injects an in-process MCP tool, writes the accepted title back into Claude
Code through the SDK's official ``rename_session`` (a ``custom-title``
transcript entry), and publishes the title over the existing
``session.meta.upsert`` path — so the whole read side (reader →
inventory sync → server → clients) needs no changes at all.

What is pinned here
-------------------
* guard order: empty → duplicate → throttle (Claudio's ``shouldApplyModelTitle``);
* the wire-form name matcher (prefix ``mcp__change-title__`` — the fd75e182
  lesson: short-name matching lets the tool card leak into the stream);
* handler behaviour on every exit: applied (rename + publish), guarded,
  rename failure (contained, no publish), missing external session id (skip);
* options injection: with a control the SDK options carry the in-process MCP
  server and the preset+append system prompt; without one both stay ``None``
  (the model-discovery path must remain byte-identical);
* timeline projection hides the tool_use/result pair — in the live
  projector and in the history-rebuild context — while real tools still show;
* the PreToolUse hook auto-allows the tool so it never surfaces as a client
  approval request.
"""

from __future__ import annotations

import asyncio
from typing import Any

import claude_agent_sdk
from claude_agent_sdk import (
    AssistantMessage,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.client import build_sdk_options
from connector.runtimes.claude.sdk.connection import ClaudeConnection
from connector.runtimes.claude.sdk.title_tool import (
    TITLE_SERVER_NAME,
    TITLE_SYSTEM_PROMPT,
    TITLE_TOOL_NAME,
    TITLE_TOOL_WIRE_NAME,
    build_change_title_tool,
    is_title_tool_name,
    should_apply_model_title,
)
from connector.runtimes.claude.sessions.reader import _history_tool_call_context
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector

SESSION_UUID = "11111111-2222-3333-4444-555555555555"


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id="sess-title-1",
        external_session_id=SESSION_UUID,
        cwd="/tmp/aa-title-test",
        title=None,
    )


class _Recorder:
    def __init__(self) -> None:
        self.renames: list[tuple[str, str, str | None]] = []
        self.applied: list[str] = []

    def rename(self, session_id: str, title: str, directory: str | None = None) -> None:
        self.renames.append((session_id, title, directory))

    async def on_applied(self, title: str) -> None:
        self.applied.append(title)


def _build(
    *,
    session: ClaudeSession | None = None,
    clock: Any = None,
    rename: Any = None,
) -> tuple[Any, ClaudeSession, _Recorder]:
    session = session or _session()
    recorder = _Recorder()
    control = build_change_title_tool(
        claude_agent_sdk,
        session_id=session.session_id,
        current_title=lambda: session.title,
        external_session_id=lambda: session.external_session_id,
        cwd=lambda: session.cwd,
        on_applied=recorder.on_applied,
        rename=rename or recorder.rename,
        clock=clock or (lambda: 1000.0),
    )
    assert control is not None
    return control, session, recorder


# ---------------------------------------------------------------------------
# Guards and matching
# ---------------------------------------------------------------------------


def test_guard_order_empty_duplicate_throttle():
    assert not should_apply_model_title(None, "   ", last_change_at=None, now=0.0)
    assert not should_apply_model_title(
        "已有标题", "  已有标题 ", last_change_at=None, now=0.0
    )
    assert not should_apply_model_title(
        None, "新标题", last_change_at=100.0, now=105.0
    )
    assert should_apply_model_title(None, "新标题", last_change_at=100.0, now=108.0)
    assert should_apply_model_title(None, "新标题", last_change_at=None, now=0.0)


def test_title_tool_name_matches_wire_prefix():
    assert is_title_tool_name("mcp__change-title__change_title")
    # Namespace-wide, not just the one tool name (fd75e182 lesson).
    assert is_title_tool_name("mcp__change-title__anything")
    assert not is_title_tool_name("change_title")
    assert not is_title_tool_name("mcp__other__change_title")
    assert not is_title_tool_name(None)


# ---------------------------------------------------------------------------
# Handler exits
# ---------------------------------------------------------------------------


def test_handler_applies_and_publishes():
    async def exercise():
        control, _, recorder = _build()
        result = await control.handler({"title": "  登录页修复  "})
        assert recorder.renames == [(SESSION_UUID, "登录页修复", "/tmp/aa-title-test")]
        assert recorder.applied == ["登录页修复"]
        assert "登录页修复" in result["content"][0]["text"]

    asyncio.run(exercise())


def test_handler_guard_paths_skip_without_side_effects():
    async def exercise():
        control, session, recorder = _build()
        session.title = "已有标题"
        await control.handler({})  # empty
        await control.handler({"title": "已有标题"})  # duplicate
        await control.handler({"title": "第二个标题"})  # applied
        await control.handler({"title": "第三个标题"})  # throttled (same clock)
        assert [call[1] for call in recorder.renames] == ["第二个标题"]
        assert recorder.applied == ["第二个标题"]

    asyncio.run(exercise())


def test_handler_without_external_session_id_skips():
    async def exercise():
        session = _session()
        session.external_session_id = None
        control, _, recorder = _build(session=session)
        result = await control.handler({"title": "标题"})
        assert recorder.renames == []
        assert recorder.applied == []
        assert "later turn" in result["content"][0]["text"]

    asyncio.run(exercise())


def test_handler_rename_failure_is_contained():
    def boom(*_args: Any, **_kwargs: Any) -> None:
        raise FileNotFoundError("no session file yet")

    async def exercise():
        control, _, recorder = _build(rename=boom)
        result = await control.handler({"title": "标题"})
        assert recorder.applied == []
        assert "failed" in result["content"][0]["text"]

    asyncio.run(exercise())


def test_publish_failure_keeps_success():
    renames: list[tuple[Any, ...]] = []

    def rename(*args: Any, **_kwargs: Any) -> None:
        renames.append(args)

    async def failing_publish(_title: str) -> None:
        raise RuntimeError("publish down")

    control = build_change_title_tool(
        claude_agent_sdk,
        session_id="sess-title-1",
        current_title=lambda: None,
        external_session_id=lambda: SESSION_UUID,
        cwd=lambda: "/tmp",
        on_applied=failing_publish,
        rename=rename,
    )
    assert control is not None

    async def exercise():
        result = await control.handler({"title": "标题"})
        # The rename is the durable act; a dropped publish must not read as
        # a failure (the inventory sync re-reads custom_title anyway).
        assert "Title set to" in result["content"][0]["text"]
        assert renames

    asyncio.run(exercise())


def test_build_returns_none_when_sdk_surface_missing():
    async def dummy(_title: str) -> None:
        return None

    class NoRename:
        pass

    class RenameOnly:
        rename_session = staticmethod(lambda *a, **k: None)

    assert (
        build_change_title_tool(
            NoRename(),
            session_id="s",
            current_title=lambda: None,
            external_session_id=lambda: None,
            cwd=lambda: None,
            on_applied=dummy,
        )
        is None
    )
    assert (
        build_change_title_tool(
            RenameOnly(),
            session_id="s",
            current_title=lambda: None,
            external_session_id=lambda: None,
            cwd=lambda: None,
            on_applied=dummy,
        )
        is None
    )


# ---------------------------------------------------------------------------
# SDK options injection
# ---------------------------------------------------------------------------


def test_sdk_options_inject_and_omit_title_control():
    session = _session()
    control, _, _ = _build(session=session)

    options = build_sdk_options(claude_agent_sdk, {}, session, title_control=control)
    assert options.mcp_servers == {TITLE_SERVER_NAME: control.server}
    assert options.system_prompt == {
        "type": "preset",
        "preset": "claude_code",
        "append": TITLE_SYSTEM_PROMPT,
    }

    plain = build_sdk_options(claude_agent_sdk, {}, session)
    # The SDK's own default for mcp_servers is an empty dict — omitting the
    # control must leave the options exactly as they were before the feature.
    assert plain.mcp_servers == {}
    assert plain.system_prompt is None


# ---------------------------------------------------------------------------
# Timeline projection hides the tool frames
# ---------------------------------------------------------------------------


def _title_tool_use() -> ToolUseBlock:
    return ToolUseBlock(
        id="tu-title",
        name="mcp__change-title__change_title",
        input={"title": "标题"},
    )


def test_timeline_hides_title_tool_frames_but_keeps_real_tools():
    session = _session()
    projector = ClaudeMessageProjector()

    assistant = AssistantMessage(content=[_title_tool_use()], model="claude")
    assert projector.tool_items_for_message(session, "turn-1", assistant) == ()

    result = UserMessage(
        content=[ToolResultBlock(tool_use_id="tu-title", content="Title set.")]
    )
    assert projector.tool_items_for_message(session, "turn-1", result) == ()

    visible = AssistantMessage(
        content=[ToolUseBlock(id="tu-bash", name="Bash", input={"command": "ls"})],
        model="claude",
    )
    assert len(projector.tool_items_for_message(session, "turn-1", visible)) == 1


def test_history_context_hides_title_tool_calls():
    session = _session()
    messages = (
        AssistantMessage(content=[_title_tool_use()], model="claude"),
        UserMessage(
            content=[ToolResultBlock(tool_use_id="tu-title", content="Title set.")]
        ),
    )
    calls, hidden = _history_tool_call_context(session, messages)
    assert "tu-title" not in calls
    assert "tu-title" in hidden


# ---------------------------------------------------------------------------
# Permission hook auto-allow
# ---------------------------------------------------------------------------


def test_before_tool_auto_allows_title_tool():
    async def noop(*_args: Any, **_kwargs: Any) -> None:
        return None

    connection = ClaudeConnection(
        client=None,
        on_activity=noop,
        on_idle=noop,
        on_background_done=noop,
        cleanup=lambda: None,
    )

    async def exercise():
        allowed = await connection.before_tool(
            {"tool_name": "mcp__change-title__change_title"}
        )
        assert allowed["hookSpecificOutput"]["permissionDecision"] == "allow"
        assert await connection.before_tool({"tool_name": "Bash"}) == {}

    asyncio.run(exercise())


# ---------------------------------------------------------------------------
# Prompt/description must speak the tool's wire name (2026-10-04 regression)
#
# Production incident: the prompt named the bare ``change_title`` and told the
# model to look for it with ``ToolSearch``, which CLI 2.1.285 does not expose.
# Weak models then invented a wire name (``mcp__change-title``), the gateway
# rejected the call, and the model reported "the tool isn't registered" to the
# user. Both prompts now carry the exact wire name instead.
# ---------------------------------------------------------------------------


def test_prompt_names_the_exact_wire_tool():
    assert TITLE_TOOL_WIRE_NAME == "mcp__change-title__change_title"
    assert TITLE_TOOL_WIRE_NAME in TITLE_SYSTEM_PROMPT


def test_prompt_never_references_absent_tools():
    # Sentinel: CLI 2.1.285's tool list has no ToolSearch, so the prompt must
    # not send the model hunting for one. If a future CLI really does expose
    # ToolSearch, this failure is the signal to re-evaluate the whole prompt.
    assert "ToolSearch" not in TITLE_SYSTEM_PROMPT

    # Nor may the prompt hand the model a short name it will paste into a call:
    # every mention of the tool has to be the full wire name.
    without_wire_name = TITLE_SYSTEM_PROMPT.replace(TITLE_TOOL_WIRE_NAME, "")
    assert TITLE_TOOL_NAME not in without_wire_name

    # A missing tool must degrade to "skip the title", not to a user-facing
    # error report — that was the incident's actual user-visible symptom.
    assert "skip" in TITLE_SYSTEM_PROMPT.lower()
    assert "never tell the user" in TITLE_SYSTEM_PROMPT.lower()


class _RecordingSdk:
    """Minimal SDK surface capturing what ``build_change_title_tool`` asks for."""

    def __init__(self) -> None:
        self.tools: list[tuple[str, str, object]] = []

    def tool(self, name: str, description: str, schema: object) -> Any:
        self.tools.append((name, description, schema))

        def decorator(fn: Any) -> Any:
            return fn

        return decorator

    def create_sdk_mcp_server(self, *, name: str, version: str, tools: list) -> Any:
        return (name, version, tools)

    def rename_session(self, *args: Any, **kwargs: Any) -> None:
        return None


def test_tool_description_carries_the_wire_name():
    sdk = _RecordingSdk()

    async def dummy(_title: str) -> None:
        return None

    control = build_change_title_tool(
        sdk,
        session_id="sess-title-1",
        current_title=lambda: None,
        external_session_id=lambda: SESSION_UUID,
        cwd=lambda: "/tmp",
        on_applied=dummy,
    )
    assert control is not None

    ((name, description, _schema),) = sdk.tools
    assert name == TITLE_TOOL_NAME
    # The description sits right next to the tool in the tool list — the last
    # chance to name it the way the model must actually type it.
    assert TITLE_TOOL_WIRE_NAME in description
