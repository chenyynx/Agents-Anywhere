from __future__ import annotations

import asyncio
import os
import secrets
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, replace
from typing import Any

from pydantic import ValidationError

from connector.core.config import ConnectorConfig
from connector.logging import logger
from connector.runtime_protocol import (
    AgentRuntime,
    RuntimeHostClient,
    RuntimeModelCatalog,
    RuntimePermissionCatalog,
    RuntimeStatus,
    RuntimeSupervisor,
    RuntimeTimelineItem,
    RuntimeTimelineSnapshot,
    RuntimeUnavailableError,
    RuntimeUnsupportedError,
    SessionMeta,
    SessionNotice,
    SessionSourceObservation,
    SessionState,
)
from connector.runtimes.catalog_revisions import (
    CatalogPushState,
    catalog_content_signature,
    catalog_push_revision,
    catalog_push_state_from_mapping,
    catalog_push_state_payload,
)
from connector.server.errors import ConnectorNetworkError
from connector.server.runtime_host import _drop_none, _timeline_item_payload
from connector.server.runtime_rpc_payloads import (
    model_catalog_payload,
    permission_catalog_payload,
    session_notice_payload,
)

NotificationSender = Callable[[str, dict[str, Any]], Awaitable[None]]
IngestNotificationSender = Callable[[list[dict[str, Any]]], Awaitable[None]]
PreferencesReader = Callable[[], dict[str, Any]]
SyncStateFlusher = Callable[[], Awaitable[bool]]
# F13: the on-demand settle lookup reads one page, the same bound the global
# sweep has always used. See `_sync_settled_session_once` for why a session past
# it is reported rather than silently skipped.
SESSION_LOOKUP_PAGE_SIZE = 100

ACTIVE_SESSION_SYNC_SKIP_STATUSES: frozenset[RuntimeStatus] = frozenset(
    {"waiting", "pending", "running", "waiting_approval", "stopping"}
)
VALIDATION_ERROR_LOG_LIMIT = 5

# T1 (stale-residue-selfheal, 2026-10-09): runtimes without a complete session
# inventory list one bounded page per cycle, so every session past it is never
# compared and its stale rows (a card stuck on `running`) are never rebuilt —
# residue cause ③. The library rotation adds ONE further window per cycle to
# the same marker-comparison flow. `AGENT_CONNECTOR_SESSION_ROTATION` selects
# the mode:
#   off    (default) — rotation is not consulted at all; behavior is exactly
#                      what it was before this feature, byte for byte.
#   report           — the sweep walks the same circle but only logs what it
#                      would rebuild: the first rollout stage. No publish, no
#                      rebuild, no durable session state.
#   on               — the sweep rebuilds, capped per cycle.
# An unrecognized value fails safe to off.
SESSION_ROTATION_ENV = "AGENT_CONNECTOR_SESSION_ROTATION"
SESSION_ROTATION_OFF = "off"
SESSION_ROTATION_REPORT = "report"
SESSION_ROTATION_ON = "on"
_SESSION_ROTATION_MODES = frozenset(
    {SESSION_ROTATION_OFF, SESSION_ROTATION_REPORT, SESSION_ROTATION_ON}
)
# One window per cycle, the same bound page 1 uses.
SESSION_ROTATION_PAGE_SIZE = 100
# Page 1 (offset 0) is fetched every cycle anyway, so the rotation ladder
# starts one window in — unless page 1 says it exposed fewer history sessions
# than that (local-only sessions displaced the tail of `history[0:limit]`), in
# which case the ladder starts at the seam so nothing falls between the two
# (R1 P2-6). A seam of 0 backed by a readable, non-empty history list is that
# same displacement covering the whole first window, so the ladder starts at
# 0 there (T1b) — those sessions are in no page and in no window otherwise.
# A persisted offset is therefore anything from 0 up; this constant is the
# lowest SEAM that is a real position (any higher seam is a real position
# too, while a seam below 1 only means what the readable-history rule above
# says it means).
SESSION_ROTATION_FIRST_OFFSET = SESSION_ROTATION_PAGE_SIZE
SESSION_ROTATION_MIN_OFFSET = 1
# Rebuilds on rotation windows are capped per cycle (task card §3 T1.4: 5~10),
# so a library-wide projection bump spreads over hours instead of spiking
# CPU/IO/ingest in minutes. Page 1 is never capped — freshness is its job.
SESSION_ROTATION_REBUILD_BUDGET = 8
# Consecutive circles that ended with candidates but no successful rebuild
# before the sweep gives up and sleeps (a poison session must not keep the
# whole sweep awake).
SESSION_ROTATION_STALL_CIRCLES = 3
# How many empty windows in a row may go unproven before the sweep is allowed
# to believe them (R1 P1-2/P1-3). An empty window is only proof of "past the
# end of the library" once this circle has actually read a non-empty window;
# the very first window of a circle can come back empty for reasons that have
# nothing to do with the library ending — the read failed, every session in it
# was filtered out as live/active, the list shifted under the ladder because a
# session was updated between two reads — and believing it there ends the
# sweep with the whole tail unread. Bounded, because a position that returns
# nothing forever (a library that shrank under a persisted offset) must still
# be able to conclude and re-seek.
SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT = 3
# How many windows the ladder may walk after a re-seek before the re-seek
# re-arms (R1c R3-1). The re-seek is what recovers a ladder left pointing past a
# library that shrank under a persisted offset, so spending it once per circle
# made that recovery unreachable for the rest of the sweep's life — and a
# circle only concludes on a read that proves something, so a reader that fails
# everywhere never concludes one: the ladder then committed forward forever,
# past a residue it could have found by looking again. Bounded, because wrapping
# on every spend would re-read the same windows in a tight loop; a sweep that
# wraps every few windows still climbs a few new ones between wraps, so a reader
# that recovers is reached within the cooldown.
SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS = 8
# Rest cycles the sweep inserts after consecutive window reads that rebuilt
# nothing, capped (R1 P2-5). The activation signal is a page-1 edge that only a
# page-1 rebuild consumes, so a page-1 session whose rebuild keeps failing
# re-lights the sweep every cycle forever, and every window read is a
# whole-library scan inside the SDK. The backoff is what makes "never sleeps"
# a bounded cost; it starts only after the first full circle so the sweep that
# a version bump just opened still walks its windows at full speed.
SESSION_ROTATION_IDLE_SLEEP_MAX = 8
# One window that rebuilt nothing is free, because it is the ordinary case:
# most windows of a large library hold nothing to rebuild, and a sweep that
# crawled from its second window on would be slower at finding residue than
# the scan it is trying to save. Each further consecutive no-progress read
# doubles the rest it buys — a sweep that is idle for many windows in a row is
# the pathological one, and it should reach the cap in a few windows, not in
# a dozen. The cap bounds the other end: residue that appears in the tail is
# still noticed within MAX rest cycles (8 cycles ≈ 4 minutes at the 30s
# default), so the backoff can never become "never look again".
SESSION_ROTATION_IDLE_FREE_READS = 1
SESSION_ROTATION_STATE_VERSION = 1


