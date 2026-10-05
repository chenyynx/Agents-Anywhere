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
# F1: the `terminalReason` a turn carries when its `completed` was downgraded
# because the result could not be attributed to it. It reaches the client's turn
# ledger verbatim, so the condition is visible rather than silently rewritten.
STALE_COMPLETION_REASON = "unowned_result_no_content"

WATCHDOG_REASON_ZERO_CONTENT = "zero_content_fast_kill"
WATCHDOG_REASON_CONTENT_CEILING = "containing_turn_ceiling"

# G4's client-visible half (pp verdict, 2026-10-04, product-level —
# .local-dev/ratelimit-fatal-retirement-notice-order.md §2 A). A killed process
# needs its own code: `claude_scheduled_turn_timeout` reads "no result within
# N seconds", which the user takes as "the model was slow", while the truth is
# "the CLI process was terminated and every task running inside it ended". They
# retry nothing and rescue nothing, because nothing in the old text says work
# was lost.
#
# The disclosure is driven by the FACT that close() happened — never by the
# ledger slot — so the watchdog limiter may be spent or not and the message
# still reaches the user. `claude_scheduled_turn_timeout` keeps its own text and
# its own path: a turn that timed out WITHOUT a close is a different incident.
CLAUDE_PROCESS_RETIRED_CODE = "claude_process_retired"
CLAUDE_PROCESS_RETIRED_SOURCE = "claude.process.retired"

