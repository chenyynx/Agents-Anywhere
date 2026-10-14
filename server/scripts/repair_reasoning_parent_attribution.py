"""One-shot repair: un-parent reasoning rows mis-attributed to a subagent.

Root cause (fixed 2026-10-14 in
``connector/runtimes/claude/timeline/stream.py``): a main-agent thinking row
was stamped with the parent of whatever frame CLOSED its block, not the frame
that opened it. LiteLLM omits a thinking block's ``content_block_stop``, so a
background subagent's ``message_start`` could be the closing boundary and hand
the main-agent row the subagent's card id — iOS then folded it into the
SubAgent capsule and the reasoning vanished from the main timeline (pp session
``sess_3vglLn61-wPSSg``; also ``sess_92gAbPjhjE6DXQ``). The code fix stops new
rows from being mis-attributed; the rows already persisted are still wrong and
must be reconciled.

Targets come from ``--ids-file``: a JSON map ``{session_id: [row_id, ...]}``
built from the CLI transcripts (a row is mis-attributed iff its
``source.itemId`` is a message id that appears in that session's MAIN
transcript with ``isSidechain=false`` and is absent from every subagent
transcript). That is ground truth; a DB-only structural heuristic was tried
and rejected — it misses rows whose only sibling did not persist (4 of 39), so
the explicit list is the driver. Each id is re-validated against the DB before
it is written.

Each targeted row is rewritten through the normal repository write path with
``parentItemId`` removed and a fresh revision + contentHash, so ``updated_seq``
is allocated by the session's monotonic revision sequence and a client reading
the session (on open, or on its next incremental pull) sees the row in the main
timeline. Idempotent: a row already without ``parentItemId`` produces an
unchanged contentHash, so the write is a no-op.

Safety:
  * Dry-run by default; ``--apply`` performs the writes.
  * A session with an active run is REFUSED unless ``--allow-active``.
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

from agent_server.core.models import TimelineItem, TimelineItemIn
from agent_server.infra.repositories.facade import Store


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-url", required=True, help="postgresql+asyncpg:// DSN")
    parser.add_argument(
        "--ids-file",
        required=True,
        help="JSON {session_id: [row_id, ...]} of rows to un-parent.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Perform the writes. Without it this is a read-only dry run.",
    )
    parser.add_argument(
        "--allow-active",
        action="store_true",
        help="Repair even a session with an active run.",
    )
    return parser.parse_args(argv)


def _load_ids(path: str) -> dict[str, set[str]]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    return {session: set(ids) for session, ids in raw.items()}


def _unparented_item(item: TimelineItem) -> TimelineItemIn:
    """The same row with ``parentItemId`` removed and a fresh revision + hash."""

    content = {k: v for k, v in (item.content or {}).items() if k != "parentItemId"}
    data = item.model_dump(exclude={"updatedSeq"})
    data["content"] = content
    data["revision"] = item.revision + 1
    payload = {
        "type": item.type,
        "status": item.status,
        "role": item.role,
        "content": content,
    }
    encoded = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str
    )
    data["contentHash"] = "sha256:" + hashlib.sha256(encoded.encode()).hexdigest()
    return TimelineItemIn.model_validate(data)


def _is_target(item: TimelineItem, ids: set[str]) -> bool:
    """A row is written only if it is the exact shape this repair targets."""

    return (
        item.id in ids
        and item.type == "system"
        and (item.content or {}).get("blockType") == "thinking"
        and bool((item.content or {}).get("parentItemId"))
    )


async def reconcile(
    store: Store,
    *,
    ids_by_session: dict[str, set[str]],
    apply: bool = False,
    allow_active: bool = False,
) -> int:
    total = 0
    for session_id, ids in ids_by_session.items():
        active = await store.get_active_run(session_id)
        if active is not None and not allow_active:
            print(f"SKIP {session_id}: active run — refusing to race a live turn")
            continue
        items = await store.timeline.read(session_id)
        doomed = [item for item in items if _is_target(item, ids)]
        missing = ids - {item.id for item in doomed}
        total += len(doomed)
        print(f"{session_id}: {len(doomed)} row(s) to un-parent")
        if missing:
            print(
                f"  WARNING: {len(missing)} requested id(s) not matched (already "
                f"clean or not found): {sorted(missing)}"
            )
        if not apply:
            continue
        for item in doomed:
            before = (item.content or {}).get("parentItemId")
            await store.upsert_timeline_item(
                session_id=session_id,
                item=_unparented_item(item),
                mark_read_on_change=False,
            )
            print(f"  unparented {item.id} (was {before})")
    return total


async def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    ids_by_session = _load_ids(args.ids_file)
    store = Store(db_url=args.db_url, backend="postgres")
    try:
        total = await reconcile(
            store,
            ids_by_session=ids_by_session,
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
