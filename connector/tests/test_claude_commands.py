from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest

from connector.runtime_protocol import (
    RuntimeAttachmentContent,
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeStatus,
    RuntimeTimelineItem,
)
from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.timeline.messages import (
    CLAUDE_COMPACT_SUMMARY_PREFIX,
)

COMPACT_SESSION = "claude_compact_session"


def test_claude_execute_command_accepts_compact() -> None:
    asyncio.run(_test_claude_execute_command_accepts_compact())


async def _test_claude_execute_command_accepts_compact() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(messages=_compaction_messages())
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_cmd", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_cmd"].active_task
    assert result.ok is True
    assert result.command == "compact"
    assert result.result["executionState"] == "accepted"
    assert result.result["turnId"].startswith("turn_claude_")
    assert task is not None

    await task

    # The CLI dispatches the native command from the prompt itself.
    assert client.queries == ["/compact"]
    assert [update["status"] for update in host.session_state_updates] == [
        "waiting",
        "running",
        "idle",
    ]
    assert host.session_turn_ends[-1]["outcome"] == "completed"


def test_claude_command_turn_publishes_no_user_bubble() -> None:
    asyncio.run(_test_claude_command_turn_publishes_no_user_bubble())


async def _test_claude_command_turn_publishes_no_user_bubble() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_bubble", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_bubble"].active_task
    assert result.ok is True
    assert task is not None
    await task

    assert [item.role for item in host.timeline_item_upserts if item.role == "user"] == []
    assert [item.type for item in host.timeline_item_upserts] == ["marker"] * 3
    recorded = runtime._sessions["sess_bubble"].timeline_items
    assert [item_id.startswith("claude_compact_") for item_id in recorded] == [True]


def test_claude_command_turn_flips_one_marker_through_its_states() -> None:
    asyncio.run(_test_claude_command_turn_flips_one_marker_through_its_states())


async def _test_claude_command_turn_flips_one_marker_through_its_states() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_marker", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_marker"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert len({item.id for item in markers}) == 1
    assert markers[0].id.startswith("claude_compact_")
    assert [item.content["state"] for item in markers] == [
        "started",
        "completed",
        "completed",
    ]
    assert [item.status for item in markers] == ["running", "done", "done"]
    assert [item.content["kind"] for item in markers] == ["compact"] * 3
    assert [item.content["label"] for item in markers] == [
        "正在压缩上下文",
        "对话已压缩",
        "对话已压缩",
    ]
    # The boundary repeats the completed state; its metadata is what settles.
    assert "preTokens" not in markers[1].content
    assert markers[2].content["trigger"] == "manual"
    assert markers[2].content["preTokens"] == 18_000
    assert markers[2].content["postTokens"] == 900
    assert markers[2].content["cumulativeDroppedTokens"] == 17_100
    assert markers[2].content["durationMs"] == 12_000
    assert markers[0].content_hash != markers[1].content_hash
    assert markers[0].turn_id == markers[1].turn_id
    assert markers[0].source["runtime"] == "claude"
    assert markers[0].source["sessionId"] == COMPACT_SESSION


def test_claude_command_turn_suppresses_cli_control_messages() -> None:
    asyncio.run(_test_claude_command_turn_suppresses_cli_control_messages())


