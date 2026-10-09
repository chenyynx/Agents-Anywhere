from __future__ import annotations

import hashlib
import json
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from typing import Any

from loguru import logger
from sqlalchemy import case, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncConnection

from agent_server.core.models import SessionView, TimelineItem, TimelineItemIn
from agent_server.core.protocol import PROTOCOL_MAX_REVISION
from agent_server.core.timeline import (
    TimelineBatchWriteResult,
    TimelineItemWriteResult,
    latest_timeline_items_by_id,
    next_timeline_item_revision,
    timeline_item_content_hash,
    timeline_item_from_runtime_input,
    timeline_item_from_snapshot,
    timeline_item_state_is_unchanged,
    timeline_snapshot_is_unchanged,
)
from agent_server.core.utc import utc_now
from agent_server.infra.db import session_active_runs as active_runs_t
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.db import timeline_items as timeline_items_t
from agent_server.infra.db.engine import SQLITE_BACKEND
from agent_server.infra.repositories.store_support import session_revision_fenced

# One shared "the janitor proved nothing is due here" answer. ``changed=False``
# is what lets the publish layer skip a session-only envelope for a sweep that
# touched no row, exactly like an unchanged sync batch.
_JANITOR_NO_CHANGE = TimelineBatchWriteResult(items=(), changed=False)


