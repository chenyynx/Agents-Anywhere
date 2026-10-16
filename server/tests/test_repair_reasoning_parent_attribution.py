"""The reasoning-parent backfill un-parents the right rows, and only those.

Covers the 2026-10-14 repair
(``scripts/repair_reasoning_parent_attribution.py``) for main-agent reasoning
rows that were stamped with a background subagent's ``parentItemId``. The
script must:

  * rewrite a targeted row by removing ``parentItemId`` and advancing its
    revision + contentHash (else the server treats the write as a no-op);
  * bump ``updated_seq`` so the change supersedes the old row for a reader;
  * touch ONLY the rows whose id is in the list;
  * never touch a legitimately-parented subagent row — including the capture
    route's ``claude.subagent.system`` row, even if its id is (wrongly) listed;
  * never touch a session that has an active run unless ``--allow-active``;
  * report the count in dry-run WITHOUT writing anything;
  * be idempotent — a second run changes nothing.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest
from session_fixtures import create_session_with_project

from agent_server.core.models import TimelineItemIn
from agent_server.infra.repositories.facade import Store

_SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "repair_reasoning_parent_attribution.py"
)


def _load_script():
    spec = importlib.util.spec_from_file_location("repair_reasoning_parent", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def repair():
    return _load_script()


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def _thinking_row(
    item_id: str,
    *,
    session_id: str,
    parent: str | None,
    event: str = "claude.turn.system",
) -> TimelineItemIn:
    content: dict[str, object] = {
        "blockType": "thinking",
        "kind": "reasoning",
        "text": f"reasoning for {item_id}",
    }
    if parent is not None:
        content["parentItemId"] = parent
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "role": "system",
            "content": content,
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": item_id,
                "itemType": "thinking",
                "event": event,
                "derivedKey": "thinking",
            },
            "orderSeq": 1,
            "revision": 3,
            "contentHash": f"sha256:seed-{item_id}",
            "createdAt": "2026-10-14T00:00:00Z",
            "updatedAt": "2026-10-14T00:00:00Z",
        }
    )


async def _store_with_session(tmp_path, *, tag: str = "main"):
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
        project_name=f"P-{tag}",
    )
    return store, session


@pytest.mark.anyio
async def test_unparented_item_drops_parent_and_changes_hash(repair) -> None:
    row = _thinking_row(
        "r1", session_id="s", parent="claude_tool_card"
    ).model_validate(
        {**_thinking_row("r1", session_id="s", parent="claude_tool_card").model_dump(),
         "updatedSeq": 7}
    )
    out = repair._unparented_item(row)
    assert "parentItemId" not in out.content, "the parent must be gone"
    assert out.revision == row.revision + 1
    assert out.contentHash != row.contentHash, "hash must change or the write is a no-op"


@pytest.mark.anyio
async def test_repair_unparents_only_listed_targets(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _thinking_row("target", session_id=session.id, parent="card_a"),
                _thinking_row("also_legit_nothing", session_id=session.id, parent=None),
                # A real subagent row on the capture route, wrongly listed:
                _thinking_row(
                    "legit_capture",
                    session_id=session.id,
                    parent="card_b",
                    event="claude.subagent.system",
                ),
                # A subagent row on the in-turn route, wrongly listed (same
                # shape a mis-attributed row has — the id list is the only
                # discriminator here):
                _thinking_row("legit_inturn", session_id=session.id, parent="card_c"),
            ],
        )
        seq_before = await store.get_session_seq(session.id)

        applied = await repair.reconcile(
            store,
            ids_by_session={
                session.id: {"target", "legit_capture", "legit_inturn", "missing"}
            },
            apply=True,
        )
        # `target` and the wrongly-listed in-turn row are both un-parented
        # (indistinguishable by shape); the capture-route row is spared.
        assert applied == 2

        rows = {item.id: item for item in await store.timeline.read(session.id)}
        assert "parentItemId" not in rows["target"].content
        assert rows["target"].revision == 4
        assert not rows["also_legit_nothing"].content.get("parentItemId")
        assert rows["legit_capture"].content.get("parentItemId") == "card_b", (
            "a capture-route subagent row must never be un-parented"
        )
        assert "parentItemId" not in rows["legit_inturn"].content
        assert await store.get_session_seq(session.id) > seq_before
    finally:
        await store.close()


@pytest.mark.anyio
async def test_dry_run_writes_nothing(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[_thinking_row("target", session_id=session.id, parent="card_a")],
        )
        counted = await repair.reconcile(
            store, ids_by_session={session.id: {"target"}}, apply=False
        )
        assert counted == 1
        rows = {item.id: item for item in await store.timeline.read(session.id)}
        assert rows["target"].content.get("parentItemId") == "card_a"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_second_run_is_idempotent(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[_thinking_row("target", session_id=session.id, parent="card_a")],
        )
        ids = {session.id: {"target"}}
        first = await repair.reconcile(store, ids_by_session=ids, apply=True)
        seq_after_first = await store.get_session_seq(session.id)
        second = await repair.reconcile(store, ids_by_session=ids, apply=True)
        assert first == 1
        assert second == 0, "a repaired row no longer matches the target shape"
        assert await store.get_session_seq(session.id) == seq_after_first
    finally:
        await store.close()


@pytest.mark.anyio
async def test_active_session_is_refused(tmp_path, repair) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[_thinking_row("target", session_id=session.id, parent="card_a")],
        )
        await store.start_active_run(session_id=session.id, runtime="claude")
        refused = await repair.reconcile(
            store, ids_by_session={session.id: {"target"}}, apply=True
        )
        assert refused == 0
        allowed = await repair.reconcile(
            store,
            ids_by_session={session.id: {"target"}},
            apply=False,
            allow_active=True,
        )
        assert allowed == 1
    finally:
        await store.close()
