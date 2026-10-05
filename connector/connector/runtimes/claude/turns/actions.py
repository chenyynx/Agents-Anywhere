from __future__ import annotations

import asyncio
import secrets
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from connector.logging import logger
from connector.runtime_protocol import (
    RuntimeAttachment,
    RuntimeInvalidRequestError,
    RuntimeOperationResult,
    RuntimeSessionStateCache,
)
from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.notifications.projector import (
    ClaudeNotificationProjector,
)
from connector.runtimes.claude.sdk.client import interrupt_client
from connector.runtimes.claude.sdk.events import (
    interrupted_terminal_event,
    is_result_message,
)
from connector.runtimes.claude.sdk.stop_affordance import (
    is_declared,
    stop_background_tasks,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.turns.interactions import ClaudeInteractionController
from connector.runtimes.claude.turns.lifecycle import ClaudeTurnRunner
from connector.runtimes.claude.turns.selections import ClaudeSelectionController

# C · drain-after-interrupt (claude-stale-frame-turn-tasks.md §4/§11).
#
# Interrupting kills the CLI's work but not its mouth: the tail frames still
# land in the session-scoped stream seconds later (real session
# sess_tPcEDi0z9xJYxQ: 32 s later), where nothing holds them and the next turn
# would inherit them. Draining what is already queued here is the cheap half of
# the fix.
#
# It is also the half that cannot be allowed to cost anything, and the shipped
# version therefore has no timeout at all: it drains what is there and returns.
# The task sheet asked for a 5-second ceiling; a 5-second ceiling is still 5
# seconds a user waits for a stop on a CLI that never answers, which the
# existing 2-second stop expectation in
# `test_claude_stop_clears_both_executions_during_scheduled_collision` rejects.
# A residual arriving after this call is the case I1 and B exist for, and they
# cost the user nothing. Switchable like every other guard here:
# `drainOnInterrupt: false` in the runtime config.


@dataclass(slots=True)
class ClaudeTurnActionHandler:
    session_states: RuntimeSessionStateCache
    session_store: ClaudeSessionStore
    notifications: ClaudeNotificationProjector
    selections: ClaudeSelectionController
    interactions: ClaudeInteractionController
    runner: ClaudeTurnRunner

    async def stop(self) -> None:
        self.runner.stopping = True
        for session in self.session_store.sessions():
            executions = (session.queued_execution, session.execution)
            for execution in executions:
                if execution is not None:
                    execution.interrupt_source = "claude.runtime.stop"
                    execution.interrupt_reason = "runtime_stopped"
            for execution in executions:
                if execution is not None:
                    await self.interrupt_execution(
                        session=session,
                        execution=execution,
                        source="claude.runtime.stop",
                        reason="runtime_stopped",
                    )
        await self.runner.stop()

    async def start_turn(
        self,
        session_id: str,
        external_session_id: str | None,
        content: str,
        selections: Mapping[str, str | None] | None = None,
        attachments: tuple[RuntimeAttachment, ...] = (),
        client_message_id: str | None = None,
        cwd: str | None = None,
        command: str | None = None,
    ) -> RuntimeOperationResult:
        """Queue one turn, optionally as a native command.

        A command turn reuses this state machine, its lock and its connection
        so compaction cannot race an ordinary turn; only the user bubble is
        withheld, because the CLI never echoes the command back.
        """

        session = self.session_for(session_id, external_session_id, cwd)
        try:
            effective_selections = await self.selections.effective_selections(
                session_id,
                selections,
            )
        except RuntimeInvalidRequestError as exc:
            return RuntimeOperationResult(
                ok=False,
                code="claude_invalid_selection",
                message=str(exc),
            )

        async with session.execution_lock:
            if session.execution is not None:
                return RuntimeOperationResult(
                    ok=False,
                    code="claude_turn_already_running",
                    message="Claude runtime already has an active turn for this session",
                )
            execution = ClaudeExecution(
                turn_id=f"turn_claude_{secrets.token_urlsafe(12)}"
            )
            session.execution = execution
            session.selections = effective_selections
            try:
                await self.notifications.session_state.session_state_update(
                    session,
                    "waiting",
                    selections=session.selections,
                    metadata={"source": "claude.turn.start"},
                )
                execution.task = asyncio.create_task(
                    self.runner.drive_turn(
                        session=session,
                        execution=execution,
                        content=content,
                        attachments=attachments,
                        client_message_id=client_message_id,
                        command=command,
                    )
                )
            except BaseException:
                session.execution = None
                execution.finished.set()
                raise
        return RuntimeOperationResult(
            ok=True,
            result={
                "turnId": execution.turn_id,
                "externalSessionId": session.external_session_id,
            },
        )

    async def interrupt_session(
        self,
        session_id: str,
        reason: str | None = None,
        preserve_background: bool = False,
    ) -> RuntimeOperationResult:
        """Stop this session's current turn.

        Two flavors, one flag (pp 2026-10-05):

        - ``preserve_background=True`` (the model-switch flow): the declared
          per-task stop affordance makes the CLI interrupt spare running
          background agents; they keep working and report later.
        - ``preserve_background=False`` (manual stop and every internal stop,
          the default): the pre-declaration semantics. The CLI interrupt
          spares the tasks, so each one is stopped explicitly right after
          (``stop_task``; a no-op on a CLI without the declaration, which
          already killed them).
        """

        session = self.session_store.get(session_id)
        if session is None:
            return RuntimeOperationResult(
                ok=True,
                result={"interrupted": False, "alreadyStopped": True},
            )
        async with session.execution_lock:
            execution = session.execution
            if execution is None:
                return RuntimeOperationResult(
                    ok=True,
                    result={"interrupted": False, "alreadyStopped": True},
                )
            execution.interrupt_source = "claude.session.interrupt"
            execution.interrupt_reason = reason
            queued = session.queued_execution
        if queued is not None:
            # A queued execution is an unstarted user message, not background
            # work: it is always dropped, whichever flavor the caller asked for.
            await self.interrupt_execution(
                session=session,
                execution=queued,
                source="claude.session.interrupt",
                reason=reason,
            )
        await self.interrupt_execution(
            session=session,
            execution=execution,
            source="claude.session.interrupt",
            reason=reason,
            preserve_background=preserve_background,
        )
        return RuntimeOperationResult(
            ok=True,
            result={"interrupted": True, "alreadyStopped": False},
        )

    async def interrupt_execution(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        source: str,
        reason: str | None,
        preserve_background: bool = False,
    ) -> None:
        """Stop one owned execution and wait until all of its work has exited."""

        execution.interrupt_source = source
        execution.interrupt_reason = reason
        # Captured before the cancel: `drive_turn`'s finally clears
        # `execution.client` on its way out, so by the time the drain runs the
        # only way to name the queue it has to empty is to have taken its
        # address first.
        response = execution.client
        connection = response.connection if response is not None else None
        # Snapshot before the interrupt: the ids a non-preserving stop owns,
        # whether the CLI killed them already (no declaration) or spared them
        # (declared). Only *subagents* are owned: the live set also holds bash
        # and workflow tasks, and those are left to the CLI's own releasing
        # (pp 2026-10-05: "先不杀" — they are neither stopped here nor folded
        # as killed). The Agent-card binding is the existing subagent
        # registry: bash/workflow tasks never bind one, and it is the same
        # vouching the killed fold uses, so what is stopped and what may be
        # reported as killed cannot drift apart.
        background_ids = (
            self._bound_subagent_ids(session, connection)
            if connection is not None and not preserve_background
            else ()
        )
        try:
            await interrupt_client(execution.client)
        except Exception:  # noqa: BLE001
            logger.debug(
                "Claude SDK interrupt raced with shutdown session_id={}",
                session.session_id,
            )
        stopped_ids: tuple[str, ...] = ()
        if background_ids and is_declared() and connection is not None:
            # Declared CLI interrupts spare background work; a caller without
            # a per-task control still gets the old all-stop, so kill what the
            # interrupt left alive. Not reached on a CLI without the
            # declaration: the interrupt already ended them.
            stopped_ids = await stop_background_tasks(connection.client, background_ids)
            if stopped_ids:
                logger.warning(
                    "Claude interrupt stopped background tasks session_id={} "
                    "tasks={}",
                    session.session_id,
                    len(stopped_ids),
                )
        task = execution.task
        if task is not None and not task.done():
            task.cancel()
        if task is not None:
            await asyncio.gather(task, return_exceptions=True)
        # The turn's consumer is gone by now, so this queue has exactly one
        # reader left: ours. Draining it here means the next turn starts with a
        # clean stream instead of inheriting the interrupted turn's tail.
        await self._drain_after_interrupt(session, execution, source=source, response=response)
        # P2-N1: the agent is told which subagents the stop killed, at the
        # stop, instead of waiting for a CLI notification that arrives minutes
        # later (2026-10-04: agent 20 s late, card 4m41s late, CLI 4m43s late).
        # Only the tasks this stop actually killed may be folded as killed —
        # a survivor folded into "interrupted" is a lie that sticks (Agent
        # cards do not heal). A preserving stop killed nothing; the explicit
        # fan-out reports exactly its accepted stops; on a CLI without the
        # declaration the CLI's own all-stop killed the snapshot, which is
        # what the live set holds until the terminal frames land.
        if preserve_background:
            reported_ids: tuple[str, ...] = ()
        elif stopped_ids:
            reported_ids = stopped_ids
        elif connection is not None:
            reported_ids = self._bound_subagent_ids(session, connection)
        else:
            reported_ids = ()
        await self._report_stopped_subagents(
            session=session,
            response=response,
            task_ids=reported_ids,
            source=source,
            reason=reason,
        )
        await self.runner.finish_execution(
            session=session,
            execution=execution,
            terminal=interrupted_terminal_event(reason),
        )

    def _bound_subagent_ids(
        self,
        session: ClaudeSession,
        connection: Any,
    ) -> tuple[str, ...]:
        """The live background ids that are bound to an Agent card.

        `ClaudeTurnRunner.agent_task_calls` is the card registry the L2 fold
        fills from `task_started` frames — only `local_agent` tasks ever bind
        one — so it is the subagent set. Bash and workflow tasks are excluded
        here exactly as they are excluded from the fold ("先不杀", pp
        2026-10-05), which keeps "what a stop kills" and "what a stop may
        report as killed" the same set by construction.
        """

        return tuple(
            task_id
            for task_id in connection.background.active_ids
            if (session.session_id, task_id) in self.runner.agent_task_calls
        )

    async def _report_stopped_subagents(
        self,
        session: ClaudeSession,
        response: Any,
        *,
        task_ids: tuple[str, ...],
        source: str,
        reason: str | None,
    ) -> None:
        """Fold every subagent this stop killed into its Agent card.

        Display only, and it must never be the reason a stop fails: the L2 fold
        already swallows its own failures, and this call sits on the stop path,
        so anything that escapes is logged and dropped rather than raised.
        """

        if response is None or not task_ids:
            return
        connection = response.connection
        if connection is None or connection.closing:
            return
        try:
            await self.runner.publish_stopped_subagents(
                session,
                task_ids,
                reason=f"{source}:{reason}" if reason else source,
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude stopped-subagent report failed session_id={} source={}",
                session.session_id,
                source,
            )

    async def _drain_after_interrupt(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        *,
        source: str,
        response: Any = None,
    ) -> None:
        """Swallow the interrupted turn's tail frames. Never waits.

        Runs after the turn task is cancelled and before this caller's terminal
        state is published, so nothing it removes could still have been
        projected and nothing it drops is visible. It takes what is already
        queued, up to and including this turn's own result — everything before
        that result is by definition the interrupted turn's residue.

        It does not wait for frames to arrive, and that is the whole design
        rather than a concession. A user's tap on stop must not be held hostage
        to a CLI that may never emit its result at all — stage 1 killed a CLI
        mid-turn, and the budget this originally carried (5 s, per the task
        sheet) blew the existing 2-second stop expectation in
        `test_claude_stop_clears_both_executions_during_scheduled_collision`,
        which is exactly the red line ("never block the stop") catching a
        guard that had been written without it. A residual that arrives after
        this call is the case I1 and B exist for, and they do not cost the user
        a millisecond.

        Measured: on the ordinary interrupt path this drains zero frames —
        `ClaudeResponse.release(interrupted=True)` empties the same queue and
        the reader's `discard` stops re-filling it, so the tail is already gone
        by the time the turn task finishes. It stays in as a cheap safety net
        for the paths where the turn had already seen a terminal: there
        `discard` is False, and the reader keeps parking frames in a queue whose
        consumer no longer exists.
        """

        if not self._drain_on_interrupt_enabled() or response is None:
            return
        messages = response.messages
        drained = 0
        saw_result = False
        started_at = time.monotonic()
        while True:
            try:
                message = messages.get_nowait()
            except asyncio.QueueEmpty:
                break
            drained += 1
            saw_result = saw_result or is_result_message(message)
            if saw_result:
                # The turn's own result is the boundary; anything the CLI
                # queued behind it belongs to the next turn, not to this one.
                break
        if drained:
            logger.info(
                "Claude interrupt drain settled session_id={} turn_id={} "
                "source={} drained={} elapsed_ms={:.1f}",
                session.session_id,
                execution.turn_id,
                source,
                drained,
                (time.monotonic() - started_at) * 1000,
            )

    def _drain_on_interrupt_enabled(self) -> bool:
        return bool(self.runner.config.values.get("drainOnInterrupt", True))

    def has_active_turn(self, session_id: str) -> bool:
        session = self.session_store.get(session_id)
        return session is not None and session.execution is not None

    def session_for(
        self,
        session_id: str,
        external_session_id: str | None,
        cwd: str | None,
    ) -> ClaudeSession:
        return self.session_store.ensure(
            session_id=session_id,
            external_session_id=external_session_id,
            cwd=cwd,
        )
