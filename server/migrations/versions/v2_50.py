"""Persist the last ended turn's Runtime id on the session.

The footer's "this turn is over" decision currently has to be reconstructed
from the latest runtime state (and its row-coverage watermark), which is not a
durable fact: the state can be stale, absent after a restart, or written before
the turn's last rows. The connector already declares the id on every
``session.turnEnded`` notification and on each timeline row's ``source.turnId``;
the server validated the notification's ``turnId`` but dropped it, keeping only
``latest_turn_end_seq``.

This column stores that id. It is nullable and additively written by both the
live turn-end notification and the connector's history sync, so rolling
upgrades are safe: an old server ignores it, and a new server with old
connector versions leaves it NULL and the client falls back to the previous
state-based rule. There is no backfill — the fact is optional, older sessions
keep working through the fallback, and the connector's next history sync seeds
the value from the transcript.

Revision ID: v2_50
Revises: v2_49
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "v2_50"
down_revision: str | None = "v2_49"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TABLE = "sessions"
_COLUMN = "latest_turn_id"


def _column_names() -> set[str]:
    inspector = sa.inspect(op.get_bind())
    if _TABLE not in inspector.get_table_names():
        return set()
    return {column["name"] for column in inspector.get_columns(_TABLE)}


def upgrade() -> None:
    # Guarded like v2_42/v2_43/v2_45/v2_47: a database created from the current
    # metadata (then stamped as unversioned) already has the column, and an
    # unconditional ADD would fail that recovery path.
    if _COLUMN not in _column_names():
        op.add_column(_TABLE, sa.Column(_COLUMN, sa.Text(), nullable=True))


def downgrade() -> None:
    if _COLUMN in _column_names():
        op.drop_column(_TABLE, _COLUMN)
