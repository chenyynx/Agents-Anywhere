"""One-shot repair: close timeline rows stranded on ``running``.

The connector's thinking/reasoning rows stayed ``running`` forever under a
gateway that dropped a block's ``content_block_stop`` (see the 2026-10-11 fix
in ``connector/runtimes/claude/timeline/stream.py``). The code fix stops NEW
rows from stranding; the rows already persisted are still wrong in the DB and
must be reconciled, or the client keeps showing "thinking" for them.

Each affected row is rewritten ``running -> done`` through the normal repository
write path, so ``updated_seq`` is allocated by the session's monotonic revision
sequence and the row supersedes the old one (a client reading the session — on
open, or on its next incremental pull — sees ``done``). The session's revision
machinery is never touched by hand.

This is deliberately SEPARATE from ``TimelineJanitor`` (the server's
age-bounded residue closure): that sweep only closes ``type='tool'`` rows and
marks them ``interrupted`` (unknown completion). A stranded thinking row is not
residue — its text streamed to completion and only the close signal was lost —
so it closes ``done``, and the row set is bounded by the fix's deploy instant
rather than a wall-clock age.

Safety:
  * ``--cutoff`` is REQUIRED: only rows created strictly before it are touched.
    Run the connector fix first, note the deploy instant, and pass it here — a
    row created at/after the fix self-heals and must not be backfilled (the
    repair would otherwise run while a live turn is still streaming into it).
  * Dry-run by default; ``--apply`` performs the writes after a per-session
    count. A session with an active run is REFUSED, as a second guard against
    racing a live turn.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from sqlalchemy import select

from agent_server.core.models import TimelineItem, TimelineItemIn
from agent_server.infra.db.schema import timeline_items
from agent_server.infra.repositories.facade import Store


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-url", required=True, help="postgresql+asyncpg:// DSN")
    parser.add_argument(
        "--cutoff",
        required=True,
        help="ISO-8601 instant (UTC). Only rows with createdAt < cutoff are touched.",
    )
    parser.add_argument(
        "--session",
        action="append",
        default=None,
        help="Restrict to this session id (repeatable). Default: all sessions.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Perform the writes. Without it this is a read-only dry run.",
    )
    parser.add_argument(
        "--allow-active",
        action="store_true",
        help=(
            "Repair even a session with an active run (safe when --cutoff is the "
            "fix's deploy instant: live turns only touch post-cutoff rows, which "
            "are skipped). Needed for a session that is continuously in use."
        ),
    )
    return parser.parse_args(argv)


async def _sessions_with_running_rows(store: Store) -> list[str]:
    async with store.engine.connect() as conn:
        rows = (
            await conn.execute(
                select(timeline_items.c.session_id)
                .where(timeline_items.c.status == "running")
                .distinct()
            )
        ).scalars().all()
    return list(rows)


def _done_item(item: TimelineItem) -> TimelineItemIn:
    """The same row with ``status='done'`` and a fresh revision + contentHash.

    The server treats ``contentHash`` as opaque state identity: changing it is
    what makes the write land (and bump ``updated_seq``). The hash covers
    ``type/status/role/content``, so recomputing over ``"done"`` is faithful.
    """

    data = item.model_dump(exclude={"updatedSeq"})
    data["status"] = "done"
    data["revision"] = item.revision + 1
    payload = {
        "type": item.type,
        "status": "done",
        "role": item.role,
        "content": item.content,
    }
    encoded = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str
    )
    data["contentHash"] = "sha256:" + hashlib.sha256(encoded.encode()).hexdigest()
    return TimelineItemIn.model_validate(data)


def _is_stranded_thinking(item) -> bool:
    """A reasoning row stranded on ``running`` — this repair's ONLY target.

    Scoped deliberately: a stranded ``tool`` row is a different defect with a
    different owner (``TimelineJanitor`` closes those ``interrupted``), and
    closing one ``done`` here would claim a completion that never happened. A
    thinking row is safe to close ``done`` because its text streamed to
    completion and only the boundary signal was lost.
    """

    return (
        item.type == "system"
        and (item.content or {}).get("blockType") == "thinking"
    )


async def reconcile_stranded(
    store: Store,
    *,
    cutoff: str,
    session_ids: list[str] | None = None,
    apply: bool = False,
    allow_active: bool = False,
) -> int:
    """Reconcile stranded thinking rows; return how many were (or would be) rewritten.

    ``allow_active`` overrides the active-run guard. It is safe for a
    cutoff-scoped repair because every targeted row was created BEFORE the
    fix's deploy: a live turn can only touch post-cutoff rows (which this skips
    and which self-heal), and it never rewrites a stranded pre-fix row, so the
    two writers cannot collide. The guard exists for the general case; when a
    session is the one being actively used (so it is never idle), this is the
    switch that lets its own backlog be repaired.
    """

    sessions = session_ids or await _sessions_with_running_rows(store)
    total = 0
    for session_id in sessions:
        active = await store.get_active_run(session_id)
        if active is not None and not allow_active:
            print(f"SKIP {session_id}: active run — refusing to race a live turn")
            continue
        items = await store.timeline.read(session_id)
        stranded = [
            item
            for item in items
            if item.status == "running"
            and _is_stranded_thinking(item)
            and (item.createdAt or "") < cutoff
        ]
        if not stranded:
            continue
        total += len(stranded)
        print(f"{session_id}: {len(stranded)} stranded row(s) before {cutoff}")
        if not apply:
            continue
        for item in stranded:
            await store.upsert_timeline_item(
                session_id=session_id,
                item=_done_item(item),
                mark_read_on_change=False,
            )
    return total


async def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    store = Store(db_url=args.db_url, backend="postgres")
    try:
        total = await reconcile_stranded(
            store,
            cutoff=args.cutoff,
            session_ids=args.session,
            apply=args.apply,
            allow_active=args.allow_active,
        )
        mode = "APPLIED" if args.apply else "DRY RUN"
        print(f"{mode}: {total} row(s)")
        return 0
    finally:
        await store.close()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
