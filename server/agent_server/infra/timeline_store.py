from __future__ import annotations

import json
from collections.abc import Callable, Mapping
from typing import Any

from sqlalchemy import delete, insert, select, tuple_
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from agent_server.core.models import TimelineItem
from agent_server.core.timeline import (
    agent_child_parent_item_id,
    timeline_item_json_bytes,
)
from agent_server.infra.db import timeline_items
from agent_server.infra.db.engine import SQLITE_BACKEND

#: Item statuses that leave an Agent card active, positively enumerated from
#: the protocol's ``TimelineStatus`` literal (core/models.py). Mirrors the
#: client's phase mapping (iOS ``SubAgentPhase.from``: ``pending``/``running``/
#: ``waiting_approval`` are the live phases; ``done``/``failed``/``cancelled``/
#: ``interrupted`` are terminal). Keep this a positive list rather than a
#: negation of the terminal set: a status a future protocol adds is then never
#: silently advertised as an active card.
_ACTIVE_AGENT_CARD_STATUSES = frozenset({"pending", "running", "waiting_approval"})

#: Filtered page reads (subagent-internal row exclusion, per-card children)
#: judge ``content.parentItemId`` in Python, so reaching ``limit + 1``
#: eligible rows can require walking past many ineligible ones — in
#: production the children are up to ~3/4 of a heavy session's rows. One
#: scan step therefore over-fetches four probe windows, which keeps a usual
#: page inside a single fetch without ever widening the returned set.
_PAGE_SCAN_BATCH_MULTIPLIER = 4


