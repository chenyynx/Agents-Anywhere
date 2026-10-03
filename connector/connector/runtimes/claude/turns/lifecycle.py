from __future__ import annotations

import asyncio
import secrets
from dataclasses import dataclass, field

from connector.logging import logger
from connector.runtime_protocol import (
    RuntimeAttachment,
    RuntimeConfig,
    RuntimeTimelineItem,
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
from connector.runtimes.claude.sdk.connection import ClaudeConnection, ClaudeResponse
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
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.scheduled import ClaudeScheduledSessions
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
POLLED_TURN_WATCHDOG_SECONDS = 30.0


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
        """

        timeout = POLLED_TURN_WATCHDOG_SECONDS
        execution.watchdog_task = asyncio.create_task(
            self._scheduled_watchdog(session, execution, response, timeout)
        )

    def disarm_scheduled_watchdog(self, execution: ClaudeExecution) -> None:
        task = execution.watchdog_task
        execution.watchdog_task = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()

    async def _scheduled_watchdog(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        timeout: float,
    ) -> None:
        try:
            await asyncio.wait_for(execution.finished.wait(), timeout)
            return
        except asyncio.TimeoutError:
            pass
        logger.warning(
            "Claude scheduled turn watchdog fired (no terminal within {}s), "
            "forcing failed terminal session_id={} turn_id={}",
            timeout,
            session.session_id,
            execution.turn_id,
        )
        connection = response.connection
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
                        f"{int(timeout)} seconds"
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
        await self.retire_stuck_transport(session, execution, response)

    async def retire_stuck_transport(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
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
                "session_id={} turn_id={} active_tasks={}",
                session.session_id,
                execution.turn_id,
                len(connection.background.active_ids),
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
                await self.open_command_compact_marker(session, turn_id)
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

            emitted_final_assistant_content = False
            async for message in receive_response_messages(client):
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
                    await self.notifications.timeline_activity.timeline_item_upsert(
                        stream_item
                    )
                if is_stream_event(message):
                    continue
                if terminal_message is not None:
                    terminal = terminal_message
                    if not emitted_final_assistant_content:
                        text = message_text(message)
                        if text:
                            await self.notifications.timeline_activity.timeline_item_upsert(
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
                                )
                            )
                            emitted_final_assistant_content = True
                            stream_accumulator.reset()
                    break
                for item in tool_items:
                    await self.notifications.timeline_activity.timeline_item_upsert(
                        item
                    )
                for item in system_items:
                    await self.notifications.timeline_activity.timeline_item_upsert(
                        item
                    )
                if compact_event is not None:
                    await self.notifications.timeline_activity.timeline_item_upsert(
                        self.markers.item_for_event(
                            session=session,
                            turn_id=turn_id,
                            event=compact_event,
                        )
                    )
                if suppressed_control:
                    continue
                if role not in {"assistant", "system"}:
                    continue
                if not text:
                    continue
                await self.notifications.timeline_activity.timeline_item_upsert(
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
                    )
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
            await self.settle_compact_markers(session, turn_id)
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
                for item in stream_accumulator.finalize_pending_thinking(
                    session,
                    turn_id,
                    self.timeline,
                ):
                    await self.notifications.timeline_activity.timeline_item_upsert(
                        item
                    )
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude reasoning flush failed session_id={}",
                    session.session_id,
                )

    async def open_command_compact_marker(
        self,
        session: ClaudeSession,
        turn_id: str,
    ) -> None:
        """Publish the running marker a command turn owes before dispatch."""

        try:
            for item in self.markers.open_command_marker(
                session=session,
                turn_id=turn_id,
            ):
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
