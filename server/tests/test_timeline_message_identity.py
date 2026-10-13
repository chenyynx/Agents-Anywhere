"""One logical message must persist as one row: live/history id convergence.

Why this file exists
--------------------
One logical assistant message can be written by two connector paths — the live
stream and a later history rebuild — that derive DIFFERENT stable item ids but
record the SAME ``source.itemId`` (the Runtime's native message id). The table's
PK is ``(session_id, id)``, so both rows persist and the client renders the
reply twice (production: 8 groups, each a ``{claude.turn.assistant,
claude.history.assistant}`` pair sharing one ``source.itemId`` but two ids).

``_converge_message_identities`` collapses such twins onto the FIRST-written id
(the canonical one — the live id the client is already rendering), rewrites an
incoming non-canonical id onto it, and reports stored duplicate rows for the
caller to delete in the same transaction. These tests pin that behaviour on
every writer path the four writers funnel through.
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import insert, select, update

from agent_server.core.models import TimelineItem, TimelineItemIn
from agent_server.core.timeline import timeline_item_from_runtime_input
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store


def message_input(
    session_id: str,
    item_id: str,
    *,
    native_item_id: str | None,
    order_seq: int,
    text: str | None = None,
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": text, "format": "markdown"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": native_item_id,
                "itemType": "assistant",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


def reasoning_input(
    session_id: str,
    item_id: str,
    *,
    native_item_id: str | None,
    order_seq: int,
    block_index: int = 0,
    text: str | None = None,
) -> TimelineItemIn:
    text = text or item_id
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "system",
            "status": "done",
            "role": "system",
            "content": {
                "kind": "reasoning",
                "blockIndex": block_index,
                "summaries": [{"index": block_index, "text": text}],
            },
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": native_item_id,
                "itemType": "thinking",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}:{text}",
        }
    )


async def _store_with_session(tmp_path: Any) -> tuple[Store, Any]:
    db_path = tmp_path / "message-identity.sqlite3"
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


async def _rows_by_id(store: Store, session_id: str) -> dict[str, Any]:
    return {item.id: item for item in await store.timeline.read(session_id)}


def _fingerprint(item: Any) -> tuple[int, int, int]:
    return (item.orderSeq, item.updatedSeq, item.revision)


async def _seed_row(
    store: Store,
    session_id: str,
    item: TimelineItemIn,
    *,
    order_seq: int,
    updated_seq: int,
) -> None:
    """Insert one row verbatim (a pre-fix row), advancing the seq counter."""

    stored = timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-10-12T00:00:00Z",
        order_seq=order_seq,
    )
    async with store.engine.begin() as conn:
        await conn.execute(
            insert(timeline_items_t),
            [store.timeline._row_values(stored)],
        )
        row = (
            await conn.execute(
                select(sessions_t.c.seq, sessions_t.c.seq_allocated_high).where(
                    sessions_t.c.id == session_id
                )
            )
        ).first()
        if row is not None:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == session_id)
                .values(
                    seq=max(int(row[0]), updated_seq),
                    seq_allocated_high=max(int(row[1]), updated_seq),
                )
            )


def _to_stored(
    store: Store, item: TimelineItemIn, *, order_seq: int, updated_seq: int
) -> TimelineItem:
    """Materialize an input as a stored TimelineItem for the buffer path."""

    _ = store
    return timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now="2026-10-12T00:00:00Z",
        order_seq=order_seq,
    )


async def _ids_with_native(
    store: Store, session_id: str, native_item_id: str
) -> list[str]:
    rows = await store.timeline.read(session_id)
    return sorted(i.id for i in rows if (i.source.itemId if i.source else None) == native_item_id)


# ---------------------------------------------------------------------------
# D1 / D2 — the core convergence, both orders of arrival.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_sync_converges_history_row_onto_a_live_row(tmp_path) -> None:
    """D1: a live row for itemId X exists; a history row with a DIFFERENT id but
    the SAME itemId X must update the live row in place, never persist an H row."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "live_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(
                    session.id, "hist_1", native_item_id="X", order_seq=9, text="hist-body"
                )
            ],
        )
        rows = await _rows_by_id(store, session.id)
        assert sorted(rows) == ["live_1"]  # exactly one row for X; hist_1 never lands
        assert rows["live_1"].content["text"] == "hist-body"  # last writer wins content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_sync_converges_live_row_onto_a_history_row_written_first(tmp_path) -> None:
    """D2: reversed arrival — the history id is stored first, so IT is canonical
    and the later live row converges onto it."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "hist_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(
                    session.id, "live_1", native_item_id="X", order_seq=2, text="live-body"
                )
            ],
        )
        rows = await _rows_by_id(store, session.id)
        assert sorted(rows) == ["hist_1"]
        assert rows["hist_1"].content["text"] == "live-body"
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D3 — healing pre-existing duplicates.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_sync_heals_preexisting_duplicate_rows(tmp_path) -> None:
    """D3: both L and H are already stored for itemId X. A write covering that
    key deletes the duplicate H and keeps only the canonical L."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "live_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "hist_1", native_item_id="X", order_seq=2),
            order_seq=2,
            updated_seq=2,
        )
        assert len(await _ids_with_native(store, session.id, "X")) == 2

        # An otherwise no-op re-write of the canonical live row is enough to
        # trigger the heal (the no-change branch still lands deletions).
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "live_1", native_item_id="X", order_seq=1)
            ],
        )
        assert await _ids_with_native(store, session.id, "X") == ["live_1"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D4 — no collateral: distinct messages / no-native-id rows are never merged.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_sync_never_merges_distinct_messages_or_native_less_rows(tmp_path) -> None:
    """D4: distinct itemIds are distinct messages; a message with no native id is
    untouched. None of them may be rewritten or deleted."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "m_x", native_item_id="X", order_seq=1),
                message_input(session.id, "m_y", native_item_id="Y", order_seq=2),
                message_input(session.id, "m_none", native_item_id=None, order_seq=3),
            ],
        )
        rows = await _rows_by_id(store, session.id)
        assert sorted(rows) == ["m_none", "m_x", "m_y"]

        # Re-writing each under a fresh id but the SAME distinct itemIds must not
        # cross-merge: each key stays a singleton and lands on its own canonical.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                message_input(session.id, "m_x2", native_item_id="X", order_seq=4),
                message_input(session.id, "m_y2", native_item_id="Y", order_seq=5),
                message_input(session.id, "m_none2", native_item_id=None, order_seq=6),
            ],
        )
        rows = await _rows_by_id(store, session.id)
        # X and Y each converge to their first id; the native-less row is a
        # distinct message by id and simply adds a second row.
        assert sorted(rows) == ["m_none", "m_none2", "m_x", "m_y"]
        assert await _ids_with_native(store, session.id, "X") == ["m_x"]
        assert await _ids_with_native(store, session.id, "Y") == ["m_y"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D5 — reasoning rows are NOT converged.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_reasoning_rows_sharing_a_native_id_all_survive(tmp_path) -> None:
    """D5: two reasoning (type='system') rows legitimately share one native id
    across blocks; they must both survive. Only message rows converge."""

    store, session = await _store_with_session(tmp_path)
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                reasoning_input(
                    session.id, "r0", native_item_id="X", order_seq=1, block_index=0
                ),
                reasoning_input(
                    session.id, "r1", native_item_id="X", order_seq=2, block_index=1
                ),
                message_input(session.id, "m1", native_item_id="X", order_seq=3),
            ],
        )
        rows = await _rows_by_id(store, session.id)
        assert sorted(rows) == ["m1", "r0", "r1"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D6 — idempotence.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_second_write_is_a_no_op(tmp_path) -> None:
    """D6: re-applying the same history write leaves one row and a byte-stable
    order across runs."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "live_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        hist = [
            message_input(
                session.id, "hist_1", native_item_id="X", order_seq=9, text="hist-body"
            )
        ]
        await store.sync_timeline_items(session_id=session.id, items=hist)
        first = sorted(
            (i.id, i.orderSeq) for i in (await store.timeline.read(session.id))
        )
        await store.sync_timeline_items(session_id=session.id, items=hist)
        second = sorted(
            (i.id, i.orderSeq) for i in (await store.timeline.read(session.id))
        )
        assert first == second == [("live_1", 1)]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D7 — the LIVE buffer path.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_live_buffer_converges_history_row_onto_a_live_row(tmp_path) -> None:
    """D7: the realtime buffer's flush (persist_buffered_timeline_items) must
    converge too — a history row with a fresh id but a shared itemId updates the
    durable live row instead of persisting a twin."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "live_1", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        hist = _to_stored(
            store,
            message_input(
                session.id, "hist_1", native_item_id="X", order_seq=2, text="hist-body"
            ),
            order_seq=2,
            updated_seq=5,
        )
        result = await store.persist_buffered_timeline_items(
            session_id=session.id,
            items=[hist],
        )
        rows = await _rows_by_id(store, session.id)
        assert sorted(rows) == ["live_1"]
        assert rows["live_1"].content["text"] == "hist-body"
        # The published push carries the canonical id, not the derived one.
        assert {i.id for i in result.items} == {"live_1"}
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# D8 — the no-duplicate fast path changes nothing.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_fast_path_is_a_true_no_op(tmp_path) -> None:
    """D8: a batch with no native-id message row does zero convergence work
    (returns the same list object), and an unrelated write leaves healthy rows
    byte-identical."""

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "keep", native_item_id="X", order_seq=1),
            order_seq=1,
            updated_seq=1,
        )
        before = {i: _fingerprint(v) for i, v in (await _rows_by_id(store, session.id)).items()}

        # No native-id message row in the batch: the helper short-circuits with
        # literally no DB work (it never touches ``conn``).
        batch = [
            message_input(session.id, "plain", native_item_id=None, order_seq=2),
            reasoning_input(session.id, "r1", native_item_id="X", order_seq=3),
        ]
        returned, deletions = await store._converge_message_identities(
            None, session.id, batch
        )
        assert returned is batch and deletions == set()

        # An unrelated write does not perturb the healthy row.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[message_input(session.id, "other", native_item_id="Y", order_seq=4)],
        )
        after = await _rows_by_id(store, session.id)
        assert _fingerprint(after["keep"]) == before["keep"]
    finally:
        await store.close()


def _role_message_input(
    session_id: str, item_id: str, *, native_item_id: str, role: str, order_seq: int
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": role,
            "content": {"text": item_id, "format": "markdown"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_1",
                "itemId": native_item_id,
                "itemType": role,
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )


@pytest.mark.anyio
async def test_rows_of_different_roles_sharing_an_item_id_are_not_merged(tmp_path) -> None:
    """The key is ``(itemId, role)``: a user turn and an assistant reply that
    happened to share a native id are different messages and must both survive.
    """

    store, session = await _store_with_session(tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            _role_message_input(
                session.id, "u1", native_item_id="X", role="user", order_seq=1
            ),
            order_seq=1,
            updated_seq=1,
        )
        await _seed_row(
            store,
            session.id,
            _role_message_input(
                session.id, "a1", native_item_id="X", role="assistant", order_seq=2
            ),
            order_seq=2,
            updated_seq=2,
        )
        # A write of the assistant row must NOT delete the user row.
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _role_message_input(
                    session.id, "a1", native_item_id="X", role="assistant", order_seq=2
                )
            ],
        )
        rows = await _rows_by_id(store, session.id)
        assert "u1" in rows and "a1" in rows
    finally:
        await store.close()
