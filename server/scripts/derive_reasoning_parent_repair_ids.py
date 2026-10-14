"""Derive the id list for ``repair_reasoning_parent_attribution.py``.

Reads every session with a parented ``thinking`` row, resolves each such row's
``source.itemId`` against the CLI transcripts, and writes the ids whose message
id appears in that session's MAIN transcript with ``isSidechain=false`` and is
absent from every subagent transcript — i.e. a main-agent row wrongly stamped
with a subagent's parent. The output JSON (``{session_id: [row_id, ...]}``) is
the only ground truth for the repair: there is no DB-only shape that separates
a mis-attributed row from a legitimately-parented one (see the repair script's
docstring).

DB row ids are read over the raw connection (``timeline_items``); the CLI
summary transcript is ``<projects>/<external_session_id>.jsonl`` and subagent
transcripts live in ``<projects>/<external_session_id>/subagents/*.jsonl``.

Run:  python scripts/derive_reasoning_parent_repair_ids.py \
        --db-url postgresql+asyncpg://... --out ids.json
"""

from __future__ import annotations

import argparse
import asyncio
import glob
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from sqlalchemy import select

from agent_server.infra.db.schema import sessions, timeline_items
from agent_server.infra.repositories.facade import Store

_DEFAULT_PROJECTS = "~/.claude/projects"


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-url", required=True, help="postgresql+asyncpg:// DSN")
    parser.add_argument("--out", required=True, help="JSON output path")
    parser.add_argument(
        "--projects-dir",
        default=_DEFAULT_PROJECTS,
        help="Claude Code projects dir holding <external_session_id>.jsonl.",
    )
    return parser.parse_args(argv)


def _ids_of(path: str) -> set[str]:
    ids: set[str] = set()
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = obj.get("message")
            if isinstance(message, dict):
                mid = message.get("id")
                if isinstance(mid, str):
                    ids.add(mid)
    return ids


async def _derive(store: Store, projects_dir: str) -> dict[str, list[str]]:
    async with store.engine.connect() as conn:
        rows = (
            await conn.execute(
                select(
                    timeline_items.c.session_id,
                    timeline_items.c.id,
                    timeline_items.c.type,
                    timeline_items.c.payload_json,
                )
            )
        ).all()
        ext = {
            sid: e
            for sid, e in (await conn.execute(
                select(sessions.c.id, sessions.c.external_session_id)
            )).all()
        }

    # session -> list of (row_id, source itemId), for parented thinking rows.
    candidates: dict[str, list[tuple[str, str]]] = {}
    for session_id, row_id, row_type, payload_json in rows:
        if row_type != "system":
            continue
        payload = json.loads(payload_json)
        content = payload.get("content") or {}
        if not (content.get("blockType") == "thinking" and content.get("parentItemId")):
            continue
        item_id = (payload.get("source") or {}).get("itemId")
        if isinstance(item_id, str):
            candidates.setdefault(session_id, []).append((row_id, item_id))

    result: dict[str, list[str]] = {}
    base = os.path.expanduser(projects_dir)
    for session_id, entries in candidates.items():
        external = ext.get(session_id)
        if not external:
            continue
        main_path = os.path.join(base, f"{external}.jsonl")
        if not os.path.exists(main_path):
            print(f"WARN {session_id}: no main transcript {main_path}", file=sys.stderr)
            continue
        main_ids = _ids_of(main_path)
        sub_ids: set[str] = set()
        for sub_path in glob.glob(os.path.join(base, external, "subagents", "*.jsonl")):
            sub_ids |= _ids_of(sub_path)
        hits = [
            row_id
            for row_id, item_id in entries
            if item_id in main_ids and item_id not in sub_ids
        ]
        if hits:
            result[session_id] = hits
    return result


async def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    store = Store(db_url=args.db_url, backend="postgres")
    try:
        result = await _derive(store, args.projects_dir)
    finally:
        await store.close()
    Path(args.out).write_text(
        json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(
        f"{sum(len(v) for v in result.values())} row(s) across {len(result)} session(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
