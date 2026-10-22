from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any

from sqlalchemy import delete, insert, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from agent_server.core.models import TimelineItem
from agent_server.infra.db import timeline_items

#: Item statuses that leave an Agent card active, positively enumerated from
#: the protocol's ``TimelineStatus`` literal (core/models.py). Mirrors the
#: client's phase mapping (iOS ``SubAgentPhase.from``: ``pending``/``running``/
#: ``waiting_approval`` are the live phases; ``done``/``failed``/``cancelled``/
#: ``interrupted`` are terminal). Keep this a positive list rather than a
#: negation of the terminal set: a status a future protocol adds is then never
#: silently advertised as an active card.
_ACTIVE_AGENT_CARD_STATUSES = frozenset({"pending", "running", "waiting_approval"})


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class SqlTimelineStore:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def read(self, session_id: str) -> list[TimelineItem]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(timeline_items.c.session_id == session_id)
                    .order_by(
                        timeline_items.c.order_seq,
                        timeline_items.c.updated_seq,
                        timeline_items.c.id,
                    )
                )
            ).mappings().all()
        return [TimelineItem.model_validate_json(row["payload_json"]) for row in rows]

    async def recovery_items(
        self, session_id: str, *, limit: int = 100,
    ) -> tuple[list[TimelineItem], bool]:
        """Probe IDs first; caller holds the session revision fence."""
        async with self._engine.connect() as conn:
            ids = (await conn.execute(
                select(timeline_items.c.id)
                .where(timeline_items.c.session_id == session_id)
                .limit(limit + 1)
            )).scalars().all()
        if len(ids) > limit:
            return [], True
        items = await self.read_many(session_id, set(ids))
        items.sort(key=lambda item: (item.orderSeq, item.updatedSeq, item.id))
        return items, False

    async def replace(self, session_id: str, items: list[TimelineItem]) -> None:
        async with self._engine.begin() as conn:
            await self.replace_all(conn, session_id, items)

    async def delete_items(
        self,
        conn: AsyncConnection,
        session_id: str,
        item_ids: set[str],
    ) -> None:
        """Delete the given stable IDs inside the caller's transaction."""

        ids = list(item_ids)
        for offset in range(0, len(ids), 500):
            await conn.execute(
                delete(timeline_items).where(
                    timeline_items.c.session_id == session_id,
                    timeline_items.c.id.in_(ids[offset : offset + 500]),
                )
            )

    async def replace_all(
        self,
        conn: AsyncConnection,
        session_id: str,
        items: list[TimelineItem],
    ) -> None:
        """Replace one complete timeline inside the caller's transaction."""

        await conn.execute(
            delete(timeline_items).where(timeline_items.c.session_id == session_id)
        )
        if not items:
            return
        sorted_items = sorted(
            items,
            key=lambda value: (value.orderSeq, value.updatedSeq, value.id),
        )
        await conn.execute(
            insert(timeline_items),
            [self._row_values(item) for item in sorted_items],
        )

    async def latest_item(self, session_id: str) -> TimelineItem | None:
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    timeline_items.select()
                    .where(timeline_items.c.session_id == session_id)
                    .order_by(
                        timeline_items.c.item_time.desc(),
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                    )
                    .limit(1)
                )
            ).mappings().first()
        return TimelineItem.model_validate_json(row["payload_json"]) if row is not None else None

    async def upsert_one(self, conn: AsyncConnection, item: TimelineItem) -> None:
        """Insert-or-update a single row by composite PK (session_id, id).

        Hot path: called per streaming Codex delta. Avoids the O(N) DELETE-all
        + INSERT-all pattern that `replace()` does. The ``ON CONFLICT`` upsert
        keeps it to one row mutation.
        """
        await self.upsert_many(conn, [item])

    async def upsert_many(
        self,
        conn: AsyncConnection,
        items: list[TimelineItem],
    ) -> None:
        """Insert or update one Runtime timeline batch by stable IDs."""

        if not items:
            return
        values = [self._row_values(item) for item in items]
        stmt = pg_insert(timeline_items)
        update_cols = {
            key: stmt.excluded[key]
            for key in values[0]
            if key not in ("session_id", "id")
        }
        stmt = stmt.on_conflict_do_update(
            index_elements=["session_id", "id"],
            set_=update_cols,
            where=stmt.excluded.updated_seq >= timeline_items.c.updated_seq,
        )
        await conn.execute(stmt, values)

    async def read_one(
        self, session_id: str, item_id: str
    ) -> TimelineItem | None:
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    timeline_items.select().where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.id == item_id,
                    )
                )
            ).mappings().first()
        return TimelineItem.model_validate_json(row["payload_json"]) if row is not None else None

    async def read_many(
        self,
        session_id: str,
        item_ids: set[str],
    ) -> list[TimelineItem]:
        """Read only the rows touched by one incremental Runtime sync."""

        if not item_ids:
            return []
        rows = []
        item_id_list = list(item_ids)
        async with self._engine.connect() as conn:
            for offset in range(0, len(item_id_list), 500):
                chunk = item_id_list[offset : offset + 500]
                rows.extend(
                    (
                        await conn.execute(
                            timeline_items.select().where(
                                timeline_items.c.session_id == session_id,
                                timeline_items.c.id.in_(chunk),
                            )
                        )
                    ).mappings().all()
                )
        return [TimelineItem.model_validate_json(row["payload_json"]) for row in rows]

    async def list_since(
        self, session_id: str, *, after_seq: int, limit: int
    ) -> tuple[list[TimelineItem], bool]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.updated_seq > after_seq,
                    )
                    .order_by(timeline_items.c.updated_seq)
                    .limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        return items, has_more

    async def list_latest(
        self,
        session_id: str,
        *,
        limit: int,
        main_only: bool = False,
    ) -> tuple[list[TimelineItem], bool]:
        """The newest ``limit`` rows, oldest first.

        ``main_only`` drops subagent child rows (``parent_item_id`` set) in
        SQL, *before* the LIMIT. Filtering afterwards would let a window made
        entirely of child rows come back empty even though the session has
        main-timeline content — the exact session-open blank page this opt-in
        reader exists for.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id
        )
        if main_only:
            statement = statement.where(
                timeline_items.c.parent_item_id.is_(None)
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_before_order_seq(
        self,
        session_id: str,
        *,
        before_order_seq: int,
        limit: int,
        main_only: bool = False,
    ) -> tuple[list[TimelineItem], bool]:
        """One history page ending before ``before_order_seq``, oldest first.

        ``main_only`` has the same meaning as in ``list_latest``: child rows
        are excluded in SQL before the LIMIT, so a page is filled with main
        rows rather than a filtered subset of an arbitrary window.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id,
            timeline_items.c.order_seq < before_order_seq,
        )
        if main_only:
            statement = statement.where(
                timeline_items.c.parent_item_id.is_(None)
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_children(
        self,
        session_id: str,
        *,
        parent_item_id: str,
        before_order_seq: int | None = None,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]:
        """One page of the child rows of one Agent card, oldest first.

        Ordered by ``(order_seq, updated_seq, id)`` descending and returned
        ascending, matching the other list readers so the client can append
        pages without re-sorting. ``before_order_seq`` pages backwards through
        a card's children and, like the history reader, assumes ``order_seq``
        is unique within the session: the cursor carries only that value, so a
        row tied with the page boundary would be skipped rather than repeated.
        ``has_more`` is raised by the extra row read past ``limit``.
        """

        statement = timeline_items.select().where(
            timeline_items.c.session_id == session_id,
            timeline_items.c.parent_item_id == parent_item_id,
        )
        if before_order_seq is not None:
            statement = statement.where(
                timeline_items.c.order_seq < before_order_seq
            )
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    statement.order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    ).limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_active_agent_cards(
        self, session_id: str, *, limit: int = 20
    ) -> list[TimelineItem]:
        """The newest non-terminal Agent cards of one session, oldest first.

        P1 of the session-open coverage plan (2026-10-09): the snapshot carries
        these rows beside the timeline page, so a client knows about in-flight
        subagents even when their cards fall outside the (100-item / byte
        budget) windows and no live frame has arrived to announce them. The
        query runs against this table directly — no connector RPC — so it adds
        no first-paint round trip.

        Per-item filter. A row qualifies when its status is non-terminal —
        positively enumerated as ``pending``/``running``/``waiting_approval``,
        mirroring the client's phase mapping (iOS ``SubAgentPhase.from``: those
        three are the live phases, the other four ``TimelineStatus`` values are
        terminal) — and its payload is a tool row whose ``content.kind`` is
        ``agent_call``. Tool rows are the only candidates: every other item
        kind has no agent-card surface.

        Defensive rule (documented, not queried). A card whose *item* status is
        already terminal while its ``content.agents`` still carries a live
        entry (``running`` or the launch receipt ``async_launched`` — the
        connector's ``AGENT_TASK_LIVE_STATUSES``) is still an active card in
        theory and should be kept too: the live entry outranks the item
        status. The engine-side clamp deployed on 2026-10-09 (a terminal fold
        re-opens a card when a *started* task outranks it; stale terminal
        publishes are gated) means such a row should never reach this table.
        That assumption is flagged for red-team review: the positive status
        enumeration cannot see terminal rows, so a terminal-with-live-agents
        row that did land would stay invisible here — and to the capsule this
        query feeds — rather than being returned defensively.

        ``limit`` caps the result at the newest cards by ``order_seq``; the
        rows are returned oldest first, like every other list_* reader here.
        The cap deliberately counts cards, not raw candidate rows: the
        candidates are only the non-terminal tool rows (bounded by construction
        — history-length does not bound them), and a non-agent tool row must
        never push a card out of the list the client promises to carry.
        """

        if limit <= 0:
            return []
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.type == "tool",
                        timeline_items.c.status.in_(
                            sorted(_ACTIVE_AGENT_CARD_STATUSES)
                        ),
                    )
                    .order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    )
                )
            ).mappings().all()
        cards = [
            item
            for item in (
                TimelineItem.model_validate_json(row["payload_json"]) for row in rows
            )
            if _is_agent_call_item(item)
        ]
        cards.sort(key=lambda item: (item.orderSeq, item.updatedSeq, item.id))
        return cards[-limit:]

    def _row_values(self, item: TimelineItem) -> dict[str, Any]:
        return {
            "session_id": item.sessionId,
            "id": item.id,
            "type": item.type,
            "status": item.status,
            "role": item.role,
            "order_seq": item.orderSeq,
            "updated_seq": item.updatedSeq,
            # The Runtime native item id shared by a message's body row and its
            # reasoning rows: the repository's intra-message order invariant
            # (v2_42) groups on it. ``source`` is required, ``itemId`` optional.
            "native_item_id": item.source.itemId,
            # The Runtime native *message* id (``source.nativeMessageId``): the
            # identity a message's tool rows share, mirrored to a column (v2_43)
            # for indexed grouping. ``source`` is required, ``nativeMessageId``
            # optional — absent on rows whose Runtime does not declare it, which
            # then store NULL, exactly as ``native_item_id`` does.
            "native_message_id": item.source.nativeMessageId,
            # The Agent card this row belongs to (``content.parentItemId``),
            # mirrored to a column (v2_47) so the main-timeline window can
            # exclude child rows in SQL before LIMIT. Free-JSON content: only
            # a non-empty string counts; anything else stores NULL.
            "parent_item_id": _parent_item_id(item),
            "item_time": _item_time(item),
            "payload_json": _json_dumps(item.model_dump(exclude_none=True)),
        }


def _item_time(item: TimelineItem) -> str | None:
    values = [value for value in (item.createdAt, item.completedAt, item.updatedAt) if value]
    return max(values) if values else None


def _parent_item_id(item: TimelineItem) -> str | None:
    """The Agent card a row was emitted inside (``content.parentItemId``).

    Total by construction: a payload whose content is not a mapping has no
    parent, and only a non-empty string id counts — the same rule the migration
    backfill applies, so a row written now and one backfilled from an identical
    payload land on the same column value.
    """

    content = item.content
    if not isinstance(content, Mapping):
        return None
    value = content.get("parentItemId")
    return value if isinstance(value, str) and value else None


def _is_agent_call_item(item: TimelineItem) -> bool:
    """Whether a stored tool row renders as an Agent card.

    Same convention as the repository's task-id readers: the content is free
    JSON, and ``content.kind == "agent_call"`` is the only marker (see
    ``repositories/timeline._agent_call_task_ids``). Total by construction: a
    payload whose content is not a mapping is not a card.
    """

    content = item.content
    return isinstance(content, Mapping) and content.get("kind") == "agent_call"