class RuntimeSyncRunner:
    """Keeps runtime startup and background local-session sync out of the WS loop."""

    def __init__(
        self,
        config: ConnectorConfig,
        supervisor: RuntimeSupervisor,
        host: RuntimeHostClient,
        preferences_reader: PreferencesReader,
        send_notification: NotificationSender,
        ingest_notifications: IngestNotificationSender | None = None,
        flush_sync_state: SyncStateFlusher | None = None,
    ) -> None:
        self.config = config
        self.supervisor = supervisor
        self.host = host
        self.preferences_reader = preferences_reader
        self.send_notification = send_notification
        self.ingest_notifications = ingest_notifications
        self.flush_sync_state = flush_sync_state
        self._recovery_generation = 0
        self._recovered: dict[str, int] = {}
        self._recovered_sessions: set[tuple[str, str]] = set()
        self._last_preferences: dict[str, Any] | None = None
        self._last_active_session_updates: dict[
            str, tuple[SessionMeta, SessionState]
        ] = {}
        # L3b (claude-stale-frame-turn-tasks.md §4/§11): one session's
        # timeline is refreshed the moment its turn settles instead of at the
        # next global beat, which is what turned a settled reply into 30-50 s of
        # silence on 2026-10-04.
        #
        # Two rules make that safe. The per-session lock is the SAME one the
        # periodic sweep takes, so a session is never read by two writers at
        # once — but it is per session rather than global, so a busy session
        # cannot hold up an unrelated one. And requests coalesce: a turn that
        # settles three times in a second is one refresh, not three.
        self._session_sync_locks: dict[tuple[str, str], asyncio.Lock] = {}
        # "queued" = a refresh is scheduled but has not read yet; "running" =
        # it is reading. The distinction is what makes coalescing lossless: a
        # settle absorbed by a "queued" refresh is inside the read that is
        # about to happen, and one that arrives at "running" is not (F5).
        self._session_sync_state: dict[tuple[str, str], str] = {}
        self._session_sync_dirty: set[tuple[str, str]] = set()
        self._session_sync_tasks: set[asyncio.Task[None]] = set()
        # Catalog push continuity (catalog-revision-conflict.md): the content
        # signature and revision of the last push per (runtime instance,
        # catalog type). Persisted through the instance's sync state so a used
        # revision is never handed to different content, including across
        # restarts; the in-process copy keeps continuity when persistence
        # itself fails.
        self._instance_state_hosts: dict[str, RuntimeHostClient] = {}
        self._catalog_push_states: dict[str, CatalogPushState] = {}
        # Session rotation (T1): the in-process copy of one runtime's
        # library-scan position, mirroring the catalog push state cache — the
        # memory copy keeps the sweep from restarting when persistence fails.
        self._rotation_states: dict[str, SessionRotationState] = {}
        self.closing = False

    def _session_sync_lock(self, runtime_id: str, session_id: str) -> asyncio.Lock:
        return self._session_sync_locks.setdefault(
            (runtime_id, session_id), asyncio.Lock()
        )

    def on_turn_settled(
        self,
        runtime_id: str | None,
        session_id: str,
        external_session_id: str | None = None,
    ) -> None:
        """Queue one refresh of the session that just settled. Returns at once.

        Called from the turn's settle path, so this schedules and returns — the
        transcript read and the publish happen on their own task. A settle must
        never wait for the very sync it is asking for.
        """

        if runtime_id is None or self.closing:
            return
        key = (runtime_id, session_id)
        state = self._session_sync_state.get(key)
        if state == "running":
            # A refresh for this session has already taken (or is taking) its
            # transcript read, so absorbing this settle would leave the rows it
            # produced in no snapshot at all — the exact lag L3b exists to
            # remove, recreated one layer up (red team F5). Mark it and let the
            # in-flight pass run once more.
            self._session_sync_dirty.add(key)
            return
        if state == "queued":
            # Scheduled but not yet reading. This settle lands inside the read
            # that is about to happen, so it is absorbed by it — coalescing
            # three settles in one tick into one transcript read, with nothing
            # lost.
            return
        self._session_sync_state[key] = "queued"
        task = asyncio.create_task(self._sync_settled_session(runtime_id, session_id))
        self._session_sync_tasks.add(task)
        task.add_done_callback(self._session_sync_tasks.discard)
        _ = external_session_id

    async def _sync_settled_session(self, runtime_id: str, session_id: str) -> None:
        key = (runtime_id, session_id)
        while True:
            self._session_sync_state[key] = "running"
            try:
                if await self._sync_settled_session_once(runtime_id, session_id):
                    # A settle landed while this read was in flight and the rows
                    # it produced are not in the snapshot just taken. One more
                    # pass, then stop.
                    self._session_sync_dirty.discard(key)
                    self._session_sync_state[key] = "queued"
                    continue
            except Exception:  # noqa: BLE001
                logger.exception(
                    "settled session sync failed runtime={} session_id={}",
                    runtime_id,
                    session_id,
                )
            break
        self._session_sync_dirty.discard(key)
        self._session_sync_state.pop(key, None)

    async def _sync_settled_session_once(
        self, runtime_id: str, session_id: str
    ) -> bool:
        """Run one refresh. Returns whether a settle is still owed.

        F13, and it is a LIMIT rather than a silent no-op. `list_sessions`
        returns a tuple with no cursor — the protocol has no directed lookup —
        so a connector holding more sessions than one page cannot find the one
        that just settled, and this path would do nothing at all for those
        users. That is the same hole the global sweep has always had, but here
        it would mean turn delivery silently depends on how many sessions the
        account has, which is exactly the kind of environment coupling the
        product rule forbids.

        So it SAYS so: an explicit warning naming the page size is the honest
        form, and it is what an on-call reads when a user's turns land slowly.
        A real directed lookup needs `list_sessions` to grow a cursor or a
        get-by-id, which is a protocol change and not this batch's business.
        """

        try:
            runtime = self.supervisor.resolve_runtime(runtime_id)
        except (RuntimeUnavailableError, RuntimeUnsupportedError):
            return False
        if runtime.sync_mode == "events":
            # An event runtime owns its own acknowledged lifecycle; its settle
            # already published everything there is to publish.
            return False
        sessions = await runtime.list_sessions(limit=SESSION_LOOKUP_PAGE_SIZE, force=False)
        session = next(
            (item for item in sessions if item.session_id == session_id), None
        )
        if session is None:
            logger.warning(
                "settled session sync found no session in the first page "
                "runtime={} session_id={} listed={} page_size={} "
                "(list_sessions has no cursor; a directed lookup is needed for "
                "connectors past one page)",
                runtime_id,
                session_id,
                len(sessions),
                SESSION_LOOKUP_PAGE_SIZE,
            )
            return False
        async with self._session_sync_lock(runtime_id, session_id):
            await self.sync_existing_session(runtime, session)
        return (runtime_id, session_id) in self._session_sync_dirty

    async def sync_existing_loop(self) -> None:
        if not self.config.sync_existing_on_connect:
            logger.info("existing session sync disabled")
            return
        logger.info(
            "existing session sync loop started interval_seconds={}",
            self.config.sync_interval_seconds,
        )
        while True:
            await self.sync_existing_once()
            await self.push_preferences_if_changed()
            await asyncio.sleep(self.config.sync_interval_seconds)

    async def stop(self) -> None:
        """L3b: retire the on-demand refreshes along with the loop."""

        self.closing = True
        tasks = tuple(self._session_sync_tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def reconnect_event_runtimes(self) -> None:
        self._recovery_generation += 1
        self._recovered_sessions.clear()
        self._last_active_session_updates.clear()
        for runtime_id in self.supervisor.runtimes:
            try:
                runtime = self.supervisor.resolve_runtime(runtime_id)
                if runtime.sync_mode == "events":
                    await runtime.resynchronize()
            except Exception:
                logger.exception("runtime event recovery deferred runtime={}", runtime_id)

    async def sync_existing_once(self) -> None:
        for runtime_id in self.supervisor.runtimes:
            runtime_started_at = time.monotonic()
            recovery_generation = self._recovery_generation
            recover = self._recovered.get(runtime_id, 0) != recovery_generation
            failed = False
            try:
                runtime = self.supervisor.resolve_runtime(runtime_id)
                if runtime.sync_mode == "events":
                    continue
                logger.info(
                    "existing session sync runtime started runtime={}", runtime_id
                )
                entry = self.supervisor.entry(runtime_id)
                await self.push_runtime_catalogs(runtime)
                inventory_scan_token: str | None = None
                runtime_type = entry.runtime_type
                scoped_runtime_id = entry.runtime_id
                if runtime.supports_complete_session_inventory():
                    inventory_scan_token = secrets.token_hex(16)
                    await self._ingest_scanner_notifications(
                        [
                            _inventory_begin_notification(
                                runtime_type,
                                scoped_runtime_id,
                                inventory_scan_token,
                            )
                        ]
                    )
                    try:
                        sessions = await runtime.list_complete_session_inventory(
                            page_size=100,
                            force=False,
                        )
                    except Exception:
                        await self._ingest_scanner_notifications(
                            [
                                _inventory_complete_notification(
                                    runtime_type,
                                    scoped_runtime_id,
                                    inventory_scan_token,
                                    (),
                                    complete=False,
                                )
                            ]
                        )
                        raise
                else:
                    sessions = await runtime.list_sessions(limit=100, force=False)
                timeline_sync_count = sum(
                    1 for session in sessions if session_requires_timeline_sync(session)
                )
                logger.info(
                    "existing session sync runtime discovered runtime={} sessions={} timeline_syncs={}",
                    runtime_id,
                    len(sessions),
                    timeline_sync_count,
                )
                for session in sessions:
                    try:
                        recovery_key = (runtime_id, session.session_id)
                        recover_session = recover and recovery_key not in self._recovered_sessions
                        if recover_session:
                            session = replace(session, metadata={
                                **dict(session.metadata),
                                "sync": {"changed": True, "requires_timeline_sync": True},
                            })
                        async with self._session_sync_lock(runtime_id, session.session_id):
                            # L3b: the same per-session lock the on-demand
                            # settle refresh takes, so the two writers of one
                            # timeline can never overlap. Per session, not
                            # global: a slow session must not delay the rest.
                            completed = await self.sync_existing_session(
                                runtime, session, source_in_inventory=inventory_scan_token is not None,
                                recovering=recover_session,
                            )
                        if completed is False:
                            failed = True
                        elif recover_session and recovery_generation == self._recovery_generation:
                            self._recovered_sessions.add(recovery_key)
                    except ConnectorNetworkError as exc:
                        logger.warning(
                            "existing session sync network failure runtime={} session_id={} external_session_id={} error={}",
                            session.runtime,
                            session.session_id,
                            session.external_session_id,
                            exc,
                        )
                        failed = True
                        continue
                    except ValidationError as exc:
                        logger.error(
                            "existing session sync validation failed runtime={} session_id={} external_session_id={} validation_errors={} details={}",
                            session.runtime,
                            session.session_id,
                            session.external_session_id,
                            exc.error_count(),
                            validation_error_summary(exc),
                        )
                        failed = True
                        continue
                    except Exception:  # noqa: BLE001
                        logger.exception(
                            "existing session sync failed runtime={} session_id={} external_session_id={}",
                            session.runtime,
                            session.session_id,
                            session.external_session_id,
                        )
                        failed = True
                        continue
                if inventory_scan_token is not None:
                    await self._ingest_scanner_notifications(
                        [
                            _inventory_complete_notification(
                                runtime_type,
                                scoped_runtime_id,
                                inventory_scan_token,
                                sessions,
                                complete=True,
                            )
                        ]
                    )
                else:
                    # T1: the inventory-less path gets one extra rotating
                    # window per cycle. It runs after page 1 (freshness keeps
                    # its priority) and its failures are its own: a rotation
                    # error must not hold back the startup reconciliation
                    # bookkeeping below.
                    try:
                        await self.run_session_rotation(
                            runtime=runtime,
                            runtime_id=runtime_id,
                            scoped_runtime_id=scoped_runtime_id,
                            runtime_type=runtime_type,
                            page_one_page=sessions,
                        )
                    except Exception:  # noqa: BLE001
                        logger.exception(
                            "session rotation cycle failed runtime={}",
                            runtime_id,
                        )
                if not failed:
                    self._recovered[runtime_id] = recovery_generation
                logger.info(
                    "existing session sync runtime completed runtime={} sessions={} elapsed_ms={:.1f}",
                    runtime_id,
                    len(sessions),
                    (time.monotonic() - runtime_started_at) * 1000,
                )
            except RuntimeUnavailableError:
                if self.runtime_has_config(runtime_id):
                    logger.info(
                        "existing session sync runtime unavailable runtime={}",
                        runtime_id,
                    )
                continue
            except ConnectorNetworkError as exc:
                logger.warning(
                    "existing {} session sync network failure error={}",
                    runtime_id,
                    exc,
                )
            except TimeoutError:
                logger.warning("existing {} session sync timed out", runtime_id)
            except Exception:  # noqa: BLE001
                logger.exception("existing {} session sync failed", runtime_id)
        if self.flush_sync_state is not None:
            try:
                await self.flush_sync_state()
            except Exception:  # noqa: BLE001
                logger.exception("history scanner sync state flush failed")

    async def sync_existing_session(
        self,
        runtime: AgentRuntime,
        session: SessionMeta,
        *,
        source_in_inventory: bool = False,
        recovering: bool = False,
    ) -> bool | None:
        """Publish one discovered session and any required fresh timeline.

        Side effects:
        - upserts new or changed session meta to the platform
        - when the runtime marks the session as changed, reads and pushes its
          timeline snapshot, current state, and active notices
        - publishes an active session's meta and state once per distinct update
        """
        if not session_requires_timeline_sync(session):
            if session_sync_changed(session) is False:
                if session.source_state is not None and not source_in_inventory:
                    await self.host.session_source_update(
                        SessionSourceObservation(
                            session_id=session.session_id,
                            external_session_id=session.external_session_id,
                            runtime=session.runtime,
                            runtime_id=session.runtime_id,
                            state=session.source_state,
                        )
                    )
                return
            await self._ingest_scanner_notifications(
                [_session_meta_notification(session)]
            )
            return
        logger.info(
            "existing session timeline sync started runtime={} session_id={} external_session_id={}",
            session.runtime,
            session.session_id,
            session.external_session_id,
        )
        read_elapsed_ms = 0.0
        publish_elapsed_ms = 0.0
        synced_items = 0
        state = await runtime.get_session_state(
            session.session_id,
            session.external_session_id,
        )
        active = state is not None and state.status in ACTIVE_SESSION_SYNC_SKIP_STATUSES
        if active and not recovering:
            active_update = (session, state)
            if (
                self._last_active_session_updates.get(session.session_id)
                == active_update
            ):
                logger.debug(
                    "existing session sync suppressed unchanged active session runtime={} session_id={} status={}",
                    session.runtime,
                    session.session_id,
                    state.status,
                )
                return
            await self._ingest_scanner_notifications(
                [
                    _session_meta_notification(session),
                    _session_state_notification(state),
                ]
            )
            self._last_active_session_updates[session.session_id] = active_update
            logger.info(
                "existing session sync deferred active session runtime={} session_id={} status={}",
                session.runtime,
                session.session_id,
                state.status,
            )
            return
        self._last_active_session_updates.pop(session.session_id, None)
        read_started_at = time.monotonic()
        prepared = await runtime.prepare_session_timeline_sync(
            session.session_id,
            session.external_session_id,
        )
        snapshot: RuntimeTimelineSnapshot | None = None
        if prepared is not None:
            read_elapsed_ms = (time.monotonic() - read_started_at) * 1000
            snapshot = prepared.snapshot
            synced_items = len(snapshot.items) if snapshot is not None else 0
        else:
            read_started_at = time.monotonic()
            snapshot = await runtime.get_session_snapshot(
                session.session_id,
                session.external_session_id,
            )
            read_elapsed_ms = (time.monotonic() - read_started_at) * 1000
            synced_items = len(snapshot.items)
            logger.info(
                "existing session timeline sync read runtime={} session_id={} items={} complete={} elapsed_ms={:.1f}",
                snapshot.runtime,
                snapshot.session_id,
                synced_items,
                snapshot.complete,
                read_elapsed_ms,
            )
        deferred_replacement = recovering and active and snapshot is not None and snapshot.complete
        if recovering and active and snapshot is not None:
            snapshot = replace(snapshot, complete=False)
        notices = await runtime.get_session_notices(
            session.session_id,
            session.external_session_id,
        )
        notifications = [_session_meta_notification(session)]
        if snapshot is not None:
            notifications.append(
                _timeline_sync_notification(
                    snapshot,
                    fallback_item_time=session.ordering_time,
                )
            )
        if state is not None:
            notifications.append(_session_state_notification(state))
        notifications.extend(_notice_notification(notice) for notice in notices)
        publish_started_at = time.monotonic()
        await self._ingest_scanner_notifications(notifications)
        publish_elapsed_ms = (time.monotonic() - publish_started_at) * 1000
        if prepared is not None and prepared.commit is not None and not deferred_replacement:
            await prepared.commit()
        if publish_elapsed_ms >= 250 or synced_items >= 100:
            logger.info(
                "existing session timeline sync published runtime={} session_id={} items={} elapsed_ms={:.1f}",
                session.runtime,
                session.session_id,
                synced_items,
                publish_elapsed_ms,
            )
        logger.info(
            "existing session sync completed runtime={} session_id={} items={} notices={} read_elapsed_ms={:.1f} publish_elapsed_ms={:.1f}",
            session.runtime,
            session.session_id,
            synced_items,
            len(notices),
            read_elapsed_ms,
            publish_elapsed_ms,
        )
        # Keep this recovery generation pending until deletion reconciliation is
        # safe; otherwise an unchanged inventory marker could suppress its retry.
        return not deferred_replacement

    async def run_session_rotation(
        self,
        *,
        runtime: AgentRuntime,
        runtime_id: str,
        scoped_runtime_id: str,
        runtime_type: str,
        page_one_page: tuple[SessionMeta, ...],
    ) -> None:
        """One cycle of the library-scan rotation (T1, stale-residue-selfheal).

        A runtime without a complete session inventory lists one bounded first
        page per cycle, so sessions past it were never compared and their stale
        rows were never rebuilt (residue cause ③). The rotation fetches ONE
        further window per cycle and runs it through the existing marker
        comparison and `requires_timeline_sync` flow — no new publish path.

        Activation is on demand (task card §3 T1.8): a cycle whose first page
        shows any `projection_outdated` session — the natural trace a
        projection version bump leaves behind, including a cursor that is
        missing entirely — opens a full-library sweep. One window is scanned per
        cycle; when a whole circle finds nothing to rebuild the sweep sleeps
        again, so steady state costs zero rotation load. A session stays a
        candidate until its rebuild lands, which is what makes the sweep
        converge: it cannot go back to sleep while an outdated session is still
        surfacing. Sessions whose source files are gone are out of any local
        scan's reach and remain the server-side age janitor's job.

        Rebuilds on rotation windows are capped per cycle (§3 T1.4) so a
        library-wide projection bump spreads over hours instead of spiking
        CPU/IO/ingest in minutes; page 1 is never capped — freshness is its job.
        A page whose candidates keep failing does not hold the sweep hostage
        (`SESSION_ROTATION_STALL_CIRCLES`).

        Mode `report` walks exactly one circle and logs what it would rebuild,
        publishing nothing; mode `off` (the default) returns before any state is
        touched or read.

        What the sweep refuses to do (R1): conclude the library on an empty
        window it cannot vouch for (P1-2), sleep for good on a circle it never
        proved (P1-3), or re-read a whole library every cycle for a signal that
        will not be consumed (P2-5). And (R1c) it keeps looking back: the
        re-seek re-arms on a cooldown instead of being spent once per circle,
        and a ladder reading empty at or beyond the furthest window that ever
        held a session re-seeks on the position alone — a sweep whose reader
        fails, or whose library shrank under a persisted offset, used to climb
        away from the residue for the life of the process.

        And (T1b) it does not walk a library that fits inside page 1 at all: a
        page whose own read proves it covers the whole library is the only
        proof such a library can ever give — every rotation window past it is
        legitimately empty, and an empty window is not proof (R1 P1-2/P1-3) —
        so a sweep opened (or left armed) there is closed at once, without a
        single window read. Without that verdict the sweep read one empty
        window per cycle forever, one whole-library scan each, exactly the
        steady-state load the on-demand design exists to avoid.
        """

        mode = session_rotation_mode()
        if mode == SESSION_ROTATION_OFF:
            return
        state = await self._rotation_state(scoped_runtime_id, runtime_type)
        # Where the ladder starts when it wraps: page 1's seam when page 1
        # reports one, the first window otherwise.
        first_offset = _first_rotation_offset(page_one_page)
        if not state.active:
            outdated = sum(
                1
                for session in page_one_page
                if session_projection_outdated(session)
            )
            if outdated == 0:
                return
            if _page_one_complete(page_one_page):
                # T1b: the whole library fits inside page 1, so there is no
                # window to walk and nothing a window could ever prove — an
                # empty window is not the end of a library this short (R1
                # P1-2/P1-3), and a sweep opened here would read one empty
                # window per cycle for the life of the process. Page 1 is
                # compared in full and rebuilt uncapped every cycle, so an
                # outdated session it shows needs no rotation; the page that
                # covers the library is its own reason not to open a sweep.
                logger.info(
                    "session rotation sweep not needed; page one covers the library "
                    "runtime={} outdated_page_one_sessions={}",
                    runtime_id,
                    outdated,
                )
                return
            state = SessionRotationState(active=True, offset=first_offset)
            logger.info(
                "session rotation sweep activated runtime={} outdated_page_one_sessions={} first_offset={}",
                runtime_id,
                outdated,
                first_offset,
            )
            # Persist before the first window read: if that read fails, the
            # activation must survive the cycle — the page-1 signal that opened
            # the sweep may already be rebuilt by the time the next cycle runs.
            await self._record_rotation_state(scoped_runtime_id, runtime_type, state)
        elif _page_one_complete(page_one_page):
            # T1b, the armed side: an already-active sweep whose page 1 now
            # proves it covers the whole library has nothing left to walk.
            # Every window past the seam is legitimately empty and empty is
            # not proof (R1 P1-2/P1-3), so staying armed would read one empty
            # window per cycle forever — the very load this sweep exists to
            # avoid. The circle is as complete as it can ever be proved: page
            # 1 itself was compared in full (and rebuilt uncapped) this very
            # cycle. Close it and sleep, keeping the extent the sweep learned.
            logger.info(
                "session rotation sweep completed; page one covers the library "
                "runtime={} offset={} circles={}",
                runtime_id,
                state.offset,
                state.circles + 1,
            )
            await self._record_rotation_state(
                scoped_runtime_id,
                runtime_type,
                replace(
                    SessionRotationState(),
                    library_extent=state.library_extent,
                ),
            )
            return
        if state.rest_cycles > 0 and state.circles > 0:
            # P2-5: this sweep has read windows without progress for a while
            # (an activation signal that keeps being re-lit but never consumed).
            # Every window read is a whole-library scan inside the SDK, so the
            # sweep rests instead of paying that price again next cycle.
            logger.debug(
                "session rotation sweep resting runtime={} offset={} rest_cycles={} idle_reads={}",
                runtime_id,
                state.offset,
                state.rest_cycles,
                state.idle_reads,
            )
            await self._record_rotation_state(
                scoped_runtime_id,
                runtime_type,
                replace(state, rest_cycles=state.rest_cycles - 1),
            )
            return
        try:
            page = await runtime.list_sessions(
                limit=SESSION_ROTATION_PAGE_SIZE,
                cursor=str(state.offset),
                force=False,
            )
        except Exception:  # noqa: BLE001
            # A failed window read must not advance the ladder; the sweep
            # resumes at the same offset next cycle.
            logger.exception(
                "session rotation window read failed runtime={} offset={}",
                runtime_id,
                state.offset,
            )
            return
        if not page:
            read_failed = _page_read_failed(page)
            scanned = _page_history_scanned(page)
            # An empty page is proof of "past the end of the library" only when
            # the read itself vouches for the emptiness and this circle has
            # already read a real window (R1 P1-2/P1-3). A read that raised, or
            # a window the live/active filters emptied, says the opposite; and
            # neither can vouch for the emptiness until a non-empty window
            # proves the circle — the ladder may have stepped into a hole (a
            # session updated between two reads shifts every index after it) or
            # been pointed past a library that shrank.
            unverified = read_failed or scanned > 0
            unproven = min(
                state.unproven_empties + 1,
                SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT,
            )
            # R1c R3-1: an empty window at or beyond the furthest offset that
            # has ever held a session is not "unproven" — there is nothing at
            # this position that has ever been there, so the ladder was pointed
            # at a position the library does not have (a persisted offset under
            # a library that shrank, or a seed from a past sweep). This reads
            # the *position*, not the circle's progress, so it recovers that
            # ladder in one read instead of a whole patience-and-cooldown run,
            # and it is the only judgement here that trusts the ladder's
            # coordinates over what it has managed to read. A window the
            # filters emptied (`scanned > 0`) is excluded on purpose: the
            # sessions are still there, so the ladder's position is fine.
            beyond_extent = (
                not unverified
                and state.library_extent > 0
                and state.offset >= state.library_extent
            )
            proven_end_of_library = (
                state.circle_windows > 0 or state.past_library_extent
            ) and not unverified
            patience_spent = unproven >= SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT
            reseek_armed = (
                state.circle_stalls == 0
                or state.windows_since_reseek >= SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS
            )
            if not proven_end_of_library:
                if (patience_spent and reseek_armed) or beyond_extent:
                    # Spent the circle's patience without ever proving an end,
                    # so the sweep must NOT disarm: the activation signal is a
                    # page-1 edge that only a page-1 rebuild consumes, so
                    # disarming here and being re-armed by that same unconsumed
                    # edge is an oscillation that never climbs the ladder and
                    # never reaches the tail (R1b R2-2). Wrap to a position
                    # that is really in the library instead: this is what
                    # recovers a ladder left pointing past a library that
                    # shrank under a persisted offset.
                    #
                    # The re-seek re-arms after the cooldown, so this shape is
                    # not one repair per circle but one per cooldown: a sweep
                    # whose reader fails everywhere never concludes a circle,
                    # and a one-shot budget left it walking forward for the life
                    # of the process (R1c R3-1). Looking beyond the extent also
                    # counts as the proof of the end that a non-empty window
                    # would otherwise have supplied, so the next empty window
                    # on the way back can conclude the circle.
                    logger.warning(
                        "session rotation re-seeking runtime={} offset={} "
                        "read_failed={} scanned={} unproven_empties={} "
                        "library_extent={} windows_since_reseek={} "
                        "beyond_extent={}",
                        runtime_id,
                        state.offset,
                        read_failed,
                        scanned,
                        unproven,
                        state.library_extent,
                        state.windows_since_reseek,
                        beyond_extent,
                    )
                    await self._record_rotation_state(
                        scoped_runtime_id,
                        runtime_type,
                        replace(
                            state,
                            offset=first_offset,
                            circle_candidates=0,
                            circle_rebuilt=0,
                            circle_windows=0,
                            unproven_empties=0,
                            circle_stalls=state.circle_stalls + 1,
                            windows_since_reseek=0,
                            past_library_extent=(
                                state.past_library_extent or beyond_extent
                            ),
                        ),
                    )
                    return
                # Step over it and keep the sweep armed; the skipped window is
                # picked up again on the next circle. The patience counter is
                # what stops a reader that fails on EVERY window from walking
                # offsets inside one run: while the re-seek is still cooling
                # down, a spent counter resets here so the ladder commits
                # FORWARD past the region that keeps failing instead of
                # wrapping back into it and re-reading the same windows
                # forever — and the cooldown is what brings the re-seek back
                # afterwards, so the forward run is bounded (R1c R3-1).
                logger.warning(
                    "session rotation window is not proof of the end of the "
                    "library runtime={} offset={} read_failed={} scanned={} "
                    "unproven_empties={} circle_windows={} circle_stalls={} "
                    "windows_since_reseek={}",
                    runtime_id,
                    state.offset,
                    read_failed,
                    scanned,
                    unproven,
                    state.circle_windows,
                    state.circle_stalls,
                    state.windows_since_reseek,
                )
                await self._record_rotation_state(
                    scoped_runtime_id,
                    runtime_type,
                    replace(
                        state,
                        offset=state.offset + SESSION_ROTATION_PAGE_SIZE,
                        unproven_empties=0 if patience_spent else unproven,
                        windows_since_reseek=state.windows_since_reseek + 1,
                    ),
                )
                return
            # End of the library: the circle is complete (page 1 plus every
            # rotation window has been compared). The extent is a fact about
            # the library, not about this circle, so a sweep that sleeps keeps
            # it: a ladder that wakes up past the end then re-seeks at once
            # instead of spending a cooldown learning the same thing again.
            if mode == SESSION_ROTATION_REPORT or state.circle_candidates == 0:
                logger.info(
                    "session rotation sweep completed runtime={} offset={} candidates_this_circle={} circles={}",
                    runtime_id,
                    state.offset,
                    state.circle_candidates,
                    state.circles + 1,
                )
                await self._record_rotation_state(
                    scoped_runtime_id,
                    runtime_type,
                    replace(
                        SessionRotationState(),
                        library_extent=state.library_extent,
                    ),
                )
                return
            if state.circle_rebuilt == 0:
                stall = state.stall_circles + 1
                if stall >= SESSION_ROTATION_STALL_CIRCLES:
                    logger.warning(
                        "session rotation sweep stalled; sleeping with candidates unrebuilt "
                        "runtime={} candidates={} circles={}",
                        runtime_id,
                        state.circle_candidates,
                        stall,
                    )
                    await self._record_rotation_state(
                        scoped_runtime_id,
                        runtime_type,
                        replace(
                            SessionRotationState(),
                            library_extent=state.library_extent,
                        ),
                    )
                    return
                logger.warning(
                    "session rotation circle rebuilt nothing runtime={} candidates={} stall_circles={}",
                    runtime_id,
                    state.circle_candidates,
                    stall,
                )
                await self._record_rotation_state(
                    scoped_runtime_id,
                    runtime_type,
                    SessionRotationState(
                        active=True,
                        offset=first_offset,
                        stall_circles=stall,
                        circles=state.circles + 1,
                        library_extent=state.library_extent,
                    ),
                )
                return
            # The circle closed with progress: start the next one, and count it
            # so the idle backoff applies from here on (P2-5) — the sweep is now
            # in the regime where it keeps being re-armed without the tail
            # giving it anything to do.
            await self._record_rotation_state(
                scoped_runtime_id,
                runtime_type,
                SessionRotationState(
                    active=True,
                    offset=first_offset,
                    circles=state.circles + 1,
                    library_extent=state.library_extent,
                ),
            )
            return
        candidates = [
            session for session in page if session_requires_timeline_sync(session)
        ]
        circle_candidates = state.circle_candidates + len(candidates)
        # A window that came back with sessions is the only evidence of where
        # the library ends, so it is the one read that raises the extent — and
        # it clears the "looked past the end" proof, because the library's end
        # has just moved.
        library_extent = max(
            state.library_extent, state.offset + SESSION_ROTATION_PAGE_SIZE
        )
        if mode == SESSION_ROTATION_REPORT:
            logger.info(
                "session rotation report runtime={} offset={} sessions={} would_rebuild={} session_ids={}",
                runtime_id,
                state.offset,
                len(page),
                len(candidates),
                ",".join(
                    session.external_session_id or session.session_id
                    for session in candidates
                ),
            )
            await self._record_rotation_state(
                scoped_runtime_id,
                runtime_type,
                replace(
                    state,
                    offset=state.offset + SESSION_ROTATION_PAGE_SIZE,
                    circle_candidates=circle_candidates,
                    circle_windows=state.circle_windows + 1,
                    unproven_empties=0,
                    windows_since_reseek=state.windows_since_reseek + 1,
                    library_extent=library_extent,
                    past_library_extent=False,
                ),
            )
            return
        rebuilt = 0
        attempted = 0
        for session in candidates:
            if attempted >= SESSION_ROTATION_REBUILD_BUDGET:
                break
            attempted += 1
            try:
                async with self._session_sync_lock(runtime_id, session.session_id):
                    # L3b: the same per-session lock the live and settle writers
                    # take, so a rotation rebuild never overlaps the session's
                    # live writer. Actively driven sessions are already dropped
                    # from a paged window by the reader's live/active filters,
                    # and `sync_existing_session` keeps its own active-status
                    # gate for the ones that reach it.
                    completed = await self.sync_existing_session(runtime, session)
            except Exception:  # noqa: BLE001
                logger.exception(
                    "session rotation rebuild failed runtime={} session_id={} external_session_id={} offset={}",
                    session.runtime,
                    session.session_id,
                    session.external_session_id,
                    state.offset,
                )
                continue
            if completed is True:
                rebuilt += 1
        # P2-5: a window that rebuilt nothing is the only evidence the idle
        # backoff has. The first circle after activation never rests — it is
        # the one the version bump paid for, and it may be the only pass that
        # ever finds the residue.
        idle_reads = (
            0
            if rebuilt
            else min(
                state.idle_reads + 1,
                SESSION_ROTATION_IDLE_SLEEP_MAX + SESSION_ROTATION_IDLE_FREE_READS,
            )
        )
        rest_cycles = (
            (
                0
                if idle_reads <= SESSION_ROTATION_IDLE_FREE_READS
                else min(
                    2 ** (idle_reads - SESSION_ROTATION_IDLE_FREE_READS - 1),
                    SESSION_ROTATION_IDLE_SLEEP_MAX,
                )
            )
            if state.circles > 0
            else 0
        )
        logger.info(
            "session rotation window runtime={} offset={} sessions={} candidates={} rebuilt={} rest_cycles={}",
            runtime_id,
            state.offset,
            len(page),
            len(candidates),
            rebuilt,
            rest_cycles,
        )
        await self._record_rotation_state(
            scoped_runtime_id,
            runtime_type,
            replace(
                state,
                offset=state.offset + SESSION_ROTATION_PAGE_SIZE,
                circle_candidates=circle_candidates,
                circle_rebuilt=state.circle_rebuilt + rebuilt,
                circle_windows=state.circle_windows + 1,
                unproven_empties=0,
                windows_since_reseek=state.windows_since_reseek + 1,
                library_extent=library_extent,
                past_library_extent=False,
                idle_reads=idle_reads,
                rest_cycles=rest_cycles,
            ),
        )

    async def _rotation_state(
        self,
        scoped_runtime_id: str,
        runtime_type: str,
    ) -> SessionRotationState:
        """This runtime's scan position, from memory or the state store."""

        cached = self._rotation_states.get(scoped_runtime_id)
        if cached is not None:
            return cached
        host = await self._instance_state_host(scoped_runtime_id)
        try:
            raw = await host.sync_state_read(
                _session_rotation_state_key(runtime_type, scoped_runtime_id)
            )
        except (NotImplementedError, AttributeError):
            logger.debug(
                "session rotation state store unavailable runtime_id={}",
                scoped_runtime_id,
            )
            return SessionRotationState()
        except Exception:  # noqa: BLE001
            logger.warning(
                "reading session rotation state failed runtime_id={}",
                scoped_runtime_id,
            )
            return SessionRotationState()
        state = session_rotation_state_from_mapping(raw)
        self._rotation_states[scoped_runtime_id] = state
        return state

    async def _record_rotation_state(
        self,
        scoped_runtime_id: str,
        runtime_type: str,
        state: SessionRotationState,
    ) -> None:
        """Remember one scan position, memory first.

        The in-process copy keeps the sweep moving when the state store cannot
        persist, mirroring the catalog push state's continuity rule.
        """

        self._rotation_states[scoped_runtime_id] = state
        host = await self._instance_state_host(scoped_runtime_id)
        try:
            await host.sync_state_write(
                _session_rotation_state_key(runtime_type, scoped_runtime_id),
                session_rotation_state_payload(state),
            )
        except (NotImplementedError, AttributeError):
            logger.debug(
                "session rotation state store unavailable runtime_id={}",
                scoped_runtime_id,
            )
        except Exception:  # noqa: BLE001
            logger.warning(
                "persisting session rotation state failed runtime_id={}; keeping in-memory continuity",
                scoped_runtime_id,
            )

    async def _ingest_scanner_notifications(
        self,
        notifications: list[dict[str, Any]],
    ) -> None:
        if self.ingest_notifications is not None:
            await self.ingest_notifications(notifications)
            return
        for notification in notifications:
            await self.send_notification(
                notification["method"],
                notification["params"],
            )

    async def push_runtime_catalogs(
        self,
        runtime: AgentRuntime,
    ) -> None:
        """Read and publish runtime-level catalogs before session sync.

        Side effects:
        - reads model and permission catalogs from the runtime
        - publishes only catalogs whose content changed since the last push,
          with a revision strictly above the last one this connector used

        The revision a catalog carries tracks the runtime config revision, which
        does not move when discovery output drifts (a model gateway adding a
        route, for example). The Server rejects same-revision content changes as
        out of order, so before this gate existed a drifted catalog was rejected
        on every sync cycle until the next connector restart; unchanged content
        was re-sent every cycle for nothing.
        """

        try:
            model_catalog = await runtime.list_model_catalog(query=None, limit=200)
            await self._publish_catalog(
                catalog=model_catalog,
                catalog_type="model",
                payload_builder=model_catalog_payload,
                send=self.host.model_catalog_update,
            )
        except RuntimeUnsupportedError:
            pass
        try:
            permission_catalog = await runtime.list_permission_catalog(
                query=None, limit=200
            )
            await self._publish_catalog(
                catalog=permission_catalog,
                catalog_type="permission",
                payload_builder=permission_catalog_payload,
                send=self.host.permission_catalog_update,
            )
        except RuntimeUnsupportedError:
            pass

    async def _publish_catalog(
        self,
        *,
        catalog: RuntimeModelCatalog | RuntimePermissionCatalog,
        catalog_type: str,
        payload_builder: Callable[[Any], dict[str, Any]],
        send: Callable[[Any], Awaitable[None]],
    ) -> None:
        signature = catalog_content_signature(payload_builder(catalog))
        runtime_id = catalog.runtime_id or catalog.runtime
        key = _catalog_push_state_key(catalog.runtime, runtime_id, catalog_type)
        state_host = await self._instance_state_host(runtime_id)
        previous = await self._catalog_push_state(state_host, key)
        if previous is not None and previous.content_signature == signature:
            logger.debug(
                "runtime catalog unchanged; push skipped runtime={} runtime_id={} "
                "catalog_type={} revision={}",
                catalog.runtime,
                runtime_id,
                catalog_type,
                previous.revision,
            )
            return
        revision = catalog_push_revision(catalog.revision, previous)
        if revision != catalog.revision:
            catalog = replace(catalog, revision=revision)
        await send(catalog)
        await self._record_catalog_push_state(
            state_host,
            key,
            CatalogPushState(content_signature=signature, revision=revision),
        )
        logger.info(
            "runtime catalog published runtime={} runtime_id={} catalog_type={} "
            "revision={} previous_revision={}",
            catalog.runtime,
            runtime_id,
            catalog_type,
            revision,
            previous.revision if previous is not None else None,
        )

    async def _instance_state_host(self, runtime_id: str) -> RuntimeHostClient:
        """Bind the host to the runtime instance whose state is read.

        Instance state (catalog push continuity, session rotation position)
        belongs to one runtime instance and lives beside that instance's other
        state. A host that cannot bind (an older or test host) keeps the shared
        host: the state key names the instance in either case, so entries never
        collide.
        """

        cached = self._instance_state_hosts.get(runtime_id)
        if cached is not None:
            return cached
        host = self.host
        prepare = getattr(host, "prepare_runtime_host", None)
        if callable(prepare):
            try:
                host = await prepare(runtime_id)
            except Exception:  # noqa: BLE001
                logger.exception(
                    "binding runtime host for instance state failed runtime_id={}",
                    runtime_id,
                )
                host = self.host
        self._instance_state_hosts[runtime_id] = host
        return host

    async def _catalog_push_state(
        self,
        host: RuntimeHostClient,
        key: str,
    ) -> CatalogPushState | None:
        """Last recorded push for one catalog, from memory or the state store."""

        cached = self._catalog_push_states.get(key)
        if cached is not None:
            return cached
        try:
            raw = await host.sync_state_read(key)
        except (NotImplementedError, AttributeError):
            logger.debug("catalog push state store unavailable key={}", key)
            return None
        except Exception:  # noqa: BLE001
            logger.warning("reading catalog push state failed key={}", key)
            return None
        state = catalog_push_state_from_mapping(raw)
        if state is not None:
            self._catalog_push_states[key] = state
        return state

    async def _record_catalog_push_state(
        self,
        host: RuntimeHostClient,
        key: str,
        state: CatalogPushState,
    ) -> None:
        """Remember one push, memory first.

        The in-process copy is the one that guarantees the next revision stays
        above this one even when the state store cannot persist, which is what
        keeps changed content from being re-pushed at a revision the Server has
        already seen.
        """

        self._catalog_push_states[key] = state
        try:
            await host.sync_state_write(key, catalog_push_state_payload(state))
        except (NotImplementedError, AttributeError):
            logger.debug("catalog push state store unavailable key={}", key)
        except Exception:  # noqa: BLE001
            logger.warning(
                "persisting catalog push state failed key={}; keeping in-memory continuity",
                key,
            )

    async def push_preferences_if_changed(self) -> None:
        try:
            current = self.preferences_reader()
        except Exception:  # noqa: BLE001
            logger.exception("reading local preferences failed")
            return
        if not isinstance(current, dict):
            return
        # readAt is a per-call timestamp — strip it before diffing so we don't
        # push an "update" every cycle when nothing actually changed.
        if _preferences_signature(current) == _preferences_signature(
            self._last_preferences or {}
        ):
            return
        self._last_preferences = current
        await self.send_notification("connector.preferencesUpdated", current)

    def runtime_has_config(self, runtime_id: str) -> bool:
        entry = self.supervisor.entry(runtime_id)
        return entry.config is not None


def validation_error_summary(error: ValidationError) -> str:
    details = error.errors(
        include_url=False,
        include_context=False,
        include_input=False,
    )
    summarized: list[str] = []
    for detail in details[:VALIDATION_ERROR_LOG_LIMIT]:
        location = ".".join(str(part) for part in detail.get("loc", ())) or "<root>"
        message = str(detail.get("msg") or "validation failed")
        error_type = str(detail.get("type") or "validation_error")
        summarized.append(f"{location}: {message} [{error_type}]")
    remaining = len(details) - len(summarized)
    if remaining > 0:
        summarized.append(f"... {remaining} more")
    return "; ".join(summarized)


def _preferences_signature(prefs: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
    """Stable signature ignoring volatile `readAt`.

    Lets us detect real user-driven changes instead of re-pushing every poll
    cycle.
    """
    return tuple(sorted((k, v) for k, v in prefs.items() if k != "readAt"))


def _catalog_push_state_key(
    runtime: str,
    runtime_id: str,
    catalog_type: str,
) -> str:
    """State key naming one runtime instance's catalog stream.

    Matches the runtime-namespaced sync state convention
    (`claude/instances/<id>/...`), so the entry lands with the instance's other
    state and never collides across instances or catalog types.
    """

    return f"{runtime}/instances/{runtime_id}/catalog-push/{catalog_type}"


def _session_rotation_state_key(runtime: str, runtime_id: str) -> str:
    """State key naming one runtime instance's rotation position.

    Same instance-namespaced convention as the catalog push state, so the
    entry lands with the instance's other state and never collides across
    instances.
    """

    return f"{runtime}/instances/{runtime_id}/session-rotation"


def session_requires_timeline_sync(session: SessionMeta) -> bool:
    sync = session.metadata.get("sync")
    if not isinstance(sync, dict):
        return False
    return sync.get("requires_timeline_sync") is True


def session_sync_changed(session: SessionMeta) -> bool | None:
    sync = session.metadata.get("sync")
    if not isinstance(sync, dict):
        return None
    changed = sync.get("changed")
    return changed if isinstance(changed, bool) else None


def session_projection_outdated(session: SessionMeta) -> bool:
    """Whether this session's stored projection is behind the current one.

    Runtimes that can say so (Claude's reader) stamp this into the sync
    metadata: True when the stored history cursor is missing or was produced by
    an older projection version. It is the library rotation's activation
    signal, because it is the trace a projection version bump leaves on every
    session it has not yet rebuilt. Runtimes that do not report it simply never
    activate a rotation.
    """

    sync = session.metadata.get("sync")
    if not isinstance(sync, dict):
        return False
    return sync.get("projection_outdated") is True


@dataclass(frozen=True, slots=True)
class SessionRotationState:
    """Durable scan position of one runtime's library rotation.

    `offset` is the NEXT rotation window; page 1 (offset 0) is fetched by every
    cycle already, so the ladder starts one window in — or at page 1's seam when
    page 1 reports one (R1 P2-6). `circle_candidates` and `circle_rebuilt`
    accumulate over the circle currently being scanned: a circle that ends with
    no candidates compared clean and puts the sweep to sleep; a circle that ends
    with candidates but zero successful rebuilds counts as stalled, and the
    stall limit stops one poison session from keeping the sweep awake forever.

    The rest is about not believing a sweep that cannot prove itself (R1
    P1-2/P1-3/P2-5):

    * `circle_windows` — non-empty windows read in this circle. Until there is
      one, an empty window is not evidence that the library ended.
    * `unproven_empties` — empty windows read so far in a circle that has no
      proof; `SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT` of them spends the
      circle's patience.
    * `circle_stalls` — how many times this circle has spent that patience and
      re-seeked. Counted, not capped (R1c R3-1): the re-seek is what recovers
      a ladder left pointing past a library that shrank under a persisted
      offset, and a budget of one per circle made that recovery unreachable for
      the rest of the sweep's life — a circle only concludes on a read that
      proves something, so a reader that fails (or a library that shrank) never
      concludes one, and the ladder committed forward past a residue it could
      have found by looking again. `windows_since_reseek` is the cooldown that
      keeps the repeats bounded (R1b R2-2's concern: wrapping on every spend
      would re-read the same windows in a tight loop).
    * `windows_since_reseek` — windows walked since the last re-seek. At
      `SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS` the next patience spend
      re-arms the re-seek; below it the ladder commits forward, which is what
      gets it out of a region that keeps failing.
    * `library_extent` — the high-water mark: one past the furthest offset that
      ever returned a non-empty window (0 = never). A ladder reading empty at
      or beyond it is not "unproven" — there is nothing there that has ever
      been there, so it re-seeks without spending patience, and a library that
      shrank under a persisted offset is recovered in one read instead of a
      whole cooldown.
    * `past_library_extent` — the sweep has looked beyond `library_extent` and
      found nothing. That IS the proof of the library's end that
      `circle_windows` otherwise supplies, so it stands in for it until a real
      window is read (which clears it).
    * `circles` — circles concluded since activation. The first one always
      runs flat out (it is the one a version bump just paid for); the idle
      backoff only applies past it.
    * `idle_reads` / `rest_cycles` — consecutive window reads that rebuilt
      nothing, and the countdown of cycles the sweep rests before its next
      read. A read that rebuilds something clears both.
    """

    active: bool = False
    offset: int = SESSION_ROTATION_FIRST_OFFSET
    circle_candidates: int = 0
    circle_rebuilt: int = 0
    stall_circles: int = 0
    circle_windows: int = 0
    unproven_empties: int = 0
    circle_stalls: int = 0
    windows_since_reseek: int = 0
    library_extent: int = 0
    past_library_extent: bool = False
    circles: int = 0
    idle_reads: int = 0
    rest_cycles: int = 0


def session_rotation_state_from_mapping(
    value: Mapping[str, Any] | None,
) -> SessionRotationState:
    if (
        not isinstance(value, Mapping)
        or value.get("version") != SESSION_ROTATION_STATE_VERSION
    ):
        return SessionRotationState()
    offset = _optional_int(value.get("offset"))
    return SessionRotationState(
        active=value.get("active") is True,
        # 0 is a legitimate position since T1b: it is the seam-0 start, where
        # page 1 displaced its whole exposed history and the ladder must read
        # the first window. Anything below 0 is corruption and falls back to
        # the fixed first window (a ladder there re-seeks to the seam anyway,
        # so the fallback costs a bounded run of unproven empties, not a hole).
        offset=(
            offset
            if offset is not None and offset >= 0
            else SESSION_ROTATION_FIRST_OFFSET
        ),
        circle_candidates=_optional_int(value.get("circleCandidates")) or 0,
        circle_rebuilt=_optional_int(value.get("circleRebuilt")) or 0,
        stall_circles=_optional_int(value.get("stallCircles")) or 0,
        circle_windows=_optional_int(value.get("circleWindows")) or 0,
        unproven_empties=_optional_int(value.get("unprovenEmpties")) or 0,
        circle_stalls=_optional_int(value.get("circleStalls")) or 0,
        windows_since_reseek=_optional_int(value.get("windowsSinceReseek")) or 0,
        library_extent=_optional_int(value.get("libraryExtent")) or 0,
        past_library_extent=value.get("pastLibraryExtent") is True,
        circles=_optional_int(value.get("circles")) or 0,
        idle_reads=_optional_int(value.get("idleReads")) or 0,
        rest_cycles=_optional_int(value.get("restCycles")) or 0,
    )


def session_rotation_state_payload(state: SessionRotationState) -> dict[str, Any]:
    return {
        "version": SESSION_ROTATION_STATE_VERSION,
        "active": state.active,
        "offset": state.offset,
        "circleCandidates": state.circle_candidates,
        "circleRebuilt": state.circle_rebuilt,
        "stallCircles": state.stall_circles,
        "circleWindows": state.circle_windows,
        "unprovenEmpties": state.unproven_empties,
        "circleStalls": state.circle_stalls,
        "windowsSinceReseek": state.windows_since_reseek,
        "libraryExtent": state.library_extent,
        "pastLibraryExtent": state.past_library_extent,
        "circles": state.circles,
        "idleReads": state.idle_reads,
        "restCycles": state.rest_cycles,
    }


def session_rotation_mode() -> str:
    """The rotation mode for this cycle, read fresh so it flips without a restart.

    Unknown values fail safe to `off`: an operator typo must never enable a
    library-wide rebuild loop.
    """

    raw = os.environ.get(SESSION_ROTATION_ENV)
    if raw is None:
        return SESSION_ROTATION_OFF
    value = raw.strip().lower()
    return value if value in _SESSION_ROTATION_MODES else SESSION_ROTATION_OFF


def _page_read_failed(page: Any) -> bool:
    """Whether a session page is empty because its read raised (R1 P1-2).

    Only the Claude reader reports this (`SessionListPage.read_failed`); for
    every other runtime an empty page keeps its old meaning, which is the
    conservative one here: a sweep that ends early is what the repair exists
    to stop, and a runtime that cannot say "my read failed" has never claimed
    otherwise.
    """

    return getattr(page, "read_failed", False) is True


def _page_history_scanned(page: Any) -> int:
    """How many library sessions the page read before filtering/truncation.

    Larger than the page length exactly when the reader's live/active filters
    emptied the window, which means the library continues past it.
    """

    scanned = getattr(page, "history_scanned", None)
    if isinstance(scanned, bool) or not isinstance(scanned, int):
        return len(page)
    return scanned


def _page_reported_seam(page_one_page: Any) -> int | None:
    """Page 1's own report of how many history sessions it exposed, if any.

    Only an explicit marker counts. `len(page)` is NOT the seam — page 1 is
    the local overlay merged over history, so its length says nothing about
    how far into the history list the page reached.
    """

    scanned = getattr(page_one_page, "history_scanned", None)
    if isinstance(scanned, bool) or not isinstance(scanned, int):
        return None
    return scanned


def _page_one_complete(page_one_page: Any) -> bool:
    """Whether page 1 itself proved it covers the entire library (T1b).

    Only the Claude reader reports this (`SessionListPage.page_one_complete`):
    the history list read whole — fewer rows than the page size, every one
    keyed, every session it would compare represented on the merged page. For
    every other runtime the answer is False, which keeps the sweep walking
    windows exactly as it did before the verdict existed.
    """

    return getattr(page_one_page, "page_one_complete", False) is True


def _first_rotation_offset(page_one_page: Any) -> int:
    """Where a starting or wrapping ladder should aim (R1 P2-6, T1b).

    Page 1 is the local overlay merged over `history[0:limit]` and then
    truncated, so local-only sessions push the tail of that history range off
    the page; those sessions are in no rotation window either. A reader that
    reports its seam (how many history sessions page 1 really exposed — its
    `history_scanned` field) is believed, and the ladder starts there, which
    is inside the usual first window when there was displacement and exactly
    the first window when there was not. A reader that reports nothing keeps
    the fixed page boundary, and so does one whose read failed — a seam of 0
    from a failed read says nothing about displacement.

    A seam of 0 with a successful read says exactly one thing (T1b): page 1
    exposed no history session under its own identity, so whatever readable
    history it left uncovered is the first thing the ladder must walk. The
    reader's coverage verdict sharpens that: a page whose history list was
    fully represented anyway (every row merged under its local identity)
    reports itself complete, and page 1 is the wrong thing to re-read — the
    sweep returns before the ladder in that case. What is left here is a
    seam-0 page that does not cover the library, which means readable rows
    exist that it did not show; they start at 0, and the fixed boundary
    would step straight over them — with every window past them legitimately
    empty, the sweep would never look back.
    """

    seam = _page_reported_seam(page_one_page)
    if seam is None or _page_read_failed(page_one_page):
        return SESSION_ROTATION_FIRST_OFFSET
    if seam >= SESSION_ROTATION_MIN_OFFSET:
        return seam
    if _page_one_complete(page_one_page):
        return SESSION_ROTATION_FIRST_OFFSET
    return 0


def _optional_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _session_meta_notification(session: SessionMeta) -> dict[str, Any]:
    return {
        "method": "session.meta.upsert",
        "params": _drop_none(
            {
                "sessionId": session.session_id,
                "runtime": session.runtime,
                "runtimeId": session.runtime_id,
                "externalSessionId": session.external_session_id,
                "title": session.title,
                "cwd": session.cwd,
                "lastActivityAt": session.ordering_time,
                "sourceObservedAt": (
                    session.source_state.observed_at
                    if session.source_state is not None
                    else None
                ),
                "sourceState": (
                    {
                        "availability": session.source_state.availability,
                        "reason": session.source_state.reason,
                        "observedAt": session.source_state.observed_at,
                        "observationOrigin": session.source_state.observation_origin,
                    }
                    if session.source_state is not None
                    else None
                ),
                "metadata": dict(session.metadata),
            }
        ),
    }


def _inventory_begin_notification(
    runtime_type: str,
    runtime_id: str,
    scan_token: str,
) -> dict[str, Any]:
    return {
        "method": "session.inventory.begin",
        "params": {
            "runtime": runtime_type,
            "runtimeId": runtime_id,
            "scanToken": scan_token,
        },
    }


def _inventory_complete_notification(
    runtime_type: str,
    runtime_id: str,
    scan_token: str,
    sessions: tuple[SessionMeta, ...],
    *,
    complete: bool,
) -> dict[str, Any]:
    return {
        "method": "session.inventory.complete",
        "params": {
            "runtime": runtime_type,
            "runtimeId": runtime_id,
            "scanToken": scan_token,
            "complete": complete,
            "sessions": [
                _drop_none(
                    {
                        "sessionId": session.session_id,
                        "externalSessionId": session.external_session_id,
                        "sourceState": _inventory_source_state(session),
                    }
                )
                for session in sessions
            ],
        },
    }


def _inventory_source_state(session: SessionMeta) -> str | dict[str, Any]:
    if session.source_state is not None:
        return _drop_none(
            {
                "availability": session.source_state.availability,
                "reason": session.source_state.reason,
                "observedAt": session.source_state.observed_at,
                "observationOrigin": session.source_state.observation_origin,
            }
        )
    metadata = session.metadata
    if any(
        metadata.get(key) is True
        for key in (
            "hidden",
            "localArchived",
            "local_archived",
            "localDeleted",
            "local_deleted",
        )
    ):
        return "hidden"
    if metadata.get("resumeSupported") is False or metadata.get("resumable") is False:
        return "hidden"
    local_state = metadata.get("localState") or metadata.get("local_state")
    return (
        "hidden" if local_state in {"archived", "deleted", "unresumable"} else "visible"
    )


def _timeline_sync_notification(
    snapshot: RuntimeTimelineSnapshot,
    fallback_item_time: str | None = None,
) -> dict[str, Any]:
    server_items = tuple(
        item for item in snapshot.items if item.type not in {"turn.start", "turn.end"}
    )
    return {
        "method": "timeline.sync",
        "params": _drop_none(
            {
                "sessionId": snapshot.session_id,
                "runtime": snapshot.runtime,
                "runtimeId": snapshot.runtime_id,
                "externalSessionId": snapshot.external_session_id,
                "items": [
                    _runtime_timeline_item_payload(
                        item,
                        fallback_time=fallback_item_time,
                    )
                    for item in server_items
                ],
                "complete": snapshot.complete,
                "metadata": dict(snapshot.metadata),
            }
        ),
    }


def _runtime_timeline_item_payload(
    item: RuntimeTimelineItem,
    fallback_time: str | None = None,
) -> dict[str, Any]:
    payload = _timeline_item_payload(item)
    if fallback_time is not None:
        payload.setdefault("createdAt", fallback_time)
        payload.setdefault("updatedAt", fallback_time)
    return payload


def _session_state_notification(state: SessionState) -> dict[str, Any]:
    return {
        "method": "session.state.updated",
        "params": _drop_none(
            {
                "sessionId": state.session_id,
                "runtime": state.runtime,
                "runtimeId": state.runtime_id,
                "externalSessionId": state.external_session_id,
                "status": state.status,
                "statusReason": state.status_reason,
                "error": dict(state.error) if state.error is not None else None,
                "selections": dict(state.selections),
                "metadata": dict(state.metadata),
            }
        ),
    }


def _notice_notification(notice: SessionNotice) -> dict[str, Any]:
    return {"method": "notice.upsert", "params": session_notice_payload(notice)}