async def _test_claude_command_turn_suppresses_cli_control_messages() -> None:
    host = _RecordingHost()
    runtime = _runtime(host=host, client=_FakeClaudeClient(_compaction_messages()))

    result = await runtime.execute_command("sess_suppress", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_suppress"].active_task
    assert result.ok is True
    assert task is not None
    await task

    # The summary, the local-command echo and the init handshake are CLI
    # bookkeeping; none of them may reach the timeline.
    texts = [
        item.content.get("text")
        for item in host.timeline_item_upserts
        if isinstance(item.content.get("text"), str)
    ]
    assert texts == []
    assert [
        item.content["kind"] for item in host.timeline_item_upserts
    ] == ["compact"] * 3


def test_claude_command_turn_without_success_evidence_settles_failed() -> None:
    asyncio.run(_test_claude_command_turn_without_success_evidence_settles_failed())


async def _test_claude_command_turn_without_success_evidence_settles_failed() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system_message(subtype="status", status="compacting", uuid="sys_start"),
            SimpleNamespace(
                type="result",
                session_id=COMPACT_SESSION,
                is_error=True,
                errors=["compaction blew up"],
            ),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_failed", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_failed"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["started", "failed"]
    assert [item.status for item in markers] == ["running", "failed"]
    assert len({item.id for item in markers}) == 1
    assert host.session_turn_ends[-1]["outcome"] == "failed"


def test_claude_interrupted_command_turn_settles_failed() -> None:
    asyncio.run(_test_claude_interrupted_command_turn_settles_failed())


async def _test_claude_interrupted_command_turn_settles_failed() -> None:
    host = _RecordingHost()
    client = _GatedClaudeClient([_system_message(subtype="status", status="compacting")])
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_interrupt", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_interrupt"].active_task
    assert result.ok is True
    assert task is not None
    await _wait_until(lambda: bool(host.timeline_item_upserts))

    task.cancel()
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["started", "failed"]
    assert len({item.id for item in markers}) == 1
    assert host.session_turn_ends[-1]["outcome"] == "interrupted"


def test_claude_unsuccessful_compact_result_fails_the_marker() -> None:
    asyncio.run(_test_claude_unsuccessful_compact_result_fails_the_marker())


async def _test_claude_unsuccessful_compact_result_fails_the_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system_message(subtype="status", status="compacting", uuid="sys_start"),
            _system_message(
                subtype="status",
                status=None,
                compact_result="error",
                uuid="sys_error",
            ),
            SimpleNamespace(type="result", session_id=COMPACT_SESSION, is_error=False),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_result", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_result"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["started", "failed"]
    assert markers[1].content["compactResult"] == "error"


def test_claude_boundary_alone_completes_the_marker() -> None:
    asyncio.run(_test_claude_boundary_alone_completes_the_marker())


async def _test_claude_boundary_alone_completes_the_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            _system_message(subtype="compact_boundary", uuid="sys_boundary"),
            SimpleNamespace(type="result", session_id=COMPACT_SESSION, is_error=False),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command("sess_boundary", "compact", COMPACT_SESSION)
    task = runtime._sessions["sess_boundary"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = host.timeline_item_upserts
    assert [item.content["state"] for item in markers] == ["completed"]
    assert markers[0].status == "done"


def test_claude_second_compaction_gets_its_own_marker() -> None:
    asyncio.run(_test_claude_second_compaction_gets_its_own_marker())


async def _test_claude_second_compaction_gets_its_own_marker() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(_compaction_messages())
    runtime = _runtime(host=host, client=client)

    for _ in range(2):
        result = await runtime.execute_command("sess_twice", "compact", COMPACT_SESSION)
        task = runtime._sessions["sess_twice"].active_task
        assert result.ok is True
        assert task is not None
        await task

    markers = host.timeline_item_upserts
    assert len({item.id for item in markers}) == 2
    assert [item.content["state"] for item in markers] == [
        "started",
        "completed",
        "completed",
        "started",
        "completed",
        "completed",
    ]
    assert markers[0].order_seq < markers[3].order_seq


def test_claude_automatic_compaction_marks_an_ordinary_turn() -> None:
    asyncio.run(_test_claude_automatic_compaction_marks_an_ordinary_turn())


async def _test_claude_automatic_compaction_marks_an_ordinary_turn() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [
            SimpleNamespace(
                type="assistant",
                uuid="assistant_auto",
                session_id=COMPACT_SESSION,
                message={
                    "id": "msg_auto",
                    "role": "assistant",
                    "content": [{"type": "text", "text": "still here"}],
                },
            ),
            _system_message(subtype="compact_boundary", uuid="sys_auto"),
            SimpleNamespace(type="result", session_id=COMPACT_SESSION, is_error=False),
        ]
    )
    runtime = _runtime(host=host, client=client)

    result = await runtime.start_turn(
        "sess_auto",
        COMPACT_SESSION,
        "keep going",
        client_message_id="client_auto",
    )
    task = runtime._sessions["sess_auto"].active_task
    assert result.ok is True
    assert task is not None
    await task

    markers = [
        item for item in host.timeline_item_upserts if item.type == "marker"
    ]
    assert [item.content["state"] for item in markers] == ["completed"]
    # The shared path keeps the ordinary turn intact: the user bubble still
    # leads and the separator lands after it.
    assert host.timeline_item_upserts[0].role == "user"
    assert markers[0].order_seq > host.timeline_item_upserts[0].order_seq
    assert any(item.role == "assistant" for item in host.timeline_item_upserts)


