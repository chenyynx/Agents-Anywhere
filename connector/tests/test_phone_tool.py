from __future__ import annotations

import json
from types import SimpleNamespace

import claude_agent_sdk

from connector.phone import ictrl_client
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.client import build_sdk_options
from connector.runtimes.claude.sdk import phone_tool


class FakeSdk:
    def tool(self, name, description, schema):
        def decorate(function):
            return (name, function)

        return decorate

    def create_sdk_mcp_server(self, *, name, version, tools):
        return {"name": name, "version": version, "tools": tools}


class FakeRunner:
    enabled = True
    local_base_url = "http://127.0.0.1:18200"

    async def list_devices(self):
        return [
            {
                "deviceId": "phone-1",
                "name": "pp 的 iPhone",
                "online": True,
                "appVersion": "1.98.16",
            }
        ]


def build(monkeypatch, tmp_path):
    monkeypatch.setattr(
        ictrl_client, "default_token_path", lambda: tmp_path / "token.json"
    )
    control = phone_tool.build_phone_tool(FakeSdk(), FakeRunner())
    assert control is not None
    tools = dict(control.server["tools"])
    return control, tools


def test_builds_five_generic_tools(monkeypatch, tmp_path):
    control, tools = build(monkeypatch, tmp_path)
    assert set(tools) == {
        "phone_devices",
        "phone_pair",
        "phone_skill",
        "phone_schema",
        "phone_call",
    }
    assert control.server_name == "phone"
    assert "mcp__phone__phone_call" in control.system_prompt


def test_devices_and_skill_are_text(monkeypatch, tmp_path):
    _control, tools = build(monkeypatch, tmp_path)

    import asyncio

    devices = asyncio.run(tools["phone_devices"]({}))
    assert "phone-1" in devices["content"][0]["text"]

    async def fake_get_text(base_url, path):
        assert path == "/skill"
        return "read me"

    monkeypatch.setattr(ictrl_client, "get_text", fake_get_text)
    skill = asyncio.run(tools["phone_skill"]({}))
    assert skill["content"][0]["text"] == "read me"


def test_call_uses_the_embedded_client(monkeypatch, tmp_path):
    _control, tools = build(monkeypatch, tmp_path)

    async def fake_call(base_url, method, params, *, token_path):
        assert method == "tap"
        assert params == {"ref": "r1"}
        return {"jsonrpc": "2.0", "id": 1, "result": {"moved": True}}

    monkeypatch.setattr(ictrl_client, "call", fake_call)

    import asyncio

    result = asyncio.run(
        tools["phone_call"]({"method": "tap", "params": {"ref": "r1"}})
    )
    payload = json.loads(result["content"][0]["text"])
    assert payload["result"] == {"moved": True}


def test_call_without_token_asks_for_pairing(monkeypatch, tmp_path):
    _control, tools = build(monkeypatch, tmp_path)

    async def fake_call(*args, **kwargs):
        raise ictrl_client.IctrlPairingRequired("missing")

    monkeypatch.setattr(ictrl_client, "call", fake_call)

    import asyncio

    result = asyncio.run(tools["phone_call"]({"method": "device_info"}))
    assert "phone_pair" in result["content"][0]["text"]


def test_disabled_runner_yields_no_tool():
    class Disabled(FakeRunner):
        enabled = False

    assert phone_tool.build_phone_tool(FakeSdk(), Disabled()) is None


def test_wire_name_matcher_never_matches_bare_names():
    assert phone_tool.is_phone_tool_name("mcp__phone__phone_call")
    assert not phone_tool.is_phone_tool_name("phone_call")
    assert not phone_tool.is_phone_tool_name(None)


def test_screenshot_is_written_to_a_file_not_the_tool_result(monkeypatch, tmp_path):
    _control, tools = build(monkeypatch, tmp_path)
    monkeypatch.setattr(phone_tool, "connector_data_dir", lambda: tmp_path)
    raw = b"\xff\xd8fake-jpeg"

    async def fake_call(*args, **kwargs):
        import base64

        return {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "data": base64.b64encode(raw).decode(),
                "format": "jpeg",
            },
        }

    monkeypatch.setattr(ictrl_client, "call", fake_call)

    import asyncio
    from pathlib import Path

    result = asyncio.run(
        tools["phone_call"]({"method": "screenshot", "params": {}})
    )
    payload = json.loads(result["content"][0]["text"])
    assert "saved" in payload
    assert "data" not in payload
    assert Path(payload["saved"]).read_bytes() == raw


def test_title_and_phone_mcp_servers_merge():
    title = SimpleNamespace(
        server_name="change-title",
        server=object(),
        system_prompt="TITLE",
    )
    phone = SimpleNamespace(
        server_name="phone",
        server=object(),
        system_prompt="PHONE",
    )
    session = ClaudeSession(
        session_id="sess-1",
        external_session_id="external-1",
        cwd="/tmp",
        title=None,
    )
    options = build_sdk_options(
        claude_agent_sdk,
        {},
        session,
        title_control=title,
        phone_control=phone,
    )
    assert options.mcp_servers == {
        "change-title": title.server,
        "phone": phone.server,
    }
    assert options.system_prompt == {
        "type": "preset",
        "preset": "claude_code",
        "append": "TITLE\n\nPHONE",
    }
