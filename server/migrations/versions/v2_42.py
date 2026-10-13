"""Store the Runtime native item id for intra-message ordering.

A message's reasoning rows and its body row come from two different write
paths and can end up with the body row sorting *before* its own reasoning
(56 of 12,272 message groups in production, worst delta +14). The client
renders by stored ``order_seq`` and keyset-paginates on it, so the fix must
land in the stored order. Grouping the two rows requires the identity they
share — the Runtime's native item id (``source.itemId``) — which was not
stored. ``native_item_id`` carries it, with an index for the per-write group
lookup.

The column is backfilled from the stored payload in the same migration: the
corrector groups rows by ``native_item_id``, so a NULL historical row would be
invisible to it and the invariant could never be repaired on existing data
(red-team finding). The payload already carries ``source.itemId`` on every
projected row, so the backfill is a faithful copy, not a guess. Rows whose
payload has no ``itemId`` (platform-authored rows, or pre-projection rows)
stay NULL and are simply out of scope.

Revision ID: v2_42
Revises: v2_41
"""

from __future__ import annotations

import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "v2_42"
down_revision: str | None = "v2_41"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NATIVE_ITEM_INDEX = "idx_timeline_items_session_native_item"
_BACKFILL_BATCH = 1000


def _column_names() -> set[str]:
    return {
        column["name"]
        for column in sa.inspect(op.get_bind()).get_columns("timeline_items")
    }


def _index_exists(name: str) -> bool:
    """Check index existence including expression-based indexes.

    ``Inspector.get_indexes`` skips expression-based indexes (the
    ``idx_timeline_items_session_latest`` swap in v2_35); this index is not
    expression-based, but the shared helper keeps the existence check uniform
    with the other timeline index migrations.
    """

    bind = op.get_bind()
    if bind.dialect.name == "sqlite":
        statement = sa.text(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = :name"
        )
    else:
        statement = sa.text("SELECT 1 FROM pg_indexes WHERE indexname = :name")
    return bind.execute(statement, {"name": name}).first() is not None


def _native_item_id_from_payload(payload_json: str) -> str | None:
    try:
        payload = json.loads(payload_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    source = payload.get("source")
    if not isinstance(source, dict):
        return None
    value = source.get("itemId")
    return value if isinstance(value, str) and value else None


def _backfill_native_item_id() -> None:
    """Copy ``source.itemId`` from each payload into the new column.

    Done in Python (not dialect SQL) so the same code runs on SQLite tests and
    PostgreSQL production, and so a payload that is not valid JSON is skipped
    rather than aborting the migration. Reads a bounded page at a time — the
    table can hold hundreds of megabytes of payload text, so materializing it
    all at once would be a needless memory spike during a live migration — and
    pages by the ``(session_id, id)`` primary key rather than by "still NULL",
    which would re-read rows whose payload has no itemId forever.
    """

    bind = op.get_bind()
    select_sql = sa.text(
        "SELECT session_id, id, payload_json FROM timeline_items "
        "WHERE session_id > :after_session "
        "OR (session_id = :after_session AND id > :after_id) "
        "ORDER BY session_id, id LIMIT :limit"
    )
    update_sql = sa.text(
        "UPDATE timeline_items SET native_item_id = :native_item_id "
        "WHERE session_id = :session_id AND id = :id"
    )
    after_session = ""
    after_id = ""
    while True:
        rows = bind.execute(
            select_sql,
            {"after_session": after_session, "after_id": after_id, "limit": _BACKFILL_BATCH},
        ).fetchall()
        if not rows:
            return
        updates: list[dict[str, str]] = []
        for session_id, item_id, payload_json in rows:
            after_session, after_id = session_id, item_id
            native_item_id = _native_item_id_from_payload(payload_json)
            if native_item_id is None:
                continue
            updates.append(
                {"session_id": session_id, "id": item_id, "native_item_id": native_item_id}
            )
        if updates:
            bind.execute(update_sql, updates)


def upgrade() -> None:
    if "native_item_id" not in _column_names():
        op.add_column(
            "timeline_items",
            sa.Column("native_item_id", sa.Text(), nullable=True),
        )
    _backfill_native_item_id()
    if not _index_exists(NATIVE_ITEM_INDEX):
        op.create_index(
            NATIVE_ITEM_INDEX,
            "timeline_items",
            ["session_id", "native_item_id"],
            unique=False,
        )


def downgrade() -> None:
    if _index_exists(NATIVE_ITEM_INDEX):
        op.drop_index(NATIVE_ITEM_INDEX, table_name="timeline_items")
    if "native_item_id" in _column_names():
        op.drop_column("timeline_items", "native_item_id")
