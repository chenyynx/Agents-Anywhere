"""Store a render-ready stub of large tool payloads and their content kind.

A session's newest timeline window can be made up entirely of tool and
reasoning rows (measured: 56 tool + 44 system reasoning, zero messages). Each
tool row can carry megabytes of output, and the client only needs a title line
until the user expands it. Parsing those payloads to build the collapsed line
is exactly the cost the window reader must avoid, so the writer keeps:

- ``kind`` — ``content.kind`` for every row (main and child);
- ``payload_bytes`` — the UTF-8 size of the stored ``payload_json``;
- ``stub_json`` — the full item payload with ``content`` replaced by a small
  render-ready summary (large outputs dropped, a 240-character tail preview
  kept, ``deferred``/``deferredBytes`` added), only for main-timeline tool
  rows (``type = 'tool'`` with no ``content.parentItemId``);
- ``stub_version`` — the stub format version (1), paired with ``stub_json``.

The summary builder is copied verbatim from
``agent_server.infra.timeline_store.build_stub_content``: a migration is
immutable and must not import application code that will keep changing. The
two copies are held together by a parity test on the write path side.

Backfill reads ``payload_json`` in Python (not dialect SQL) so the same code
runs on SQLite tests and PostgreSQL production and a malformed payload is
skipped rather than aborting the deploy. It pages by the ``(session_id, id)``
primary key with ``payload_bytes IS NULL`` as the "not yet backfilled" marker:
every parsed row gets ``payload_bytes`` in the same UPDATE as its other
columns, so a re-run never reprocesses it. A row whose payload does not parse
keeps all four columns NULL and is re-read on a retry, but the keyset cursor
always advances past it, so the loop terminates. A main tool row that parsed
but whose content yields no stub (not a mapping, or empty) permanently keeps
``stub_json`` NULL — that is the outcome, not a miss, and the cursor guarantees
no infinite loop.

Parent detection reads ``content.parentItemId`` from the payload, not the
v2_47 column: during a rolling upgrade an old server process can write a child
tool row after the v2_47 backfill passed its key, leaving ``parent_item_id``
NULL while the payload does declare the parent. The payload rule is the same
one the runtime writer applies, so a row backfilled here and one written by a
new process agree.

Revision ID: v2_48
Revises: v2_47
"""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op

revision: str = "v2_48"
down_revision: str | None = "v2_47"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

#: Stub format version stored in ``stub_version``; mirrors
#: ``agent_server.infra.timeline_store.STUB_VERSION``.
STUB_VERSION = 1
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


def _backfill_deferred_activity() -> None:
    bind = op.get_bind()
    select_sql = sa.text(
        "SELECT session_id, id, type, payload_json FROM timeline_items "
        "WHERE payload_bytes IS NULL "
        "AND (session_id > :after_session "
        "OR (session_id = :after_session AND id > :after_id)) "
        "ORDER BY session_id, id LIMIT :limit"
    )
    update_sql = sa.text(
        "UPDATE timeline_items SET kind = :kind, payload_bytes = :payload_bytes, "
        "stub_json = :stub_json, stub_version = :stub_version "
        "WHERE session_id = :session_id AND id = :id "
        "AND payload_bytes IS NULL"
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
            try:
                payload = json.loads(payload_json)
            except (TypeError, ValueError):
                continue
            payload_bytes = len(payload_json.encode("utf-8"))
            content = payload.get("content") if isinstance(payload, dict) else None
            stub_json = None
            stub_version = None
            if item_type == "tool" and not _has_parent(content):
                stub = _build_stub_content(content, payload_bytes)
                if stub is not None:
                    packed = dict(payload)
                    packed["content"] = stub
                    stub_json = _json_dumps(packed)
                    stub_version = STUB_VERSION
            updates.append(
                {
                    "session_id": session_id,
                    "id": item_id,
                    "kind": _content_kind(content),
                    "payload_bytes": payload_bytes,
                    "stub_json": stub_json,
                    "stub_version": stub_version,
                }
            )
        if updates:
            bind.execute(update_sql, updates)


def upgrade() -> None:
    """Add the four columns, then backfill them from the stored payload.

    Each step runs in its own committed ``autocommit_block`` so the
    ``ADD COLUMN`` locks are not held for the whole backfill: the table can
    hold hundreds of megabytes of payload text, and a single-transaction
    migration would block every timeline write until the scan finishes. A
    partial run is recovered by re-running the migration.
    """

    context = op.get_context()
    with context.autocommit_block():
        _add_columns()
    with context.autocommit_block():
        _backfill_deferred_activity()


def downgrade() -> None:
    existing = _column_names()
    for name in ("stub_version", "stub_json", "payload_bytes", "kind"):
        if name in existing:
            op.drop_column("timeline_items", name)