class TimelineRepositoryMixin:
    async def reserve_timeline_sequence(
        self,
        *,
        session_id: str,
        mark_read_on_change: bool = False,
    ) -> int:
        """Reserve one session revision without writing a timeline row.

        The realtime ingest path uses this small atomic update before it pushes an
        item.  The comparatively expensive timeline row write can then be
        coalesced without changing the sequence already observed by clients.
        """

        async with self._timeline_lock(session_id), self._engine.begin() as conn:
            return await self._bump_session(
                conn,
                session_id,
                mark_read=mark_read_on_change,
            )

    async def lease_session_revision_range(
        self,
        *,
        session_id: str,
        count: int,
    ) -> tuple[int, int]:
        """Durably lease revisions for a low-latency Redis live counter.

        Leasing advances only the internal allocation high-water mark. The
        public ``sessions.seq`` cursor advances later, in the same transaction
        that materializes the buffered timeline projection.
        """

        if count <= 0:
            raise ValueError("session revision lease count must be positive")
        async with self._timeline_lock(session_id), self._engine.begin() as conn:
            allocated_floor = case(
                (
                    sessions_t.c.seq_allocated_high < sessions_t.c.seq,
                    sessions_t.c.seq,
                ),
                else_=sessions_t.c.seq_allocated_high,
            )
            leased_high = allocated_floor + count
            row = (
                await conn.execute(
                    update(sessions_t)
                    .where(
                        sessions_t.c.id == session_id,
                        allocated_floor <= PROTOCOL_MAX_REVISION - count,
                    )
                    .values(seq_allocated_high=leased_high)
                    .returning(sessions_t.c.seq_allocated_high)
                )
            ).first()
            if row is None:
                exists = (
                    await conn.execute(
                        select(sessions_t.c.id).where(sessions_t.c.id == session_id)
                    )
                ).first()
                if exists is None:
                    raise KeyError(session_id)
                raise OverflowError("session revision lease exceeds protocol limit")
        end = int(row.seq_allocated_high)
        return end - count + 1, end

    async def get_max_timeline_order_seq(self, session_id: str) -> int:
        async with self._timeline_lock(session_id), self._engine.connect() as conn:
            return await self._max_timeline_order_seq(conn, session_id)

    async def persist_buffered_timeline_items(
        self,
        *,
        session_id: str,
        items: list[TimelineItem],
        source_observed_at: str | None = None,
        mark_read_on_change: bool = False,
    ) -> TimelineBatchWriteResult:
        """Persist pre-sequenced realtime items without allocating new revisions.

        A complete snapshot is a reset fence.  Buffered items accepted before
        that fence must not be able to reintroduce rows removed by the snapshot.
        Older delayed writes are also ignored when a newer value for the same ID
        is already durable (for example after two server instances race to
        flush the same shared buffer).
        """

        incoming_by_id = {
            item.id: item for item in sorted(items, key=lambda value: value.updatedSeq)
        }
        async with self._timeline_lock(session_id):
            current_items = await self.timeline.read_many(
                session_id,
                set(incoming_by_id),
            )
            current_by_id = {item.id: item for item in current_items}
            async with self._engine.begin() as conn:
                row = (
                    await conn.execute(
                        select(
                            sessions_t.c.timeline_reset_seq,
                            sessions_t.c.seq,
                            sessions_t.c.last_read_seq,
                            sessions_t.c.latest_turn_end_seq,
                        ).where(sessions_t.c.id == session_id)
                    )
                ).first()
                if row is None:
                    raise KeyError(session_id)
                timeline_reset_seq = int(row.timeline_reset_seq or 0)
                persistable_items = [
                    item
                    for item in incoming_by_id.values()
                    if item.updatedSeq > timeline_reset_seq
                    and (
                        (existing := current_by_id.get(item.id)) is None
                        or item.updatedSeq >= existing.updatedSeq
                    )
                ]
                changed_items = [
                    item
                    for item in persistable_items
                    if (
                        (existing := current_by_id.get(item.id)) is None
                        or item.updatedSeq > existing.updatedSeq
                        or (
                            item.updatedSeq == existing.updatedSeq
                            and item.model_dump() != existing.model_dump()
                        )
                    )
                ]
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                await self.timeline.upsert_many(conn, changed_items)
                accepted_watermark = max(
                    [int(row.seq)]
                    + [item.updatedSeq for item in incoming_by_id.values()]
                )
                if accepted_watermark > int(row.seq):
                    session_values: dict[str, Any] = {
                        "seq": accepted_watermark,
                        "updated_seq": accepted_watermark,
                        "updated_at": utc_now(),
                    }
                    if mark_read_on_change and int(row.latest_turn_end_seq or 0) <= int(
                        row.last_read_seq or 0
                    ):
                        session_values["last_read_seq"] = accepted_watermark
                    await conn.execute(
                        update(sessions_t)
                        .where(sessions_t.c.id == session_id)
                        .values(**session_values)
                    )
        return TimelineBatchWriteResult(
            items=tuple(persistable_items),
            changed=bool(changed_items),
        )

    @session_revision_fenced
    async def sync_timeline_items(
        self,
        *,
        session_id: str,
        items: list[TimelineItemIn],
        source_observed_at: str | None = None,
        mark_read_on_change: bool = False,
        prune_orphan_agent_calls: bool = False,
    ) -> TimelineBatchWriteResult:
        """Apply a Runtime-owned incremental timeline batch by stable item ID.

        Side effects:
        - updates source observation time when supplied
        - inserts or updates only IDs present in this batch
        - reserves one consecutive session revision per changed item
        - ``prune_orphan_agent_calls`` additionally removes agent-call card
          rows the batch does not cover, when every task they name is covered
          by the batch itself (a full-history rebuild superseding older
          projection generations; see ``_prune_orphan_agent_call_rows``)
        """

        incoming_by_id = latest_timeline_items_by_id(items)
        async with self._timeline_lock(session_id):
            current_items = await self.timeline.read_many(
                session_id,
                set(incoming_by_id),
            )
            current_by_id = {item.id: item for item in current_items}
            changed_inputs = [
                item
                for item_id, item in incoming_by_id.items()
                if (existing := current_by_id.get(item_id)) is None
                or not timeline_item_state_is_unchanged(existing, item)
            ]
            if not changed_inputs:
                if prune_orphan_agent_calls:
                    async with self._engine.begin() as conn:
                        await update_source_observed_at(
                            conn,
                            session_id=session_id,
                            source_observed_at=source_observed_at,
                        )
                        pruned = await self._prune_orphan_agent_call_rows(
                            conn,
                            session_id=session_id,
                            covered_by_id=incoming_by_id,
                        )
                        if pruned:
                            # Deletions with no item write of their own must
                            # still advance the session so a refetch reaches
                            # clients that already hold the removed rows. The
                            # bump is for the refetch only: a deletion is not
                            # content the user has now seen, so it must never
                            # consume the unread badge (R2, red-team review).
                            await self._bump_session(
                                conn,
                                session_id,
                                mark_read=False,
                            )
                else:
                    await self._update_source_observed_at(
                        session_id=session_id,
                        source_observed_at=source_observed_at,
                    )
                return TimelineBatchWriteResult(items=(), changed=False)

            now = utc_now()
            changed_items: list[TimelineItem] = []
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                max_order_seq = await self._max_timeline_order_seq(conn, session_id)
                first_updated_seq = await self._reserve_session_revisions(
                    conn,
                    session_id,
                    count=len(changed_inputs),
                    mark_read=mark_read_on_change,
                )
                for index, item in enumerate(changed_inputs):
                    existing = current_by_id.get(item.id)
                    if existing is not None:
                        order_seq = existing.orderSeq
                    elif item.orderSeq > max_order_seq:
                        order_seq = item.orderSeq
                    else:
                        order_seq = max_order_seq + 1
                    max_order_seq = max(max_order_seq, order_seq)
                    normalized = timeline_item_from_runtime_input(
                        item,
                        updated_seq=first_updated_seq + index,
                        now=now,
                        existing=existing,
                        order_seq=order_seq,
                        revision=next_timeline_item_revision(item, existing),
                    )
                    changed_items.append(normalized)
                await self.timeline.upsert_many(conn, changed_items)
                if prune_orphan_agent_calls:
                    await self._prune_orphan_agent_call_rows(
                        conn,
                        session_id=session_id,
                        covered_by_id=incoming_by_id,
                    )
        return TimelineBatchWriteResult(
            items=tuple(changed_items),
            changed=True,
        )

    async def _prune_orphan_agent_call_rows(
        self,
        conn: AsyncConnection,
        *,
        session_id: str,
        covered_by_id: Mapping[str, TimelineItemIn],
    ) -> list[str]:
        """Delete agent-call cards a full-history rebuild no longer covers.

        A rebuild republishes every card the engine still knows, so an
        agent-call row outside that set can only be a leftover of an older
        projection generation that minted ids the current one will never emit
        again (the restart-race alias twins). A leftover is pruned only when
        every task it names is covered by the batch itself: a rebuild window
        that starts after a compaction cannot reach pre-compaction cards, and
        those must keep their rows even though the batch does not cover them.
        Non-agent-call rows are never touched here — other item kinds have
        producers outside the projection (queued client messages, local
        snapshots) that a history rebuild does not speak for.

        Runs inside the caller's transaction under the session timeline lock,
        so the rows it sees are exactly the rows inside the session fence.
        """

        covered_item_ids = set(covered_by_id)
        covered_task_ids: set[str] = set()
        for item in covered_by_id.values():
            covered_task_ids.update(_agent_call_task_ids(item.content))
        if not covered_task_ids:
            return []
        row = (
            await conn.execute(
                select(sessions_t.c.seq).where(sessions_t.c.id == session_id)
            )
        ).first()
        if row is None:
            raise KeyError(session_id)
        fence = int(row[0])
        rows = (
            await conn.execute(
                select(
                    timeline_items_t.c.id,
                    timeline_items_t.c.updated_seq,
                    timeline_items_t.c.payload_json,
                ).where(
                    timeline_items_t.c.session_id == session_id,
                    timeline_items_t.c.type == "tool",
                )
            )
        ).all()
        doomed: list[str] = []
        for item_id, updated_seq, payload_json in rows:
            if item_id in covered_item_ids or int(updated_seq) > fence:
                continue
            tasks = _stored_agent_call_task_ids(payload_json)
            if not tasks or not tasks <= covered_task_ids:
                continue
            doomed.append(item_id)
        if not doomed:
            return []
        await self.timeline.delete_items(conn, session_id, set(doomed))
        logger.info(
            "Timeline rebuild pruned orphan agent cards session_id={} pruned={}",
            session_id,
            sorted(doomed),
        )
        return sorted(doomed)

    async def stale_running_tool_candidates(
        self,
        *,
        older_than: datetime,
        limit: int,
    ) -> list[tuple[str, str]]:
        """Probe for age-bounded residue: ``running`` tool rows past the bound.

        Only ``type='tool' AND status='running'`` rows are ever candidates: a
        queued message may legitimately sit ``pending`` across days and a hung
        approval may legitimately wait in ``waiting_approval``, so an age bound
        cannot tell those apart from dead residue. When source files vanish
        entirely (a wiped /tmp workspace, a rotated transcript) no connector
        rebuild can reach such a row again, so the server janitor is the only
        floor that will ever close it (``close_stale_running_tool_items``).

        The result is a probe, not a verdict: the age is only proven in
        Python over parsed timestamps (see ``_timestamp_is_older_than``), the
        SQL bound stays a deliberately generous lexical superset, and every
        guard is re-checked inside the close. Ordering by ``item_time`` walks
        the lexically oldest spellings first, so a capped sweep drains the
        stalest residue before the cap can matter.
        """

        probe_bound = _stale_probe_bound(older_than)
        async with self._engine.connect() as conn:
            rows = (
                await conn.execute(
                    select(
                        timeline_items_t.c.session_id,
                        timeline_items_t.c.id,
                        timeline_items_t.c.item_time,
                    )
                    .where(
                        timeline_items_t.c.type == "tool",
                        timeline_items_t.c.status == "running",
                        timeline_items_t.c.item_time.is_not(None),
                        timeline_items_t.c.item_time < probe_bound,
                    )
                    .order_by(timeline_items_t.c.item_time, timeline_items_t.c.id)
                    .limit(limit)
                )
            ).all()
        return [
            (session_id, item_id)
            for session_id, item_id, item_time in rows
            if _timestamp_is_older_than(item_time, older_than)
        ]

    @session_revision_fenced
    async def close_stale_running_tool_items(
        self,
        *,
        session_id: str,
        item_ids: list[str],
        older_than: datetime,
        closed_by_evidence: str,
    ) -> TimelineBatchWriteResult:
        """Close age-bounded residue rows without deleting them.

        Guards, all re-checked here under the session timeline lock and the
        caller's revision fence (the probe only narrows the set):

        - the row is still ``type='tool' AND status='running'`` and its stored
          item time is older than ``older_than`` (a queued message in
          ``pending`` or an approval in ``waiting_approval`` is never touched
          whatever its age);
        - the row has settled: ``updated_seq`` at or below the session fence
          (a higher value is an in-flight buffered write);
        - the session has no ``session_active_runs`` row — something is
          running there right now;
        - the session is fully silent: ``last_activity_at`` is missing or old
          and ``updated_at`` is old. A connector observation refreshes
          ``source_observed_at``/``source_state_at`` but neither of these, so
          a session that is still being talked about by its connector keeps
          its rows even when they look old.

        Both silence columns are read, and this writer must leave both alone:
        the revision bump below passes ``touch_updated_at=False`` precisely
        because this method is the one writer that must not count as the
        session being talked about. A janitor that stamped ``updated_at``
        with its own clock re-armed every session it healed, so any sweep
        that covered only part of a session (the candidate probe is capped
        and global) left the remainder ``running`` with nothing left to close
        it until the whole 48h bound elapsed a second time.

        Closing never deletes: ``status`` becomes ``interrupted`` (a legal
        terminal value), the embedded payload status follows, the content
        gains ``closedByEvidence``, and the state hash is recomputed with the
        canonical item-state formula — so a later Runtime push of the old
        state reads as a change and supersedes this row through the ordinary
        higher-``updated_seq`` upsert guard. The revision bump copies the
        prune precedent (``mark_read=False``): a closure is not content the
        user has now seen, so it must never consume the unread badge.

        The return type is the prune precedent's ``TimelineBatchWriteResult``
        so the revision publishes the closed rows: a bare id list reaches
        ``publish_revision_result`` as an unknown result and yields a
        session-only envelope with no items and no refetch flag, which moves
        every client's cursor past the closure without ever telling them the
        row changed.
        """

        now = utc_now()
        closed: list[TimelineItem] = []
        async with self._timeline_lock(session_id), self._engine.begin() as conn:
            session_row = (
                await conn.execute(
                    select(
                        sessions_t.c.seq,
                        sessions_t.c.last_activity_at,
                        sessions_t.c.updated_at,
                    )
                    .where(sessions_t.c.id == session_id)
                    .with_for_update()
                )
            ).first()
            if session_row is None:
                raise KeyError(session_id)
            if not _timestamp_is_older_than(
                session_row.last_activity_at,
                older_than,
                allow_missing=True,
            ):
                return _JANITOR_NO_CHANGE
            if not _timestamp_is_older_than(session_row.updated_at, older_than):
                return _JANITOR_NO_CHANGE
            active_run = (
                await conn.execute(
                    select(active_runs_t.c.session_id).where(
                        active_runs_t.c.session_id == session_id
                    )
                )
            ).first()
            if active_run is not None:
                return _JANITOR_NO_CHANGE
            fence = int(session_row.seq)
            rows = (
                await conn.execute(
                    select(
                        timeline_items_t.c.id,
                        timeline_items_t.c.type,
                        timeline_items_t.c.status,
                        timeline_items_t.c.item_time,
                        timeline_items_t.c.updated_seq,
                        timeline_items_t.c.payload_json,
                    ).where(
                        timeline_items_t.c.session_id == session_id,
                        timeline_items_t.c.id.in_(item_ids),
                    )
                )
            ).all()
            doomed = [
                TimelineItem.model_validate_json(payload_json)
                for (
                    _item_id,
                    item_type,
                    status,
                    item_time,
                    updated_seq,
                    payload_json,
                ) in rows
                if item_type == "tool"
                and status == "running"
                and int(updated_seq) <= fence
                and _timestamp_is_older_than(item_time, older_than)
            ]
            if not doomed:
                return _JANITOR_NO_CHANGE
            first_seq = await self._reserve_session_revisions(
                conn,
                session_id,
                count=len(doomed),
                touch_updated_at=False,
            )
            for index, existing in enumerate(sorted(doomed, key=lambda item: item.id)):
                content = existing.content
                if isinstance(content, Mapping):
                    content = {**content, "closedByEvidence": closed_by_evidence}
                closed.append(
                    existing.model_copy(
                        update={
                            "status": "interrupted",
                            "content": content,
                            "contentHash": timeline_item_content_hash(
                                item_type=existing.type,
                                status="interrupted",
                                role=existing.role,
                                content=content,
                            ),
                            "revision": existing.revision + 1,
                            "updatedSeq": first_seq + index,
                            "updatedAt": now,
                        }
                    )
                )
            await self.timeline.upsert_many(conn, closed)
        if closed:
            logger.info(
                "Timeline age janitor closed stale tool rows session_id={} closed={}",
                session_id,
                sorted(item.id for item in closed),
            )
        return TimelineBatchWriteResult(items=tuple(closed), changed=True)

    @session_revision_fenced
    async def replace_timeline_snapshot(
        self,
        *,
        session_id: str,
        items: list[TimelineItemIn],
        source_observed_at: str | None = None,
        mark_read_on_change: bool = False,
    ) -> TimelineBatchWriteResult:
        """Replace a timeline from a complete Runtime-owned snapshot."""

        incoming_by_id = latest_timeline_items_by_id(items)
        async with self._timeline_lock(session_id):
            current_items = await self.timeline.read(session_id)
            current_by_id = {item.id: item for item in current_items}
            if timeline_snapshot_is_unchanged(current_by_id, incoming_by_id):
                await self._update_source_observed_at(
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                return TimelineBatchWriteResult(
                    items=tuple(current_items),
                    changed=False,
                )

            now = utc_now()
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                updated_seq = await self._bump_session(
                    conn,
                    session_id,
                    mark_read=mark_read_on_change,
                )
                await conn.execute(
                    update(sessions_t)
                    .where(sessions_t.c.id == session_id)
                    .values(timeline_reset_seq=updated_seq)
                )
                normalized = [
                    timeline_item_from_snapshot(
                        item=item,
                        existing=current_by_id.get(item.id),
                        updated_seq=updated_seq,
                        now=now,
                    )
                    for item in incoming_by_id.values()
                ]
                # ``timeline_item_from_snapshot`` returns the stored row itself
                # for unchanged items, so only rebuilt rows need a write.
                # Rewriting the whole session (delete-all + insert-all) turned
                # every reconnect into a full table rewrite and left the table
                # heavily bloated.
                await self.timeline.upsert_many(
                    conn,
                    [
                        item
                        for item in normalized
                        if current_by_id.get(item.id) is not item
                    ],
                )
                await self.timeline.delete_items(
                    conn,
                    session_id,
                    set(current_by_id) - set(incoming_by_id),
                )
        return TimelineBatchWriteResult(
            items=tuple(normalized),
            changed=True,
        )

    @session_revision_fenced
    async def upsert_timeline_item(
        self,
        *,
        session_id: str,
        item: TimelineItemIn,
        source_observed_at: str | None = None,
        mark_read_on_change: bool = False,
    ) -> TimelineItemWriteResult:
        """Apply one Runtime-owned item by stable ID without scanning history."""

        async with self._timeline_lock(session_id):
            now = utc_now()
            existing = await self.timeline.read_one(session_id, item.id)
            unchanged = existing is not None and timeline_item_state_is_unchanged(
                existing, item
            )
            if unchanged and source_observed_at is None:
                return TimelineItemWriteResult(item=existing, changed=False)
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                if unchanged:
                    result = existing
                else:
                    updated_seq = await self._bump_session(
                        conn,
                        session_id,
                        mark_read=mark_read_on_change,
                    )
                    order_seq = await self._live_order_seq_for_upsert(
                        conn,
                        session_id,
                        existing,
                    )
                    result = timeline_item_from_runtime_input(
                        item,
                        updated_seq=updated_seq,
                        now=now,
                        existing=existing,
                        order_seq=order_seq,
                        revision=next_timeline_item_revision(item, existing),
                    )
                    await self.timeline.upsert_one(conn, result)
        return TimelineItemWriteResult(item=result, changed=not unchanged)

    async def list_timeline_since(
        self,
        *,
        session_id: str,
        after_seq: int,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]:
        return await self.timeline.list_since(
            session_id,
            after_seq=after_seq,
            limit=limit,
        )

    async def get_timeline_reset_seq(self, session_id: str) -> int:
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    select(sessions_t.c.timeline_reset_seq).where(
                        sessions_t.c.id == session_id
                    )
                )
            ).first()
        if row is None:
            raise KeyError(session_id)
        return int(row.timeline_reset_seq or 0)

    async def list_timeline_latest(
        self,
        *,
        session_id: str,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]:
        return await self.timeline.list_latest(session_id, limit=limit)

    async def list_timeline_before_order_seq(
        self,
        *,
        session_id: str,
        before_order_seq: int,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]:
        return await self.timeline.list_before_order_seq(
            session_id,
            before_order_seq=before_order_seq,
            limit=limit,
        )

    @session_revision_fenced
    async def record_session_turn_end(
        self,
        *,
        session_id: str,
        source_observed_at: str | None = None,
        mark_read_on_change: bool = False,
    ) -> SessionView:
        async with self._timeline_lock(session_id):
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                updated_seq = await self._bump_session(
                    conn,
                    session_id,
                    mark_read=mark_read_on_change,
                )
                await conn.execute(
                    update(sessions_t)
                    .where(sessions_t.c.id == session_id)
                    .values(latest_turn_end_seq=updated_seq)
                )
        return await self.get_session(session_id)

    @asynccontextmanager
    async def timeline_writer_lock(self, session_id: str) -> AsyncIterator[None]:
        async with self._timeline_lock(session_id):
            yield

    async def _update_source_observed_at(
        self,
        *,
        session_id: str,
        source_observed_at: str | None,
    ) -> None:
        if source_observed_at is None:
            return
        async with self._engine.begin() as conn:
            await update_source_observed_at(
                conn,
                session_id=session_id,
                source_observed_at=source_observed_at,
            )

    async def _bump_session(
        self,
        conn: AsyncConnection,
        session_id: str,
        *,
        mark_read: bool = False,
    ) -> int:
        return await self._reserve_session_revisions(
            conn,
            session_id,
            count=1,
            mark_read=mark_read,
        )

    async def _reserve_session_revisions(
        self,
        conn: AsyncConnection,
        session_id: str,
        *,
        count: int,
        mark_read: bool = False,
        touch_updated_at: bool = True,
    ) -> int:
        """Reserve a consecutive revision range with one session update.

        ``touch_updated_at=False`` keeps ``sessions.updated_at`` where it was.
        That column is the "this session was written" activity signal the
        age janitor's silence guard reads, so a maintenance writer that only
        records its own repair must not refresh it — otherwise the janitor
        re-arms every session it just healed and a sweep that covers only part
        of a session strands the rest until the bound elapses a second time.
        """

        if count <= 0:
            raise ValueError("timeline revision count must be positive")
        current = (
            await conn.execute(
                select(
                    sessions_t.c.seq,
                    sessions_t.c.seq_allocated_high,
                )
                .where(sessions_t.c.id == session_id)
                .with_for_update()
            )
        ).first()
        if current is None:
            raise KeyError(session_id)
        current_seq = int(current.seq)
        expected_high = int(current.seq_allocated_high)
        allocated_floor = max(current_seq, expected_high)
        if allocated_floor > PROTOCOL_MAX_REVISION - count:
            raise OverflowError("session revision exceeds the protocol limit")

        # Retire the active Redis lease only after this transaction owns the
        # session row. If the Redis lock is replaced before sealing, the guard
        # fails and this transaction cannot publish a stale durable revision.
        # If replacement happens after sealing, the next allocator must wait on
        # this row before it can lease a higher range.
        await self.seal_session_revision_range(session_id, allocated_floor)
        next_seq = allocated_floor + count
        values: dict[str, Any] = {
            "seq": next_seq,
            "updated_seq": next_seq,
            "seq_allocated_high": next_seq,
        }
        if touch_updated_at:
            values["updated_at"] = utc_now()
        if mark_read:
            values["last_read_seq"] = case(
                (
                    sessions_t.c.latest_turn_end_seq <= sessions_t.c.last_read_seq,
                    next_seq,
                ),
                else_=sessions_t.c.last_read_seq,
            )
        row = (
            await conn.execute(
                update(sessions_t)
                .where(
                    sessions_t.c.id == session_id,
                    sessions_t.c.seq_allocated_high == expected_high,
                )
                .values(**values)
                .returning(sessions_t.c.seq)
            )
        ).first()
        if row is None:
            raise RuntimeError("session revision allocation fence changed")
        return int(row.seq) - count + 1

    async def _max_timeline_order_seq(
        self,
        conn: AsyncConnection,
        session_id: str,
    ) -> int:
        row = (
            await conn.execute(
                select(func.max(timeline_items_t.c.order_seq)).where(
                    timeline_items_t.c.session_id == session_id
                )
            )
        ).first()
        return int(row[0] or 0) if row is not None else 0

    async def _live_order_seq_for_upsert(
        self,
        conn: AsyncConnection,
        session_id: str,
        existing: TimelineItem | None,
    ) -> int:
        if existing is not None:
            return existing.orderSeq
        return await self._max_timeline_order_seq(conn, session_id) + 1

    @asynccontextmanager
    async def _timeline_lock(self, session_id: str) -> AsyncIterator[None]:
        """Serialize concurrent writers for one session timeline."""

        if self.backend == SQLITE_BACKEND:
            lock = await self.timeline_lock(session_id)
            async with lock:
                yield
            return

        lock_key = session_timeline_lock_key(session_id)
        async with self._engine.connect() as conn:
            await conn.execute(text("SELECT pg_advisory_lock(:k)"), {"k": lock_key})
            try:
                yield
            finally:
                try:
                    await conn.execute(
                        text("SELECT pg_advisory_unlock(:k)"),
                        {"k": lock_key},
                    )
                except Exception:  # noqa: BLE001, S110
                    pass


