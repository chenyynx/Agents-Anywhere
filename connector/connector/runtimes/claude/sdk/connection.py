from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

from connector.logging import logger
from connector.runtimes.claude.domain.session import ClaudeExecution
from connector.runtimes.claude.sdk.background import (
    ClaudeBackgroundTasks,
    is_background_activity,
)
from connector.runtimes.claude.sdk.client import (
    connect_client,
    disconnect_client,
    interrupt_client,
    query_client,
    receive_response_messages,
)
from connector.runtimes.claude.sdk.events import (
    is_result_message,
    terminal_event_from_message,
)
from connector.runtimes.claude.sdk.tasks import (
    ClaudeTaskEvent,
    task_event_from_message,
)
from connector.runtimes.claude.sdk.title_tool import is_title_tool_name
from connector.runtimes.claude.timeline.messages import (
    is_synthetic_control_message,
    message_id,
    message_role,
)
from connector.runtimes.claude.timeline.stream import is_stream_event

RECONCILE_DONE_MARKER = "AA_MAINTENANCE_DONE"
CONNECTION_CLOSE_TIMEOUT_SECONDS = 30
# V9/L2: how many projection events one transport may hold while the host is
# slow. Sized for a burst of subagent progress, not for backpressure: when the
# host cannot keep up, the OLDEST event is dropped (a progress row that is
# already stale is worth less than the ones that follow), the drop is counted
# and warned, and the reader is never made to wait. The invariant being
# protected is "the reader never stops reading the stream", so the queue must be
# able to say no.
DEFERRED_EVENT_QUEUE_MAXSIZE = 256
DEFERRED_EVENT_WORKER_TIMEOUT_SECONDS = 5.0
LEGACY_RECONCILE_PROMPT = (
    "AA connection maintenance: call CronList exactly once to report the current "
    "scheduled task list, then stop. If needed, use ToolSearch to find CronList. "
    "Do not create, delete, execute or modify tasks or perform any other work."
)
RECONCILE_PROMPT = (
    f"{LEGACY_RECONCILE_PROMPT} End with exactly {RECONCILE_DONE_MARKER}."
)


def _is_wire_chrome(message: Any) -> bool:
    """Report frames that must never mint a scheduled reply from silence.

    Hook lifecycle frames the CLI emits around its own SessionStart hooks, the
    non-task system handshake, and the command echoes the CLI replays as user
    messages are all governed rather than answered: no prompt was accepted for
    them, so minting a turn waits forever for a result that belongs to a turn
    which has already settled (real session 84275e9e, 2026-10-02).
    """

    if is_synthetic_control_message(message):
        return True
    # The SDK nests every non-task system payload inside `.data`, and all of its
    # subtypes are handshake or compaction bookkeeping, never a conversation
    # reply (real wire: status probing frames, hook narration, compact_result,
    # compact_boundary, drive_turn's system blocks).
    return message.__class__.__name__ == "SystemMessage"


