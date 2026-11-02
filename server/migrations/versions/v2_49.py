"""Rebuild pre-v2 stubs with the tool-result truncation fields.

v2_48 backfilled ``stub_json`` with format version 1. The writer later bumped
the format to version 2 so a stub keeps ``truncated`` and ``readMetadata`` --
without them the deferred window loses the official "Showing X of Y lines"
note. The reader only accepts ``stub_version = 2``, so every row backfilled by
v2_48 (and not rewritten since) is still served full, which is exactly the
payload the deferred window exists to avoid.

This migration rebuilds those stubs from ``payload_json`` with the current
builder and marks them version 2. It does not touch ``payload_json``, ``kind``
or ``payload_bytes``. Rows whose payload cannot be parsed are marked version 2
with a NULL stub: the reader then falls back to the full row, and a re-run does
not retry them forever.

Revision ID: v2_49
Revises: v2_48
"""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op

revision: str = "v2_49"
down_revision: str | None = "v2_48"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: Stub format version stored in ``stub_version``; mirrors
#: ``agent_server.infra.timeline_store.STUB_VERSION``.
STUB_VERSION = 2
#: Byte budget for one stub's ``content`` object; mirrors
#: ``agent_server.infra.timeline_store.STUB_MAX_BYTES``.
STUB_MAX_BYTES = 2048

_BACKFILL_BATCH = 1000
_DEFERRED_DROP_KEYS = (
    "output",
    "outputText",
    "text",
    "result",
    "arguments",
    "details",
    "changes",
    "rawText",
)
_STUB_INPUT_KEYS = (
    "file_path",
    "path",
    "filePath",
    "file",
    "uri",
    "notebook_path",
    "query",
    "url",
    "command",
    "cmd",
    "description",
    "pattern",
    "glob",
    "subagent_type",
    "run_in_background",
    "timeout",
    "limit",
    "offset",
)
_STUB_INPUT_STRING_LIMIT = 200
_STUB_OUTPUT_PREVIEW_LIMIT = 240
_STUB_OUTPUT_BINARY_WINDOW = 4000
_STUB_REQUIRED_STRING_LIMITS = (200, 100, 50)
_STUB_REQUIRED_KEYS = frozenset(
    {
        "kind",
        "name",
        "toolName",
        "tool",
        "title",
        "description",
        "command",
        "outputLength",
        "toolUseId",
        "isError",
        "deferred",
        "deferredBytes",
        "outputPreview",
        "truncated",
        "readMetadata",
    }
)


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _content_kind(content: Any) -> str | None:
    if not isinstance(content, Mapping):
        return None
    value = content.get("kind")
    return value if isinstance(value, str) and value else None


def _has_parent(content: Any) -> bool:
    if not isinstance(content, Mapping):
        return False
    value = content.get("parentItemId")
    return isinstance(value, str) and bool(value)


def _looks_binary_output(text: str) -> bool:
    head = text[:_STUB_OUTPUT_BINARY_WINDOW]
    if "base64" in head or "media_type" in head:
        return True
    tail = text[-_STUB_OUTPUT_PREVIEW_LIMIT:]
    return not any(character.isspace() for character in tail)


def _output_preview(content: Mapping[str, Any]) -> str | None:
    raw = content.get("output") or content.get("outputText") or content.get("text")
    if not isinstance(raw, str) or not raw:
        return None
    if _looks_binary_output(raw):
        return None
    return raw[-_STUB_OUTPUT_PREVIEW_LIMIT:]


def _trim_stub_input(value: Any) -> Any | None:
    if isinstance(value, str):
        return value[:_STUB_INPUT_STRING_LIMIT]
    if not isinstance(value, Mapping):
        return None
    trimmed: dict[str, Any] = {}
    for key in _STUB_INPUT_KEYS:
        if key not in value:
            continue
        item = value[key]
        if isinstance(item, str) and len(item) > _STUB_INPUT_STRING_LIMIT:
            item = item[:_STUB_INPUT_STRING_LIMIT]
        trimmed[key] = item
    return trimmed


def _value_size(key: str, value: Any) -> int:
    return len(_json_dumps({key: value}).encode("utf-8"))


def _stub_size(stub: Mapping[str, Any]) -> int:
    return len(_json_dumps(stub).encode("utf-8"))


