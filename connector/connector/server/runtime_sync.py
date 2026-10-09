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
# starts one window in.
SESSION_ROTATION_FIRST_OFFSET = SESSION_ROTATION_PAGE_SIZE
# Rebuilds on rotation windows are capped per cycle (task card §3 T1.4: 5~10),
# so a library-wide projection bump spreads over hours instead of spiking
# CPU/IO/ingest in minutes. Page 1 is never capped — freshness is its job.
SESSION_ROTATION_REBUILD_BUDGET = 8
# Consecutive circles that ended with candidates but no successful rebuild
# before the sweep gives up and sleeps (a poison session must not keep the
# whole sweep awake).
SESSION_ROTATION_STALL_CIRCLES = 3
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
                            page_one_sessions=sessions,
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
        page_one_sessions: tuple[SessionMeta, ...],
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
        """

        mode = session_rotation_mode()
        if mode == SESSION_ROTATION_OFF:
            return
        state = await self._rotation_state(scoped_runtime_id, runtime_type)
        if not state.active:
            outdated = sum(
                1
                for session in page_one_sessions
                if session_projection_outdated(session)
            )
            if outdated == 0:
                return
            state = SessionRotationState(active=True)
            logger.info(
                "session rotation sweep activated runtime={} outdated_page_one_sessions={}",
                runtime_id,
                outdated,
            )
            # Persist before the first window read: if that read fails, the
            # activation must survive the cycle — the page-1 signal that opened
            # the sweep may already be rebuilt by the time the next cycle runs.
            await self._record_rotation_state(scoped_runtime_id, runtime_type, state)
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
            # End of the library: the circle is complete (page 1 plus every
            # rotation window has been compared).
            if mode == SESSION_ROTATION_REPORT or state.circle_candidates == 0:
                logger.info(
                    "session rotation sweep completed runtime={} offset={} candidates_this_circle={}",
                    runtime_id,
                    state.offset,
                    state.circle_candidates,
                )
                await self._record_rotation_state(
                    scoped_runtime_id, runtime_type, SessionRotationState()
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
                        scoped_runtime_id, runtime_type, SessionRotationState()
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
                    SessionRotationState(active=True, stall_circles=stall),
                )
                return
            await self._record_rotation_state(
                scoped_runtime_id, runtime_type, SessionRotationState(active=True)
            )
            return
        candidates = [
            session for session in page if session_requires_timeline_sync(session)
        ]
        circle_candidates = state.circle_candidates + len(candidates)
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
        logger.info(
            "session rotation window runtime={} offset={} sessions={} candidates={} rebuilt={}",
            runtime_id,
            state.offset,
            len(page),
            len(candidates),
            rebuilt,
        )
        await self._record_rotation_state(
            scoped_runtime_id,
            runtime_type,
            replace(
                state,
                offset=state.offset + SESSION_ROTATION_PAGE_SIZE,
                circle_candidates=circle_candidates,
                circle_rebuilt=state.circle_rebuilt + rebuilt,
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
    cycle already, so the ladder starts one window in. `circle_candidates` and
    `circle_rebuilt` accumulate over the circle currently being scanned: a
    circle that ends with no candidates compared clean and puts the sweep to
    sleep; a circle that ends with candidates but zero successful rebuilds
    counts as stalled, and the stall limit stops one poison session from
    keeping the sweep awake forever.
    """

    active: bool = False
    offset: int = SESSION_ROTATION_FIRST_OFFSET
    circle_candidates: int = 0
    circle_rebuilt: int = 0
    stall_circles: int = 0


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
        offset=(
            offset
            if offset is not None and offset >= SESSION_ROTATION_FIRST_OFFSET
            else SESSION_ROTATION_FIRST_OFFSET
        ),
        circle_candidates=_optional_int(value.get("circleCandidates")) or 0,
        circle_rebuilt=_optional_int(value.get("circleRebuilt")) or 0,
        stall_circles=_optional_int(value.get("stallCircles")) or 0,
    )


def session_rotation_state_payload(state: SessionRotationState) -> dict[str, Any]:
    return {
        "version": SESSION_ROTATION_STATE_VERSION,
        "active": state.active,
        "offset": state.offset,
        "circleCandidates": state.circle_candidates,
        "circleRebuilt": state.circle_rebuilt,
        "stallCircles": state.stall_circles,
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
