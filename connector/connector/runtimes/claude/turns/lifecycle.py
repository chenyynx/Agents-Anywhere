from __future__ import annotations

import asyncio
import secrets
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, replace
from typing import Any

from connector.logging import logger
from connector.runtime_protocol import (
    RuntimeAttachment,
    RuntimeConfig,
    RuntimeTimelineItem,
    timeline_content_hash,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.catalogs.reader import ClaudeCatalogReader
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
    client_message_text_matches,
)
from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.notifications.projector import (
    ClaudeNotificationProjector,
)
from connector.runtimes.claude.sdk.client import (
    ClaudeClientFactory,
    SdkLoader,
    connect_client,
    load_sdk,
    new_sdk_client,
    query_client,
    receive_response_messages,
)
from connector.runtimes.claude.sdk.connection import (
    ClaudeConnection,
    ClaudeResponse,
    _is_wire_chrome,
)
from connector.runtimes.claude.sdk.events import (
    ClaudeTerminalEvent,
    failed_terminal_event,
    interrupted_terminal_event,
    terminal_event_from_message,
)
from connector.runtimes.claude.sdk.settings import (
    create_gateway_settings_file,
    remove_gateway_settings_file,
)
from connector.runtimes.claude.sdk.stderr import ClaudeStderrBuffer
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sdk.title_tool import build_change_title_tool
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.scheduled import ClaudeScheduledSessions
from connector.runtimes.claude.timeline.agent_calls import (
    agent_task_overlay_for_event,
)
from connector.runtimes.claude.timeline.markers import (
    ClaudeTimelineMarkers,
    claude_compact_event,
    is_compaction_control_message,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    is_synthetic_control_message,
    message_id,
    message_role,
    message_session_id,
    message_text,
    stable_message_item_id,
    stable_tool_item_id,
)
from connector.runtimes.claude.timeline.stream import (
    ClaudeStreamAccumulator,
    is_stream_event,
)
from connector.runtimes.claude.turns.attachments import (
    content_with_attachment_notes,
    materialize_claude_attachments,
)
from connector.runtimes.claude.turns.interactions import ClaudeInteractionController

# The execution-lock circuit breaker (pp verdict, 2026-10-02, product-level):
# guarding a minted-from-silence turn is invariant-shaped, not trigger-shaped,
# so the deadline is a fixed budget any unknown wire shape falls into.
#
# This budget governs the ZERO-CONTENT class only (claude-watchdog-longrun-
# tasks.md §2 G1/G3). A turn that published a timeline item or consumed a
# non-chrome wire frame is a real long-running turn — the shape a subagent
# wake-up or a post-compaction resume takes — and the pure timer used to kill
# it at 30.002s regardless (production 17/17 firings), which retired the
# transport, killed the host CLI and every subagent in it, and lost the reply.
POLLED_TURN_WATCHDOG_SECONDS = 30.0

# The absolute ceiling for a turn that left the zero-content class. It exists
# so the content gate cannot become "long turns never settle" — the red line
# in §5 — and it is deliberately on the same magnitude as the CLI's own tool
# timeouts (Bash 600s, 420s; `idleTimeoutSeconds=600`). The longest tool this
# product has ever been observed running is 223.4s (AskUserQuestion), so the
# headroom is wide; the timing is measured from the cast, not from when the
# content showed up.
CONTENTING_TURN_WATCHDOG_SECONDS = 600.0

# G4: why the breaker fired. The two values are the whole diagnosis of a
# watchdog log line, so they are named once and reused by the fire line, the
# retirement-skip line and the fatal-close line.
WATCHDOG_REASON_ZERO_CONTENT = "zero_content_fast_kill"
WATCHDOG_REASON_CONTENT_CEILING = "containing_turn_ceiling"


