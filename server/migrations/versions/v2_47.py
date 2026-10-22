"""Store the Agent-card parent of a subagent timeline row.

A session's newest timeline window can be made up entirely of rows emitted by
subagents. The iOS main timeline hides those rows (L2.1: any row whose
``content.parentItemId`` is non-empty renders only inside its parent card), so
a client opening such a session sees an empty page even though the session has
content. The server-side answer is an opt-in "main timeline window" that
excludes child rows, plus a query that pages a card's child rows on demand —
both need the parent id *in a column*, because filtering and paging must happen
in SQL (before ``LIMIT``), not after materializing the page.

The column is backfilled from the stored payload in the same migration, exactly
as v2_42/v2_43 backfill their columns: the payload already carries
``content.parentItemId`` on every row a Runtime projected as a subagent child,
so the backfill is a faithful copy, not a heuristic. Rows without a non-empty
string ``content.parentItemId`` stay NULL — that is the correct outcome, not a
miss; nothing is guessed.

The scan sees the table as of the moment it runs. A row written by an *old*
server process during the rolling upgrade, after the cursor has passed its
key, keeps NULL until that row is written again by a new process — the writer
rewrites every column, so it self-heals. Clients only opt into the main-only
window after the server rollout, by which point no old writer remains; the
deployment note is in ``docs/upgrading.md``.

Revision ID: v2_47
Revises: v2_46
"""

from __future__ import annotations

import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "v2_47"
down_revision: str | None = "v2_46"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

PARENT_ITEM_INDEX = "idx_timeline_items_session_parent_order"
_BACKFILL_BATCH = 1000
# A CONCURRENTLY build that cannot take its lock (a long-running unrelated
# transaction, a stuck idle-in-transaction) waits forever by default. Bound it
# so the migration fails fast and visibly instead of hanging the deploy; the
# failed build leaves an INVALID index that the retry path (above) clears and
# rebuilds.
_LOCK_TIMEOUT = "5s"


def _bound_lock_wait() -> None:
    """Cap how long a CONCURRENTLY build waits for its lock.

    ``CREATE INDEX CONCURRENTLY`` waits without limit for the lock it needs at
    its start and finish phases. A long-running unrelated transaction (or an
    idle-in-transaction session) therefore hangs the whole deploy with no
    output. ``lock_timeout`` turns that into a fast, visible failure; the retry
    path drops the INVALID shell and rebuilds. Session-scoped ``SET`` (not
    ``SET LOCAL``): the autocommit block commits between statements, so a
    transaction-local setting would not survive to the ``CREATE INDEX``. Only
    PostgreSQL has the GUC; SQLite ignores ``SET`` entirely, so it is skipped
    there.
    """

    if op.get_bind().dialect.name != "postgresql":
        return
    op.execute(sa.text(f"SET lock_timeout = '{_LOCK_TIMEOUT}'"))


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


def _index_is_usable(name: str) -> bool:
    """Whether a *planner-usable* index of this name exists.

    ``CREATE INDEX CONCURRENTLY`` that fails (a cancelled statement, a deadlock,
    an operator's Ctrl-C) leaves the index behind marked ``indisvalid = false``.
    It still shows up in ``pg_indexes``, but the planner ignores it — so a
    retry that only checked existence would conclude "already built" and leave
    the column permanently unindexed with no error to notice. On SQLite there
    is no such state, so existence is usability.
    """

    bind = op.get_bind()
    if bind.dialect.name == "sqlite":
        return _index_exists(name)
    row = bind.execute(
        sa.text(
            "SELECT i.indisvalid FROM pg_class c "
            "JOIN pg_index i ON i.indexrelid = c.oid "
            "WHERE c.relname = :name AND c.relkind = 'i'"
        ),
        {"name": name},
    ).first()
    return bool(row and row[0])


