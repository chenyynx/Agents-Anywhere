#!/usr/bin/env python3
"""Diff a Claude history rebuild against the rows the Server stores.

Read-only diagnostic for the "a rebuild rewrites hundreds of rows" class
(2026-11-22: a recovery snapshot replaced a 526-row window because the
post-turn sync's delta exceeded the Server's 3 MiB recovery budget).

It runs the connector's own history reader over the real transcript and
compares the result with an exported snapshot of `timeline_items`:

    # 1. Export the stored rows (main rows; children are counted separately).
    sudo docker exec moonveil-cloud-postgres-1 psql -U moonveil -d moonveil \
      -At -F $'\t' -c "select id, order_seq, type, coalesce(role,''), \
      coalesce(parent_item_id,''), coalesce(payload_json::jsonb->>'contentHash',''), \
      coalesce(payload_json::jsonb->'source'->>'turnId',''), \
      coalesce(payload_json::jsonb->'source'->>'contentBlockIndex',''), \
      coalesce(payload_json::jsonb->'source'->>'contentBlockIndexSource','') \
      from timeline_items where session_id='sess_...' order by order_seq;" \
      > /tmp/rows.tsv

    # 2. Run with the connector venv.
    connector/.venv/bin/python connector/devtools/claude_sync_diff.py \
      --session sess_... --external <claude-session-uuid> --rows /tmp/rows.tsv

The comparison follows the Server's own rules: a differing content hash, a
declared differing turn id, a declared content-block index (and its source)
or a different relative order each count as a change.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter

from connector.runtime_protocol import RuntimeConfig
from connector.runtimes.claude import discovery
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.reader import ClaudeSessionReader
from connector.runtimes.claude.sessions.subagent_oracle import ClaudeSubagentOracle
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore


class _Host:
    async def sync_state_read(self, key: str):
        return None

    async def sync_state_write(self, key: str, value) -> None:
        return None


async def _snapshot(session_id: str, external_session_id: str):
    reader = ClaudeSessionReader(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=_Host(),
        session_store=ClaudeSessionStore({}),
        sdk_loader=discovery.load_claude_sdk,
        sync_states=ClaudeSessionSyncStateStore(_Host()),
        pending_messages=ClaudePendingClientMessageRegistry(connector_id="sync-diff"),
        oracle=ClaudeSubagentOracle(),
    )
    return await reader.get_session_snapshot(session_id, external_session_id)


def _load_rows(path: str) -> dict[str, dict[str, object]]:
    rows: dict[str, dict[str, object]] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 9:
                continue
            (item_id, order, item_type, role, parent, content_hash,
             turn_id, block_index, block_index_source) = parts[:9]
            rows[item_id] = {
                "order": int(order),
                "type": item_type,
                "role": role,
                "parent": parent,
                "hash": content_hash,
                "turnId": turn_id,
                "cbi": block_index,
                "cbis": block_index_source,
            }
    return rows


def _report(snapshot_items, rows: dict[str, dict[str, object]]) -> dict[str, object]:
    snap = {
        item.id: {
            "order": item.order_seq,
            "hash": item.content_hash,
            "turnId": item.source.get("turnId") if isinstance(item.source, dict) else None,
            "cbi": item.source.get("contentBlockIndex") if isinstance(item.source, dict) else None,
            "cbis": item.source.get("contentBlockIndexSource") if isinstance(item.source, dict) else None,
        }
        for item in snapshot_items
    }
    snapshot_ids = set(snap)
    stored_ids = set(rows)
    common = snapshot_ids & stored_ids
    main_common = [item_id for item_id in common if not rows[item_id]["parent"]]

    def same(left, right) -> bool:
        return (left or "") == (right or "")

    hash_diff = [i for i in common if snap[i]["hash"] != rows[i]["hash"]]
    turn_diff = [i for i in common if not same(snap[i]["turnId"], rows[i]["turnId"])]
    cbi_diff = [
        i for i in common
        if snap[i]["cbi"] is not None and not same(snap[i]["cbi"], rows[i]["cbi"])
    ]
    cbis_diff = [
        i for i in common
        if snap[i]["cbis"] == "message" and rows[i]["cbis"] != "message"
    ]
    snapshot_order = sorted(main_common, key=lambda i: snap[i]["order"])
    stored_order = sorted(main_common, key=lambda i: rows[i]["order"])
    position = {item_id: n for n, item_id in enumerate(stored_order)}
    order_mismatch = [
        item_id for n, item_id in enumerate(snapshot_order)
        if position[item_id] != n
    ]
    turn_pairs = Counter(
        (rows[i]["turnId"], snap[i]["turnId"]) for i in turn_diff
    )
    return {
        "snapshot_items": len(snapshot_items),
        "stored_rows": len(rows),
        "stored_main_rows": sum(1 for row in rows.values() if not row["parent"]),
        "stored_child_rows": sum(1 for row in rows.values() if row["parent"]),
        "common_ids": len(common),
        "only_snapshot": len(snapshot_ids - stored_ids),
        "only_stored": len(stored_ids - snapshot_ids),
        "content_hash_diff": len(hash_diff),
        "turn_id_diff": len(turn_diff),
        "turn_id_pairs": len(turn_pairs),
        "content_block_index_diff": len(cbi_diff),
        "content_block_index_source_diff": len(cbis_diff),
        "order_position_diff": len(order_mismatch),
        "samples": {
            "only_snapshot": sorted(snapshot_ids - stored_ids)[:5],
            "only_stored": sorted(stored_ids - snapshot_ids)[:5],
            "content_hash": hash_diff[:5],
            "turn_id": turn_diff[:5],
            "order": order_mismatch[:5],
            "turn_id_pairs_top": [
                {"stored": stored, "history": history, "rows": count}
                for (stored, history), count in turn_pairs.most_common(5)
            ],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True, help="AA session id (sess_...)")
    parser.add_argument("--external", required=True, help="Claude session uuid")
    parser.add_argument("--rows", required=True, help="TSV exported from timeline_items")
    parser.add_argument("--json-out", help="write the full report (and the snapshot) here")
    args = parser.parse_args()

    snapshot = asyncio.run(_snapshot(args.session, args.external))
    report = _report(snapshot.items, _load_rows(args.rows))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "report": report,
                    "snapshot": [
                        {
                            "id": item.id, "order": item.order_seq,
                            "type": item.type, "role": item.role,
                            "status": item.status, "hash": item.content_hash,
                            "source": item.source,
                        }
                        for item in snapshot.items
                    ],
                },
                handle, ensure_ascii=False,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