@dataclass(slots=True)
class ClaudeTurnRunner:
    config: RuntimeConfig
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    timeline: ClaudeMessageProjector
    notifications: ClaudeNotificationProjector
    interactions: ClaudeInteractionController
    pending_messages: ClaudePendingClientMessageRegistry
    catalogs: ClaudeCatalogReader
    sdk_loader: SdkLoader | None = None
    client_factory: ClaudeClientFactory | None = None
    connections: dict[str, ClaudeConnection] = field(default_factory=dict, init=False)
    # Cron* bookkeeping handed over by a transport that was retired before its
    # replacement was built. `close()` drops the retired connection from
    # `connections`, so without this a breaker (or any failed turn) would
    # silently untrack a session's scheduled tasks.
    carried_task_ids: dict[str, set[str]] = field(default_factory=dict, init=False)
    # L2 subagent progress: task_started binds (session_id, task_id) to the
    # dispatch tool_use id — the double key verified against the wire (L2 A1
    # findings §2) — because task_updated carries no tool_use_id at all. In
    # memory only: task frames live and die with the transport that hosts the
    # work (findings §8.7 on the pipeline's own dedup).
    agent_task_calls: dict[tuple[str, str], str] = field(
        default_factory=dict, init=False
    )
    # B: terminal frames the start gate refused to settle this turn on. Read by
    # the post-deploy observation window alongside `ClaudeConnection
    # .absorbed_terminal_frames`: the two are the same leak seen at its two
    # entry points (the reader refusing to mint, the turn refusing to settle).
    foreign_terminal_frames: int = field(default=0, init=False)
    stopping: bool = False
    markers: ClaudeTimelineMarkers = field(init=False)
    scheduled_sessions: ClaudeScheduledSessions = field(init=False)

    def __post_init__(self) -> None:
        # One allocator for the whole timeline: a compaction separator must
        # never reuse an order_seq a projected message already published.
        self.markers = ClaudeTimelineMarkers(
            order_allocator=self.timeline.order_seq_for,
        )
        self.scheduled_sessions = ClaudeScheduledSessions(self.host)

    async def stop(self) -> None:
        self.stopping = True
        for connection in tuple(self.connections.values()):
            await connection.close()

    async def reconnect_sessions(self) -> None:
        """Resume only AA sessions previously observed to have scheduled tasks."""
        if self.stopping:
            return
        for session_id, saved in (await self.scheduled_sessions.read()).items():
            session = self.session_store.ensure(
                session_id=session_id,
                external_session_id=saved["externalSessionId"],
                cwd=saved["cwd"],
            )
            if session.execution is not None or session_id in self.connections:
                continue
            session.selections = dict(saved["selections"])
            try:
                connection = await self.connection_for(
                    session, ClaudeStderrBuffer(session.session_id)
                )
                connection.task_ids.update(saved["taskIds"])
                connection.queried.set()
                await connection.connect()
            except Exception as exc:  # noqa: BLE001
                await self.notifications.session_state.session_state_update(
                    session,
                    "error",
                    error={
                        "code": "claude_schedule_resume_failed",
                        "message": str(exc),
                    },
                    metadata={"source": "claude.scheduled.resume"},
                )

    async def scheduled_activity(
        self, session: ClaudeSession, response: ClaudeResponse
    ) -> None:
        async with session.execution_lock:
            if self.stopping:
                return
            if response.execution is not None:
                return
            session.queued_execution = session.execution
            execution = ClaudeExecution(
                turn_id=f"turn_claude_{secrets.token_urlsafe(12)}"
            )
            session.execution = execution
            response.execution = execution
            try:
                await self.notifications.session_state.session_state_update(
                    session,
                    "running",
                    metadata={"source": "claude.scheduled.running"},
                )
                execution.task = asyncio.create_task(
                    self.drive_turn(
                        session,
                        execution,
                        "",
                        (),
                        None,
                        scheduled=True,
                        response=response,
                    )
                )
                self.arm_scheduled_watchdog(session, execution, response)
            except BaseException:
                self.disarm_scheduled_watchdog(execution)
                session.execution = session.queued_execution
                session.queued_execution = None
                execution.finished.set()
                raise

    def arm_scheduled_watchdog(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
    ) -> None:
        """Arm the execution-lock circuit breaker for one scheduled turn.

        This is the main defense against the ghost turn (pp verdict, 2026-10-02,
        product-level and highest priority). The trigger cannot be enumerated:
        a scheduled turn may be minted by any wire shape the connector reader
        has never seen before. What is invariant is what a stuck turn looks
        like: it holds `session.execution`, it never sees a terminal event, and
        it publishes nothing. After a silence deadline we force a failed
        terminal, release the lock and surface a one-line WARNING. The worst
        possible user experience is capped at one failed bubble instead of a
        session that is permanently running with the composer disabled.

        The deadline this used to apply unconditionally is now two-stage
        (§2 G1–G3 of claude-watchdog-longrun-tasks.md). The zero-content class
        keeps the original budget, so the P0 above is untouched; a turn that
        published items or consumed non-chrome frames leaves the fast kill and
        is only bounded by an absolute ceiling. Both counts exclude everything
        the queue held up to and including the cast frame — preamble flush +
        cast, by position, because passive arrival is not labour — so a
        re-cast's lone residue frame (B5: in-flight `tool_result`,
        StreamEvent), with or without stale preamble in front of it, still
        lands in the fast kill it had before B3a instead of buying the ghost
        ten minutes of held lock. The exemption is on the FAST KILL only — a
        long turn can never become "never settled".
        """

        execution.watchdog_task = asyncio.create_task(
            self._scheduled_watchdog(
                session,
                execution,
                response,
                POLLED_TURN_WATCHDOG_SECONDS,
            )
        )

    def disarm_scheduled_watchdog(self, execution: ClaudeExecution) -> None:
        task = execution.watchdog_task
        execution.watchdog_task = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()

    @staticmethod
    async def _await_watchdog_deadlines(
        execution: ClaudeExecution,
        timeout: float,
        ceiling: float,
    ) -> str | None:
        """Wait out both deadlines; return why the breaker has to fire.

        `None` means the turn settled on its own and there is nothing to do.

        The two deadlines are sequential rather than concurrent, which is what
        "absolute ceiling" means: the fast kill is measured from the cast, and
        the ceiling is a second wait covering only the time the first one left.
        A turn that produces content at t=1s is re-armed for the remaining
        570s; one that produces it at t=599s still has to settle by t=600s.
        """

        try:
            await asyncio.wait_for(execution.finished.wait(), timeout)
            return None
        except TimeoutError:
            pass
        if not execution.has_turn_content:
            return WATCHDOG_REASON_ZERO_CONTENT
        try:
            await asyncio.wait_for(
                execution.finished.wait(), max(0.0, ceiling - timeout)
            )
            return None
        except TimeoutError:
            return WATCHDOG_REASON_CONTENT_CEILING

    async def _scheduled_watchdog(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        timeout: float,
        ceiling: float | None = None,
    ) -> None:
        if ceiling is None:
            ceiling = CONTENTING_TURN_WATCHDOG_SECONDS
        reason = await self._await_watchdog_deadlines(execution, timeout, ceiling)
        if reason is None:
            return
        connection = response.connection
        active_tasks = len(connection.background.active_ids)
        logger.warning(
            "Claude scheduled turn watchdog fired reason={} "
            "published_items={} consumed_frames={} active_tasks={} "
            "no terminal within {}s (absolute ceiling {}s), "
            "forcing failed terminal session_id={} turn_id={}",
            reason,
            execution.published_items,
            execution.consumed_frames,
            active_tasks,
            timeout if reason == WATCHDOG_REASON_ZERO_CONTENT else ceiling,
            ceiling,
            session.session_id,
            execution.turn_id,
        )
        async with connection.stuck_report_lock:
            publish = connection.stuck_timeout_reports == 0
            if publish:
                # Reserve the single client-visible slot atomically (R2): a
                # watchdog firing concurrently must not double-report.
                connection.stuck_timeout_reports += 1

        async def release_reserved_slot() -> None:
            if publish:
                async with connection.stuck_report_lock:
                    connection.stuck_timeout_reports -= 1

        try:
            settled = await self.finish_execution(
                session=session,
                execution=execution,
                terminal=failed_terminal_event(
                    code="claude_scheduled_turn_timeout",
                    message=(
                        "Scheduled work did not report a result within "
                        f"{int(timeout if reason == WATCHDOG_REASON_ZERO_CONTENT else ceiling)}"
                        " seconds"
                    ),
                    reason="scheduled_watchdog_timeout",
                ),
                response=response,
                publish=publish,
            )
        except BaseException:
            # A publication that raised (host I/O) must not leak the reserved
            # slot: a later genuine timeout still has to reach the ledger (R3).
            await release_reserved_slot()
            raise
        if not settled:
            # The turn settled by itself inside the race window; its own exit
            # path already decided what happens to the transport. Release the
            # reserved slot so a later genuine timeout can still report.
            await release_reserved_slot()
            return
        await self.retire_stuck_transport(
            session,
            execution,
            response,
            reason=reason,
            client_reported=publish,
        )

    async def retire_stuck_transport(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        *,
        reason: str | None = None,
        client_reported: bool = True,
    ) -> None:
        """Retire everything the stuck turn left behind on its connection.

        Releasing `session.execution` is only half of the circuit breaker. The
        turn also owns the reader's `current` response, its own `drive_turn`
        task, and the transport they share — and each one outlives the release:

        * the zombie task keeps draining the reader's queue, so the next human
          message is answered into it and lost;
        * when a terminal finally arrives the zombie's `finish_execution`
          returns early on the flag this watchdog just set, so
          `response.release()` never runs and the reader parks on `released`
          forever.

        Left alone, the session looks unlocked while being permanently
        unusable, which is worse than the ghost it replaced. So the breaker
        finishes the job the turn could not: the response is already released
        by `finish_execution`, the zombie task is cancelled, and the transport
        is retired the same way any failed turn retires it — a native prompt
        cannot be retracted one turn at a time. The next turn rebuilds the
        connection from stored session state, which is the only recovery that
        does not depend on guessing what the CLI thought it was doing.

        The transport kill is withheld while `has_live_background_work` is
        true — background subagents/commands exist nowhere else, and upstream
        never replays in-flight work after process loss. The ghost response is
        dropped instead so the reader can route again.
        """

        connection = response.connection
        zombie = execution.task
        execution.task = None
        if zombie is not None and zombie is not asyncio.current_task():
            zombie.cancel()
        if connection.has_live_background_work:
            # Do-not-retire invariant (pp verdict, 2026-10-02, product-level):
            # the CLI process is the only place live background work exists.
            # Upstream keeps the transport for exactly this reason
            # (docs/claude-session-lifecycle.md: the connection is not
            # reclaimed while a background task is active, and in-flight
            # background work is not replayed after process loss). The breaker
            # has already released the lock through `finish_execution`; the
            # only action withheld here is killing the host process the
            # running subagents/commands live in. The zombie cancel above
            # still runs so the next human turn is not answered into it, and
            # the ghost response is dropped so the reader can route again.
            logger.warning(
                "Claude stuck-turn retirement skipped: background work is live "
                "session_id={} turn_id={} active_tasks={} published_items={} "
                "consumed_frames={}",
                session.session_id,
                execution.turn_id,
                len(connection.background.active_ids),
                execution.published_items,
                execution.consumed_frames,
            )
            connection.drop_current(response)
            return
        task_ids = set(connection.task_ids)
        if task_ids:
            self.carried_task_ids[session.session_id] = task_ids
            try:
                await self.scheduled_sessions.save(session, task_ids)
            except Exception as exc:  # noqa: BLE001
                logger.exception(
                    "Claude scheduled task handover failed session_id={}: {}",
                    session.session_id,
                    exc,
                )
        # G4: this is the only branch that kills the host CLI process, and with
        # it every subagent running inside that process. It is logged on its own
        # line, BEFORE the close, and deliberately outside the client-visible
        # limiter above: the limiter only decides whether the failed turn reaches
        # the ledger, but a process death is not a ledger event, and on 2026-10-03
        # 13:49 exactly this branch fired on a rate-limited watchdog
        # (`stuck_timeout_reports` already spent) and left no server-side trace
        # of a killed process anywhere. Server WARNING, not a ledger report.
        logger.warning(
            "Claude stuck transport retirement is FATAL: closing the host CLI "
            "process and every subagent in it session_id={} turn_id={} "
            "reason={} published_items={} consumed_frames={} active_tasks=0 "
            "client_reported={}",
            session.session_id,
            execution.turn_id,
            reason,
            execution.published_items,
            execution.consumed_frames,
            client_reported,
        )
        try:
            await connection.close()
        except Exception as exc:  # noqa: BLE001
            logger.exception(
                "Claude stuck transport retirement failed session_id={}: {}",
                session.session_id,
                exc,
            )

    async def reclaim_idle_connection(
        self, session: ClaudeSession, connection: ClaudeConnection
    ) -> None:
        async with session.execution_lock:
            if (
                self.connections.get(session.session_id) is not connection
                or self.stopping
                or connection.closing
                or session.execution is not None
                or session.queued_execution is not None
                or connection.current is not None
                or connection.pending is not None
                or connection.task_ids
                or connection.background.active_ids
            ):
                return
            await connection.close()

    async def reconcile_after_background(
        self, session: ClaudeSession, connection: ClaudeConnection
    ) -> None:
        try:
            async with session.execution_lock:
                if (
                    self.stopping
                    or self.connections.get(session.session_id) is not connection
                    or connection.closing
                    or session.execution is not None
                    or connection.current is not None
                    or connection.pending is not None
                    or connection.background.active_ids
                    or not connection.reconcile_needed
                    or not connection.retained
                    or connection.reconciling
                ):
                    return
            # The SDK reader can discover a scheduled reply while this prompt is
            # queued. Its on_activity callback needs execution_lock to own that
            # reply, so never hold the lock across the SDK round trip.
            await connection.reconcile_tasks()
            async with session.execution_lock:
                if (
                    self.stopping
                    or self.connections.get(session.session_id) is not connection
                    or connection.closing
                ):
                    return
                await self.scheduled_sessions.save(session, connection.task_ids)
                connection.arm_idle()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude deferred task reconciliation failed session_id={}",
                session.session_id,
            )

    async def fold_agent_task_event(
        self,
        session: ClaudeSession,
        event: ClaudeTaskEvent,
    ) -> None:
        """Fold one CLI task event into its Agent call card (L2 progress).

        Aggregation is display state: it must never break the reader that
        routes the session's frames (the L1 lesson — nothing on this path may
        take a transport down), so every failure is logged and swallowed.

        `local_bash` tasks — including the background Bash a subagent itself
        runs — never surface: their tool ids point *inside* a subagent and
        there is no card to fold them into (L2 §3.4, findings §8.11).
        """

        try:
            key = (session.session_id, event.task_id)
            if event.kind == "started":
                # task_type exists only on task_started (the later frames
                # name the task, not its kind), so the local_bash filter runs
                # here and only a local_agent task is ever bound.
                if event.task_type != "local_agent" or event.tool_use_id is None:
                    return
                # The double key (findings §2): task_started.tool_use_id is
                # the dispatch call (== the card's metadata.toolUseId) and
                # task_id is the receipt agentId (== the card's agents-map
                # key). Binding here is what lets task_updated — which carries
                # no tool_use_id at all — find its card.
                self.agent_task_calls[key] = event.tool_use_id
            # Every non-started frame resolves through the binding alone —
            # never through its own tool_use_id, which for a local_bash task
            # points *inside* the subagent and would attach a Bash row to a
            # task that has no card (findings §8.11). An unbound task (its
            # task_started was filtered or missed) is not projected.
            tool_use_id = self.agent_task_calls.get(key)
            if tool_use_id is None:
                return
            if (
                event.session_id is not None
                and session.external_session_id != event.session_id
            ):
                # The fold can run before the turn projection has adopted the
                # native session id (the reader and the turn consume the same
                # stream through different queues), and the card's stable item
                # id is scoped by that id — adopting it here too keeps the
                # event and the dispatch on one card instead of two.
                await self._update_external_session_id(session, event.session_id)
            overlay, status = agent_task_overlay_for_event(event)
            item = self.timeline.fold_agent_task_event(
                session,
                tool_use_id=tool_use_id,
                overlay=overlay,
                status=status,
            )
            previous = session.timeline_items.get(item.id)
            if (
                previous is not None
                and previous.status == item.status
                and dict(previous.content) == dict(item.content)
            ):
                # Idempotent closure (L2 §3.4): the terminal burst repeats
                # itself — an identical card is not republished here, and the
                # batch coalesce / server dedup / content-hash no-op behind
                # this still catches anything that does (findings §8.7).
                return
            await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude task event folding failed session_id={} task_id={}",
                session.session_id,
                event.task_id,
            )

    async def publish_stopped_subagents(
        self,
        session: ClaudeSession,
        task_ids: Iterable[str],
        *,
        reason: str | None = None,
    ) -> int:
        """Tell the agent card, at the stop, which subagents the stop killed.

        P2-N1 (claude-stale-frame-turn-tasks.md §4/§11). The gap this closes is
        measured, not hypothetical: on 2026-10-04 12:18 the agent kept reporting
        "still running in the background" 20 s after the user hit stop, the
        client card did not flip for 4m41s, and the CLI's own notification for
        the same events came 4m43s late. The information was never missing — the
        CLI emits `task_notification` for every task it kills, and the L2 fold
        already binds `task_id -> card` — it simply arrived after anyone was
        still looking at the turn.

        So the connector stops waiting for it. A stop knows exactly which tasks
        it killed: `ClaudeBackgroundTasks.active_ids` is the live set on that
        transport, and every id in it is bound to a card by the L2 fold (killed
        tasks are 100% capturable — findings §8.7). Each is re-folded as the
        `task_updated`/killed event the CLI itself would have sent, which is the
        point: the same normalizer, the same overlay table
        (`AGENT_TASK_TERMINAL_STATUSES` maps killed -> interrupted), the same
        idempotent closure. The CLI's late notification then finds a card
        already in the state it would have set, and publishes nothing.

        Only ids the caller vouches for are folded, because that is the one
        guard this needs: a "killed" overlay on a card the CLI already closed
        as `done` would walk a finished card backwards. The caller reads the
        live set, so finished cards are never in it.

        Nothing here changes what a stop does — it only says what already
        happened, on a surface that is already there. A notification into the
        model's own context would mean sending a prompt to the process the user
        just killed, which is the one thing a stop must not do.
        """

        stopped = 0
        for task_id in task_ids:
            await self.fold_agent_task_event(
                session,
                ClaudeTaskEvent(
                    kind="updated",
                    task_id=task_id,
                    session_id=session.external_session_id,
                    status="killed",
                ),
            )
            stopped += 1
        if stopped:
            logger.warning(
                "Claude subagents reported stopped session_id={} tasks={} "
                "reason={}",
                session.session_id,
                stopped,
                reason,
            )
        return stopped

    async def project_background_frame(
        self,
        session: ClaudeSession,
        message: Any,
    ) -> None:
        """Project one subagent frame that reached silence into the timeline.

        L1 absorbs these frames so they can never mint a scheduled reply; L2
        captures them at the same guard so the subagent's thinking, text and
        tool rows become visible instead of dropped. The shared projector is
        what already owns this session's item ids and order slots, so the rows
        converge with the in-turn projection and the history rebuild — and
        every row is attributed to the card the frame is parented to
        (`content.parentItemId`; messages.py tags tool rows, helper below the
        reasoning/message rows). Nothing here mints a turn.
        """

        try:
            native_session_id = message_session_id(message)
            if (
                native_session_id is not None
                and session.external_session_id != native_session_id
            ):
                # Same scope-adoption rule as the task fold: captured rows
                # must hash under the native session id the turn uses.
                await self._update_external_session_id(session, native_session_id)
            parent_tool_use_id = _parent_tool_use_id(message)
            parent_item_id = (
                stable_tool_item_id(session, parent_tool_use_id)
                if parent_tool_use_id is not None
                else None
            )
            turn_id = self._subagent_turn_id(session, parent_tool_use_id)
            items: list[RuntimeTimelineItem] = [
                *self.timeline.tool_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                ),
                *self.timeline.system_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    event="claude.subagent.system",
                ),
            ]
            role = message_role(message)
            text = message_text(message)
            if (
                role in {"assistant", "system"}
                and text
                and not is_synthetic_control_message(message)
            ):
                items.append(
                    self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role=role,
                        text=text,
                        event=f"claude.subagent.{role}",
                        native_item_id=message_id(message),
                    )
                )
            for item in items:
                await self.notifications.timeline_activity.timeline_item_upsert(
                    _with_parent_card(item, parent_item_id)
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude subagent frame projection failed session_id={}",
                session.session_id,
            )

    def _subagent_turn_id(
        self,
        session: ClaudeSession,
        parent_tool_use_id: str | None,
    ) -> str:
        """Pick the turn id for a row projected from a captured subagent frame.

        The frames land while the dispatch turn has already settled, so the
        value is bookkeeping (no client sections by it): the parent card's own
        turn is inherited when it has been projected, and the deterministic
        fallback keeps one subagent's rows together under a stable id.
        """

        if parent_tool_use_id is None:
            return "turn_claude_subagent_orphan"
        parent_item_id = stable_tool_item_id(session, parent_tool_use_id)
        parent = session.timeline_items.get(parent_item_id)
        if parent is not None and parent.turn_id:
            return parent.turn_id
        return f"turn_claude_subagent_{parent_item_id}"

    async def connection_for(
        self,
        session: ClaudeSession,
        stderr: ClaudeStderrBuffer,
    ) -> ClaudeConnection:
        existing = self.connections.get(session.session_id)
        if existing is not None:
            if not existing.closing and existing.selections == session.selections:
                existing.cancel_idle()
                return existing
            if existing.background.active_ids:
                raise RuntimeError(
                    "Claude selection change requires background work to finish"
                )
            await existing.close()
        # A transport retired out of band (the scheduled-turn circuit breaker)
        # is already gone from `connections`, so its Cron* bookkeeping arrives
        # here by handover instead of by the registry entry above.
        carried = self.carried_task_ids.pop(session.session_id, None)
        # Scheduled reconnect bypasses the normal start/update selection path.
        # Resolve its saved CLI-only selection before constructing SDK options.
        await self.catalogs.resolve_model_selection(session.selections.get("model"))
        sdk = load_sdk(self.sdk_loader)
        settings_path = create_gateway_settings_file(self.config.values)

        async def approval(tool_name, tool_input, context):
            await connection.prepare_approval()
            return await self.interactions.approval_callback(
                sdk,
                session,
                session.active_turn_id,
            )(tool_name, tool_input, context)

        async def tool_result(data, *args):
            result = await connection.tool_result(data, *args)
            native_id = data.get("session_id")
            if session.external_session_id is None and isinstance(native_id, str):
                await self._update_external_session_id(session, native_id)
            await self.scheduled_sessions.save(session, connection.task_ids)
            return result

        def cleanup():
            remove_gateway_settings_file(settings_path)
            if self.connections.get(session.session_id) is connection:
                self.connections.pop(session.session_id)

        async def apply_agent_title(title: str) -> None:
            # The agent named its own session. Keep the local record in sync
            # and publish immediately; the periodic inventory sync re-reads
            # the custom-title entry from Claude Code itself, so nothing here
            # has to survive a connector restart.
            self.session_store.update_meta(session, title=title)
            await self.notifications.session_state.session_meta_upsert(
                session,
                source="claude.session.agent_title",
            )

        title_control = build_change_title_tool(
            sdk,
            session_id=session.session_id,
            current_title=lambda: session.title,
            external_session_id=lambda: session.external_session_id,
            cwd=lambda: session.cwd,
            on_applied=apply_agent_title,
        )
        try:
            client = new_sdk_client(
                sdk=sdk,
                config_values=self.config.values,
                session=session,
                client_factory=self.client_factory,
                can_use_tool=approval,
                stderr=stderr.record,
                settings_path=settings_path,
                cli_models=self.catalogs.cli_models,
                on_tool_result=tool_result,
                before_tool=lambda data: connection.before_tool(data),
                title_control=title_control,
            )
        except BaseException:
            remove_gateway_settings_file(settings_path)
            raise
        connection = ClaudeConnection(
            client=client,
            on_activity=lambda response: self.scheduled_activity(session, response),
            on_idle=lambda current: self.reclaim_idle_connection(session, current),
            on_background_done=lambda current: self.reconcile_after_background(
                session, current
            ),
            # L2 subagent progress (claude-subagent-progress-tasks.md §3.4):
            # both routes publish items through the projector this runtime
            # already shares (`self.timeline`), so ids and order slots stay
            # convergent with the live turn projection and the history rebuild.
            on_task_event=lambda event: self.fold_agent_task_event(session, event),
            on_background_frame=lambda message: self.project_background_frame(
                session, message
            ),
            cleanup=cleanup,
            idle_timeout_seconds=self.config.values.get("idleTimeoutSeconds", 600),
            selections=dict(session.selections),
            task_ids=(
                set(existing.task_ids) | set(carried or ())
                if existing is not None
                else set(carried or ())
            ),
        )
        self.connections[session.session_id] = connection
        return connection

    async def refresh_idle_connection(self, session: ClaudeSession) -> None:
        async with session.execution_lock:
            existing = self.connections.get(session.session_id)
            if (
                self.stopping
                or session.execution is not None
                or existing is None
                or existing.selections == session.selections
                or existing.background.active_ids
            ):
                return
            try:
                connection = await self.connection_for(
                    session,
                    ClaudeStderrBuffer(session.session_id),
                )
                connection.queried.set()
                await connection.connect()
                await self.scheduled_sessions.save(session, connection.task_ids)
            except Exception as exc:  # noqa: BLE001
                connection = self.connections.get(session.session_id)
                if connection is not None:
                    await connection.close()
                await self.notifications.session_state.session_state_update(
                    session,
                    "error",
                    error={
                        "code": "claude_connection_refresh_failed",
                        "message": str(exc),
                    },
                    metadata={"source": "claude.connection.refresh"},
                )

    async def drive_turn(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        content: str,
        attachments: tuple[RuntimeAttachment, ...],
        client_message_id: str | None,
        scheduled: bool = False,
        response: ClaudeResponse | None = None,
        command: str | None = None,
    ) -> None:
        turn_id = execution.turn_id
        stderr = ClaudeStderrBuffer(session.session_id)
        client = response
        connection = response.connection if response is not None else None
        terminal: ClaudeTerminalEvent | None = None
        reserved_user_item = None
        attachment_mappings: tuple[dict[str, object], ...] = ()
        replayed_user_message: tuple[str, str] | None = None
        response_external_session_confirmed = False
        # A native command is CLI chrome rather than a message the user sent:
        # Claude never echoes it back, so no user item is reserved, published or
        # replayed. The compaction marker is the whole surface of the turn.
        user_message_published = scheduled or command is not None
        published_user_item_id: str | None = None
        stream_accumulator = ClaudeStreamAccumulator()
        try:
            if command is not None:
                # The user asked for this compaction: publish the running
                # separator before the prompt leaves, so a silent CLI settles
                # a visible marker instead of leaving the turn invisible. The
                # marker is the session's, because the CLI's verdict for it
                # usually arrives on a later turn than this one.
                await self.open_command_compact_marker(session, turn_id, execution)
            if client is None:
                connection = await self.connection_for(session, stderr)
                maintenance = connection.background_done_task
                if maintenance is not None and not maintenance.done():
                    # Keep the queued maintenance response's native user id in
                    # pending until it completes (or its 30-second timeout).
                    # Cancelling this user turn must not cancel shared upkeep.
                    await asyncio.shield(maintenance)
                    if self.stopping:
                        raise asyncio.CancelledError
                    if connection.closing:
                        task_ids = set(connection.task_ids)
                        connection = await self.connection_for(session, stderr)
                        connection.task_ids.update(task_ids)
                client = connection.response_for(execution)
            execution.client = client
            await connect_client(client)
            materialized_attachments = await materialize_claude_attachments(
                self.host,
                session.session_id,
                attachments,
            )
            effective_content = content_with_attachment_notes(
                content,
                materialized_attachments,
            )
            if not scheduled:
                await self.notifications.session_state.session_state_update(
                    session,
                    "running",
                    metadata={"source": "claude.turn.running"},
                )
            attachment_mappings = tuple(
                attachment.to_mapping() for attachment in materialized_attachments
            )
            if not scheduled:
                prompt_uuid = client.ensure_prompt_uuid() if command is None else None
                if command is None and (
                    client_message_id is not None
                    or session.external_session_id is not None
                ):
                    # Identity is known up front: publish the user item now so
                    # clients confirm the sent bubble without waiting for the
                    # first response byte. The SDK replay, the transcript and
                    # history all derive this exact item id from prompt_uuid.
                    # The registry binding is completed by the replay
                    # confirmation below, so it always follows the UUID the
                    # SDK actually used.
                    user_item = self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role="user",
                        text=content,
                        event="claude.turn.user",
                        client_message_id=client_message_id,
                        native_item_id=prompt_uuid,
                        item_id=stable_message_item_id(session, prompt_uuid),
                        attachments=attachment_mappings,
                    )
                    reserved_user_item = user_item
                    published_user_item_id = user_item.id
                    try:
                        await self.publish_user_message(
                            session=session,
                            item=user_item,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            native_message_id=None,
                        )
                        user_message_published = True
                    except Exception:  # noqa: BLE001
                        # Fall back to the content-gated publish; the turn still
                        # reaches Claude and the item is retried below.
                        logger.exception(
                            "Claude early user publish failed session_id={}",
                            session.session_id,
                        )
                elif command is None:
                    reserved_user_item = self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role="user",
                        text=content,
                        event="claude.turn.user",
                        client_message_id=client_message_id,
                        attachments=attachment_mappings,
                    )
                await query_client(client, effective_content)

            # The frame that cast this turn out of silence, stamped by the
            # reader's mint branch on the response itself. It is a structural
            # fact — "was this the frame the cast arrived on" — never a frame
            # type, because the trigger chain is not enumerable (C3).
            #
            # The gate is positional, covering BOTH halves of what was already
            # in the queue when the turn was born: the reader's preamble flush
            # (chrome parked at silence, delivered ahead of the cast frame)
            # and the cast frame itself. Neither is this turn's own labour —
            # the turn neither produced them nor chose to consume them, they
            # arrived passively. Only what comes AFTER the turn's own cast
            # counts, which is what separates the two ghosts the content gate
            # must tell apart: re-cast residue (one in-flight tool's
            # `tool_result` or a StreamEvent — with or without stale preamble
            # in front of it — then nothing ever → stays (0, 0) → 30s fast
            # kill) from a wake that keeps working (13:49: 248.6s, 155
            # timeline items → leaves the fast kill, bounded only by the
            # ceiling). Human/pending turns are never stamped
            # (`cast_frame is None`) so `cast_reached` starts True and every
            # post-cast frame is judged by the single `_is_wire_chrome`
            # authority, exactly as a scheduled turn's are.
            # Silence itself still proves nothing either way — no frame-based
            # reset exists, so a legal `sleep 75` (72.003s of zero-frame
            # silence) is never re-armed into a short deadline.
            cast_frame = client.cast_frame
            cast_reached = cast_frame is None
            # B · start gate (claude-stale-frame-turn-tasks.md §4/§11, D1).
            #
            # The consume loop drains a session-scoped stream: whatever the CLI
            # is still emitting when this turn takes the lock is in this queue,
            # including frames that belong to a turn which already settled. The
            # 12:23 ghost is exactly that — the interrupted turn's residual
            # result was still on the wire when the next message started (real
            # session sess_tPcEDi0z9xJYxQ, 2026-10-04). I1 refuses such a frame
            # to MINT a turn; B is the second half of the same invariant, on the
            # SETTLE side: a terminal only ends a turn that has shown a start
            # it owns, and one that cannot is counted and named.
            #
            # A turn's start, by kind:
            #
            #   cast turn      — the cast frame's own position (`message is
            #                   cast_frame`): the B1 content gate's positional
            #                   rule promoted to settlement. The cast frame and
            #                   everything flushed ahead of it are passive, so a
            #                   terminal there cannot settle the turn (it is
            #                   skipped; `counts_as_labour` is false there).
            #   prompted turn  — the prompt echo the `prompt_uuid` facility binds
            #                   above, or any other non-terminal frame: once the
            #                   turn has spoken, a later result is its own.
            #   command /
            #     maintenance  — no prompt uuid exists to pair with (the CLI does
            #                   not echo those), so there is no start evidence to
            #                   wait for and the gate starts open.
            #
            # WHAT THIS GATE DOES NOT DO, and why (recorded here so nobody
            # re-derives it as an oversight): an unowned terminal is counted and
            # refused as labour, but it still settles. The refusal cannot go
            # further for two reasons that are structural, not budgeted.
            #
            #   1. It cannot be told apart from a legitimate empty reply. By the
            #      time a result is the turn's first terminal, the residual and
            #      an empty answer are the same shape on the same queue — stage-1
            #      findings §7.1 already established the payload cannot separate
            #      the reproduced residual from the production one, and the real
            #      turn's own result is indistinguishable from a leftover by
            #      construction. Dropping it would hang every empty reply until
            #      the ceiling (R1's false kill, product-level).
            #   2. The read cannot simply continue. `ClaudeResponse
            #      .receive_response` ends a response at its first result, and
            #      the reader holds `current` until the turn releases it — so
            #      "keep reading for the real one" needs the release protocol
            #      rewritten, which is the reader's core backpressure design and
            #      far outside this batch.
            #
            # I1 is the fix that does hold: a residual result can no longer
            # enter a queue at all from silence, which is the only shape stage 1
            # ever reproduced (3/3). This gate's job is to make the residue
            # measurable (the counter and the WARN), to keep it out of the labour
            # count so a ghost stays in the fast-kill class, and to name the
            # occurrence for the observation window.
            turn_started = cast_frame is None and client.prompt_uuid is None
            emitted_final_assistant_content = False
            async for message in receive_response_messages(client):
                # Position, not shape: the same payload would count one frame
                # later.
                counts_as_labour = cast_reached
                if message is cast_frame:
                    cast_reached = True
                external_session_id = message_session_id(message)
                if external_session_id is not None:
                    await self._update_external_session_id(session, external_session_id)
                    response_external_session_confirmed = True
                    user_message_published = await self.publish_replayed_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                        replayed_user_message=replayed_user_message,
                        already_published=user_message_published,
                    )
                role = message_role(message)
                text = message_text(message)
                native_message_id = message_id(message)
                synthetic_control = is_synthetic_control_message(message)
                # Compaction is reported through the same events whether the CLI
                # compacted a `/compact` prompt or its own context window, so the
                # mapping stays on this shared path.
                compact_event = claude_compact_event(message)
                suppressed_control = (
                    synthetic_control or is_compaction_control_message(message)
                )
                if (
                    role == "user"
                    and text
                    and native_message_id
                    and not suppressed_control
                ):
                    replayed_user_message = (native_message_id, text)
                    if user_message_published:
                        if (
                            client.prompt_uuid is not None
                            and native_message_id != client.prompt_uuid
                        ):
                            logger.warning(
                                "Claude prompt uuid was not adopted by the SDK replay "
                                "session_id={} prompt_uuid={} replayed_uuid={}",
                                session.session_id,
                                client.prompt_uuid,
                                native_message_id,
                            )
                        self._confirm_replayed_user_binding(
                            session=session,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            replayed_user_message=replayed_user_message,
                            platform_item_id=published_user_item_id,
                        )
                    if response_external_session_confirmed:
                        user_message_published = (
                            await self.publish_replayed_user_message(
                                session=session,
                                turn_id=turn_id,
                                content=content,
                                attachments=attachment_mappings,
                                client_message_id=client_message_id,
                                reserved_user_item=reserved_user_item,
                                replayed_user_message=replayed_user_message,
                                already_published=user_message_published,
                            )
                        )
                stream_item = stream_accumulator.item_from_stream_event(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    projector=self.timeline,
                )
                terminal_message = terminal_event_from_message(message)
                if terminal_message is not None and not counts_as_labour:
                    # B1's position rule promoted to settlement: the cast frame
                    # and everything the reader flushed ahead of it are passive
                    # arrival, so a terminal there is not this turn's verdict and
                    # does not end it. I1 already refuses to let a terminal
                    # cast a turn, so this is the second line — reachable only
                    # if that guard ever regresses. Skipped, not counted as
                    # foreign: it is not another turn's frame, it is simply not
                    # this turn's result.
                    continue
                unowned_terminal = terminal_message is not None and not turn_started
                if unowned_terminal:
                    # This turn has shown no work of its own, so this result
                    # cannot be shown to be its own. It is counted and named —
                    # that is the number the observation window reads — and it
                    # is not credited as labour, so a turn that only ever saw
                    # unowned arrivals stays in the zero-content class and is
                    # reaped by the 30 s fast kill instead of drifting out to
                    # the 600 s ceiling (the same rule the cast frame follows).
                    self.foreign_terminal_frames += 1
                    logger.warning(
                        "Claude unowned terminal frame in-turn "
                        "session_id={} turn_id={} scheduled={} "
                        "foreign_total={} status={} reason={}",
                        session.session_id,
                        turn_id,
                        scheduled,
                        self.foreign_terminal_frames,
                        terminal_message.status,
                        terminal_message.reason,
                    )
                elif terminal_message is not None:
                    turn_started = True
                elif message is cast_frame or (
                    counts_as_labour
                    and not (
                        role == "user"
                        and client.prompt_uuid is not None
                        and native_message_id == client.prompt_uuid
                    )
                ):
                    # A cast turn starts at its cast; a prompted turn starts at
                    # the first frame of WORK it owns. The prompt echo is
                    # excluded on purpose: the echo is the connector's own
                    # prompt coming back, not the turn doing anything, and a
                    # leftover result can arrive right behind it (the reconnect
                    # replay). "Once the turn has spoken" is the proof; the echo
                    # is not speech.
                    turn_started = True
                # Everything downstream that asks "did this frame prove the turn
                # did work" must also answer no for an unowned arrival: passive
                # by definition, exactly like the cast frame above.
                counts_this_frame = counts_as_labour and not unowned_terminal
                tool_items = self.timeline.tool_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                )
                system_items = self.timeline.system_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    event="claude.turn.system",
                    reasoning_revision=stream_accumulator.next_thinking_final_revision(),
                )
                has_visible_message = (
                    not suppressed_control
                    and role in {"assistant", "system"}
                    and bool(text)
                )
                # Content-gate consumption point (§2 G1).
                #
                # The six-way test below IS a second authority on "did this turn
                # produce something" — the first being `drive_turn`'s own branches.
                # That duplication is deliberate and must stay in sync; it is
                # pinned from the outside by
                # `test_content_gate_counts_every_shape_that_projects_something`
                # (property over the SDK frame corpus: a shape that projects an
                # item MUST move the counter), so a future `drive_turn` branch that
                # projects without matching one of these six shapes turns the suite
                # red instead of silently under-counting into a false kill.
                #
                # DO NOT "de-duplicate" it into
                # `counts_as_labour and not _is_wire_chrome(message)`. That form is
                # shorter and looks like the obvious cleanup; it is wrong. It
                # exempts any turn that receives a single non-chrome frame after the
                # cast, which pushes a zero-content ghost out of the 30s fast kill
                # and into the 600s ceiling — and a held execution lock refuses
                # user messages outright (`turns/actions.py`:
                # `claude_turn_already_running`), so that is ten minutes of an
                # unusable session, bought to remove a hypothetical.
                #
                # The gate also trusts two structural facts — the frame is this turn's
                # labour (past the cast: everything the queue held BEFORE and AT
                # the cast is passive, set positionally by `counts_as_labour`) and
                # the frame is not chrome (`_is_wire_chrome`, the single authority
                # the reader itself gates minting on).
                #
                # DO NOT collapse this into `counts_as_labour and not
                # _is_wire_chrome(message)`. That form is simpler and would remove
                # the apparent duplication with `drive_turn` below — and it is
                # wrong: it exempts any turn that receives one non-chrome frame
                # after the cast, which pushes a zero-content ghost from the 30s
                # fast kill out to the 600s ceiling. A held execution lock refuses
                # user messages outright (`turns/actions.py`: `claude_turn_already_running`),
                # so that is ten minutes of an unusable session, bought to remove a
                # hypothetical. The duplication is instead pinned from the outside
                # by `test_content_gate_counts_every_shape_that_projects_something`
                # (property over the SDK frame corpus: projects an item ⇒ counts),
                # so a future `drive_turn` branch that projects without counting
                # turns the suite red instead of silently under-counting into a
                # false kill.
                if (
                    counts_this_frame
                    and not _is_wire_chrome(message)
                    and (
                        is_stream_event(message)
                        or stream_item is not None
                        or terminal_message is not None
                        or bool(tool_items)
                        or bool(system_items)
                        or has_visible_message
                    )
                ):
                    execution.consumed_frames += 1
                if not user_message_published and (
                    stream_item is not None
                    or terminal_message is not None
                    or bool(tool_items)
                    or bool(system_items)
                    or has_visible_message
                ):
                    await self.publish_fallback_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                    )
                    user_message_published = True
                if stream_item is not None:
                    await self.publish_items(
                        execution,
                        (stream_item,),
                        counted=counts_this_frame,
                    )
                if is_stream_event(message):
                    continue
                if terminal_message is not None:
                    terminal = terminal_message
                    if not emitted_final_assistant_content:
                        text = message_text(message)
                        if text:
                            await self.publish_items(
                                execution,
                                (
                                    self.timeline.message_item(
                                        session=session,
                                        turn_id=turn_id,
                                        role="assistant",
                                        text=text,
                                        event="claude.turn.result",
                                        native_item_id=message_id(message),
                                        item_id=stream_accumulator.final_item_id(
                                            session,
                                            turn_id,
                                        ),
                                        revision=stream_accumulator.next_final_revision(),
                                    ),
                                ),
                                counted=counts_this_frame,
                            )
                            emitted_final_assistant_content = True
                            stream_accumulator.reset()
                    if not unowned_terminal and counts_as_labour:
                        break
                await self.publish_items(
                    execution, tool_items, counted=counts_this_frame
                )
                await self.publish_items(
                    execution, system_items, counted=counts_this_frame
                )
                if compact_event is not None:
                    await self.publish_items(
                        execution,
                        (
                            self.markers.item_for_event(
                                session=session,
                                turn_id=turn_id,
                                event=compact_event,
                            ),
                        ),
                        counted=counts_this_frame,
                    )
                if suppressed_control:
                    continue
                if role not in {"assistant", "system"}:
                    continue
                if not text:
                    continue
                await self.publish_items(
                    execution,
                    (
                        self.timeline.message_item(
                            session=session,
                            turn_id=turn_id,
                            role=role,
                            text=text,
                            event=f"claude.turn.{role}",
                            native_item_id=message_id(message),
                            item_id=stream_accumulator.final_item_id(session, turn_id)
                            if role == "assistant"
                            else None,
                            revision=stream_accumulator.next_final_revision()
                            if role == "assistant"
                            else 1,
                        ),
                    ),
                    counted=counts_this_frame,
                )
                if role == "assistant":
                    emitted_final_assistant_content = True
                    stream_accumulator.reset()

            if terminal is None:
                terminal = failed_terminal_event(
                    code="claude_stream_ended_without_result",
                    message="Claude response stream ended without a terminal result",
                    reason="stream_exhausted",
                )
        except asyncio.CancelledError:
            terminal = interrupted_terminal_event(
                execution.interrupt_reason or "cancelled"
            )
        except Exception as exc:  # noqa: BLE001
            terminal = failed_terminal_event(
                code=exc.__class__.__name__,
                message=stderr.failure_message(exc),
            )
        finally:
            if execution.interrupt_source is not None:
                terminal = interrupted_terminal_event(execution.interrupt_reason)
            if reserved_user_item is not None and not user_message_published:
                try:
                    user_message_published = await self.publish_replayed_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                        replayed_user_message=replayed_user_message,
                        already_published=False,
                    )
                    if not user_message_published:
                        await self.publish_fallback_user_message(
                            session=session,
                            turn_id=turn_id,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            reserved_user_item=reserved_user_item,
                        )
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "Claude user message publish failed session_id={}",
                        session.session_id,
                    )
            reconciled = False
            if connection is not None and client is not None:
                if (
                    scheduled
                    and terminal is not None
                    and terminal.status == "completed"
                ):
                    connection.reconcile_needed = True
                if (
                    connection.reconcile_needed
                    and connection.retained
                    and not connection.reconciling
                    and not connection.background.active_ids
                    and connection.pending is None
                    and not connection.closing
                    and not self.stopping
                    and terminal is not None
                    and terminal.status == "completed"
                ):
                    try:
                        reconciled = await connection.reconcile_tasks(client)
                    except asyncio.CancelledError:
                        terminal = interrupted_terminal_event(
                            execution.interrupt_reason
                        )
            if connection is not None and (connection.retained or reconciled):
                try:
                    await self.scheduled_sessions.save(session, connection.task_ids)
                except Exception as exc:  # noqa: BLE001
                    terminal = failed_terminal_event(
                        code="claude_schedule_save_failed", message=str(exc)
                    )
            execution.client = None
            if terminal is None:
                terminal = failed_terminal_event(
                    code="claude_turn_missing_terminal_state",
                    message="Claude turn stopped without a terminal state",
                )
            await self.settle_compact_markers(session, turn_id, execution)
            try:
                await self.finish_execution(
                    session=session,
                    execution=execution,
                    terminal=terminal,
                    response=client,
                )
            finally:
                if connection is not None:
                    if terminal.status == "failed":
                        if connection.has_live_background_work:
                            # Do-not-retire invariant: a failed turn retires
                            # its transport because the CLI state is no longer
                            # trusted — but never while background work lives
                            # in that process; killing it would destroy work
                            # upstream cannot replay. The next turn reuses the
                            # transport; real breakage still surfaces as its
                            # own failed turn.
                            logger.warning(
                                "Claude failed-turn transport close skipped: "
                                "background work is live session_id={} "
                                "turn_id={} active_tasks={}",
                                session.session_id,
                                turn_id,
                                len(connection.background.active_ids),
                            )
                        else:
                            await connection.close()
                    else:
                        if (
                            not connection.streaming
                            and not connection.retained
                            and connection.pending is None
                        ):
                            await connection.close()
                        else:
                            connection.arm_idle()
                        await self.refresh_idle_connection(session)
            try:
                await self.publish_items(
                    execution,
                    stream_accumulator.finalize_pending_thinking(
                        session,
                        turn_id,
                        self.timeline,
                    ),
                )
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude reasoning flush failed session_id={}",
                    session.session_id,
                )

    async def publish_items(
        self,
        execution: ClaudeExecution,
        items: Iterable[RuntimeTimelineItem],
        *,
        counted: bool = True,
    ) -> None:
        """Upsert one turn's projected items and count them for the content gate.

        Every publish point inside `drive_turn` goes through here so
        `published_items` cannot drift from what the user actually saw. The
        count is bookkeeping only: nothing reads it unless a scheduled watchdog
        is armed, and no human turn is.

        `counted=False` is the cast-frame gate: items projected while
        processing the frame that cast this turn still reach the user (the
        projection itself must not change), but they are not evidence that the
        turn did work — that frame arrived passively. Publication outside the
        consume loop (compact markers, the reasoning flush) is the turn's own
        action and always counts.
        """

        for item in items:
            await self.notifications.timeline_activity.timeline_item_upsert(item)
            if counted:
                execution.published_items += 1

    async def open_command_compact_marker(
        self,
        session: ClaudeSession,
        turn_id: str,
        execution: ClaudeExecution | None = None,
    ) -> None:
        """Publish the running marker a command turn owes before dispatch."""

        try:
            items = self.markers.open_command_marker(
                session=session,
                turn_id=turn_id,
            )
            if execution is not None:
                await self.publish_items(execution, items)
            else:
                for item in items:
                    await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude compaction marker open failed session_id={}",
                session.session_id,
            )

    async def settle_compact_markers(
        self,
        session: ClaudeSession,
        turn_id: str,
        execution: ClaudeExecution | None = None,
    ) -> None:
        """Close a compaction marker this turn never proved complete.

        A command turn opens its marker before dispatch, and compaction
        otherwise reports success through its own events. Either way a turn
        that ends without proof of completion — failed, interrupted, or
        resolved without compacting — must not leave the client showing a
        running separator.

        The marker belongs to the session but only its opening turn may settle
        it. The CLI streams the frames that finish a compaction after that turn
        has ended, so this runs on the scheduled reader turn too; settling there
        would fail a separator whose success is already on the wire. Evidence
        that arrives after a settle corrects the marker instead.
        """

        try:
            items = self.markers.settle_turn(session=session, turn_id=turn_id)
            if execution is not None:
                await self.publish_items(execution, items)
            else:
                for item in items:
                    await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude compaction marker settle failed session_id={}",
                session.session_id,
            )

    async def publish_replayed_user_message(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        reserved_user_item: RuntimeTimelineItem,
        replayed_user_message: tuple[str, str] | None,
        already_published: bool,
    ) -> bool:
        """Publish the live user item once Claude confirms its native identity."""

        if already_published:
            return True
        if session.external_session_id is None or replayed_user_message is None:
            return False
        native_message_id, text = replayed_user_message
        if not client_message_text_matches(text, content):
            return False
        item_id = stable_message_item_id(session, native_message_id)
        self.timeline.move_reserved_order(reserved_user_item.id, item_id)
        user_item = self.timeline.message_item(
            session=session,
            turn_id=turn_id,
            role="user",
            text=content,
            event="claude.turn.user",
            client_message_id=client_message_id,
            native_item_id=native_message_id,
            item_id=item_id,
            attachments=attachments,
        )
        await self.publish_user_message(
            session=session,
            item=user_item,
            content=content,
            attachments=attachments,
            client_message_id=client_message_id,
            native_message_id=native_message_id,
        )
        return True

    def _confirm_replayed_user_binding(
        self,
        *,
        session: ClaudeSession,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        replayed_user_message: tuple[str, str] | None,
        platform_item_id: str | None,
    ) -> None:
        """Bind the live user item to the UUID the SDK actually replayed.

        The early publish only pre-assigned a UUID; the replay is the
        authority. With a client message id this promotes the pending
        registry binding; without one it records a native-to-platform bridge
        so history keeps reusing the live item id.
        """

        if replayed_user_message is None or session.external_session_id is None:
            return
        native_message_id, text = replayed_user_message
        if not client_message_text_matches(text, content):
            return
        try:
            if client_message_id is not None:
                self.pending_messages.bind_live_native_message(
                    session_id=session.session_id,
                    external_session_id=session.external_session_id,
                    client_message_id=client_message_id,
                    native_message_id=native_message_id,
                    text=content,
                )
            elif platform_item_id is not None:
                self.pending_messages.record_replayed_platform_id(
                    session_id=session.session_id,
                    external_session_id=session.external_session_id,
                    native_message_id=native_message_id,
                    platform_item_id=platform_item_id,
                    text=content,
                    attachments=attachments,
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude user message identity binding failed session_id={}",
                session.session_id,
            )

    async def publish_fallback_user_message(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        reserved_user_item: RuntimeTimelineItem,
    ) -> None:
        """Publish the reserved ID when the SDK omits a replayed user UUID."""

        fallback_user_item = self.timeline.message_item(
            session=session,
            turn_id=turn_id,
            role="user",
            text=content,
            event="claude.turn.user",
            client_message_id=client_message_id,
            item_id=reserved_user_item.id,
            attachments=attachments,
        )
        await self.publish_user_message(
            session=session,
            item=fallback_user_item,
            content=content,
            attachments=attachments,
            client_message_id=client_message_id,
            native_message_id=None,
        )

    async def publish_user_message(
        self,
        *,
        session: ClaudeSession,
        item: RuntimeTimelineItem,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        native_message_id: str | None,
    ) -> None:
        """Publish one user item and retain bounded history reconciliation data."""

        await self.notifications.timeline_activity.timeline_item_upsert(item)
        try:
            self.pending_messages.register_live_message(
                session_id=session.session_id,
                external_session_id=session.external_session_id,
                client_message_id=client_message_id,
                platform_item_id=item.id,
                text=content,
                attachments=attachments,
            )
            if native_message_id is None or session.external_session_id is None:
                return
            self.pending_messages.bind_live_native_message(
                session_id=session.session_id,
                external_session_id=session.external_session_id,
                client_message_id=client_message_id,
                native_message_id=native_message_id,
                text=content,
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude user message identity persistence failed session_id={}",
                session.session_id,
            )

    async def finish_execution(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        response: ClaudeResponse | None = None,
        *,
        publish: bool = True,
    ) -> bool:
        """Publish one terminal state and release this exact execution.

        `publish=False` keeps the terminal off the client-visible turn ledger
        while every lock/release guarantee still runs — the circuit breaker's
        one-report-per-window limiter uses it for repeat timeouts.
        """

        async with execution.finalization_lock:
            self.disarm_scheduled_watchdog(execution)
            if execution.finished.is_set():
                return False
            async with session.execution_lock:
                queued = session.queued_execution is execution
                if session.execution is not execution and not queued:
                    if response is not None:
                        response.release(interrupted=terminal.status == "interrupted")
                    execution.finished.set()
                    return False
                try:
                    if not queued:
                        await self.interactions.close_open_interaction_notices(
                            session,
                            status="closed",
                            reason=terminal.status,
                        )
                    await self.publish_terminal_state(
                        session,
                        execution,
                        terminal,
                        update_state=not queued,
                        publish=publish,
                    )
                finally:
                    if response is not None:
                        response.release(interrupted=terminal.status == "interrupted")
                    if queued:
                        session.queued_execution = None
                    else:
                        session.execution = session.queued_execution
                        session.queued_execution = None
                    if not queued and session.execution is not None:
                        await self.notifications.session_state.session_state_update(
                            session,
                            "running",
                            metadata={"source": "claude.turn.running"},
                        )
                    execution.finished.set()
            return True

    async def publish_terminal_state(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        *,
        update_state: bool = True,
        publish: bool = True,
    ) -> None:
        reason = terminal.reason or execution.interrupt_reason
        if terminal.status == "failed":
            metadata = {
                "source": "claude.turn.failed",
                **({"terminalReason": reason} if reason else {}),
            }
            if publish:
                await self.host.session_turn_ended(
                    session_id=session.session_id,
                    runtime="claude",
                    external_session_id=session.external_session_id,
                    turn_id=execution.turn_id,
                    outcome="failed",
                    metadata=metadata,
                )
            else:
                logger.warning(
                    "Claude repeat scheduled-timeout failure kept off the "
                    "client ledger session_id={} turn_id={}",
                    session.session_id,
                    execution.turn_id,
                )
            if not update_state:
                return
            await self.notifications.session_state.session_state_update(
                session,
                "error",
                error={
                    "code": terminal.error_code or "claude_turn_failed",
                    "message": terminal.error_message or "Claude turn failed",
                },
                metadata=metadata,
            )
            return
        source = "claude.turn.completed"
        if terminal.status == "interrupted":
            source = execution.interrupt_source or "claude.turn.interrupted"
        metadata = {
            "source": source,
            **({"terminalReason": reason} if reason else {}),
        }
        await self.host.session_turn_ended(
            session_id=session.session_id,
            runtime="claude",
            external_session_id=session.external_session_id,
            turn_id=execution.turn_id,
            outcome=terminal.status,
            metadata=metadata,
        )
        if not update_state:
            return
        await self.notifications.session_state.session_state_update(
            session,
            "idle",
            metadata=metadata,
        )

    async def _update_external_session_id(
        self,
        session: ClaudeSession,
        external_session_id: str,
    ) -> None:
        if not self.session_store.update_external_session_id(
            session,
            external_session_id,
        ):
            return
        self.pending_messages.bind_external_session(
            session.session_id,
            external_session_id,
        )
        await self.notifications.session_state.session_meta_upsert(
            session,
            source="claude.session.external_id",
        )


