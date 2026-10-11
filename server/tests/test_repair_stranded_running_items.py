"""The stranded-running backfill script closes the right rows, and only those.

Covers the 2026-10-11 repair (`scripts/repair_stranded_running_items.py`) for
the thinking rows that stayed ``running`` under a gateway that dropped a
block's ``content_block_stop``. The script must:

  * rewrite every affected row to ``done`` with a fresh revision and a
    contentHash that actually changed (else the server treats it as a no-op);
  * bump ``updated_seq`` so the change supersedes the old row for any reader;
  * touch ONLY rows created before the cutoff — rows at/after the fix self-heal
    and a live turn may still be streaming into them;
  * never touch a session that has an active run;
  * report the count in dry-run WITHOUT writing anything.
"""

from __future__ import annotations

import importlib.util
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from session_fixtures import create_session_with_project

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "repair_stranded_running_items.py"


def _load_script():
    spec = importlib.util.spec_from_file_location("repair_stranded", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def repair():
    return _load_script()


def _iso(hours_ago: float) -> str:
    return (datetime.now(UTC) - timedelta(hours=hours_ago)).isoformat().replace(
        "+00:00", "Z"
    )


def _thinking_row(
    item_id: str, *, session_id: str, order_seq: int, status: str, age_hours: float
) -> TimelineItemIn:
    stamp = _iso(age_hours)
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": status,
            "role": "system",
            "content": {
                "blockType": "thinking",
                "kind": "reasoning",
                "text": f"reasoning for {item_id}",
            },
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "thinking",
                "event": "claude.turn.system",
                "derivedKey": "thinking",
            },
            "orderSeq": order_seq,
            "revision": 3,
            "contentHash": f"sha256:seed-{item_id}",
            "createdAt": stamp,
            "updatedAt": stamp,
        }
    )


async def _store_with_session(tmp_path):
    db_path = tmp_path / "repair.sqlite3"
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    return store, session


@pytest.mark.anyio
async def test_done_item_changes_hash_and_bumps_revision(repair) -> None:
    row = _thinking_row("r1", session_id="s", order_seq=1, status="running", age_hours=5)
    done = repair._done_item(row.model_validate({**row.model_dump(), "updatedSeq": 7}))
    assert done.status == "done"
    assert done.revision == row.revision + 1
    assert done.contentHash != row.contentHash, "hash must change or the write is a no-op"


@pytest.mark.anyio
async def test_backfill_closes_old_running_and_skips_new(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        cutoff = _iso(1.0)  # 1 hour ago
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _thinking_row(
                    "old", session_id=session.id, order_seq=1, status="running", age_hours=5
                ),
                _thinking_row(
                    "new", session_id=session.id, order_seq=2, status="running", age_hours=0.1
                ),
                _thinking_row(
                    "done_already",
                    session_id=session.id,
                    order_seq=3,
                    status="done",
                    age_hours=5,
                ),
            ],
        )
        seq_before = await store.get_session_seq(session.id)

        applied = await repair.reconcile_stranded(
            store, cutoff=cutoff, session_ids=[session.id], apply=True
        )
        assert applied == 1, "only the pre-cutoff running row is reconciled"

        rows = {item.id: item for item in await store.timeline.read(session.id)}
        assert rows["old"].status == "done"
        assert rows["new"].status == "running", "post-cutoff row must be untouched"
        assert rows["done_already"].status == "done"
        assert rows["old"].revision == 4
        assert rows["old"].updatedSeq > seq_before or await store.get_session_seq(
            session.id
        ) > seq_before
    finally:
        await store.close()


@pytest.mark.anyio
async def test_dry_run_writes_nothing(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _thinking_row(
                    "old", session_id=session.id, order_seq=1, status="running", age_hours=5
                )
            ],
        )
        counted = await repair.reconcile_stranded(
            store, cutoff=_iso(1.0), session_ids=[session.id], apply=False
        )
        assert counted == 1
        rows = {item.id: item for item in await store.timeline.read(session.id)}
        assert rows["old"].status == "running", "dry run must not write"
    finally:
        await store.close()
