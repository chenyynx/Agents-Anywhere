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
built from the CLI transcripts by ``derive_reasoning_parent_repair_ids.py`` (a
row is mis-attributed iff its ``source.itemId`` is a message id that appears in
that session's MAIN transcript with ``isSidechain=false`` and is absent from
every subagent transcript). That transcript relation IS the ground truth, and
the ids file is therefore authoritative: there is NO DB-only shape that tells
a mis-attributed main row from a legitimately-parented one (the capture route
marks a subagent reasoning row ``claude.subagent.system``, but the in-turn
route marks it ``claude.turn.system`` — the same event a mis-attributed row
carries). A DB-only structural heuristic was tried and rejected: it misses
rows whose only sibling did not persist (4 of 39).

Each id is re-validated before it is written (`_is_target`):
``type=system``, ``content.blockType=thinking``, a non-empty
``content.parentItemId``, and — a cheap backstop that can never exclude a real
target, since every mis-attributed row is on the ``claude.turn.*`` route —
``source.event`` is not the capture route's ``claude.subagent.system``.

Each targeted row is rewritten through the normal repository write path with
``parentItemId`` removed and a fresh revision + contentHash, so ``updated_seq``
is allocated by the session's monotonic revision sequence and a client reading
the session (on open, or on its next incremental pull) sees the row in the main
timeline. Idempotent: a row already without ``parentItemId`` produces an
unchanged contentHash, so the write is a no-op.

Safety:
  * Dry-run by default; ``--apply`` performs the writes.
  * A session with an active run is REFUSED unless ``--allow-active``. The flag
    is for a session that is continuously in use: a targeted reasoning row is
    historical — the connector never re-streams an old thinking block, so it
    never rewrites this row — and the server serialises the write through the
    session's revision sequence, so the only exposure is a wasted revision
    against a concurrently-written *different* row, not a corrupted target.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import sys
from collections.abc import Mapping
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from agent_server.core.models import TimelineItem, TimelineItemIn
from agent_server.infra.repositories.facade import Store

# The capture route's event. A row on it is a real subagent row (its parent is
# correct) and must never be un-parented; every mis-attributed row this repair
# targets is on the ``claude.turn.*`` route instead.
_SUBAGENT_CAPTURE_EVENT = "claude.subagent.system"


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


def _content(item: TimelineItem) -> Mapping[str, object]:
    """The row's content as a mapping — a malformed shape reads as empty.

    Guards against a non-mapping ``content`` (defensive backstop; the field is
    always a mapping on real rows) turning a read into an ``AttributeError``
    that aborts the whole run after earlier rows were already written.
    """

    value = item.content
    return value if isinstance(value, Mapping) else {}


def _source_event(item: TimelineItem) -> str | None:
    """The row's ``source.event``; the read may give a model or a mapping."""

    source = item.source
    if isinstance(source, Mapping):
        event = source.get("event")
    else:
        event = getattr(source, "event", None)
    return event if isinstance(event, str) else None


def _unparented_item(item: TimelineItem) -> TimelineItemIn:
    """The same row with ``parentItemId`` removed and a fresh revision + hash."""

    content = {k: v for k, v in _content(item).items() if k != "parentItemId"}
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
    """A row is written only if it is the exact shape this repair targets.

    The id must be in the (transcript-derived) list AND the row must be a
    parented reasoning row AND must not be on the capture route
    (``claude.subagent.system`` — a genuinely subagent-owned row).
    """

    content = _content(item)
    return (
        item.id in ids
        and item.type == "system"
        and content.get("blockType") == "thinking"
        and bool(content.get("parentItemId"))
        and _source_event(item) != _SUBAGENT_CAPTURE_EVENT
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
            before = _content(item).get("parentItemId")
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