# The age-probe bound sits this far past the real cutoff. It must exceed any
# real-world ISO-8601 spelling skew (timezone offsets go up to 14h, plus
# sub-second fraction spellings), so the SQL probe cannot miss a stale row
# whose offset spelling sorts after the cutoff string. Rows inside this band
# ride along and are dropped by the exact parsed comparison.
_STALE_PROBE_MARGIN_HOURS = 15


def _stale_probe_bound(older_than: datetime) -> str:
    """Lexical superset bound for stored ``item_time`` strings.

    ``item_time`` values are ISO-8601 strings; comparing them against a
    chronologically formatted cutoff would be wrong across the ``Z`` and
    ``+00:00`` spellings and across non-UTC offsets, so the SQL probe only
    narrows the candidate set and ``_timestamp_is_older_than`` proves the age.
    """

    bound = older_than + timedelta(hours=_STALE_PROBE_MARGIN_HOURS)
    return bound.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S")


def _parse_utc_timestamp(value: str | None) -> datetime | None:
    """Parse one stored ISO-8601 timestamp; ``None`` when unparsable."""

    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed


def _timestamp_is_older_than(
    value: str | None,
    older_than: datetime,
    *,
    allow_missing: bool = False,
) -> bool:
    """True only when ``value`` parses and sits before ``older_than``.

    A missing value follows ``allow_missing`` (a session that never recorded
    activity is silent); an unparsable value is never treated as old — the
    janitor must never close a row whose age it cannot actually read.
    """

    if not value:
        return allow_missing
    parsed = _parse_utc_timestamp(value)
    if parsed is None:
        return False
    return parsed < older_than