# Kept in the connector so a client that has not shipped the localized copy yet
# still shows something true rather than an empty or raw-JSON error.
PROCESS_RETIRED_MESSAGE = (
    "The Claude process was terminated after failing to respond. This turn "
    "produced no result and any running background tasks have ended. Please "
    "try again."
)
# close() raised: the kill was attempted but never confirmed. Downgraded, not
# silent — the turn is lost either way; only the certainty changed.
PROCESS_RETIRED_UNCONFIRMED_MESSAGE = (
    "The Claude process was terminated after failing to respond, but the "
    "shutdown could not be confirmed. This turn produced no result. Please "
    "try again."
)


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
    # F1/F6: turns whose `completed` was downgraded to `interrupted` because
    # they settled on a result they could not attribute. After the release
    # protocol this is the FALLBACK number: the turn declined the leftover and
    # kept reading, and nothing of its own ever arrived, so it settled on the
    # downgraded verdict instead. Zero in normal operation; non-zero means the
    # fix did not catch this one and the session is back to reporting "this
    # round produced nothing" — read it together with
    # `stale_terminal_recoveries`, which counts the ones it did catch.
    stale_completion_downgrades: int = field(default=0, init=False)
    # F1 release protocol: turns that met an unowned terminal, declined it,
    # kept reading, and DID get their own result behind it. This is the
    # "the reply reached the timeline in the turn that asked for it" counter —
    # the P1 shape being closed, not merely re-labelled. Its counterpart is
    # `stale_completion_downgrades`: recoveries + downgrades is every time the
    # gate saw an unowned terminal and settled the turn by one of the two
    # rules, so a falling downgrade count with a rising recovery count is the
    # fix working, and not a disappearing symptom.
    stale_terminal_recoveries: int = field(default=0, init=False)
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

        # The budget the turn actually ran out of. Named once because three
        # consumers depend on it agreeing: the failed terminal's text, the fire
        # line, and the process-retirement disclosure's `stuckSeconds`.
        stuck_budget = timeout if reason == WATCHDOG_REASON_ZERO_CONTENT else ceiling
        try:
            settled = await self.finish_execution(
                session=session,
                execution=execution,
                terminal=failed_terminal_event(
                    code="claude_scheduled_turn_timeout",
                    message=(
                        "Scheduled work did not report a result within "
                        f"{int(stuck_budget)}"
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
            stuck_seconds=stuck_budget,
        )

    async def retire_stuck_transport(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        *,
        reason: str | None = None,
        client_reported: bool = True,
        stuck_seconds: float | None = None,
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
        #
        # Snapshotted before the close so the disclosure below reports what was
        # in the process at the moment it was killed. It is 0 on the ordinary
        # path — the L1 gate above already returned when background work was
        # live — and non-zero only when the transport was failing or closing,
        # which is exactly when the user needs to be told work was cut.
        interrupted_background_tasks = len(connection.background.active_ids)
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
            # Not confirmed, not silent: the turn is lost either way, and a
            # user who is told "still working" when the kill was attempted is
            # worse off than one told the truth.
            await self._disclose_process_retirement(
                session,
                stuck_seconds=stuck_seconds,
                interrupted_background_tasks=interrupted_background_tasks,
                confirmed=False,
            )
            return
        await self._disclose_process_retirement(
            session,
            stuck_seconds=stuck_seconds,
            interrupted_background_tasks=interrupted_background_tasks,
            confirmed=True,
        )

    async def _disclose_process_retirement(
        self,
        session: ClaudeSession,
        *,
        stuck_seconds: float | None,
        interrupted_background_tasks: int | None,
        confirmed: bool,
    ) -> None:
        """Tell the user the host process died, whatever the limiters decided.

        This sits outside every gate on the retirement path, and that is the
        whole point of it. `publish` decides whether a failed TURN reaches the
        ledger; `update_state` decides who owns the session status. Neither has
        anything to do with "the CLI process was just killed", and on
        2026-10-03 13:49 that gap produced a killed process whose only trace
        was a WARNING line no user will ever read. So this disclosure is driven
        by the close itself and therefore fires on every retirement: with the
        ledger slot spent or not, and for a queued execution that never owned
        the status (`update_state=False`).

        It is deliberately NOT reached when the L1 gate withholds the kill —
        `retire_stuck_transport` returns before the close, so nothing was
        retired and nothing is disclosed. A disclosure that fires when the
        process survived would teach users to distrust it.

        Failures are logged and swallowed: by the time this runs the turn is
        already settled and the process already dead, so a host I/O error must
        not escalate into a second incident on top of the first.
        """

        params: dict[str, Any] = {"retirementConfirmed": confirmed}
        if stuck_seconds is not None:
            params["stuckSeconds"] = int(stuck_seconds)
        if interrupted_background_tasks is not None:
            params["interruptedBackgroundTaskCount"] = interrupted_background_tasks
        try:
            await self.notifications.session_state.session_state_update(
                session,
                "error",
                error={
                    "code": CLAUDE_PROCESS_RETIRED_CODE,
                    "message": (
                        PROCESS_RETIRED_MESSAGE
                        if confirmed
                        else PROCESS_RETIRED_UNCONFIRMED_MESSAGE
                    ),
                    "params": params,
                },
                metadata={"source": CLAUDE_PROCESS_RETIRED_SOURCE},
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude process retirement disclosure failed session_id={}",
                session.session_id,
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

    async def wait_for_selection_change(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> None:
        """Wait out a transport's background work instead of refusing to rebuild.

        The model is a CLI launch argument, so a selection change must rebuild
        the process; the do-not-retire invariant forbids killing live
        background work. This used to refuse — the next turn failed with
        `RuntimeError("Claude selection change requires background work to
        finish")` and the user's message never ran (measured 2026-10-05 in
        ~/aa-test/model-switch-composer-harness). Wait instead:

        - the drain is event-driven — the last terminal task frame is the
          signal (`ClaudeBackgroundTasks.drained`);
        - the wake turn the CLI starts to report that task is allowed to
          finish, bounded by `selectionChangeDrainCeilingSeconds` (a long
          report cannot hold the rebuild forever);
        - a second switch during the wait is seen on the next pass, and the
          caller re-checks the selections when this returns;
        - the wait is cancellable: a stop cancels the driving turn's task and
          the `CancelledError` propagates into the interrupted terminal the
          turn machinery already publishes.

        State is never republished from here: the queued turn's "waiting"
        state (published by `start_turn`) stays the honest one until the turn
        actually runs, so no client sees a fake idle or a re-locked composer.
        """

        settle = float(self.config.values.get("selectionChangeSettleSeconds", 1.0))
        ceiling = float(
            self.config.values.get("selectionChangeDrainCeilingSeconds", 600.0)
        )
        while connection.background.active_ids:
            if self.stopping or connection.closing:
                raise asyncio.CancelledError
            await connection.wait_background_drained()
            if self.stopping or connection.closing:
                raise asyncio.CancelledError
            if not await connection.wait_settled(grace=settle, ceiling=ceiling):
                logger.warning(
                    "Claude selection change proceeding without a settled "
                    "transport session_id={} background_tasks={}",
                    session.session_id,
                    len(connection.background.active_ids),
                )
                return
            if dict(session.selections) == connection.selections:
                # The user switched back while this waited; the caller reuses
                # the transport.
                return
            # Otherwise loop: the wake turn may have dispatched fresh
            # background work, and that new batch owns the transport too.

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
                await self.wait_for_selection_change(session, existing)
            if not existing.closing and existing.selections == session.selections:
                # A second switch during the wait may land back on the
                # selection this transport already carries.
                existing.cancel_idle()
                return existing
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
        # The card the accumulator's still-open thinking belongs to. Stream
        # events carry no parent today (the CLI does not stream sidechains), so
        # this stays None on every real turn and the settle-time flush below is
        # an identity transform; it exists so a parented stream frame, if the
        # CLI ever emits one, cannot leak a second way (recon findings §3.4).
        stream_parent_item_id: str | None = None
        # F1 release protocol state, seeded HERE rather than beside the read
        # loop below: the `finally` consults them, and anything raised between
        # the loop's opening and its body would otherwise leave them unbound —
        # which raises out of `finally` and replaces the real error with a
        # name error. `terminal` above follows the same rule.
        #
        # `declined_any` says at least one terminal was ruled out of this turn;
        # `downgraded_verdict` holds the exact verdict object recorded for
        # that case, so the settle path can tell "this turn fell back to the
        # downgrade" from "this turn recovered and overwrote it" by identity,
        # without a second judgement about the frames.
        declined_any = False
        downgraded_verdict: ClaudeTerminalEvent | None = None
        # The frame that was deferred, kept so the fallback can still publish
        # its text if the read ends without anything better. See the publish
        # below the read loop.
        declined_message: Any = None
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
            # WHAT HAPPENS TO AN UNOWNED TERMINAL, and why it is not simply
            # settled (claude-stale-frame-f1-release-protocol.md §8.1).
            #
            # An unowned terminal cannot be told apart from a legitimate empty
            # reply: by the time a result is the turn's first terminal, the
            # leftover and an empty answer are the same shape on the same
            # queue (stage-1 findings §7.1), and the turn's own result is
            # indistinguishable from a leftover by construction. So the turn
            # cannot WAIT for a better frame to prove itself — that would hang
            # every empty reply until the ceiling (R1's false kill).
            #
            # It does not have to. The reason the read could not simply
            # continue used to be structural — `ClaudeResponse
            # .receive_response` ended a response at its first result, and the
            # reader held `current` until the turn released it, so "keep
            # reading for the real one" needed the release protocol rewritten.
            # That protocol now exists (F1, §8.1.2):
            #
            #   * a `completed` unowned terminal is DECLINED — recorded, never
            #     published, and the read continues;
            #   * `receive_response` bounds that continued read with
            #     `DECLINED_TERMINAL_GRACE_SECONDS`, because a human turn has
            #     no watchdog and an unbounded read is R1's worst outcome;
            #   * if the turn's own result arrives inside the window, the turn
            #     settles on it — `completed`, reply delivered
            #     (`stale_terminal_recoveries`);
            #   * if the window expires or the stream ends, the turn settles
            #     on the downgraded verdict recorded at decline time — exactly
            #     the pre-protocol behavior, G later
            #     (`stale_completion_downgrades`). The downgrade is the
            #     FALLBACK, not the verdict.
            #
            # `failed` and `interrupted` are NOT declined: they are already
            # honest about a round that went nowhere, and holding a turn open
            # past them would bury a failure the user needs to see.
            #
            # I1 still holds and is still the first line: a residual result can
            # no longer enter a queue at all from silence, which is the only
            # shape stage 1 ever reproduced (3/3). This gate is the second
            # line, and its residue stays measurable (the counters and the
            # WARN) and out of the labour count.
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
                # The card this frame is parented to. Read after the native
                # session id is adopted, so the item id hashes under the same
                # scope the capture route would (recon findings §1.2).
                #
                # A turn active period does not sort frames by parent — every
                # frame the connection hands to the consume loop is projected
                # here, so a subagent frame that lands before this turn's result
                # used to publish its reasoning and text rows with no
                # `parentItemId` and the SubAgent panel let them into the main
                # chat (pp session sess_k4g1dE968ahtWg, seq 10/14/16/41). A
                # main-agent frame has no parent and stays byte-identical.
                frame_parent_tool_use_id = _parent_tool_use_id(message)
                frame_parent_item_id = (
                    stable_tool_item_id(session, frame_parent_tool_use_id)
                    if frame_parent_tool_use_id is not None
                    else None
                )
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
                if is_stream_event(message):
                    # Whatever the accumulator is still holding belongs to the
                    # message this stream event belongs to, so the card travels
                    # with it into the settle-time thinking flush.
                    stream_parent_item_id = frame_parent_item_id
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
                    #
                    # The decline is defensive, and it has to be here anyway:
                    # since the release protocol the reader parks on a verdict
                    # after EVERY terminal, so a path that skips a terminal
                    # without answering would leave it waiting on a `released`
                    # only a settled turn can set. Unreachable under I1, fatal
                    # without this line if I1 ever regresses.
                    client.decline_terminal()
                    continue
                unowned_terminal = terminal_message is not None and not turn_started
                if unowned_terminal:
                    # This turn has shown no work of its own, so this result
                    # cannot be shown to be its own. Counted and named, and not
                    # credited as labour (the same rule the cast frame follows:
                    # a passive arrival is not evidence the turn worked).
                    #
                    # A `completed` one does not settle the turn at all: it is
                    # DECLINED. The verdict is recorded first and the frame is
                    # then skipped completely — no result text published, no
                    # stream accumulator touched — because that text belongs to
                    # the turn that already settled, and publishing it would
                    # show the user a second copy of an answer they have. What
                    # follows it on the queue (the real reply, this turn's own
                    # result) is consumed normally and reaches the timeline.
                    #
                    # The recorded verdict is the fallback, not the outcome: if
                    # this turn's own result arrives inside the grace window it
                    # overwrites `terminal` below and the turn settles
                    # `completed`. If nothing arrives, the loop ends and the
                    # downgrade is what the user is told — "this round produced
                    # nothing" — which is both honest and re-sendable.
                    #
                    # `failed` and `interrupted` are deliberately NOT declined.
                    # They are already honest, they are not the shape this
                    # protocol was written for, and holding a turn open past
                    # them would bury the failure visibility the pending branch
                    # exists to preserve. They fall through to the settle block
                    # below, which breaks the turn.
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
                    if terminal_message.status == "completed":
                        downgraded_verdict = self._verdict_for_terminal(
                            execution=execution,
                            terminal=terminal_message,
                            unowned=True,
                        )
                        terminal = downgraded_verdict
                        declined_any = True
                        declined_message = message
                        client.decline_terminal()
                        continue
                elif message is cast_frame or (
                    counts_as_labour
                    and not _is_wire_chrome(message)
                    and not (
                        role == "user"
                        and client.prompt_uuid is not None
                        and native_message_id == client.prompt_uuid
                    )
                ):
                    # A cast turn starts at its cast; a prompted turn starts at
                    # the first frame of WORK it owns. Two kinds of frame are
                    # excluded on purpose, and neither of them is the turn
                    # speaking:
                    #
                    #   * the prompt echo — the connector's own prompt coming
                    #     back, with a leftover result able to arrive right
                    #     behind it (the reconnect replay);
                    #   * wire chrome — the CLI's handshake and bookkeeping
                    #     (`_is_wire_chrome`, the single authority the reader
                    #     itself gates minting on). This is §9 of the F1
                    #     release protocol, and it is what makes the gate fire
                    #     on the REAL wire. The observed order there is
                    #     [init, status, echo, residual, …]: without the
                    #     exclusion the handshake opened the gate before the
                    #     echo was even seen, the leftover counted as owned,
                    #     and the turn settled `completed` ~2 s before its own
                    #     model request — the P1 report, unfixed. 31/31 real
                    #     captures put `init` first
                    #     (recon/stale-frame/f1-preamble-gate-finding.md).
                    #
                    # "Once the turn has done real work" is the proof. Neither
                    # an echo nor a handshake is that.
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
                        (_with_parent_card(stream_item, frame_parent_item_id),),
                        counted=counts_this_frame,
                    )
                if is_stream_event(message):
                    continue
                if terminal_message is not None:
                    terminal = self._verdict_for_terminal(
                        execution=execution,
                        terminal=terminal_message,
                        unowned=unowned_terminal,
                    )
                    if not emitted_final_assistant_content:
                        emitted_final_assistant_content = await self._publish_result_text(
                            execution=execution,
                            session=session,
                            turn_id=turn_id,
                            message=message,
                            stream_accumulator=stream_accumulator,
                            parent_item_id=frame_parent_item_id,
                            counted=counts_this_frame,
                        )
                    if declined_any and not unowned_terminal:
                        # The turn's verdict was NOT the frame it would have
                        # settled on: a leftover was declined, the read
                        # continued, and this turn's own result arrived behind
                        # it. The reply reached the timeline in the turn that
                        # asked for it — the P1 shape closed, not relabelled.
                        self.stale_terminal_recoveries += 1
                        logger.info(
                            "Claude stale terminal declined, turn recovered "
                            "turn_id={} recoveries={}",
                            execution.turn_id,
                            self.stale_terminal_recoveries,
                        )
                    if counts_as_labour:
                        # Every case where this terminal is NOT the turn's
                        # verdict has already left the loop above: the cast
                        # position, or an unowned `completed` declined. So
                        # arriving here always ends the turn. The condition
                        # used to also name `not unowned_terminal`, because an
                        # unowned terminal used to fall through HERE to settle;
                        # it is the `continue` that decides that now. Leaving
                        # this out would read past the turn's own verdict into
                        # whatever the next turn sends — the generator no longer
                        # stops at its first result, so nothing else stops it.
                        break
                await self.publish_items(
                    execution, tool_items, counted=counts_this_frame
                )
                await self.publish_items(
                    execution,
                    _with_parent_cards(system_items, frame_parent_item_id),
                    counted=counts_this_frame,
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
                        _with_parent_card(
                            self.timeline.message_item(
                                session=session,
                                turn_id=turn_id,
                                role=role,
                                text=text,
                                event=f"claude.turn.{role}",
                                native_item_id=message_id(message),
                                item_id=stream_accumulator.final_item_id(
                                    session, turn_id
                                )
                                if role == "assistant"
                                else None,
                                revision=stream_accumulator.next_final_revision()
                                if role == "assistant"
                                else 1,
                            ),
                            frame_parent_item_id,
                        ),
                    ),
                    counted=counts_this_frame,
                )
                if role == "assistant":
                    emitted_final_assistant_content = True
                    stream_accumulator.reset()

            if (
                declined_message is not None
                and not emitted_final_assistant_content
                and terminal is downgraded_verdict
            ):
                # The decline was a DEFERRAL, and the read ended without
                # anything better, so the frame the turn deferred is now its
                # verdict — text included. Publishing it here is what the
                # pre-protocol path did; staying silent would drop a
                # legitimate empty reply's answer on the floor, which is a
                # worse failure than the one the protocol fixes. When a real
                # reply did arrive, this branch is skipped and the leftover's
                # text is never published at all.
                await self._publish_result_text(
                    execution=execution,
                    session=session,
                    turn_id=turn_id,
                    message=declined_message,
                    stream_accumulator=stream_accumulator,
                    parent_item_id=None,
                    counted=False,
                )
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
            # F1: commit the downgrade only now, and only if it is still the
            # verdict. Identity is the test — a decline recorded the exact
            # object, and every path that replaced the verdict since (this
            # turn's own result, a failure, an interrupt, an exhausted stream)
            # left a different object behind. So a recovered turn never lands
            # here with the downgrade, and the counter keeps its narrowed
            # meaning: "the fix did not catch this one".
            if downgraded_verdict is not None and terminal is downgraded_verdict:
                self._record_stale_completion_downgrade(execution)
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
                settled_batch = stream_accumulator.finalize_pending_thinking(
                    session,
                    turn_id,
                    self.timeline,
                )
                await self.publish_items(
                    execution,
                    _with_parent_cards(settled_batch, stream_parent_item_id),
                )
            except Exception:  # noqa: BLE001
                settled_batch = ()
                logger.exception(
                    "Claude reasoning flush failed session_id={}",
                    session.session_id,
                )
            if settled_batch:
                # L3b, second half (red team F4). The first request for this
                # session's refresh went out from `finish_execution`, which runs
                # BEFORE this block — so the snapshot it asked for could not
                # contain the rows this block is about to publish, and the very
                # batch L3b was raised for (12:24: a dozen rows formed at settle
                # and shipped on the next global beat) still waited a whole
                # interval. Ask again now that they are out. Only when there is
                # a batch: a turn that published nothing extra must not pay for
                # a second transcript read.
                await self._request_settled_session_sync(session)

    def _verdict_for_terminal(
        self,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        *,
        unowned: bool,
    ) -> ClaudeTerminalEvent:
        """Downgrade a `completed` this turn cannot own, and say why.

        The invariant a turn settles on: a terminal frame ends exactly one turn,
        the one that can prove it started it. When the proof is missing,
        `completed` is a lie with consequences — the
        client shows the turn succeeded, the reply that is still behind the
        swallowed frame never arrives, and the user is looking at an idle
        session with an empty composer. That is the 2026-10-04 P1 report
        verbatim, and it survived I1 because I1 only guards the MINT path: this
        frame was already inside a live turn.

        So the verdict is degraded, not suppressed. `interrupted` with a
        structured reason says exactly what happened — this round produced
        nothing — and it is a state the user can act on (re-send) rather than
        one that invites them to wait for a reply that is never coming. The
        reason string is what the client's `terminalReason` carries, so the
        condition is visible in the turn ledger instead of being swallowed here.

        This is a PURE function of the frame: it decides the verdict and counts
        nothing. Since F1 the verdict is recorded at DECLINE time, long before
        the turn knows whether it will be the one it settles on, so the
        counter moved to `_record_stale_completion_downgrade`, which only runs
        where the downgrade is actually committed.

        Cost, stated plainly: a genuine empty reply — a turn whose whole stream
        is its own result — is indistinguishable from this and is degraded too.
        That is the deliberate trade (pp, red team F1): to the user both are
        "this round produced nothing", and reporting one of them as a success
        is the failure mode being fixed. Under the release protocol that trade
        is now bounded by the grace window rather than permanent: the empty
        reply settles on this verdict G seconds late instead of at once, and
        the reply that does exist behind a leftover is no longer lost.

        THE CASCADE this can still create, measured (red team round 2 §5.3).
        The release protocol removes the everyday path: a leftover no longer
        ends the turn, so the frames behind it — the prompt echo, the real
        reply, the real result — are consumed by the turn that asked for
        them. But it is bounded by `DECLINED_TERMINAL_GRACE_SECONDS`, and a
        leftover whose real frames arrive later than that still falls back to
        settling here. Then the turn breaks on the frame it could not attribute,
        the frames behind it are left in the reader's queue with nobody holding
        them, and at silence the echo is a user frame, which mints a scheduled
        turn: that phantom consumes the rest and settles `completed` carrying
        the answer. As measured it is benign — two bubbles, `completed`,
        session back to idle, no error state, nothing left running — and the
        user-visible cost is one answer split across two bubbles, the first
        marked "interrupted / this round produced nothing".

        The honest edge: the "phantom with only the echo and nothing after it"
        variant could NOT be constructed by the red team, so whether that one
        would sit zero-content until the 30 s fast kill and flip the session to
        an error is UNVERIFIED. Mechanically it is the same shape as a genuinely
        hung turn (zero content, no terminal), which is why it is on the stage-3
        watch list rather than dismissed.

        Only `completed` is degraded. `failed` and `interrupted` are already
        honest about a round that went nowhere, and rewriting them would destroy
        the failure visibility the pending branch exists to preserve. Only
        `completed` is declined, too — see the gate's note in `drive_turn` for
        why a failure must not be waited out.
        """

        if terminal.status != "completed" or not unowned:
            return terminal
        # No separate "and the turn produced nothing" test, and that is a
        # measured decision rather than an omission: it cannot be reached. Any
        # frame that counts as work also opens the start gate above (every
        # counted shape is a non-terminal one), so an unowned terminal already
        # implies a turn that consumed nothing. Writing the check anyway made
        # it a guard with no failing input — the thing red team F7 flagged in B
        # — and a guard nobody can trip is a comment that lies about what the
        # code guarantees.
        return interrupted_terminal_event(STALE_COMPLETION_REASON)

    async def _publish_result_text(
        self,
        *,
        execution: ClaudeExecution,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
        stream_accumulator: ClaudeStreamAccumulator,
        parent_item_id: str | None,
        counted: bool,
    ) -> bool:
        """Publish a terminal frame's own text as this turn's final bubble.

        The fallback for a turn whose reply never arrived as a separate
        assistant frame — the CLI put the words in the result envelope
        instead. It is reached in exactly two shapes: an ordinary empty reply,
        and a turn that declined a leftover and then got nothing better, where
        the declined frame becomes the verdict after all (see the publish
        below the read loop).

        The item id it shares with the assistant frame is NOT a "a later reply
        replaces this text by revision" promise. Within a turn the read is
        over by the time this runs, so there is no later reply to do any
        replacing; and a reply that arrives in a LATER turn is that turn's own
        bubble — if the same answer is ever seen in two bubbles, the second is
        a phantom, not a revision.

        Returns whether anything was published, so the caller can keep its
        "final content already emitted" flag honest.
        """

        text = message_text(message)
        if not text:
            return False
        await self.publish_items(
            execution,
            (
                _with_parent_card(
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
                    parent_item_id,
                ),
            ),
            counted=counted,
        )
        stream_accumulator.reset()
        return True

    def _record_stale_completion_downgrade(self, execution: ClaudeExecution) -> None:
        """Count a turn that really did settle on a result it could not own.

        Called only where that verdict is COMMITTED — after the read ends, once
        nothing better has replaced it. A turn that declined a leftover and
        then received its own result never reaches here with the downgraded
        verdict, which is what makes this counter and
        `stale_terminal_recoveries` a control pair: one counts the frames the
        release protocol saved, the other the ones it did not, and the raw
        `foreign_terminal_frames` counts every unowned terminal either way
        (F6: it cannot carry this job — a legitimate empty reply increments
        it too).
        """

        self.stale_completion_downgrades += 1
        logger.warning(
            "Claude completed downgraded to interrupted: turn settled on a "
            "result it could not attribute turn_id={} downgrades={}",
            execution.turn_id,
            self.stale_completion_downgrades,
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
                    if not queued:
                        # L3b: ask the connector to refresh this session's
                        # timeline now instead of at the next global sync beat.
                        # The push above already carried this turn's rows; what
                        # this buys is the snapshot that catches anything the
                        # push published late, reordered, or missed — which on
                        # 2026-10-04 was the difference between a reply and 30
                        # to 50 seconds of an idle-looking session.
                        #
                        # Fire-and-forget by contract: `on_turn_settled` returns
                        # immediately, so this costs the turn nothing. And it is
                        # display plumbing, so it can never fail a turn that has
                        # already been correctly settled.
                        await self._request_settled_session_sync(session)
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

    async def _request_settled_session_sync(self, session: ClaudeSession) -> None:
        """Tell the connector this session settled, so it can refresh it now.

        L3b. A no-op on any host that does not implement the signal (the
        protocol default), which is what keeps a runtime built for tests or for
        an older connector behaving exactly as before. Failures are logged and
        swallowed: the turn has already published its verdict by the time this
        runs, and nothing about a follow-up refresh is worth failing it for.
        """

        try:
            await self.host.on_turn_settled(
                session.session_id, session.external_session_id
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude settled session sync request failed session_id={}",
                session.session_id,
            )

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
    """Attach the parentItemId convention to a subagent reasoning/message row.

    Tool rows already carry it from the projector (messages.py); the rows the
    projector cannot reach — reasoning (thinking) and message (text) rows —
    get the same free-JSON key here so the SubAgent panel can attribute them
    (claude-subagent-progress-tasks.md §3.3).

    Two routes reach this, because a subagent frame is projected by whichever
    one the frame's arrival time selects: the capture route (frames that reach
    silence) and the in-turn projection (frames that land while a turn or a
    scheduled turn is active — recon findings §1.2). The history rebuild and
    nested Agent rows keep their exact content, and so does every row of a
    frame with no parent: `parent_item_id is None` returns the item itself.
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


def _with_parent_cards(
    items: Iterable[RuntimeTimelineItem],
    parent_item_id: str | None,
) -> tuple[RuntimeTimelineItem, ...]:
    """`_with_parent_card` over a batch, for the projection's batched rows.

    The in-turn projection publishes two batches rather than single items — the
    frame's reasoning rows and the settle-time thinking flush — so this keeps
    the same call at both instead of rebuilding a tuple per site. It stays the
    identity transform (the very same item objects) when there is no parent, so
    a main-agent turn publishes exactly what it published before.
    """

    if parent_item_id is None:
        return tuple(items)
    return tuple(_with_parent_card(item, parent_item_id) for item in items)