@dataclass(slots=True)
class ClaudeResponse:
    connection: ClaudeConnection
    execution: ClaudeExecution | None = None
    user_id: str | None = None
    prompt_uuid: str | None = None
    messages: asyncio.Queue[Any] = field(default_factory=asyncio.Queue)
    released: asyncio.Event = field(default_factory=asyncio.Event)
    terminal_received: bool = False
    discard: bool = False
    maintenance: bool = False
    task_snapshot: set[str] | None = None
    # The frame whose arrival at silence cast this response into a turn,
    # stamped by the reader's mint branch below before `select_response`
    # hands the response to `on_activity`. Structural, not a frame type:
    # whichever shape carried the cast, it arrived passively — no prompt was
    # accepted for it and the turn did nothing to earn it — so `drive_turn`
    # must not read it as evidence that this turn did work (B1 §6: the
    # evidence may not be the casting frame itself). `drive_turn` reads it as
    # a POSITION marker: everything the reader flushed ahead of it (the
    # preamble parked at silence) plus the cast frame itself is passive; only
    # what follows counts. Human/pending turns never stamp it; they are not
    # armed and count every frame as before.
    cast_frame: Any = None

    async def connect(self) -> None:
        await self.connection.connect()

    async def query(self, content: str) -> None:
        prompt_uuid = self.prompt_uuid or self.user_id
        if prompt_uuid is None:
            await query_client(self.connection.client, content)
        else:

            async def prompt():
                yield {
                    "type": "user",
                    "uuid": prompt_uuid,
                    "message": {"role": "user", "content": content},
                    "parent_tool_use_id": None,
                    "priority": "later",
                }

            await self.connection.client.query(prompt())
        self.connection.queried.set()

    async def receive_response(self):
        while True:
            message = await self.messages.get()
            if message is None:
                if self.connection.failure is not None:
                    raise self.connection.failure
                return
            yield message
            if is_result_message(message):
                return

    async def interrupt(self) -> None:
        if self.connection.current is None and self.connection.pending is self:
            await self.connection.select_response(self)
        await interrupt_client(self.connection.client)
        current = self.connection.current
        if (
            current is not None
            and current is not self
            and not current.terminal_received
        ):
            # A submitted native prompt cannot be individually retracted.
            await self.connection.close()

    def release(self, *, interrupted: bool = False) -> None:
        if interrupted:
            while not self.messages.empty():
                self.messages.get_nowait()
        self.discard = interrupted and not self.terminal_received
        self.released.set()

    def ensure_prompt_uuid(self) -> str:
        """Return the UUID this prompt carries on the wire, pre-assigning one.

        The SDK replays this exact UUID, so timeline identity is known at send
        time instead of at the first response byte.
        """

        if self.prompt_uuid is None:
            self.prompt_uuid = self.user_id or str(uuid4())
        return self.prompt_uuid