def test_claude_command_catalog_follows_session_state() -> None:
    asyncio.run(_test_claude_command_catalog_follows_session_state())


async def _test_claude_command_catalog_follows_session_state() -> None:
    runtime = _runtime()

    (idle,) = await runtime.list_commands("sess_catalog", COMPACT_SESSION)
    assert idle.enabled is True
    assert idle.id == "compact"

    await runtime._session_states.update("sess_catalog", COMPACT_SESSION, "running")
    (busy,) = await runtime.list_commands("sess_catalog", COMPACT_SESSION)
    assert busy.enabled is False
    assert busy.disabled_reason == "session_running"


def test_claude_command_catalog_resolves_the_loaded_session() -> None:
    asyncio.run(_test_claude_command_catalog_resolves_the_loaded_session())


async def _test_claude_command_catalog_resolves_the_loaded_session() -> None:
    runtime = _runtime()
    runtime._session_store.ensure("sess_loaded", external_session_id=COMPACT_SESSION)

    (loaded,) = await runtime.list_commands("sess_loaded")
    assert loaded.enabled is True

    (unloaded,) = await runtime.list_commands("sess_unknown")
    assert unloaded.enabled is False
    assert unloaded.disabled_reason == "session_unloaded"


def test_claude_execute_command_rejects_an_unloaded_session() -> None:
    asyncio.run(_test_claude_execute_command_rejects_an_unloaded_session())


async def _test_claude_execute_command_rejects_an_unloaded_session() -> None:
    runtime = _runtime()

    result = await runtime.execute_command("sess_unloaded", "compact")

    assert result.ok is False
    assert result.code == "command_unavailable"
    assert result.message == "session_unloaded"


def test_claude_execute_command_rejects_a_busy_session() -> None:
    asyncio.run(_test_claude_execute_command_rejects_a_busy_session())


async def _test_claude_execute_command_rejects_a_busy_session() -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient(
        [SimpleNamespace(type="result", session_id=COMPACT_SESSION, is_error=False)]
    )
    runtime = _runtime(host=host, client=client)

    started = await runtime.start_turn("sess_busy", COMPACT_SESSION, "hello")
    task = runtime._sessions["sess_busy"].active_task
    assert started.ok is True

    result = await runtime.execute_command("sess_busy", "compact", COMPACT_SESSION)
    assert task is not None
    await task

    assert result.ok is False
    assert result.code == "command_unavailable"
    assert result.message == "session_waiting"
    assert client.queries == ["hello"]


@pytest.mark.parametrize(
    ("command", "raw", "args", "code"),
    (
        ("compact", None, ("now",), "invalid_command"),
        ("compact", "/compact now", (), "invalid_command"),
        ("compact", "  /compact please  ", (), "invalid_command"),
        ("compact", "/clear", (), "invalid_command"),
        ("compact", "not a command", (), "invalid_command"),
        ("compact", None, ("a", "b"), "invalid_command"),
        ("compact", None, (1,), "invalid_command"),
        ("!!!", None, (), "invalid_command"),
        ("", None, (), "invalid_command"),
        ("clear", None, (), "unknown_command"),
        ("compact-thread", None, (), "unknown_command"),
    ),
)
def test_claude_execute_command_rejects_bad_input(
    command: str,
    raw: str | None,
    args: tuple[Any, ...],
    code: str,
) -> None:
    asyncio.run(
        _test_claude_execute_command_rejects_bad_input(command, raw, args, code)
    )