def _shrink_required_strings(stub: dict[str, Any]) -> None:
    if _stub_size(stub) <= STUB_MAX_BYTES:
        return
    for limit in _STUB_REQUIRED_STRING_LIMITS:
        truncated = False
        for key, value in stub.items():
            if (
                key in _STUB_REQUIRED_KEYS
                and isinstance(value, str)
                and len(value) > limit
            ):
                stub[key] = value[:limit]
                truncated = True
        if truncated and _stub_size(stub) <= STUB_MAX_BYTES:
            return


def _build_stub_content(content: Any, payload_bytes: int) -> dict[str, Any] | None:
    """A small render-ready copy of ``content`` (``None`` when there is none).

    Copied verbatim from
    ``agent_server.infra.timeline_store.build_stub_content``; keep the two
    identical (the write path has a parity test).
    """

    if not isinstance(content, Mapping) or not content:
        return None
    stub = dict(content)
    preview = _output_preview(content)
    for key in _DEFERRED_DROP_KEYS:
        stub.pop(key, None)
    if "input" in stub:
        trimmed_input = _trim_stub_input(stub["input"])
        if trimmed_input is None:
            stub.pop("input")
        else:
            stub["input"] = trimmed_input
    if preview is not None:
        stub["outputPreview"] = preview
    stub["deferred"] = True
    stub["deferredBytes"] = payload_bytes
    candidates = [key for key in stub if key not in _STUB_REQUIRED_KEYS]
    candidates.sort(key=lambda key: (-_value_size(key, stub[key]), key))
    for key in candidates:
        if _stub_size(stub) <= STUB_MAX_BYTES:
            break
        del stub[key]
    _shrink_required_strings(stub)
    return stub


def _column_names() -> set[str]:
    return {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("timeline_items")
    }


def _add_columns() -> None:
    existing = _column_names()
    for name, column_type in (
        ("kind", sa.Text()),
        ("payload_bytes", sa.Integer()),
        ("stub_json", sa.Text()),
        ("stub_version", sa.SmallInteger()),
    ):
        if name not in existing:
            op.add_column(
                "timeline_items",
                sa.Column(name, column_type, nullable=True),
            )


def _backfill_stub_version() -> None:
    bind = op.get_bind()
    select_sql = sa.text(
        "SELECT session_id, id, type, payload_json FROM timeline_items "
        "WHERE stub_version = 1 "
        "AND (session_id > :after_session "
        "OR (session_id = :after_session AND id > :after_id)) "
        "ORDER BY session_id, id LIMIT :limit"
    )
    update_sql = sa.text(
        "UPDATE timeline_items SET stub_json = :stub_json, "
        "stub_version = :stub_version "
        "WHERE session_id = :session_id AND id = :id AND stub_version = 1"
    )
    after_session = ""
    after_id = ""
    while True:
        rows = bind.execute(
            select_sql,
            {
                "after_session": after_session,
                "after_id": after_id,
                "limit": _BACKFILL_BATCH,
            },
        ).fetchall()
        if not rows:
            return
        updates: list[dict[str, Any]] = []
        for session_id, item_id, item_type, payload_json in rows:
            after_session, after_id = session_id, item_id
            stub_json = None
            try:
                payload = json.loads(payload_json)
            except (TypeError, ValueError):
                payload = None
            if isinstance(payload, dict):
                payload_bytes = len(payload_json.encode("utf-8"))
                content = payload.get("content")
                if item_type == "tool" and not _has_parent(content):
                    stub = _build_stub_content(content, payload_bytes)
                    if stub is not None:
                        packed = dict(payload)
                        packed["content"] = stub
                        stub_json = _json_dumps(packed)
            updates.append(
                {
                    "session_id": session_id,
                    "id": item_id,
                    "stub_json": stub_json,
                    "stub_version": STUB_VERSION,
                }
            )
        if updates:
            bind.execute(update_sql, updates)


def upgrade() -> None:
    """Rewrite every version-1 stub with the current builder.

    The whole pass runs in one ``autocommit_block``: it only updates the
    ``stub_json``/``stub_version`` columns and pages by primary key, so the
    server keeps writing throughout. Progress is the row's own version, so a
    partial run is recovered by re-running the migration.
    """

    with op.get_context().autocommit_block():
        _backfill_stub_version()


def downgrade() -> None:
    """The v1 bytes are not reconstructible; the reader ignores v1 anyway."""