def _json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _agent_child_payload_needle(parent_item_id: str) -> str:
    """The compact-JSON pair every child row of ``parent_item_id`` carries.

    Stored payloads are always serialized by ``_json_dumps`` (compact
    separators, ``ensure_ascii=False``), so a row whose parsed
    ``content.parentItemId`` equals the ID contains this exact
    ``"parentItemId":"<id>"`` text verbatim — the substring the existence
    probe matches without parsing any JSON. Serializing the pair with the
    same json options guarantees the needle's escaping matches the stored
    payload byte for byte.
    """

    pair = json.dumps(
        {"parentItemId": parent_item_id},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return pair[1:-1]


class SqlTimelineStore:
    def __init__(self, engine: AsyncEngine, *, backend: str = SQLITE_BACKEND) -> None:
        self._engine = engine
        self._backend = backend

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
        + INSERT-all pattern that `replace()` does. The dialect-specific
        upsert keeps it to one row mutation.
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
        if self._backend == SQLITE_BACKEND:
            stmt = sqlite_insert(timeline_items)
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
        else:
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

    async def list_latest(self, session_id: str, *, limit: int) -> tuple[list[TimelineItem], bool]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(timeline_items.c.session_id == session_id)
                    .order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    )
                    .limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_before_order_seq(
        self, session_id: str, *, before_order_seq: int, limit: int
    ) -> tuple[list[TimelineItem], bool]:
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    timeline_items.select()
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.order_seq < before_order_seq,
                    )
                    .order_by(
                        timeline_items.c.order_seq.desc(),
                        timeline_items.c.updated_seq.desc(),
                        timeline_items.c.id.desc(),
                    )
                    .limit(limit + 1)
                )
            ).mappings().all()
        has_more = len(rows) > limit
        items = [TimelineItem.model_validate_json(row["payload_json"]) for row in rows[:limit]]
        items.reverse()
        return items, has_more

    async def list_latest_excluding_agent_children(
        self,
        session_id: str,
        *,
        limit: int,
        byte_budget: int | None = None,
    ) -> tuple[list[TimelineItem], bool]:
        """The newest conversation-view page: subagent-internal rows dropped.

        Same shape as ``list_latest`` (oldest-first items, ``hasMore`` over
        the returned collection), except rows whose ``content.parentItemId``
        is a non-empty string — the rows the client folds under an Agent card
        — do not occupy the window. ``hasMore`` is computed over the filtered
        rows: an older eligible row exists exactly when a client must page
        back further. ``byte_budget`` optionally caps the page's serialized
        size; the snapshot caller leaves it unset because it applies its own
        aggregate budget to the returned page.
        """

        return await self._scan_page(
            session_id,
            limit=limit,
            byte_budget=byte_budget,
            before_order_seq=None,
            include=_is_not_agent_child,
        )

    async def list_before_order_seq_excluding_agent_children(
        self,
        session_id: str,
        *,
        before_order_seq: int,
        limit: int,
        byte_budget: int | None = None,
    ) -> tuple[list[TimelineItem], bool]:
        """One conversation-view history page, newest→oldest paging.

        The excluding sibling of ``list_before_order_seq``: the returned page
        is the newest ``limit`` subagent-internal-free rows older than
        ``before_order_seq``, and ``hasMore``/cursor semantics follow the
        filtered collection, so a page that is empty in raw rows but has
        older content behind it still pages correctly.
        """

        return await self._scan_page(
            session_id,
            limit=limit,
            byte_budget=byte_budget,
            before_order_seq=before_order_seq,
            include=_is_not_agent_child,
        )

    async def list_agent_children(
        self,
        session_id: str,
        *,
        parent_item_id: str,
        before_order_seq: int | None,
        limit: int,
        byte_budget: int | None = None,
    ) -> tuple[list[TimelineItem], bool]:
        """One page of a single card's own subagent-internal rows.

        Returns the newest ``limit`` rows whose ``content.parentItemId``
        equals ``parent_item_id``, newest→oldest paging like history
        (``before_order_seq`` is the exclusive cursor; ``None`` starts at the
        newest row). Rows of any other card — and every non-child row — are
        never returned; rows of other sessions cannot match because the scan
        is session-scoped.

        A cheap existence probe runs first: a parent with no child rows at
        all — the common case for the client only when it asks about a card
        that has none — returns an empty exhausted page without paying for
        the filtered full scan.
        """

        if not await self._agent_children_exist(session_id, parent_item_id):
            return [], False

        def include(item: TimelineItem) -> bool:
            return agent_child_parent_item_id(item) == parent_item_id

        return await self._scan_page(
            session_id,
            limit=limit,
            byte_budget=byte_budget,
            before_order_seq=before_order_seq,
            include=include,
        )

    async def _agent_children_exist(
        self, session_id: str, parent_item_id: str
    ) -> bool:
        """Whether any stored row looks like a child of ``parent_item_id``.

        One ``LIMIT 1`` substring match over ``payload_json`` — no payload is
        JSON-parsed, so a miss costs a fraction of the filtered scan. The
        LIKE pattern is escaped (``%``/``_``/``\\`` match literally), so the
        probe only widens at worst: a false positive (the needle happens to
        appear in unrelated payload text, e.g. inside some tool output) sends
        the caller through the scan it would have run anyway and cannot
        change the result; a false negative cannot occur for rows this store
        writes, because every payload is serialized compactly with the
        literal pair inlined (see ``_agent_child_payload_needle``), so a
        parent that does have children always probes positive.
        """

        needle = _agent_child_payload_needle(parent_item_id)
        escaped = (
            needle.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        )
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    select(timeline_items.c.id)
                    .where(
                        timeline_items.c.session_id == session_id,
                        timeline_items.c.payload_json.like(
                            f"%{escaped}%", escape="\\"
                        ),
                    )
                    .limit(1)
                )
            ).first()
        return row is not None

    async def _scan_page(
        self,
        session_id: str,
        *,
        limit: int,
        byte_budget: int | None,
        before_order_seq: int | None,
        include: Callable[[TimelineItem], bool],
    ) -> tuple[list[TimelineItem], bool]:
        """Read one newest→oldest page over the rows ``include`` accepts.

        Raw rows are walked newest-first in keyset-paginated windows and the
        filtered rows accumulate until either gate trips:

        - the page already holds ``limit`` rows and one more eligible row
          exists (the count probe — that row must stay reachable through the
          next page, so ``hasMore`` is true and the page's oldest item is the
          correct cursor);
        - adding the next eligible row would exceed ``byte_budget`` (a page
          never serializes past the budget; at least one row is always kept,
          so a single oversized row is returned whole rather than split).

        ``hasMore`` is computed over the *filtered* collection, never the raw
        rows: a whole window of excluded rows never ends the walk, and an
        empty result means the filtered timeline is genuinely exhausted
        (``hasMore`` false), so no client is ever handed an empty page with
        more content behind it. Items come back oldest-first, like every
        other ``list_*`` reader here.
        """

        page: list[TimelineItem] = []  # newest-first while accumulating
        page_bytes = 0
        has_more = False
        cursor: tuple[int, int, str] | None = None
        batch = (limit + 1) * _PAGE_SCAN_BATCH_MULTIPLIER
        while True:
            async with self._engine.connect() as conn:
                statement = timeline_items.select().where(
                    timeline_items.c.session_id == session_id
                )
                if before_order_seq is not None:
                    statement = statement.where(
                        timeline_items.c.order_seq < before_order_seq
                    )
                if cursor is not None:
                    statement = statement.where(
                        tuple_(
                            timeline_items.c.order_seq,
                            timeline_items.c.updated_seq,
                            timeline_items.c.id,
                        )
                        < cursor
                    )
                rows = (
                    await conn.execute(
                        statement.order_by(
                            timeline_items.c.order_seq.desc(),
                            timeline_items.c.updated_seq.desc(),
                            timeline_items.c.id.desc(),
                        ).limit(batch)
                    )
                ).mappings().all()
            if not rows:
                break
            exhausted = len(rows) < batch
            stop = False
            for row in rows:
                item = TimelineItem.model_validate_json(row["payload_json"])
                if not include(item):
                    continue
                if len(page) >= limit:
                    has_more = True
                    stop = True
                    break
                item_bytes = 0
                if byte_budget is not None:
                    item_bytes = timeline_item_json_bytes(item)
                    if page and page_bytes + item_bytes > byte_budget:
                        has_more = True
                        stop = True
                        break
                page.append(item)
                page_bytes += item_bytes
            if stop or exhausted:
                break
            last = rows[-1]
            cursor = (int(last.order_seq), int(last.updated_seq), str(last.id))
        page.reverse()
        return page, has_more

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
            "item_time": _item_time(item),
            "payload_json": _json_dumps(item.model_dump(exclude_none=True)),
        }


def _item_time(item: TimelineItem) -> str | None:
    values = [value for value in (item.createdAt, item.completedAt, item.updatedAt) if value]
    return max(values) if values else None


def _is_agent_child_item(item: TimelineItem) -> bool:
    """Whether a stored row is a subagent-internal row (it has a parent)."""

    return agent_child_parent_item_id(item) is not None


def _is_not_agent_child(item: TimelineItem) -> bool:
    return not _is_agent_child_item(item)


def _is_agent_call_item(item: TimelineItem) -> bool:
    """Whether a stored tool row renders as an Agent card.

    Same convention as the repository's task-id readers: the content is free
    JSON, and ``content.kind == "agent_call"`` is the only marker (see
    ``repositories/timeline._agent_call_task_ids``). Total by construction: a
    payload whose content is not a mapping is not a card.
    """

    content = item.content
    return isinstance(content, Mapping) and content.get("kind") == "agent_call"