async def _test_claude_execute_command_rejects_bad_input(
    command: str,
    raw: str | None,
    args: tuple[Any, ...],
    code: str,
) -> None:
    host = _RecordingHost()
    client = _FakeClaudeClient()
    runtime = _runtime(host=host, client=client)

    result = await runtime.execute_command(
        "sess_reject",
        command,
        COMPACT_SESSION,
        raw=raw,
        args=args,
    )

    assert result.ok is False
    assert result.code == code
    assert client.queries == []
    assert host.timeline_item_upserts == []


def test_claude_execute_command_accepts_a_bare_raw_line() -> None:
    asyncio.run(_test_claude_execute_command_accepts_a_bare_raw_line())


async def _test_claude_execute_command_accepts_a_bare_raw_line() -> None:
    client = _FakeClaudeClient(_compaction_messages())
    runtime = _runtime(client=client)

    result = await runtime.execute_command(
        "sess_raw",
        "/Compact",
        COMPACT_SESSION,
        raw="/compact",
    )
    task = runtime._sessions["sess_raw"].active_task
    assert result.ok is True
    assert task is not None
    await task

    assert client.queries == ["/compact"]


def test_claude_command_turn_reports_a_rejected_dispatch() -> None:
    asyncio.run(_test_claude_command_turn_reports_a_rejected_dispatch())


async def _test_claude_command_turn_reports_a_rejected_dispatch() -> None:
    runtime = _runtime()
    await runtime._session_states.update("sess_reject_dispatch", COMPACT_SESSION, "idle")
    # The catalog reads the state cache, so a session that still owns an
    # execution is the only way to reach the branch where the shared turn
    # machinery refuses the dispatch itself.
    session = runtime._session_store.ensure(
        "sess_reject_dispatch",
        external_session_id=COMPACT_SESSION,
    )
    session.execution = ClaudeExecution(turn_id="turn_blocking")

    result = await runtime.execute_command(
        "sess_reject_dispatch",
        "compact",
        COMPACT_SESSION,
    )

    assert result.ok is False
    assert result.code == "command_rejected"
    assert result.result["executionState"] == "completed"
    assert "already" in (result.message or "")


# --- fixtures -------------------------------------------------------------


def _system_message(**fields: Any) -> SimpleNamespace:
    return SimpleNamespace(
        type="system",
        session_id=COMPACT_SESSION,
        **fields,
    )


def _compaction_messages() -> list[Any]:
    """Replay the 2026-10-02 probe order for a manual `/compact`."""

    return [
        _system_message(subtype="status", status="compacting", uuid="sys_start"),
        _system_message(subtype="init", uuid="sys_init"),
        _system_message(
            subtype="status",
            status=None,
            compact_result="success",
            uuid="sys_result",
        ),
        _system_message(
            subtype="compact_boundary",
            uuid="sys_boundary",
            logical_parent_uuid="sys_result",
            compact_metadata={
                "trigger": "manual",
                "pre_tokens": 18_000,
                "post_tokens": 900,
                "cumulative_dropped_tokens": 17_100,
                "duration_ms": 12_000,
            },
        ),
        SimpleNamespace(
            type="user",
            uuid="user_summary",
            session_id=COMPACT_SESSION,
            message={
                "role": "user",
                "content": (
                    f"{CLAUDE_COMPACT_SUMMARY_PREFIX} The user asked me to ..."
                ),
            },
        ),
        SimpleNamespace(
            type="user",
            uuid="user_stdout",
            session_id=COMPACT_SESSION,
            message={
                "role": "user",
                "content": "<local-command-stdout>Compacted </local-command-stdout>",
            },
        ),
        SimpleNamespace(
            type="result",
            session_id=COMPACT_SESSION,
            is_error=False,
            result="",
        ),
    ]


def _runtime(
    host: _RecordingHost | None = None,
    client: _FakeClaudeClient | None = None,
) -> ClaudeRuntime:
    active_host = host or _RecordingHost()
    active_client = client or _FakeClaudeClient()

    def client_factory(sdk: Any, options: Any) -> _FakeClaudeClient:
        _ = sdk
        active_client.options = options
        return active_client

    return ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=active_host,
        sdk_loader=lambda: SimpleNamespace(
            __version__="1.0",
            ClaudeAgentOptions=_FakeOptions,
            list_sessions=lambda **_: [],
            get_session_info=lambda **_: None,
            get_session_messages=lambda **_: [],
        ),
        client_factory=client_factory,
    )