async def update_source_observed_at(
    conn: AsyncConnection,
    *,
    session_id: str,
    source_observed_at: str | None,
) -> None:
    if source_observed_at is None:
        return
    await conn.execute(
        update(sessions_t)
        .where(sessions_t.c.id == session_id)
        .values(source_observed_at=source_observed_at)
    )


def session_timeline_lock_key(session_id: str) -> int:
    """Hash a session ID into a signed 64-bit PostgreSQL advisory lock key."""

    digest = hashlib.sha256(session_id.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big", signed=True)


def _agent_call_task_ids(content: Any) -> set[str]:
    """The task ids an agent-call content names; empty for every other item."""

    if not isinstance(content, Mapping) or content.get("kind") != "agent_call":
        return set()
    agents = content.get("agents")
    if not isinstance(agents, Mapping):
        return set()
    return {key for key in agents if isinstance(key, str) and key}


def _stored_agent_call_task_ids(payload_json: str) -> set[str]:
    """The task ids a stored timeline row names; empty for non-agent rows.

    Total by construction: a row whose payload cannot be read as an
    agent-call content yields the empty set, and the empty set never prunes.
    """

    try:
        payload = json.loads(payload_json)
    except (TypeError, ValueError):
        return set()
    if not isinstance(payload, dict):
        return set()
    return _agent_call_task_ids(payload.get("content"))
