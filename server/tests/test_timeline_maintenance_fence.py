"""Production-shape regression for the startup timeline maintenance passes.

Doris FINAL-REVIEW 2026-10-13 (P0-1) independently reproduced a production
wiring defect: the startup maintenance passes (``deduplicate_message_identities``
and ``repair_intra_message_order``) took only the Timeline/DB lock, so the
revision they reserve reaches ``TimelineWriteBuffer``'s bound Redis range sealer
(``SessionRevisionAllocator.seal_active_range``) WITHOUT the outer
``session_revision_fence``. In production (distributed Redis) that raises

    distributed lock is not held: session-revision:<id>

and the whole maintenance transaction rolls back — the first-boot repair the fix
is named for silently never happens, while the bare-``Store`` unit tests
(``test_timeline_redteam_fixes`` / ``test_timeline_redteam_round2``) stay green
because they never bind the sealer.

These tests assemble the EXACT production wiring
(``Store + TimelineWriteBuffer + SessionRevisionAllocator +
RedisCoordinator(FakeAsyncRedis)``) and bind the fence/publisher/sealer the same
way ``TimelineWriteBuffer.__init__`` does, so the passes must succeed with the
ownership guard active. They are RED before the fix and green after it, and they
deliberately do NOT touch production data or any real Redis — only a tmp SQLite
database and an in-process ``FakeAsyncRedis``.

Reference for the isolated reproduction (not a green test itself):
``/tmp/e2e/repro_maintenance_fence.py``.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from fakeredis import FakeAsyncRedis
from test_timeline_message_identity import (
    _last_read_seq,
    _rows_by_id,
    _seed_row,
    _store_with_session,
    message_input,
    reasoning_input,
)

from agent_server.infra.redis_coordinator import RedisCoordinator
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_broker import TimelineBroker
from agent_server.services.timeline_write_buffer import TimelineWriteBuffer

# ---------------------------------------------------------------------------
# Production-shape assembly helpers.
# ---------------------------------------------------------------------------


class _BufferFixture:
    def __init__(
        self,
        store: Store,
        redis: FakeAsyncRedis,
        buffer: TimelineWriteBuffer,
        payloads: list[dict[str, Any]],
    ) -> None:
        self.store = store
        self.redis = redis
        self.buffer = buffer
        self.payloads = payloads

    async def aclose(self) -> None:
        await self.buffer.close()
        await self.redis.aclose()
        await self.store.close()


async def _production_buffer(
    store: Store,
    tmp_path: Any,
    *,
    publish_fails: bool = False,
) -> _BufferFixture:
    """Bind a real write buffer exactly like ``app.py`` does at startup.

    A ``FakeAsyncRedis`` makes ``RedisCoordinator.distributed`` True, so
    ``SessionRevisionAllocator`` takes its production ownership-guard branch and
    ``seal_active_range`` requires the ``session-revision:<id>`` lock to be held
    by the current task. ``TimelineWriteBuffer.__init__`` then installs the three
    bindings (fence + publisher + range sealer) — the ones the maintenance passes
    must respect.

    ``publish_fails`` injects a publish-time failure so a caller can assert the
    failure is reported rather than silently swallowed.
    """

    _ = tmp_path
    redis = FakeAsyncRedis(decode_responses=True)
    coordinator = RedisCoordinator(client=redis, prefix="maintenance-fence-test")
    broker = TimelineBroker(coordinator)
    payloads: list[dict[str, Any]] = []

    async def record_publish(_session_id: str, message: str) -> None:
        if publish_fails:
            raise RuntimeError("injected publish failure")
        payloads.append(json.loads(message))

    broker.publish_message = record_publish  # type: ignore[method-assign]
    buffer = TimelineWriteBuffer(
        store,
        broker,
        coordinator,
        flush_interval_seconds=60,
        revision_lease_size=8,
    )
    # Guard the exact binding the defect bypassed.
    assert store._session_revision_fence_factory is not None
    assert store._session_revision_range_sealer is not None
    return _BufferFixture(store, redis, buffer, payloads)


# ---------------------------------------------------------------------------
# P0-1: repair order under the production binding.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_repair_intra_message_order_succeeds_under_production_binding(
    tmp_path,
) -> None:
    """A stored body-before-reasoning group is repaired, not rolled back.

    Before the fix this raises ``RuntimeError: distributed lock is not held:
    session-revision:<id>`` and leaves the rows broken.
    """

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
    try:
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "body", native_item_id="X", order_seq=5),
            order_seq=5,
            updated_seq=5,
        )
        await _seed_row(
            store,
            session.id,
            reasoning_input(session.id, "rsn", native_item_id="X", order_seq=6),
            order_seq=6,
            updated_seq=6,
        )
        read_before = await _last_read_seq(store, session.id)
        before = {
            i: (v.orderSeq, v.updatedSeq)
            for i, v in (await _rows_by_id(store, session.id)).items()
        }
        assert before["rsn"][0] > before["body"][0]  # broken to start

        moved = await store.repair_intra_message_order()

        assert moved > 0
        rows = await _rows_by_id(store, session.id)
        assert rows["rsn"].orderSeq < rows["body"].orderSeq
        # The durable revision advanced for the mvos, and the client was told.
        assert (await store.get_session_seq(session.id)) > before["body"][1]
        assert any(payload.get("items") for payload in fixture.payloads)
        # A maintenance repair is not content the user has now seen.
        assert await _last_read_seq(store, session.id) == read_before
        # Idempotent: a healthy session moves nothing.
        assert await store.repair_intra_message_order() == 0
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# P0-1: deduplicate under the production binding.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_deduplicate_message_identities_succeeds_under_production_binding(
    tmp_path,
) -> None:
    """A stored live/history twin is removed and the removal is published.

    Before the fix this raises the ownership-guard error and rolls back, so the
    duplicate row survives forever.
    """

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
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
        read_before = await _last_read_seq(store, session.id)

        removed = await store.deduplicate_message_identities()

        assert removed == 1
        rows = await _rows_by_id(store, session.id)
        assert set(rows) == {"live_1"}  # first-written kept
        # A removal has no surviving item to carry it: the envelope must refetch.
        assert any(
            payload.get("refetch") or payload.get("deleted")
            for payload in fixture.payloads
        )
        assert await _last_read_seq(store, session.id) == read_before
        # Idempotent.
        assert await store.deduplicate_message_identities() == 0
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# Nested fence: the maintenance pass must also work when the app already holds
# the buffer fence around the sweep (no self-deadlock, no double Redis lock).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_maintenance_passes_are_safe_nested_in_the_buffer_fence(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
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
        async with fixture.buffer.session_fence(session.id):
            removed = await store.deduplicate_message_identities()
        assert removed == 1
        assert set(await _rows_by_id(store, session.id)) == {"live_1"}
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# Pending buffered rows are flushed before the maintenance write (so the sweep
# never races an unflushed projection for the same session).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_maintenance_flushes_pending_buffered_rows_first(tmp_path) -> None:
    from test_timeline_write_buffer import timeline_input

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
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
        pending = await fixture.buffer.accept(
            session_id=session.id,
            item=timeline_input(
                session.id,
                text="pending",
                content_hash="sha256:pending",
                revision=1,
                item_id="pending_1",
            ),
        )
        assert pending.item.updatedSeq > 0
        # The pending row must be durable BEFORE the dedup sweep runs.
        assert "pending_1" not in {
            item.id for item in await store.timeline.read(session.id)
        }

        removed = await store.deduplicate_message_identities()

        assert removed == 1
        ids = {item.id for item in await store.timeline.read(session.id)}
        assert "pending_1" in ids
        assert ids == {"live_1", "pending_1"}
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# Backfill stays outside the session swarm: it reserves no revision and must
# keep working under the production binding (regression guard, not a fix).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_backfill_native_item_ids_works_under_production_binding(
    tmp_path,
) -> None:
    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
    try:
        # A row the migration could not cover: stored column NULL, payload still
        # carries the Runtime native itemId. Backfill reserves no revision, so it
        # needs no fence — this is a regression guard, not a fix.
        from sqlalchemy import text

        async with store.engine.begin() as conn:
            await conn.execute(
                text(
                    "INSERT INTO timeline_items "
                    "(session_id, id, type, status, role, order_seq, updated_seq, "
                    " native_item_id, payload_json) VALUES "
                    "(:s, 'row', 'message', 'done', 'assistant', 1, 1, NULL, "
                    " '{\"source\":{\"itemId\":\"NATIVE_1\"}}')"
                ),
                {"s": session.id},
            )
        refilled = await store.backfill_native_item_ids()
        assert refilled == 1
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# A publish failure during maintenance must be REPORTED, not swallowed, and the
# durable write must nevertheless have committed (the next flush/refetch heals).
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_publish_failure_is_reported_and_write_still_commits(tmp_path) -> None:
    """A publish error must not lose the sweep's committed deletion.

    The per-group try/except logs the sweep's own publish failure and keeps
    going, but the fence-exit recovery publish (durable_sequence >
    published_head) goes through the same broken broker and re-raises out of
    the fence — by design: a publish channel that is down must surface, not be
    silently swallowed. What the test pins is the durable half: the deletion
    HAS committed, it is logged, and the failure is the fence-exit one, not a
    rolled-back write.
    """

    from loguru import logger as loguru_logger

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path, publish_fails=True)
    messages: list[str] = []
    sink_id = loguru_logger.add(messages.append, level="INFO")
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

        # The sweep's own publish failure is contained; the fence-exit recovery
        # publish then re-raises through the same broken broker.
        with pytest.raises(RuntimeError, match="injected publish failure"):
            await store.deduplicate_message_identities()

        # The DB transaction committed BEFORE any publish attempt — the
        # duplicate is gone and the session advanced, so a later working
        # flush/refetch delivers the removal.
        rows = await _rows_by_id(store, session.id)
        assert set(rows) == {"live_1"}
        # The sweep's containment logged the failure (reported, not silent).
        text = "".join(messages)
        assert "dedup publish failed" in text
    finally:
        loguru_logger.remove(sink_id)
        # Close must swallow the deferred publish drain rather than raise.
        await fixture.buffer.close()
        await fixture.redis.aclose()
        await store.close()


# ---------------------------------------------------------------------------
# A NULL-role duplicate group (role is nullable; platform rows can carry no
# role) must be healed too — and must not crash the keyset cursor, which
# cannot build a plain ``role > None`` comparison.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_dedup_heals_null_role_group_and_cursor_survives(tmp_path) -> None:
    """Both rows of a NULL-role twin group share ``role IS NULL`` (role is
    nullable; a Runtime that spells the role differently splits the group key,
    which the live heal's tripwire warns about). The keyset cursor must survive
    the NULL boundary — a plain ``role > None`` comparison cannot even be
    built — and keep visiting later non-NULL groups."""

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
    try:
        null_twin_a = message_input(
            session.id, "n_1", native_item_id="N", order_seq=1
        ).model_copy(update={"role": None})
        null_twin_b = message_input(
            session.id, "n_2", native_item_id="N", order_seq=2
        ).model_copy(update={"role": None})
        await _seed_row(store, session.id, null_twin_a, order_seq=1, updated_seq=1)
        await _seed_row(store, session.id, null_twin_b, order_seq=2, updated_seq=2)
        # A non-NULL-role group AFTER the null-role key: the cursor must reach
        # it instead of dying at the NULL boundary.
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "x_1", native_item_id="X", order_seq=3),
            order_seq=3,
            updated_seq=3,
        )
        await _seed_row(
            store,
            session.id,
            message_input(session.id, "x_2", native_item_id="X", order_seq=4),
            order_seq=4,
            updated_seq=4,
        )

        removed = await store.deduplicate_message_identities()

        assert removed == 2
        rows = await _rows_by_id(store, session.id)
        assert set(rows) == {"n_1", "x_1"}
        # Idempotent.
        assert await store.deduplicate_message_identities() == 0
    finally:
        await fixture.aclose()


# ---------------------------------------------------------------------------
# The session fence must be released on the success path (the Redis range lock
# is not left held), so a subsequent accept for the same session proceeds.
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_session_fence_is_released_after_maintenance(tmp_path) -> None:
    from test_timeline_write_buffer import timeline_input

    store, session = await _store_with_session(tmp_path)
    fixture = await _production_buffer(store, tmp_path)
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
        assert await store.deduplicate_message_identities() == 1
        # The coordinator no longer believes this task holds the session lock,
        # and a fresh buffered accept for the session still succeeds.
        assert not fixture.buffer._coordinator.holds_lock(
            f"session-revision:{session.id}"
        )
        accepted = await fixture.buffer.accept(
            session_id=session.id,
            item=timeline_input(
                session.id,
                text="after",
                content_hash="sha256:after",
                revision=1,
                item_id="after_1",
            ),
        )
        assert accepted.item.updatedSeq > 0
    finally:
        await fixture.aclose()