class _FakeOptions:
    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs


class _FakeClaudeClient:
    def __init__(self, messages: list[Any] | None = None) -> None:
        self.messages = list(messages or [])
        self.options: Any = None
        self.connected = False
        self.disconnected = False
        self.interrupted = False
        self.queries: list[str] = []

    async def connect(self) -> None:
        self.connected = True

    async def disconnect(self) -> None:
        self.disconnected = True

    async def query(self, prompt: Any) -> None:
        if isinstance(prompt, str):
            self.queries.append(prompt)
            return
        # The connector pre-assigns a prompt UUID on reused connections, so the
        # SDK receives a message envelope instead of a bare string.
        envelopes = [message async for message in prompt]
        self.queries.append(envelopes[0]["message"]["content"])

    async def receive_response(self) -> list[Any]:
        return self.messages

    async def interrupt(self) -> None:
        self.interrupted = True


class _GatedClaudeClient(_FakeClaudeClient):
    """Stream the opening events, then hold the reply open for an interrupt."""

    def __init__(self, messages: list[Any] | None = None) -> None:
        super().__init__(messages)
        self.release = asyncio.Event()

    async def receive_response(self) -> Any:
        for message in self.messages:
            yield message
        await self.release.wait()


class _RecordingHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.session_meta_upserts: list[dict[str, Any]] = []
        self.session_state_updates: list[dict[str, Any]] = []
        self.session_turn_ends: list[dict[str, Any]] = []
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []
        self.timeline_syncs: list[dict[str, Any]] = []
        self.session_capability_updates: list[Any] = []
        self.notice_upserts: list[Any] = []
        self.sync_states: dict[str, dict[str, Any]] = {}

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def session_meta_upsert(
        self,
        session_id: str,
        runtime: str,
        external_session_id: str | None = None,
        title: str | None = None,
        cwd: str | None = None,
        ordering_time: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_meta_upserts.append(
            {
                "session_id": session_id,
                "external_session_id": external_session_id,
                "metadata": metadata or {},
            }
        )

    async def session_state_update(
        self,
        session_id: str,
        runtime: str,
        status: RuntimeStatus | None = None,
        selections: dict[str, str | None] | None = None,
        external_session_id: str | None = None,
        status_reason: str | None = None,
        error: dict[str, Any] | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_state_updates.append(
            {
                "session_id": session_id,
                "status": status,
                "external_session_id": external_session_id,
                "error": error,
                "metadata": metadata or {},
            }
        )

    async def session_turn_ended(
        self,
        session_id: str,
        runtime: str,
        external_session_id: str | None = None,
        turn_id: str | None = None,
        outcome: str = "completed",
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.session_turn_ends.append(
            {
                "session_id": session_id,
                "turn_id": turn_id,
                "outcome": outcome,
                "metadata": metadata or {},
            }
        )

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)

    async def session_capabilities_update(self, capabilities: Any) -> None:
        self.session_capability_updates.append(capabilities)

    async def timeline_sync(
        self,
        session_id: str,
        runtime: str,
        items: tuple[RuntimeTimelineItem, ...],
        external_session_id: str | None = None,
        complete: bool = False,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.timeline_syncs.append({"session_id": session_id, "metadata": metadata or {}})

    async def notice_upsert(self, notice: Any) -> None:
        self.notice_upserts.append(notice)

    async def attachment_download(
        self,
        session_id: str,
        file_id: str,
    ) -> RuntimeAttachmentContent:
        raise NotImplementedError

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.sync_states.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.sync_states[key] = value

    async def sync_state_delete(self, key: str) -> None:
        self.sync_states.pop(key, None)


async def _wait_until(predicate: Any) -> None:
    for _ in range(200):
        if predicate():
            return
        await asyncio.sleep(0.005)
    assert predicate()