@dataclass(slots=True)
class ClaudeConnection:
    """Own the SDK's task-scoped transport independently of a single reply."""

    client: Any
    on_activity: Callable[[ClaudeResponse], Awaitable[None]]
    on_idle: Callable[[ClaudeConnection], Awaitable[None]]
    on_background_done: Callable[[ClaudeConnection], Awaitable[None]]
    cleanup: Callable[[], None]
    # L2 subagent progress (claude-subagent-progress-tasks.md §3.4). Both are
    # optional so a transport built without them keeps the pre-L2 behavior
    # (task frames absorbed, parented frames dropped) — aggregation is display
    # state and must never be a dependency of the session lifecycle.
    on_task_event: Callable[[ClaudeTaskEvent], Awaitable[None]] | None = None
    on_background_frame: Callable[[Any], Awaitable[None]] | None = None
    idle_timeout_seconds: float = 600.0
    task: asyncio.Task[None] | None = None
    idle_task: asyncio.Task[None] | None = None
    background_done_task: asyncio.Task[None] | None = None
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    queried: asyncio.Event = field(default_factory=asyncio.Event)
    selected: asyncio.Event = field(default_factory=asyncio.Event)
    pending: ClaudeResponse | None = None
    current: ClaudeResponse | None = None
    failure: BaseException | None = None
    closing: bool = False
    task_ids: set[str] = field(default_factory=set)
    background: ClaudeBackgroundTasks = field(default_factory=ClaudeBackgroundTasks)
    selections: dict[str, str | None] = field(default_factory=dict)
    reconcile_needed: bool = False
    reconciling: bool = False
    # Scheduled-timeout failures already published for this connection window.
    # Repeat ghosts (unknown frames minting again while background work keeps
    # the transport alive) still force-fail and release the lock, but only the
    # first one reaches the client as a failed-turn report; the session state
    # still updates on every repeat. The lock makes check-and-reserve atomic
    # across concurrently firing watchdogs (R2).
    stuck_timeout_reports: int = 0
    stuck_report_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # I1: foreign terminal frames absorbed at silence instead of minting a
    # scheduled turn (claude-stale-frame-turn-tasks.md §4). A counter, not a
    # limit — the guard is an invariant, not a rate limiter.
    #
    # It is ALSO not, on its own, a leak alarm, and the per-status breakdown
    # exists because of that (red team F6, round 1). A turn whose only frame is
    # its own result — an empty reply — is absorbed by exactly this path, so the
    # raw total is non-zero in normal operation and a rate alarm on it would
    # fire on day one. What separates "the CLI shed a result" from "a reply came
    # back empty" is the status breakdown: `completed` at silence is the ghost
    # shape (a leftover success that would have reported `completed` on the
    # wrong turn), `interrupted` is the abort tail of a turn this connector
    # stopped itself, and `failed` is a queued prompt's failure that found no
    # pending to land on.
    absorbed_terminal_frames: int = 0
    absorbed_terminal_by_status: dict[str, int] = field(default_factory=dict)
    # V9/L2 (claude-stale-frame-turn-tasks.md §4/§11): the reader loop must do
    # zero host round trips. Both projection callbacks below end in a host
    # upsert, and at 400 ms of host backpressure that parked the reader for
    # 271.66 s against upstream's 2.96 s — while also letting it cast a ghost
    # and push the human turn into `queued_execution` (stage-1 findings §2.2,
    # V9 vs V11). Bounded queue + one drain worker per connection: the reader
    # hands the event over and goes straight back to the stream.
    deferred_event_queue: asyncio.Queue[Any] = field(
        default_factory=lambda: asyncio.Queue(maxsize=DEFERRED_EVENT_QUEUE_MAXSIZE)
    )
    deferred_event_worker: asyncio.Task[None] | None = None
    deferred_dropped_events: int = 0

    @property
    def retained(self) -> bool:
        return bool(self.task_ids)

    @property
    def has_live_background_work(self) -> bool:
        """Whether this transport still hosts work that retirement would kill.

        The do-not-retire invariant (2026-10-02) reads this signal at every
        retirement decision point. A dead or closing transport cannot protect
        anything — the process that ran the work is already gone — so
        transport health is part of the signal, and the invariant's exceptions
        (shutdown, genuine transport failure) fall out of it for free.
        """

        return (
            bool(self.background.active_ids)
            and self.failure is None
            and not self.closing
        )

    @property
    def streaming(self) -> bool:
        return callable(getattr(self.client, "receive_messages", None))

    def cancel_idle(self) -> None:
        timer = self.idle_task
        self.idle_task = None
        if timer is not None and timer is not asyncio.current_task():
            timer.cancel()

    def defer_event(self, callback: Awaitable[Any] | None, event: Any) -> None:
        """Hand one projection event to the drain worker without awaiting it.

        The reader calls this instead of awaiting the callback. That is the whole
        point: the reader's job is to read the CLI's stream, and both callbacks
        end in a host upsert whose latency is the server's business, not the
        stream's. Ordering is preserved by the single worker, so the events this
        defers still reach the timeline in the order the CLI produced them.

        Overflow drops the OLDEST event: a progress row the host has not seen
        yet is already behind whatever the CLI said after it, and stalling the
        reader to preserve it would trade a cosmetic lag for the ghost this
        whole queue exists to prevent. Drops are counted and warned so the
        observation window can see backpressure rather than infer it.
        """

        if callback is None:
            return
        worker = self.deferred_event_worker
        if worker is None or worker.done():
            worker = asyncio.create_task(self._drain_deferred_events())
            self.deferred_event_worker = worker
        queue = self.deferred_event_queue
        if queue.full():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:  # pragma: no cover - single consumer
                pass
            self.deferred_dropped_events += 1
            logger.warning(
                "Claude deferred projection event dropped on overflow "
                "dropped_total={} queue_max={}",
                self.deferred_dropped_events,
                queue.maxsize,
            )
        queue.put_nowait((callback, event))

    async def _drain_deferred_events(self) -> None:
        """Project queued events, one at a time, in order.

        Nothing in here may mint or select a turn: these are display-only
        projections, and the worker's whole reason to exist is that they are not
        worth a round trip on the reader's hot path. A failing callback is
        logged and skipped — the L1 lesson again: nothing on this path may take
        a transport down, and a poisoned worker would silently stop projecting
        every later event too.
        """

        queue = self.deferred_event_queue
        while True:
            callback, event = await queue.get()
            try:
                await callback(event)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude deferred projection event failed",
                )

    async def _stop_deferred_events(self) -> None:
        """Retire the drain worker without letting shutdown wait on the host.

        Cancelling first, then emptying the queue by hand: a worker cancelled
        mid-host-call leaves whatever it was holding in flight, and calling back
        into a host that is itself shutting down is exactly the hang this queue
        was introduced to avoid. What is left is counted, not replayed.
        """

        worker = self.deferred_event_worker
        self.deferred_event_worker = None
        if worker is not None and worker is not asyncio.current_task():
            worker.cancel()
            await asyncio.wait(
                (worker,), timeout=DEFERRED_EVENT_WORKER_TIMEOUT_SECONDS
            )
        queue = self.deferred_event_queue
        remaining = 0
        while True:
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            remaining += 1
        if remaining:
            self.deferred_dropped_events += remaining
            logger.warning(
                "Claude deferred projection events discarded on close "
                "discarded={} dropped_total={}",
                remaining,
                self.deferred_dropped_events,
            )

    def arm_idle(self) -> None:
        if (
            self.closing
            or not self.streaming
            or self.task_ids
            or self.background.active_ids
            or self.current is not None
            or self.pending is not None
        ):
            return
        self.cancel_idle()

        async def expire() -> None:
            await asyncio.sleep(self.idle_timeout_seconds)
            await self.on_idle(self)

        self.idle_task = asyncio.create_task(expire())

    def response_for(self, execution: ClaudeExecution | None) -> ClaudeResponse:
        self.cancel_idle()
        response = ClaudeResponse(
            self,
            execution=execution,
            user_id=str(uuid4()) if self.retained or self.queried.is_set() else None,
        )
        self.pending = response
        return response

    async def select_response(self, response: ClaudeResponse) -> None:
        self.cancel_idle()
        self.current = response
        if self.pending is response:
            self.pending = None
        if not response.maintenance:
            await self.on_activity(response)
        self.selected.set()

    def drop_current(self, response: ClaudeResponse) -> bool:
        """Abandon the reader's current response without touching the transport.

        The stuck-turn breaker withholds retirement while background work is
        live (the CLI process is the only place that work exists). The ghost's
        consumer is gone by then, so routing must stop parking frames in its
        dead queue — otherwise the session would look unlocked while being
        permanently unusable, the very state the breaker exists to prevent.
        """

        if self.current is not response:
            return False
        self.current = None
        self.selected.clear()
        return True

    async def prepare_approval(self) -> None:
        if self.current is None:
            if self.pending is None:
                await self.select_response(ClaudeResponse(self))
            elif self.pending.user_id is None:
                await self.select_response(self.pending)
            else:
                await self.selected.wait()

    async def tool_result(self, data: Any, *_args: Any) -> dict[str, Any]:
        response = data.get("tool_response")
        name = data.get("tool_name")
        if isinstance(response, dict):
            task_id = response.get("id")
            if name == "CronCreate" and isinstance(task_id, str):
                self.task_ids.add(task_id)
            elif name == "CronDelete" and isinstance(task_id, str):
                self.task_ids.discard(task_id)
            elif name == "CronList" and isinstance(response.get("jobs"), list):
                jobs = response["jobs"]
                if any(
                    not isinstance(job, dict) or not isinstance(job.get("id"), str)
                    for job in jobs
                ):
                    return {}
                ids = {job["id"] for job in jobs}
                if self.current is not None and self.current.maintenance:
                    self.current.task_snapshot = ids
                else:
                    self.task_ids = ids
            return {}
        return {}

    async def before_tool(self, data: Any) -> dict[str, Any]:
        if self.reconciling:
            await self.prepare_approval()
        if self.current is not None and self.current.maintenance:
            allowed = data.get("tool_name") in {"CronList", "ToolSearch"}
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow" if allowed else "deny",
                    "permissionDecisionReason": "AA maintenance only reads the scheduled task list.",
                }
            }
        if is_title_tool_name(data.get("tool_name")):
            # Session titles are connector bookkeeping — they must never
            # surface as an approval request in the client. Auto-allow after
            # the maintenance gate above (reconcile turns stay locked down).
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "Session titles are set by the connector.",
                }
            }
        return {}

    async def reconcile_tasks(self, response: ClaudeResponse | None = None) -> bool:
        self.reconcile_needed = False
        self.reconciling = True
        check = self.response_for(response.execution if response is not None else None)
        check.maintenance = True
        if response is not None:
            if response.execution is not None:
                response.execution.client = check
            response.release()
        try:
            async with asyncio.timeout(30):
                await check.query(RECONCILE_PROMPT)
                async for message in check.receive_response():
                    terminal = terminal_event_from_message(message)
                    if terminal is not None:
                        if (
                            terminal.status == "completed"
                            and check.task_snapshot is not None
                        ):
                            self.task_ids = check.task_snapshot
                            return True
                        break
            logger.warning(
                "Claude task reconciliation did not return a valid task list"
            )
            return False
        except Exception as exc:  # noqa: BLE001
            logger.warning("Claude task reconciliation failed: {}", exc)
            return False
        finally:
            try:
                if not check.terminal_received and not self.closing:
                    # A queued native prompt cannot be individually retracted.
                    # Retire this transport on failure instead of interrupting
                    # whichever scheduled reply happens to own it now.
                    await self.close()
            finally:
                check.release(interrupted=not check.terminal_received)
                self.reconciling = False

    async def connect(self) -> None:
        if self.task is None:
            self.task = asyncio.create_task(self._run())
        await self.ready.wait()
        if self.failure is not None:
            raise self.failure

    async def _run(self) -> None:
        try:
            await connect_client(self.client)
            self.ready.set()
            await self.queried.wait()
            preamble = []
            async for message in receive_response_messages(self.client):
                had_background = bool(self.background.active_ids)
                task_event = self.background.observe(message)
                if task_event:
                    if self.background.active_ids:
                        self.cancel_idle()
                    else:
                        self.arm_idle()
                        if had_background and self.current is None:
                            self.background_done_task = asyncio.create_task(
                                self.on_background_done(self)
                            )
                    # L2: the observe point is the only place that sees task
                    # frames both mid-turn and at silence (in-turn they are
                    # discarded later as unprojectable; at silence they were
                    # absorbed outright). The fold itself only publishes the
                    # Agent card and must not mint anything.
                    #
                    # V9/L2: handed to the drain worker, not awaited here. The
                    # fold ends in a host upsert, and at 400 ms of host
                    # backpressure awaiting it parked the reader for 271.66 s
                    # (upstream: 2.96 s) — long enough for it to cast a ghost
                    # and push the human turn into `queued_execution`.
                    if self.on_task_event is not None:
                        agent_event = task_event_from_message(message)
                        if agent_event is not None:
                            self.defer_event(self.on_task_event, agent_event)
                background_activity = is_background_activity(message)
                if background_activity:
                    # Frames parented to a tool use are activity *inside* a
                    # background subagent leaking into the parent stream (real
                    # wire, 2026-10-02: a subagent thinking frame landed 47 ms
                    # after the dispatch reply; tool results seconds later).
                    # They are work in progress: keep the reclaim timer away
                    # while they flow, and never let them mint a reply from
                    # silence (the mint branch below refuses them). Frames tied
                    # to an accepted pending turn still flow, because an agent
                    # call legitimately streams its children mid-turn.
                    self.cancel_idle()
                if self.current is None:
                    if task_event:
                        continue
                    terminal_event = terminal_event_from_message(message)
                    # I1 (claude-stale-frame-turn-tasks.md §4/§11): a terminal
                    # frame settles exactly one turn — the one that can prove it
                    # started it. Arriving at silence it can prove none, because
                    # the CLI's stream is session-scoped and shared: a result
                    # belonging to a turn that already settled (real session
                    # sess_tPcEDi0z9xJYxQ, 2026-10-04 12:22:53) lands here as
                    # if it were the next turn's own. Minting from it is what
                    # produced "completed" 0.27 s BEFORE the turn's own model
                    # request was even sent (stage-1 findings §4 H-a, S2
                    # upstream/m1).
                    #
                    # This is the attribution invariant, NOT a frame-shape
                    # enumeration. The chrome gate below already proves the
                    # point: gating on `origin.kind == "task-notification"` (or
                    # any other observed payload) catches the residual shape
                    # this investigation happened to record and nothing else —
                    # a bare `ResultMessage(success)` with no origin still
                    # mints (findings §2.3). The trigger chain is not
                    # enumerable, so the guard cannot be either.
                    #
                    # EVERY terminal is absorbed here, whatever its status.
                    # `completed` was the obvious one; `interrupted` was not, and
                    # it is worse than useless: the CLI emits `aborted_streaming`
                    # / `aborted_tools` for turns this connector interrupted
                    # itself, those frames land at silence seconds later, and
                    # minting from one hands the lifecycle a turn whose only
                    # content is the abort — which then either settles as a
                    # bogus `interrupted` or, once the cast-frame position gate
                    # refuses it, exhausts its stream and turns the session red
                    # (`claude_stream_ended_without_result`) with no user action
                    # anywhere. Red team F3, round 1.
                    #
                    # `failed` is absorbed from the MINT path too, and keeps its
                    # visibility through the pending branch above — which runs
                    # first: a queued prompt whose CLI failed must still surface
                    # that failure (red line), and that path routes the frame
                    # into the pending response rather than casting a new turn.
                    #
                    # Note what is deliberately NOT special-cased here: the
                    # pending selection is left exactly as it was. A pending
                    # with no wire uuid is a prompt submitted on this
                    # transport's first turn, before the reader has ever yielded
                    # a frame, so no earlier turn's result can be in flight to
                    # hijack it (red team could not falsify this, and proved
                    # the two rebuild entry points set `queried` explicitly).
                    if self.pending is not None and (
                        self.pending.user_id is None
                        or (
                            message_role(message) == "user"
                            and message_id(message) == self.pending.user_id
                        )
                        or (
                            terminal_event is not None
                            and terminal_event.status == "failed"
                        )
                    ):
                        await self.select_response(self.pending)
                    elif terminal_event is not None:
                        # Absorbed. NOT appended to `preamble`: preamble is
                        # flushed into the queue of whichever response is
                        # selected next (lines 490-493), so parking a terminal
                        # there would smuggle it back in as that turn's "first
                        # frame" — the very ghost this guard exists to kill, by
                        # the back door. There is also nothing to preserve: a
                        # result carries no context the CLI will not replay.
                        self.absorbed_terminal_frames += 1
                        self.absorbed_terminal_by_status[terminal_event.status] = (
                            self.absorbed_terminal_by_status.get(
                                terminal_event.status, 0
                            )
                            + 1
                        )
                        logger.warning(
                            "Claude foreign terminal frame absorbed at silence "
                            "session_pending={} absorbed_total={} status={} "
                            "reason={}",
                            self.pending is not None,
                            self.absorbed_terminal_frames,
                            terminal_event.status,
                            terminal_event.reason,
                        )
                        continue
                    elif message_role(message) == "system":
                        preamble.append(message)
                        continue
                    elif (
                        message_role(message) in {"assistant", "user"}
                        or is_stream_event(message)
                        or terminal_event is not None
                    ):
                        if _is_wire_chrome(message):
                            # Chrome replayed into silence is not a scheduled
                            # reply waking up: no prompt was accepted for it,
                            # so minting a turn hangs forever waiting for a
                            # result that belongs to an already-settled turn.
                            # Buffered as preamble so a real reply that follows
                            # still sees these context frames, in order.
                            preamble.append(message)
                            continue
                        if background_activity:
                            # In-subagent activity at silence must never mint
                            # a scheduled reply either: no prompt was accepted
                            # for it, and the main agent's own wake-and-report
                            # frames all carry parent_tool_use_id=None. The
                            # minted ghost used to get the transport retired
                            # 30 s later, killing the very subagents whose
                            # frames it was minted from (2026-10-02).
                            #
                            # L2: the same guard is the capture point — the
                            # frame is routed to the timeline projector so the
                            # subagent's work is visible (and folds into its
                            # Agent card) instead of being dropped. The route
                            # is the strict complement of the in-turn queue
                            # below, so no frame is projected twice, and the
                            # callback publishes items only — still no turn is
                            # minted here. V9/L2: deferred, same reason as the
                            # task-event fold above — same-shape host round
                            # trip on the reader's hot path.
                            self.defer_event(self.on_background_frame, message)
                            continue
                        # The mint branch: this frame is about to cast a
                        # scheduled turn, so it is stamped as the response's
                        # `cast_frame` before `on_activity` spawns the turn —
                        # `drive_turn` then excludes it from the content gate
                        # (it is passive arrival, not this turn's labour).
                        await self.select_response(
                            ClaudeResponse(self, cast_frame=message)
                        )
                    else:
                        continue
                response = self.current
                if not response.discard:
                    for buffered in preamble:
                        await response.messages.put(buffered)
                preamble.clear()
                terminal = is_result_message(message)
                response.terminal_received = terminal
                if not response.discard:
                    await response.messages.put(message)
                if terminal:
                    await response.released.wait()
                    self.current = None
                    self.selected.clear()
                    self.arm_idle()
                    if (
                        not self.streaming
                        and not self.retained
                        and self.pending is None
                    ) or self.closing:
                        break
            if (
                self.streaming or self.retained or self.background.active_ids
            ) and not self.closing:
                raise RuntimeError(
                    "Claude session transport ended unexpectedly"
                )
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            self.failure = exc
            if self.current is None and self.pending is None:
                await self.select_response(ClaudeResponse(self))
        finally:
            self.closing = True
            self.cancel_idle()
            if self.background_done_task is not None:
                self.background_done_task.cancel()
            self.ready.set()
            # V9/L2: stop the drain worker before the transport goes away, so a
            # projection in flight cannot call back into a host that is closing.
            await self._stop_deferred_events()
            try:
                await disconnect_client(self.client)
            finally:
                self.cleanup()
                await self._release_responses()

    async def _release_responses(self) -> None:
        responses = (self.current, self.pending)
        self.current = self.pending = None
        for response in responses:
            if response is not None:
                await response.messages.put(None)

    async def close(self) -> None:
        was_closing = self.closing
        self.closing = True
        if self.background_done_task is asyncio.current_task():
            # The reader's finally must not cancel the maintenance task that
            # is waiting here for the reader's own shutdown.
            self.background_done_task = None
        try:
            if self.task is not None:
                if not self.task.done() and not was_closing:
                    self.task.cancel()
                done, _ = await asyncio.wait(
                    (self.task,), timeout=CONNECTION_CLOSE_TIMEOUT_SECONDS,
                )
                if done:
                    await asyncio.gather(self.task, return_exceptions=True)
                else:
                    if self.failure is None:
                        self.failure = TimeoutError("Claude transport shutdown timed out")
                    logger.warning("Claude transport shutdown timed out")
        finally:
            # A slow SDK disconnect can continue in its owning reader task,
            # but must not keep an expired response or block its replacement.
            # V9/L2: the same goes for the drain worker — a reader task that
            # timed out above is still running, so only stop the worker if this
            # call is not racing its own finally.
            if self.deferred_event_worker is not None:
                await self._stop_deferred_events()
            self.cleanup()
            await self._release_responses()