def _parent_item_id_from_payload(payload_json: str) -> str | None:
    try:
        payload = json.loads(payload_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    content = payload.get("content")
    if not isinstance(content, dict):
        return None
    value = content.get("parentItemId")
    return value if isinstance(value, str) and value else None


def _backfill_parent_item_id() -> None:
    """Copy ``content.parentItemId`` from each payload into the new column.

    Done in Python (not dialect SQL) so the same code runs on SQLite tests and
    PostgreSQL production, and so a payload that is not valid JSON is skipped
    rather than aborting the migration. Reads a bounded page at a time — the
    table can hold hundreds of megabytes of payload text, so materializing it
    all at once would be a needless memory spike during a live migration.

    A row whose payload has no non-empty string ``content.parentItemId`` (main
    timeline rows, platform-authored rows, pre-projection rows) stays NULL —
    that is the correct outcome, not a miss. The scan is restricted to rows
    still NULL and pages by the ``(session_id, id)`` primary key: the ``IS
    NULL`` predicate keeps a re-run from re-reading every payload to find the
    rows a previous attempt already filled, while the keyset cursor guarantees
    termination — a row that stays NULL forever is always advanced past rather
    than looped on.
    """

    bind = op.get_bind()
    select_sql = sa.text(
        "SELECT session_id, id, payload_json FROM timeline_items "
        "WHERE parent_item_id IS NULL "
        "AND (session_id > :after_session "
        "OR (session_id = :after_session AND id > :after_id)) "
        "ORDER BY session_id, id LIMIT :limit"
    )
    update_sql = sa.text(
        "UPDATE timeline_items SET parent_item_id = :parent_item_id "
        "WHERE session_id = :session_id AND id = :id "
        "AND parent_item_id IS NULL"
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
        updates: list[dict[str, str]] = []
        for session_id, item_id, payload_json in rows:
            after_session, after_id = session_id, item_id
            parent_item_id = _parent_item_id_from_payload(payload_json)
            if parent_item_id is None:
                continue
            updates.append(
                {
                    "session_id": session_id,
                    "id": item_id,
                    "parent_item_id": parent_item_id,
                }
            )
        if updates:
            bind.execute(update_sql, updates)


def upgrade() -> None:
    """Add, backfill and index ``parent_item_id`` without a long table lock.

    The whole Alembic chain runs inside one transaction (``migrations/env.py``
    wraps ``context.run_migrations()``). On PostgreSQL ``ADD COLUMN`` takes an
    ACCESS EXCLUSIVE lock that is held until that transaction commits, so on a
    large ``timeline_items`` a single-transaction migration would block every
    read and write to the table for the whole backfill + index build. Each step
    therefore runs in its own committed ``autocommit_block``; the index is built
    ``CONCURRENTLY`` so it never blocks writers.
    """

    context = op.get_context()

    with context.autocommit_block():
        if "parent_item_id" not in _column_names():
            op.add_column(
                "timeline_items",
                sa.Column("parent_item_id", sa.Text(), nullable=True),
            )

    with context.autocommit_block():
        _backfill_parent_item_id()

    with context.autocommit_block():
        if not _index_is_usable(PARENT_ITEM_INDEX):
            # Either the index is absent, or a previous CONCURRENTLY build left
            # it INVALID (present but unusable). Both mean "build it"; the drop
            # clears the invalid shell so the name is free.
            _bound_lock_wait()
            if _index_exists(PARENT_ITEM_INDEX):
                _drop_index_concurrently(PARENT_ITEM_INDEX)
            op.create_index(
                PARENT_ITEM_INDEX,
                "timeline_items",
                ["session_id", "parent_item_id", "order_seq"],
                unique=False,
                postgresql_concurrently=True,
            )


def _drop_index_concurrently(name: str) -> None:
    """Drop ``name`` without an ACCESS EXCLUSIVE scan of the table.

    On PostgreSQL a plain ``DROP INDEX`` locks the table against writes for the
    whole drop; this migration's whole point is to avoid that. ``CONCURRENTLY``
    cannot run inside a transaction, which is why every caller is already
    inside an ``autocommit_block``.
    """

    bind = op.get_bind()
    op.drop_index(
        name,
        table_name="timeline_items",
        if_exists=True,
        **(
            {"postgresql_concurrently": True}
            if bind.dialect.name == "postgresql"
            else {}
        ),
    )


def downgrade() -> None:
    if _index_exists(PARENT_ITEM_INDEX):
        with op.get_context().autocommit_block():
            _bound_lock_wait()
            _drop_index_concurrently(PARENT_ITEM_INDEX)
    if "parent_item_id" in _column_names():
        op.drop_column("timeline_items", "parent_item_id")
