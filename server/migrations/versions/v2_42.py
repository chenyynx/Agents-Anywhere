"""Store the Runtime native item id for intra-message ordering.

A message's reasoning rows and its body row come from two different write
paths and can end up with the body row sorting *before* its own reasoning
(56 of 12,272 message groups in production, worst delta +14). The client
renders by stored ``order_seq`` and keyset-paginates on it, so the fix must
land in the stored order. Grouping the two rows requires the identity they
share — the Runtime's native item id (``source.itemId``) — which was not
stored. ``native_item_id`` carries it, with an index for the per-write group
lookup.

No backfill: historical rows keep a NULL ``native_item_id`` until a later
rewrite of that row repopulates it from the payload. Until then their order is
left exactly as it is.

Revision ID: v2_42
Revises: v2_41
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "v2_42"
down_revision: str | None = "v2_41"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NATIVE_ITEM_INDEX = "idx_timeline_items_session_native_item"


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


def upgrade() -> None:
    if "native_item_id" not in _column_names():
        op.add_column(
            "timeline_items",
            sa.Column("native_item_id", sa.Text(), nullable=True),
        )
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
