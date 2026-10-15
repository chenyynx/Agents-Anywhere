"""Compare a session's DB tool-row order against the transcript's tool_use order.

Ground truth = the MAIN transcript: each assistant message lists its tool_use
blocks in emission order. A DB tool row's `source.itemId` is the tool_use id
(`call_0X_...`). For each assistant message with 2+ tool calls, the DB rows
(ordered by `order_seq`) must list those ids in the same relative order as the
transcript. Any strict inversion (a higher index ordered before a lower one) is
a real ordering bug; equal ids (a call's tool_use + tool_result pair) are fine.

Usage: python compare_tool_order.py --session <sess_id> --db-url <dsn>
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]  # <repo>/server/scripts -> <repo>
sys.path.insert(0, str(REPO / "server"))

from sqlalchemy import select

from agent_server.infra.db.schema import sessions, timeline_items
from agent_server.infra.repositories.facade import Store

PROJECTS = os.path.expanduser("~/.claude/projects/-home-ubuntu")


def _transcript_tooluse_order(ext: str) -> dict[str, list[str]]:
    """message_id -> [tool_use_id, ...] in transcript order."""
    path = os.path.join(PROJECTS, f"{ext}.jsonl")
    out: dict[str, list[str]] = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = obj.get("message") or {}
            if obj.get("type") == "assistant" and isinstance(msg.get("content"), list):
                mid = msg.get("id")
                for block in msg["content"]:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tid = block.get("id")
                        if mid and tid:
                            out.setdefault(mid, []).append(tid)
    return out


async def _db_tool_rows(store: Store, session_id: str):
    async with store.engine.connect() as conn:
        return (
            await conn.execute(
                select(timeline_items.c.order_seq, timeline_items.c.payload_json)
                .where(
                    timeline_items.c.session_id == session_id,
                    timeline_items.c.type == "tool",
                )
                .order_by(timeline_items.c.order_seq)
            )
        ).all()


def _call_id(payload_json: str) -> str | None:
    payload = json.loads(payload_json)
    cid = (payload.get("source") or {}).get("itemId")
    return cid if isinstance(cid, str) else None


async def run(session_id: str, db_url: str) -> list[tuple[int, str, int, str]]:
    store = Store(db_url=db_url, backend="postgres")
    try:
        async with store.engine.connect() as conn:
            row = (
                await conn.execute(
                    select(sessions.c.external_session_id).where(
                        sessions.c.id == session_id
                    )
                )
            ).first()
        ext = row[0] if row else None
        if not ext:
            return []
        order = _transcript_tooluse_order(ext)
        rows = await _db_tool_rows(store, session_id)
    finally:
        await store.close()

    inversions: list[tuple[int, str, int, str]] = []
    # Group DB tool rows by the transcript message that owns each tool_use id,
    # preserving DB order_seq order; flag any inversion within one message.
    owner: dict[str, str] = {}
    for mid, ids in order.items():
        for tid in ids:
            owner[tid] = mid
    groups: dict[str, list[tuple[int, str]]] = {}
    for order_seq, payload_json in rows:
        cid = _call_id(payload_json)
        mid = owner.get(cid) if cid else None
        if mid:
            groups.setdefault(mid, []).append((order_seq, cid))
    for mid, seen in groups.items():
        idx = {tid: i for i, tid in enumerate(order[mid])}
        prev_idx = -1
        prev_cid = None
        for order_seq, cid in seen:
            i = idx.get(cid)
            if i is None:
                continue
            if i < prev_idx:
                inversions.append((order_seq, cid, prev_idx, prev_cid))
            prev_idx = max(prev_idx, i)
            prev_cid = cid
    return inversions


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument(
        "--db-url",
        required=True,
        help=(
            "postgresql+asyncpg:// DSN of the target database. Never hardcode a "
            "credential here; pass it in (env var, secret store, or shell)."
        ),
    )
    args = ap.parse_args()
    inv = await run(args.session, args.db_url)
    print(f"{args.session}: {len(inv)} inversion(s)")
    for order_seq, cid, prev_idx, prev_cid in inv:
        print(f"  order_seq={order_seq} ({cid}) ordered after index {prev_idx} ({prev_cid})")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
