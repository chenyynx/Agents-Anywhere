from __future__ import annotations

import hashlib
import json
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from loguru import logger
from sqlalchemy import and_, case, func, or_, select, text, update
from sqlalchemy.ext.asyncio import AsyncConnection

from agent_server.core.models import SessionView, TimelineItem, TimelineItemIn
from agent_server.core.protocol import PROTOCOL_MAX_REVISION
from agent_server.core.timeline import (
    TimelineBatchWriteResult,
    TimelineItemWriteResult,
    latest_timeline_items_by_id,
    native_item_id_from_payload,
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

    async def backfill_native_item_ids(
        self,
        *,
        batch_size: int = 1000,
        max_batches: int = 1000,
    ) -> int:
        """Refill ``native_item_id`` for rows the migration v2_42 did not cover.

        The migration backfills every row present when it ran; a row written by
        an older worker during a rolling upgrade (or a session restored from an
        old backup) can still carry NULL, and a NULL row is invisible to the
        intra-message corrector. This is idempotent and bounded — it pages by
        the ``(session_id, id)`` primary key, so a payload with no itemId cannot
        stall it — and is meant to be run best-effort at startup. Returns the
        number of rows refilled.
        """

        refilled = 0
        after_session = ""
        after_id = ""
        for _ in range(max_batches):
            async with self._engine.begin() as conn:
                rows = (
                    await conn.execute(
                        select(
                            timeline_items_t.c.session_id,
                            timeline_items_t.c.id,
                            timeline_items_t.c.payload_json,
                        )
                        .where(
                            or_(
                                timeline_items_t.c.session_id > after_session,
                                and_(
                                    timeline_items_t.c.session_id == after_session,
                                    timeline_items_t.c.id > after_id,
                                ),
                            )
                        )
                        .order_by(
                            timeline_items_t.c.session_id,
                            timeline_items_t.c.id,
                        )
                        .limit(batch_size)
                    )
                ).all()
                if not rows:
                    return refilled
                updates: list[dict[str, Any]] = []
                for session_id, item_id, payload_json in rows:
                    after_session, after_id = session_id, item_id
                    native_item_id = native_item_id_from_payload(payload_json)
                    if native_item_id is None:
                        continue
                    updates.append(
                        {
                            "native_item_id": native_item_id,
                            "session_id": session_id,
                            "id": item_id,
                        }
                    )
                if updates:
                    await conn.execute(
                        text(
                            "UPDATE timeline_items SET native_item_id = :native_item_id "
                            "WHERE session_id = :session_id AND id = :id "
                            "AND native_item_id IS NULL"
                        ),
                        updates,
                    )
                    refilled += len(updates)
        return refilled

    async def deduplicate_message_identities(
        self,
        *,
        max_groups: int = 10_000,
    ) -> int:
        """Remove stored duplicate message rows (pre-fix live/history twins).

        A write heals the twins for its own key, but a group that is never
        written again would keep both rows forever — precisely the production
        duplicates the fix is meant to remove. This one-time, idempotent sweep
        finds every ``(session_id, native_item_id, role)`` message group with
        more than one id, keeps the first-written row and deletes the rest,
        advancing each affected session so a client refetches and drops the
        removed id. Returns the number of rows removed.
        """

        removed = 0
        for _ in range(max_groups):
            session_id, native_item_id, role = await self._next_duplicate_key()
            if session_id is None:
                return removed
            # The removal runs under the same per-session timeline lock as the
            # writers, so a live write for this session cannot interleave
            # between the duplicate scan and the delete.
            async with self._timeline_lock(session_id):
                async with self._engine.begin() as conn:
                    rows = (
                        await conn.execute(
                            select(
                                timeline_items_t.c.id,
                                timeline_items_t.c.updated_seq,
                            )
                            .where(
                                timeline_items_t.c.session_id == session_id,
                                timeline_items_t.c.type == "message",
                                timeline_items_t.c.native_item_id == native_item_id,
                                timeline_items_t.c.role.is_(role)
                                if role is None
                                else timeline_items_t.c.role == role,
                            )
                            .order_by(
                                timeline_items_t.c.updated_seq,
                                timeline_items_t.c.id,
                            )
                        )
                    ).all()
                    doomed = {row_id for row_id, _ in rows[1:]}
                    if not doomed:
                        continue  # healed by a concurrent write; re-scan
                    await self.timeline.delete_items(conn, session_id, doomed)
                    await self._bump_session(conn, session_id, mark_read=False)
                    removed += len(doomed)
        return removed

    async def _next_duplicate_key(self) -> tuple[str | None, str, str | None]:
        """The next ``(session, native_item_id, role)`` message group with more
        than one stored id, or ``(None, "", None)`` when none remains."""

        async with self._engine.connect() as conn:
            group = (
                await conn.execute(
                    select(
                        timeline_items_t.c.session_id,
                        timeline_items_t.c.native_item_id,
                        timeline_items_t.c.role,
                    )
                    .where(
                        timeline_items_t.c.type == "message",
                        timeline_items_t.c.native_item_id.is_not(None),
                    )
                    .group_by(
                        timeline_items_t.c.session_id,
                        timeline_items_t.c.native_item_id,
                        timeline_items_t.c.role,
                    )
                    .having(func.count(func.distinct(timeline_items_t.c.id)) > 1)
                    .limit(1)
                )
            ).first()
        if group is None:
            return None, "", None
        return group[0], group[1], group[2]

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

        async with self._timeline_lock(session_id):
            # Converge a message's duplicate live/history ids onto the canonical
            # (first-written) id before any id-keyed math, so the read set, the
            # change detection, the published push and the durable row all speak
            # the same id.
            async with self._engine.connect() as conn:
                items, converged_deletions = await self._converge_message_identities(
                    conn,
                    session_id,
                    items,
                )
            incoming_by_id = {
                item.id: item
                for item in sorted(items, key=lambda value: value.updatedSeq)
            }
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
                if converged_deletions:
                    # Remove the converged twins BEFORE the order pass and the
                    # published-set build, so a row that is about to disappear
                    # never takes part in the intra-message invariant (it would
                    # otherwise be counted as a second body row and even pushed
                    # back to the client with a fresh revision).
                    await self.timeline.delete_items(
                        conn, session_id, converged_deletions
                    )
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
                # A message's reasoning rows and its body row can arrive in one
                # flush; enforce the invariant across the batch after every
                # order_seq is known. In-batch rows are corrected in place; a
                # durable sibling the batch did not carry comes back to be
                # rewritten (with a fresh revision so `list_since` replays the
                # move to clients that reconnect).
                sibling_movers = await self._apply_intra_message_order_batch(
                    conn,
                    session_id,
                    changed_items,
                )
                if sibling_movers:
                    first_mover_seq = await self._reserve_session_revisions(
                        conn,
                        session_id,
                        count=len(sibling_movers),
                        mark_read=False,
                        touch_updated_at=False,
                    )
                    siblings = [
                        mover.model_copy(
                            update={"updatedSeq": first_mover_seq + index}
                        )
                        for index, mover in enumerate(sibling_movers)
                    ]
                    mover_ids = {mover.id for mover in siblings}
                    changed_items = [
                        item for item in changed_items if item.id not in mover_ids
                    ] + siblings
                await self.timeline.upsert_many(conn, changed_items)
                if converged_deletions and not changed_items:
                    # Pure heal (the twin was already removed above): a fresh
                    # revision so the published set is not skipped as unchanged.
                    await self._bump_session(conn, session_id, mark_read=False)
                # The push must carry the corrected order, so rebuild the
                # published set from the corrected rows (the corrector replaced
                # the in-batch entries wholesale; ``persistable_items`` still
                # holds the pre-correction order). A moved durable sibling is
                # not in ``persistable_items`` (it was not in the batch), so it
                # is appended explicitly — a client must receive the move.
                changed_by_id = {item.id: item for item in changed_items}
                published_items = [
                    changed_by_id.get(item.id, item) for item in persistable_items
                ]
                if sibling_movers:
                    published_ids = {item.id for item in published_items}
                    published_items = [
                        *published_items,
                        *(
                            item
                            for item in changed_items
                            if item.id not in published_ids
                        ),
                    ]
                accepted_watermark = max(
                    [int(row.seq)]
                    + [item.updatedSeq for item in changed_items]
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
            items=tuple(published_items),
            changed=bool(changed_items),
            deleted=tuple(sorted(converged_deletions)),
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

        async with self._timeline_lock(session_id):
            # Converge duplicate live/history message ids onto the canonical
            # (first-written) id before any id-keyed math, so a later write of
            # the same logical message updates the one canonical row in place
            # instead of upserting a twin under a freshly-derived id.
            async with self._engine.connect() as conn:
                items, converged_deletions = await self._converge_message_identities(
                    conn,
                    session_id,
                    items,
                )
            incoming_by_id = latest_timeline_items_by_id(items)
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
                # The batch carries no item change, but it may still have healed
                # a live/history twin (a duplicate row removed with no item write
                # of its own), or pruned orphan cards, or refreshed the source
                # observation time. A batch with none of those opens no
                # transaction at all — the healthy incremental sync stays as
                # cheap as it was before this heal existed.
                if (
                    converged_deletions
                    or prune_orphan_agent_calls
                    or source_observed_at is not None
                ):
                    async with self._engine.begin() as conn:
                        await update_source_observed_at(
                            conn,
                            session_id=session_id,
                            source_observed_at=source_observed_at,
                        )
                        pruned: list[str] = []
                        if prune_orphan_agent_calls:
                            pruned = await self._prune_orphan_agent_call_rows(
                                conn,
                                session_id=session_id,
                                covered_by_id=incoming_by_id,
                            )
                        if converged_deletions or pruned:
                            await self.timeline.delete_items(
                                conn, session_id, converged_deletions
                            )
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
                return TimelineBatchWriteResult(
                    items=(),
                    changed=False,
                    deleted=tuple(sorted(converged_deletions)),
                )

            now = utc_now()
            changed_items: list[TimelineItem] = []
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                if converged_deletions:
                    # Remove converged twins before the order pass, so a row
                    # about to disappear is never counted as a second body row
                    # of the group (which would move it and re-publish it).
                    await self.timeline.delete_items(
                        conn, session_id, converged_deletions
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
                # A message's reasoning rows and its body row can arrive in one
                # batch; enforce the intra-message order across the batch after
                # every order_seq is known. In-batch rows are corrected in
                # place; corrected on-disk siblings come back for this write.
                sibling_movers = await self._apply_intra_message_order_batch(
                    conn,
                    session_id,
                    changed_items,
                )
                if sibling_movers:
                    # Fresh updated_seq per moved sibling (see the single-row
                    # writer's call site): a move invisible to list_since
                    # leaves online clients rendering the broken order.
                    first_mover_seq = await self._reserve_session_revisions(
                        conn,
                        session_id,
                        count=len(sibling_movers),
                        mark_read=False,
                        touch_updated_at=False,
                    )
                    for index, mover in enumerate(sibling_movers):
                        sibling_movers[index] = mover.model_copy(
                            update={"updatedSeq": first_mover_seq + index}
                        )
                    mover_ids = {item.id for item in sibling_movers}
                    changed_items = [
                        item for item in changed_items if item.id not in mover_ids
                    ] + sibling_movers
                await self.timeline.upsert_many(conn, changed_items)
                if converged_deletions and not changed_items:
                    # Pure heal (the twin was removed at the top of this
                    # transaction): a fresh revision so the deletion is
                    # delivered — the prune precedent, mark_read=False because
                    # removing a duplicate row is not content the user has seen.
                    await self._bump_session(conn, session_id, mark_read=False)
                if prune_orphan_agent_calls:
                    await self._prune_orphan_agent_call_rows(
                        conn,
                        session_id=session_id,
                        covered_by_id=incoming_by_id,
                    )
        return TimelineBatchWriteResult(
            items=tuple(changed_items),
            changed=True,
            deleted=tuple(sorted(converged_deletions)),
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

        async with self._timeline_lock(session_id):
            # Converge duplicate live/history message ids onto the canonical
            # (first-written) id before any id-keyed math. A rebuild that derives
            # a fresh id for a message already stored under a live id must land
            # on that live id, not mint a twin the snapshot diff would then
            # treat as a brand-new row.
            async with self._engine.connect() as conn:
                items, converged_deletions = await self._converge_message_identities(
                    conn,
                    session_id,
                    items,
                )
            incoming_by_id = latest_timeline_items_by_id(items)
            current_items = await self.timeline.read(session_id)
            current_by_id = {item.id: item for item in current_items}
            if timeline_snapshot_is_unchanged(current_by_id, incoming_by_id):
                async with self._engine.begin() as conn:
                    await update_source_observed_at(
                        conn,
                        session_id=session_id,
                        source_observed_at=source_observed_at,
                    )
                    if converged_deletions:
                        # The snapshot's content matches, but it still healed a
                        # duplicate twin: remove it and advance the session so a
                        # refetch reaches clients that hold the stale id.
                        await self.timeline.delete_items(
                            conn, session_id, converged_deletions
                        )
                        await self._bump_session(conn, session_id, mark_read=False)
                return TimelineBatchWriteResult(
                    items=tuple(current_items),
                    changed=False,
                    deleted=tuple(sorted(converged_deletions)),
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
                if converged_deletions:
                    # A live/history twin is collapsed onto the canonical id
                    # before the diff; delete the now-unreferenced rows in this
                    # transaction (the snapshot already bumped the session, so
                    # no extra revision is needed to publish the removal).
                    await self.timeline.delete_items(
                        conn, session_id, converged_deletions
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
                # A complete snapshot replaces every row, so the intra-message
                # invariant must hold across the snapshot itself: the Runtime's
                # own orderSeq can place a message's reasoning after its body.
                # The repair is purely in-memory — the snapshot's own slot set
                # is the only collision domain (no stored row survives it).
                await self._apply_intra_message_order_to_snapshot(
                    conn,
                    session_id,
                    normalized,
                )
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
        # A snapshot replacement removes any stored row the snapshot omits; the
        # converged twins are already excluded from ``incoming_by_id`` above, so
        # report them as deletions the publisher can express.
        return TimelineBatchWriteResult(
            items=tuple(normalized),
            changed=True,
            deleted=tuple(
                sorted(set(current_by_id) - set(incoming_by_id) | converged_deletions)
            ),
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
            # Converge a duplicate live/history message id onto the canonical
            # (first-written) id before any id-keyed math: this writer's whole
            # contract is "one item by stable id", so converging here is what
            # keeps the two connector paths from persisting two twin rows.
            async with self._engine.connect() as conn:
                converged, converged_deletions = await self._converge_message_identities(
                    conn,
                    session_id,
                    [item],
                )
            item = converged[0]
            existing = await self.timeline.read_one(session_id, item.id)
            unchanged = existing is not None and timeline_item_state_is_unchanged(
                existing, item
            )
            if unchanged and source_observed_at is None and not converged_deletions:
                return TimelineItemWriteResult(item=existing, changed=False)
            async with self._engine.begin() as conn:
                await update_source_observed_at(
                    conn,
                    session_id=session_id,
                    source_observed_at=source_observed_at,
                )
                if converged_deletions:
                    # Remove the converged twin BEFORE the order pass, so a row
                    # about to disappear is never counted as a second body row
                    # of the group (which would move it and waste a revision).
                    await self.timeline.delete_items(
                        conn, session_id, converged_deletions
                    )
                if unchanged:
                    result = existing
                    if converged_deletions:
                        # Pure heal: the canonical row already holds this state,
                        # but a duplicate twin is being removed with no write of
                        # its own. Advance the session so the deletion is
                        # delivered (a refetch reaches clients holding the
                        # stale id); the removal is not content the user has
                        # now seen, so it never consumes the unread badge.
                        await self._bump_session(conn, session_id, mark_read=False)
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
                    order_seq, sibling_movers = (
                        await self._apply_intra_message_order(
                            conn,
                            session_id,
                            item,
                            order_seq,
                        )
                    )
                    if sibling_movers:
                        # A moved sibling's order change is real content the
                        # client must see: without a fresh updated_seq the
                        # incremental stream (list_since) would not deliver
                        # the move, and an online client would keep rendering
                        # the broken order until the next full snapshot.
                        first_mover_seq = await self._reserve_session_revisions(
                            conn,
                            session_id,
                            count=len(sibling_movers),
                            mark_read=False,
                            touch_updated_at=False,
                        )
                        for index, mover in enumerate(sibling_movers):
                            sibling_movers[index] = mover.model_copy(
                                update={"updatedSeq": first_mover_seq + index}
                            )
                        await self.timeline.upsert_many(conn, sibling_movers)
                    result = timeline_item_from_runtime_input(
                        item,
                        updated_seq=updated_seq,
                        now=now,
                        existing=existing,
                        order_seq=order_seq,
                        revision=next_timeline_item_revision(item, existing),
                    )
                    await self.timeline.upsert_one(conn, result)
        return TimelineItemWriteResult(
            item=result,
            changed=not unchanged,
            deleted=tuple(sorted(converged_deletions)),
        )

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

    async def list_active_agent_cards(
        self,
        *,
        session_id: str,
        limit: int = 20,
    ) -> list[TimelineItem]:
        """The session's non-terminal Agent cards for the snapshot payload."""

        return await self.timeline.list_active_agent_cards(
            session_id,
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
        async with self._timeline_lock(session_id), self._engine.begin() as conn:
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

    async def _converge_message_identities(
        self,
        conn: AsyncConnection,
        session_id: str,
        items: list[TimelineItem],
    ) -> tuple[list[TimelineItem], set[str]]:
        """Collapse a message's duplicate live/history ids onto one row id.

        One logical assistant message can be written by two connector paths —
        the live stream and a later history rebuild — that derive DIFFERENT
        stable item ids but record the SAME ``source.itemId`` (the native
        message id). The table's PK is ``(session_id, id)``, so both rows
        persist and the client renders the reply twice (production: 8 groups,
        each a ``{claude.turn.assistant, claude.history.assistant}`` pair).

        The canonical id for a ``(session_id, native_item_id)`` message key is
        the FIRST-written row — the smallest ``(updatedSeq, id)``. In production
        the live row is written first, so the canonical id is the id the client
        is already rendering; adopting it means the heal never flips a visible
        id, while the later history write updates that same row in place.

        Returns the incoming ``items`` with any non-canonical message id
        rewritten onto the canonical id (preserving the incoming content /
        order / revision — last writer wins for content), and the set of stored
        duplicate row ids (a different id for the same key) the caller deletes
        in the same transaction.

        Conservative by construction:

        - Only ``type == "message"`` rows with a non-empty ``source.itemId``
          participate. ``system`` / ``tool`` / ``artifact`` / ``marker`` rows
          are never touched: a message's reasoning blocks legitimately share a
          native id across rows and must NOT be merged into one.
        - The key is ``(source.itemId, role)`` for ``type='message'``. Role is
          part of it because two rows of different roles are definitionally
          different messages even if a Runtime ever reused one native id; a
          role-blind key could then merge a user turn into an assistant reply.
          In production a native id never spans two roles (verified: 0 groups),
          so the role term is a no-op today and pure defence.

        Idempotent and cheap: one indexed load per batch (or zero when the batch
        carries no native-id message row); a batch with no duplicate is a strict
        no-op. Returns ``items`` unchanged (same list) when nothing converges.
        """

        keys = {
            (item.source.itemId, item.role)
            for item in items
            if item.type == "message" and item.source.itemId
        }
        if not keys:
            return items, set()
        native_ids = {native_item_id for native_item_id, _ in keys}

        stored: dict[tuple[str, str | None], list[tuple[str, int]]] = {}
        for native_item_id, row_id, row_role, updated_seq in (
            await conn.execute(
                select(
                    timeline_items_t.c.native_item_id,
                    timeline_items_t.c.id,
                    timeline_items_t.c.role,
                    timeline_items_t.c.updated_seq,
                ).where(
                    timeline_items_t.c.session_id == session_id,
                    timeline_items_t.c.type == "message",
                    timeline_items_t.c.native_item_id.in_(native_ids),
                )
            )
        ).all():
            stored.setdefault((native_item_id, row_role), []).append(
                (row_id, int(updated_seq))
            )

        # Tripwire: one native id appearing under two roles means a Runtime gave
        # the same message id to a user turn and an assistant reply (or a path
        # spelled the role differently — e.g. None on one side, "assistant" on
        # the other). The role-aware key then splits and the duplicate silently
        # survives, so surface it rather than letting it stay invisible.
        roles_by_native: dict[str, set[str | None]] = {}
        for native_item_id, row_role in stored:
            roles_by_native.setdefault(native_item_id, set()).add(row_role)
        for native_item_id, roles in roles_by_native.items():
            if len(roles) > 1:
                logger.warning(
                    "timeline native item id spans multiple roles "
                    "session_id={} native_item_id={} roles={}",
                    session_id,
                    native_item_id,
                    sorted(str(role) for role in roles),
                )

        # Canonical id per key: the first-written row. Tie-break on the id so
        # the choice is deterministic when two rows share an ``updated_seq``.
        canonical = {
            key: min(rows, key=lambda row: (row[1], row[0]))[0]
            for key, rows in stored.items()
        }

        # Stored duplicates: every stored row that is not its key's canonical
        # row. Every incoming row for such a key is rewritten onto the canonical
        # id below, so no incoming write targets the non-canonical id — the
        # stored duplicate is unreachable and safe to delete in the same
        # transaction.
        duplicate_ids: set[str] = {
            row_id
            for key, rows in stored.items()
            for row_id, _ in rows
            if row_id != canonical[key]
        }

        if not canonical:
            return items, set()

        rewritten: list[TimelineItem] = []
        for item in items:
            target = (
                canonical.get((item.source.itemId, item.role))
                if item.type == "message" and item.source.itemId
                else None
            )
            if target is not None and target != item.id:
                rewritten.append(item.model_copy(update={"id": target}))
            else:
                rewritten.append(item)
        return rewritten, duplicate_ids

    async def _apply_intra_message_order(
        self,
        conn: AsyncConnection,
        session_id: str,
        item: TimelineItemIn,
        order_seq: int,
    ) -> int:
        """Keep one message's reasoning rows strictly before its body row.

        A message group is the set of stored rows sharing ``source.itemId``:
        the body row (``type == "message"``) and its reasoning rows
        (``type == "system" and content.kind == "reasoning"``). A client
        keyset-paginates on the *stored* ``order_seq`` and renders in that
        order, so a reasoning row that lands after its body row renders below
        the answer. This is a strict corrector, not a normalizer: it runs on
        every write but returns the incoming ``order_seq`` untouched and
        writes nothing unless the invariant is actually broken (some reasoning
        row's ``order_seq`` is not strictly below some message row's) — the
        99.5% fast path. Re-applying it is therefore a no-op.

        Returns the (possibly corrected) ``order_seq`` for the incoming row and
        the stored sibling rows that must be rewritten (empty when nothing
        moves). Persisting the siblings — with a fresh ``updated_seq`` each —
        is the caller's job: the caller owns the session revision allocation,
        and a sibling written with its stale ``updated_seq`` would be invisible
        to the incremental stream (``list_since``) and an online client would
        keep rendering the broken order. This is the single-row writer's
        entry point (``upsert_timeline_item``); the batch writer uses
        ``_apply_intra_message_order_batch``, because a group whose rows all
        arrive in one batch has no on-disk sibling for this query to find.
        """

        incoming_kind = _intra_message_kind(item.type, item.content)
        native_item_id = item.source.itemId
        if not native_item_id or incoming_kind is None:
            return order_seq, []
        group: dict[str, _IntraMessageGroupRow] = {}
        for row in await self._load_intra_message_group(conn, session_id, native_item_id):
            if row.id != item.id:
                group[row.id] = row
        group[item.id] = _IntraMessageGroupRow(
            id=item.id,
            kind=incoming_kind,
            order_seq=order_seq,
            stored=None,
        )
        corrected = await self._repack_intra_message_group(
            conn,
            session_id,
            [group],
            logger_context=(session_id, native_item_id),
        )
        if corrected is None:
            return order_seq, []
        movers = self._intra_message_movers(corrected, [group], skip_ids={item.id})
        return corrected.get(item.id, order_seq), movers

    async def _apply_intra_message_order_batch(
        self,
        conn: AsyncConnection,
        session_id: str,
        items: list[TimelineItem],
    ) -> list[TimelineItem]:
        """Enforce the invariant across one sync batch, in place on ``items``.

        Runs after the loop has computed every item's ``order_seq``: a group
        whose rows all arrive in one batch has no on-disk sibling during the
        loop, so the per-item helper cannot see it. This pass groups the
        batch's own rows by ``source.itemId`` (the in-batch value winning over
        any stored row of the same id), folds in on-disk siblings, and repacks
        only the groups whose invariant is broken. ``base`` is the loop's
        running high-water mark (no batch row is written yet, so the on-disk
        maximum would undercount it). Corrected in-batch rows are mutated on
        ``items``; corrected on-disk siblings are returned so the caller can
        upsert them together with ``items`` (the caller dedupes by id). Groups
        that already hold the invariant are never touched, so an unrelated
        write cannot perturb a healthy group.
        """

        batch_by_native: dict[str, dict[str, TimelineItem]] = {}
        for item in items:
            native_item_id = item.source.itemId
            if not native_item_id:
                continue
            if _intra_message_kind(item.type, item.content) is None:
                continue
            batch_by_native.setdefault(native_item_id, {})[item.id] = item
        if not batch_by_native:
            return []
        groups: list[dict[str, _IntraMessageGroupRow]] = []
        batch_ids: set[str] = set()
        for native_item_id, batch_rows in batch_by_native.items():
            group: dict[str, _IntraMessageGroupRow] = {}
            for row in await self._load_intra_message_group(
                conn, session_id, native_item_id
            ):
                if row.id in batch_rows:
                    continue  # the in-batch value supersedes the stored row
                group[row.id] = row
            for row_id, batch_item in batch_rows.items():
                kind = _intra_message_kind(batch_item.type, batch_item.content)
                group[row_id] = _IntraMessageGroupRow(
                    id=row_id,
                    kind=kind or "message",
                    order_seq=batch_item.orderSeq,
                    stored=None,
                )
                batch_ids.add(row_id)
            groups.append(group)
        corrected = await self._repack_intra_message_group(
            conn,
            session_id,
            groups,
            logger_context=(session_id, None),
            # Every slot the batch has already allocated (not written yet) is
            # off limits to an in-place correction, or a corrected row and an
            # unrelated in-batch row could end up sharing an order_seq.
            extra_occupied={item.orderSeq for item in items},
        )
        if corrected is None:
            return []
        # Rewrite the corrected in-batch rows on ``items`` in place so the
        # caller's upsert carries the new ``order_seq``; the corrected on-disk
        # siblings come back as extra rows for the caller to upsert.
        for index, item in enumerate(items):
            new_order_seq = corrected.get(item.id)
            if new_order_seq is not None and new_order_seq != item.orderSeq:
                items[index] = item.model_copy(update={"orderSeq": new_order_seq})
        return self._intra_message_movers(
            corrected, groups, skip_ids=batch_ids
        )

    async def _apply_intra_message_order_to_snapshot(
        self,
        conn: AsyncConnection,
        session_id: str,
        items: list[TimelineItem],
    ) -> None:
        """Enforce the intra-message invariant across a complete snapshot.

        A snapshot replaces every row, so every sibling is in ``items`` and the
        repair needs no stored-row lookup: the snapshot's own slot set is the
        whole collision domain. Corrected ``order_seq`` values are written back
        onto ``items`` in place. A snapshot that already holds the invariant is
        untouched (strict corrector).
        """

        groups: list[dict[str, _IntraMessageGroupRow]] = []
        by_native: dict[str, dict[str, _IntraMessageGroupRow]] = {}
        slots: set[int] = set()
        for item in items:
            slots.add(item.orderSeq)
            native_item_id = item.source.itemId
            kind = _intra_message_kind(item.type, item.content)
            if not native_item_id or kind is None:
                continue
            by_native.setdefault(native_item_id, {})[item.id] = _IntraMessageGroupRow(
                id=item.id,
                kind=kind,
                order_seq=item.orderSeq,
                stored=None,
            )
        if not by_native:
            return
        groups.extend(by_native.values())
        corrected = await self._repack_intra_message_group(
            conn,
            session_id,
            groups,
            logger_context=(session_id, None),
            occupation=slots,
        )
        if corrected is None:
            return
        for index, item in enumerate(items):
            new_order_seq = corrected.get(item.id)
            if new_order_seq is not None and new_order_seq != item.orderSeq:
                items[index] = item.model_copy(update={"orderSeq": new_order_seq})

    async def _load_intra_message_group(
        self,
        conn: AsyncConnection,
        session_id: str,
        native_item_id: str,
    ) -> list[_IntraMessageGroupRow]:
        """The stored reasoning/message rows of one native-item group."""

        rows = (
            await conn.execute(
                select(
                    timeline_items_t.c.id,
                    timeline_items_t.c.type,
                    timeline_items_t.c.order_seq,
                    timeline_items_t.c.payload_json,
                ).where(
                    timeline_items_t.c.session_id == session_id,
                    timeline_items_t.c.native_item_id == native_item_id,
                )
            )
        ).all()
        group: list[_IntraMessageGroupRow] = []
        for row_id, row_type, row_order_seq, payload_json in rows:
            kind = _stored_intra_message_kind(row_type, payload_json)
            if kind is None:
                continue
            group.append(
                _IntraMessageGroupRow(
                    id=row_id,
                    kind=kind,
                    order_seq=int(row_order_seq),
                    stored=TimelineItem.model_validate_json(payload_json),
                )
            )
        return group

    async def _session_order_seq_occupation(
        self,
        conn: AsyncConnection,
        session_id: str,
    ) -> set[int]:
        """Every ``order_seq`` a row of this session already stores."""

        rows = (
            await conn.execute(
                select(timeline_items_t.c.order_seq).where(
                    timeline_items_t.c.session_id == session_id
                )
            )
        ).all()
        return {int(row[0]) for row in rows}

    @staticmethod
    def _free_slot_run(
        *,
        start: int,
        count: int,
        occupation: set[int],
        ceiling: int,
    ) -> list[int] | None:
        """``count`` consecutive unoccupied slots in ``[start, ceiling]``, or None.

        In-place means the group's rows stay inside the slot space the session
        already uses: a run that would need a slot above ``ceiling`` (the
        highest slot in play, including rows the caller has allocated but not
        yet written) defeats the point and returns ``None`` so the caller uses
        the fresh-block fallback instead. That bound is what keeps a search
        from walking off the end of a dense session and landing on a slot a
        concurrent in-batch row already holds.
        """

        if start < 1 or count < 1 or start > ceiling:
            return None
        run: list[int] = []
        slot = start
        while len(run) < count:
            if slot > ceiling:
                return None
            if slot in occupation:
                run.clear()
            else:
                run.append(slot)
            slot += 1
        return run or None

    async def _repack_intra_message_group(
        self,
        conn: AsyncConnection,
        session_id: str,
        groups: list[dict[str, _IntraMessageGroupRow]],
        *,
        logger_context: tuple[str, str | None],
        occupation: set[int] | None = None,
        extra_occupied: set[int] | None = None,
    ) -> dict[str, int] | None:
        """Corrected ``order_seq`` per row id for every broken group in ``groups``.

        Returns ``None`` when no group is broken (the strict-corrector fast
        path): nothing is written and **no session-wide query runs**, so a
        healthy write costs zero extra DB work (the red team measured the
        occupation scan at up to ~86 ms on the largest session — it must not
        fire when the invariant already holds).

        ``occupation`` is the set of slots already taken by rows the caller is
        not about to rewrite. It is read from the session by default; a
        complete-snapshot caller passes the snapshot's own slot set so the
        repair stays in-memory (the snapshot replaces every row, so the only
        collisions it must avoid are among its own items).

        A broken group is repacked **in place** whenever a run of free slots
        exists at the group's own position: the group keeps its place in the
        conversation and only its rows' relative order changes — reasoning
        rows first in their stored relative order, then the message rows in
        theirs. When no in-place run fits, the group falls back to a fresh
        contiguous block above ``base`` (the highest occupied slot); the
        running base advances past each block so two corrected groups can
        never share a slot.
        """

        corrected: dict[str, int] = {}
        repaired: list[tuple[int, int]] = []

        # Classify first; find the broken groups and their in-order row lists.
        # Nothing is written and no session-wide query runs when every group is
        # already correct — the 99.5% fast path must cost zero DB work.
        broken: list[tuple[list[_IntraMessageGroupRow], list[_IntraMessageGroupRow]]] = []
        for group in groups:
            reasoning = sorted(
                (row for row in group.values() if row.kind == "reasoning"),
                key=lambda row: (row.order_seq, row.id),
            )
            messages = sorted(
                (row for row in group.values() if row.kind == "message"),
                key=lambda row: (row.order_seq, row.id),
            )
            if not reasoning or not messages:
                continue  # singleton group: nothing to order
            if max(row.order_seq for row in reasoning) < min(
                row.order_seq for row in messages
            ):
                continue  # already correct: strict corrector, no write
            broken.append((reasoning, messages))
        if not broken:
            return None

        # Only a broken group needs the slot occupancy (for the in-place
        # preference). Deferred to here so the healthy path never pays for the
        # scan.
        if occupation is None:
            occupation = await self._session_order_seq_occupation(conn, session_id)
        else:
            occupation = set(occupation)

        # Slots that must never be handed out: every slot a row the caller is
        # NOT rewriting currently holds, every slot an in-batch row the caller
        # has ALREADY allocated but not yet written, plus every slot a rewritten
        # row is currently in (those become free only for the group that owns
        # them). ``claimed`` accumulates the NEW slots this call has assigned,
        # so a later broken group can never reuse a slot an earlier one just
        # took (the red-team cross-group collision: two independent messages
        # landing on the same ``order_seq``).
        own_slots = {row.order_seq for group in groups for row in group.values()}
        foreign_slots = (occupation - own_slots) | (extra_occupied or set())
        claimed: set[int] = set()
        # The highest slot in play. An in-place run must stay at or below it;
        # the fresh-block fallback lands above it. Both include the caller's
        # in-flight allocations so a corrected row can never collide with a
        # batch row that has a slot but is not written yet.
        ceiling = max(
            [max(occupation, default=0), *own_slots, *(extra_occupied or set())]
        )
        base = max(
            [max(occupation, default=0), *own_slots, *(extra_occupied or set())]
        )
        for reasoning, messages in broken:
            ordered = [*reasoning, *messages]
            start = min(row.order_seq for row in ordered)
            # This group may reclaim its OWN current slots but nothing else:
            # not a foreign slot, not an in-flight batch slot, not a slot an
            # earlier group already claimed.
            blocked = foreign_slots | claimed | (
                own_slots - {row.order_seq for row in ordered}
            )
            slots = self._free_slot_run(
                start=start,
                count=len(ordered),
                occupation=blocked,
                ceiling=ceiling,
            )
            if slots is None:
                # No in-place run fits; fall back to a fresh block above base.
                base = max(base, max(blocked, default=0))
                slots = [base + offset for offset in range(1, len(ordered) + 1)]
                base = base + len(ordered)
            for row, new_order_seq in zip(ordered, slots, strict=True):
                if row.order_seq != new_order_seq:
                    corrected[row.id] = new_order_seq
                claimed.add(new_order_seq)
            repaired.append((len(reasoning), len(messages)))
        logger.debug(
            "Timeline intra-message order repaired session_id={} native_item_id={} groups={}",
            logger_context[0],
            logger_context[1],
            repaired,
        )
        return corrected

    @staticmethod
    def _intra_message_movers(
        corrected: dict[str, int],
        groups: list[dict[str, _IntraMessageGroupRow]],
        *,
        skip_ids: set[str],
    ) -> list[TimelineItem]:
        """Stored rows that must be rewritten to a corrected ``order_seq``.

        The incoming / in-batch rows are the caller's to write (it rebuilds
        them itself), so they are passed in ``skip_ids``; the on-disk siblings
        are returned as rows the caller upserts beside its own.
        """

        movers: list[TimelineItem] = []
        for group in groups:
            for row in group.values():
                if row.id in skip_ids or row.stored is None:
                    continue
                new_order_seq = corrected.get(row.id)
                if new_order_seq is None or new_order_seq == row.order_seq:
                    continue
                movers.append(row.stored.model_copy(update={"orderSeq": new_order_seq}))
        return movers

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


@dataclass(frozen=True, slots=True)
class _IntraMessageGroupRow:
    """One stored row of a message's intra-message order group.

    ``kind`` is ``"reasoning"`` or ``"message"`` (the only two kinds the
    invariant speaks about). ``stored`` is the full row for a sibling already
    on disk, or ``None`` for the in-flight row whose stored payload/model is
    supplied by the caller — the caller only needs its id and kind.
    """

    id: str
    kind: str
    order_seq: int
    stored: TimelineItem | None


# The Runtime protocol's ``SystemContentKind`` reasoning member. Named and
# centralised so the classification is auditable and a future Runtime that
# spells its reasoning block differently has one place to extend.
_REASONING_CONTENT_KINDS = frozenset({"reasoning"})


def _intra_message_kind(item_type: str, content: Any) -> str | None:
    """Classify one item as ``"reasoning"``, ``"message"`` or neither.

    Generic on purpose: reasoning is ``type == "system"`` with a
    ``content.kind`` in ``_REASONING_CONTENT_KINDS`` and a message body is
    ``type == "message"`` — the same free-JSON ``content.kind`` convention the
    agent-card readers use (``_agent_call_task_ids``). No provider or runtime is
    consulted, so a Runtime that never reports a native item id (no group) is
    untouched and a future Runtime is classified by shape alone.

    Provider boundary (verified in production): the Runtimes we ship — Claude
    and Codex — both store their reasoning as ``type == "system"`` with
    ``content.kind == "reasoning"``, so both are covered. A Runtime that stored
    reasoning under ``type == "message"`` would be treated as a *body* row
    (which is what the protocol says ``message`` means); that shape is not
    produced by our adapters and is out of scope by contract.
    """

    if item_type == "message":
        return "message"
    if item_type == "system" and isinstance(content, Mapping) and content.get(
        "kind"
    ) in _REASONING_CONTENT_KINDS:
        return "reasoning"
    return None


def _stored_intra_message_kind(row_type: str, payload_json: str) -> str | None:
    """Classify one stored timeline row; ``None`` for any other item.

    Total by construction: a payload that cannot be read as a mapping yields
    ``None`` (an unreadable row is never ordered).
    """

    try:
        payload = json.loads(payload_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    return _intra_message_kind(row_type, payload.get("content"))


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
