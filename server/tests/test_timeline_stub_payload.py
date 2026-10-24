"""Deferred-activity stubs for large tool payloads (v2_48).

A session's newest window can be all tool and reasoning rows, each carrying
megabytes of output. The writer stores a small render-ready ``stub_json`` of
every main-timeline tool row's payload beside the full one, so a window reader
never parses megabytes to render one collapsed line. These tests pin:

- the stub's shape: title fields survive, bulk output is dropped, a bounded
  tail preview is kept for readable text and never for binary/base64 output;
- the 2048-byte budget is enforced by dropping optional keys largest-first;
- the write path fills ``kind``/``payload_bytes``/``stub_json``/``stub_version``
  for every upsert, with a stub only on main tool rows;
- the migration's local copy of the builder produces identical output (a
  migration cannot import application code, so the copies must be held
  together here).
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from conftest import TEST_DATABASE_URL
from session_fixtures import create_session_with_project

from agent_server.core.models import TimelineItemIn
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_store import (
    STUB_MAX_BYTES,
    STUB_VERSION,
    build_stub_content,
    content_kind,
)

_BASH_OUTPUT = "".join(f"result line {index}\n" for index in range(600))


def _bash_content(output: str = _BASH_OUTPUT) -> dict[str, Any]:
    """A Claude Bash tool row: the command lives at the content top level."""

    return {
        "kind": "command",
        "toolName": "Bash",
        "tool": "Bash",
        "title": "Run ls",
        "command": "ls -la",
        "description": "list files",
        "cwd": "/repo",
        "outputLength": len(output),
        "output": output,
        "toolUseId": "toolu_1",
        "isError": False,
        "input": {
            "command": "ls -la",
            "cwd": "/repo",
            "description": "d" * 300,
            "extra": "dropped",
        },
    }


def _serialized_size(value: Any) -> int:
    return len(
        json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    )


def test_build_stub_content_keeps_title_fields_and_tail_preview() -> None:
    content = _bash_content()

    stub = build_stub_content(content, 12345)

    assert stub is not None
    for key in ("kind", "toolName", "tool", "title", "command", "outputLength"):
        assert stub[key] == content[key]
    assert stub["outputPreview"] == _BASH_OUTPUT[-240:]
    for dropped in (
        "output",
        "outputText",
        "text",
        "result",
        "arguments",
        "details",
        "changes",
        "rawText",
    ):
        assert dropped not in stub
    # Only whitelisted input fields survive, with long strings truncated.
    assert stub["input"] == {
        "command": "ls -la",
        "description": "d" * 200,
    }
    assert stub["deferred"] is True
    assert stub["deferredBytes"] == 12345
    assert _serialized_size(stub) <= STUB_MAX_BYTES


def test_build_stub_content_never_previews_binary_output() -> None:
    image = {
        "kind": "file",
        "title": "Read image",
        "output": '{"base64":"iVBORw0KGgoAAAANSUhEUg","media_type":"image/png"}',
    }
    assert "outputPreview" not in build_stub_content(image, 99)

    # A tail with no whitespace is treated as binary/base64 even without the
    # markers: a readable text tail practically always contains whitespace.
    packed = {"kind": "command", "command": "cat blob", "output": "A" * 500}
    assert "outputPreview" not in build_stub_content(packed, 99)


def test_build_stub_content_returns_none_without_content() -> None:
    assert build_stub_content({}, 10) is None
    assert build_stub_content(None, 10) is None
    assert build_stub_content("plain text", 10) is None
    assert build_stub_content(["not", "a", "mapping"], 10) is None


def test_build_stub_content_bounds_non_mapping_input() -> None:
    stub = build_stub_content(
        {"kind": "command", "command": "ls", "input": "x" * 5000}, 10
    )
    assert stub is not None
    assert stub["input"] == "x" * 200

    # Any other non-mapping input cannot be whitelisted; it is dropped so it
    # can never carry the stub past the byte budget.
    stub = build_stub_content(
        {"kind": "command", "command": "ls", "input": ["a", "b"]}, 10
    )
    assert stub is not None
    assert "input" not in stub


def test_build_stub_content_shrinks_required_strings_to_fit_budget() -> None:
    filler = "工" * 3000
    content = {
        "kind": "command",
        "toolName": "Bash",
        "name": filler,
        "tool": filler,
        "title": filler,
        "description": filler,
        "command": filler,
        "toolUseId": filler,
        "output": "x",
    }

    stub = build_stub_content(content, 9000)

    assert stub is not None
    assert _serialized_size(stub) <= STUB_MAX_BYTES
    # The fields a collapsed row renders survive; only their length shrinks.
    assert stub["kind"] == "command"
    assert stub["toolName"] == "Bash"
    assert 0 < len(stub["title"]) <= 100
    assert 0 < len(stub["command"]) <= 100
    assert stub["deferred"] is True


def test_build_stub_content_drops_oversized_unknown_fields() -> None:
    content = {
        "kind": "command",
        "toolName": "Bash",
        "command": "ls",
        "unknownBlob": "x" * 5000,
        "anotherBlob": "y" * 900,
    }

    stub = build_stub_content(content, 6000)

    assert stub is not None
    assert "unknownBlob" not in stub
    assert stub["kind"] == "command"
    assert stub["command"] == "ls"
    assert stub["toolName"] == "Bash"
    assert _serialized_size(stub) <= STUB_MAX_BYTES


def test_content_kind_accepts_only_non_empty_strings() -> None:
    assert content_kind({"kind": "command"}) == "command"
    assert content_kind({"kind": ""}) is None
    assert content_kind({"kind": 42}) is None
    assert content_kind({"text": "no kind"}) is None
    assert content_kind(None) is None
    assert content_kind("command") is None


# ---------------------------------------------------------------------------
# Write path
# ---------------------------------------------------------------------------


def _tool_item(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    content: dict[str, Any],
    content_hash: str | None = None,
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": "done",
            "role": "assistant",
            "content": content,
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": content_hash or f"sha256:{item_id}",
        }
    )


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name="P-stub-payload",
    )
    return store, session


async def _deferred_columns(session_id: str) -> dict[str, dict[str, Any]]:
    """Read the mirrored columns straight from the table.

    The point of the write-path test is the *columns*, not what a reader
    returns, so it deliberately bypasses the store (same approach as the
    ``parent_item_id`` write-path test).
    """

    import asyncpg

    connection = await asyncpg.connect(
        TEST_DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://", 1)
    )
    try:
        rows = await connection.fetch(
            "SELECT id, kind, payload_bytes, stub_json, stub_version, payload_json "
            "FROM timeline_items WHERE session_id = $1",
            session_id,
        )
    finally:
        await connection.close()
    return {row["id"]: dict(row) for row in rows}


@pytest.mark.anyio
async def test_upsert_writes_deferred_activity_columns() -> None:
    store, session = await _store_with_session()
    try:
        content = _bash_content()
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _tool_item(session.id, "main-tool", order_seq=1, content=content),
                _tool_item(
                    session.id,
                    "child-tool",
                    order_seq=2,
                    content={**content, "parentItemId": "main-tool"},
                ),
            ],
        )

        rows = await _deferred_columns(session.id)
        main = rows["main-tool"]
        payload_bytes = len(main["payload_json"].encode("utf-8"))
        assert main["kind"] == "command"
        assert main["payload_bytes"] == payload_bytes
        assert main["stub_version"] == STUB_VERSION
        stub_payload = json.loads(main["stub_json"])
        assert stub_payload["id"] == "main-tool"
        assert stub_payload["content"] == build_stub_content(content, payload_bytes)
        assert stub_payload["content"]["deferred"] is True
        assert stub_payload["content"]["deferredBytes"] == payload_bytes
        assert stub_payload["content"]["outputPreview"] == _BASH_OUTPUT[-240:]
        assert "output" not in stub_payload["content"]
        assert _serialized_size(stub_payload["content"]) <= STUB_MAX_BYTES

        child = rows["child-tool"]
        assert child["kind"] == "command"
        assert child["payload_bytes"] == len(child["payload_json"].encode("utf-8"))
        assert child["stub_json"] is None
        assert child["stub_version"] is None

        # Re-sending the identical content leaves the stub byte-for-byte
        # stable (a Runtime repeating its batch must not churn the row).
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _tool_item(session.id, "main-tool", order_seq=1, content=content),
            ],
        )
        assert (await _deferred_columns(session.id))["main-tool"]["stub_json"] == (
            main["stub_json"]
        )

        # A changed output regenerates the stub: the preview and the deferred
        # size both follow the new payload.
        updated_output = "".join(f"fresh line {index}\n" for index in range(400))
        updated_content = _bash_content(updated_output)
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _tool_item(
                    session.id,
                    "main-tool",
                    order_seq=1,
                    content=updated_content,
                    content_hash="sha256:main-tool-updated",
                ),
            ],
        )
        updated = (await _deferred_columns(session.id))["main-tool"]
        updated_bytes = len(updated["payload_json"].encode("utf-8"))
        updated_stub = json.loads(updated["stub_json"])["content"]
        assert updated["payload_bytes"] == updated_bytes
        assert updated_stub["deferredBytes"] == updated_bytes
        assert updated_stub["outputPreview"] == updated_output[-240:]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Migration parity
# ---------------------------------------------------------------------------

_STUB_FIXTURES = [
    pytest.param(_bash_content(), id="claude-bash"),
    pytest.param(
        {
            "kind": "file",
            "title": "Read image",
            "output": '{"base64":"AAAA","media_type":"image/png"}',
        },
        id="image-base64",
    ),
    pytest.param(
        {
            "kind": "command",
            "toolName": "Bash",
            "command": "ls",
            "unknownBlob": "x" * 5000,
            "anotherBlob": "y" * 900,
        },
        id="oversized-optional-fields",
    ),
    pytest.param(
        {
            "kind": "command",
            "toolName": "Bash",
            "name": "工" * 3000,
            "tool": "工" * 3000,
            "title": "工" * 3000,
            "description": "工" * 3000,
            "command": "工" * 3000,
            "toolUseId": "工" * 3000,
            "output": "x",
        },
        id="oversized-required-fields",
    ),
    pytest.param(
        {"kind": "command", "command": "ls", "input": "z" * 5000},
        id="string-input",
    ),
    pytest.param(
        {"kind": "command", "command": "ls", "input": ["a", "b"]},
        id="non-mapping-input",
    ),
    pytest.param({"kind": "agent_call", "title": "Subagent"}, id="minimal"),
    pytest.param({}, id="empty"),
    pytest.param(None, id="none"),
    pytest.param("not a mapping", id="not-a-mapping"),
]


@pytest.mark.parametrize("content", _STUB_FIXTURES)
def test_migration_stub_builder_matches_runtime(content: Any) -> None:
    """``v2_48._build_stub_content`` is a verbatim local copy (a migration is
    immutable and cannot import application code). Both copies must produce
    identical stubs for identical content, or a backfilled row and a freshly
    written row would diverge."""

    from migrations.versions import v2_48

    for payload_bytes in (0, 1, 12345):
        assert v2_48._build_stub_content(content, payload_bytes) == (
            build_stub_content(content, payload_bytes)
        )