def _parent_tool_use_id(message: Any) -> str | None:
    """Read the dispatch tool call a captured subagent frame is parented to."""

    if isinstance(message, Mapping):
        value = message.get("parent_tool_use_id")
    else:
        value = getattr(message, "parent_tool_use_id", None)
    return value if isinstance(value, str) and value else None


def _with_parent_card(
    item: RuntimeTimelineItem,
    parent_item_id: str | None,
) -> RuntimeTimelineItem:
    """Attach the parentItemId convention to a captured subagent row.

    Tool rows already carry it from the projector (messages.py); the rows the
    projector cannot reach — reasoning (thinking) and message (text) rows —
    get the same free-JSON key here so the SubAgent panel can attribute them
    (claude-subagent-progress-tasks.md §3.3). Scoped to the capture route:
    the in-turn projection, the history rebuild, nested Agent rows and every
    main-agent row keep their exact content.
    """

    if parent_item_id is None or item.type not in {"system", "message"}:
        return item
    content = {**dict(item.content), "parentItemId": parent_item_id}
    return replace(
        item,
        content=content,
        content_hash=timeline_content_hash(
            item_type=item.type,  # type: ignore[arg-type]
            status=item.status,  # type: ignore[arg-type]
            role=item.role,  # type: ignore[arg-type]
            content=content,
        ),
    )
