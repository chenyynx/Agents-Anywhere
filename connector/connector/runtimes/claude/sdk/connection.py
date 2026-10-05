from __future__ import annotations

import asyncio
from collections import deque
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
# F2: the state-bearing queue gets its own budget. Two independent bounds, so
# a decorative burst cannot consume the space a task closure needs, and a task
# burst cannot consume the space subagent rows need.
DEFERRED_TASK_QUEUE_MAXSIZE = 256
DEFERRED_EVENT_WORKER_TIMEOUT_SECONDS = 5.0
# F1 release protocol (claude-stale-frame-f1-release-protocol.md §8.1.3): how
# long a response keeps reading after the turn DECLINED a terminal frame.
#
# This is R1's arm, and it is not optional. A human turn has no watchdog —
# `arm_scheduled_watchdog` is only installed for `scheduled_activity`, so the
# 600 s ceiling and the 30 s fast kill do NOT cover this shape. Without a
# bound, "echo → leftover result → decline → nothing after it" would wait for
# the user forever.
#
# Why 30 s: it sits in the same class as the existing 30 s fast kill and the
# ~32 s residual window measured on the real transport (2026-10-04), so the
# extra user-visible latency for an empty-reply-shaped turn is one such
# window and no more. The trade this buys is explicit: a leftover whose real
# frames arrive MORE than G later falls back to exactly today's behavior
# (settle on the downgraded verdict, late by G), including the benign
# phantom-turn cascade documented in `turns/lifecycle.py`. That direction is
# deliberate — this must never be worse than not shipping it.
#
# Read at call time, so a test can shrink it without patching call sites.
DECLINED_TERMINAL_GRACE_SECONDS = 30.0
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
    """One response's place on a shared transport, and the handshake that hands
    it back and forth between the reader and the turn consuming it.

    THE RELEASE PROTOCOL (F1, claude-stale-frame-f1-release-protocol.md §8.1).
    After every terminal frame the reader enqueues, it parks for exactly one of
    two signals, and both are set from the consumer:

    * `released` — the turn is done with this response. The reader clears
      `current`, re-arms the idle reclaim, and re-evaluates whether the
      transport should keep running. This is the verdict the reader acted on
      before the protocol existed.
    * `terminal_declined` — the turn read that terminal and ruled it NOT its
      own verdict (an unowned `completed`: a leftover from a turn that already
      settled). The reader keeps `current` and keeps reading, so the frames
      behind the leftover — the real reply, this turn's own result — are still
      this response's. Before this signal existed, the leftover swallowed
      them: the turn settled on it and they died in a queue nobody drained.

    `released` has priority: a turn that declines and then ends anyway (grace
    window expired, stream ended, user interrupted) sets both, and only the
    first is a verdict about `current`.

    There is deliberately no own/foreign judgement here. The reader cannot
    make one — the same payload is a legitimate empty reply and a leftover —
    and duplicating the decision in two places is how the two would drift.
    `drive_turn` is the single authority; the reader only answers signals.
    """

    connection: ClaudeConnection
    execution: ClaudeExecution | None = None
    user_id: str | None = None
    prompt_uuid: str | None = None
    messages: asyncio.Queue[Any] = field(default_factory=asyncio.Queue)
    released: asyncio.Event = field(default_factory=asyncio.Event)
    # The other half of the handshake: "this terminal is not yours, keep
    # reading". Cleared by `await_terminal_verdict` when it is consumed, so it
    # re-arms for the next terminal.
    terminal_declined: asyncio.Event = field(default_factory=asyncio.Event)
    # Monotonic count of terminals the turn declined, and how many of those
    # declines were followed by another frame (which is what lifts the grace
    # window). Diagnostic only: the actionable numbers live on the runner.
    declined_terminals: int = 0
    _satisfied_declines: int = 0
    # The parked reader, and a verdict that arrived with nobody parked. The
    # turn can rule on a frame before the reader gets to wait on it, so the
    # ruling has to be remembered rather than dropped.
    _verdict_waiter: asyncio.Future[bool] | None = None
    _verdict_pending: bool = False
    # Set by the reader when it keeps `current` after a decline. From then on
    # the reader will not run the clear-`current` step that follows a
    # `released` verdict, so `release()` takes `current` back instead.
    reader_declined: bool = False
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

    def decline_terminal(self) -> None:
        """Rule the terminal just read out of this turn, and keep reading.

        `drive_turn` calls this immediately before it `continue`s past a frame
        it cannot attribute. It is the consumer's half of a handshake the
        reader is parked on: without it the reader would sit on `released`,
        which only a SETTLED turn can set, and the two would wait on each
        other forever.
        """

        self.declined_terminals += 1
        self.terminal_declined.set()
        self._settle_verdict(False)

    def _consume_verdict_signals(self) -> None:
        """Destroy a ruling exactly once, on whichever channel answered it.

        The decline ruling travels on three channels: the level event a park
        would poll, the remembered flag for a ruling that arrived with nobody
        parked, and the future handed to a parked reader. Whichever one
        answers a park must clear the others with it. A ruling that outlives
        the park it answered pre-empts the NEXT park — and that is not a rare
        race, it is every recovered turn: the reader parks twice (once on the
        leftover, once on the turn's own terminal) and the second park would
        be answered by the first decline's leftovers. The reader then never
        waits where it must, reads through the whole settle phase, and every
        frame that arrives in that window is routed into a response whose turn
        has already chosen its verdict — and destroyed with it.

        `released` is deliberately not cleared. It is level-triggered, it is
        checked first at every park, and it says something permanent about
        `current`; only the one-shot decline needs consuming.
        """

        self.terminal_declined.clear()
        self._verdict_pending = False

    async def await_terminal_verdict(self) -> bool:
        """Wait for the consumer's ruling on the terminal just enqueued.

        Returns True when the turn settled this response (`released`) and the
        reader must hand the transport back. Returns False when the turn
        declined the frame and the reader must keep `current` and keep
        reading. `released` wins when both are set: it is the one that says
        something about `current`, and a release that lands while a decline's
        answer is in flight is a release about a turn that has since ended.

        Every channel consumes the ruling as it answers
        (`_consume_verdict_signals`), so the next terminal frame re-arms the
        handshake.
        """

        if self.released.is_set():
            return True
        if self.terminal_declined.is_set():
            self._consume_verdict_signals()
            return False
        if self._verdict_pending:
            # Both rulings can land while the reader is away and both answer
            # the same question, so one flag is enough: `released` first.
            self._consume_verdict_signals()
            return self.released.is_set()
        waiter: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self._verdict_waiter = waiter
        try:
            released = await waiter
        finally:
            if self._verdict_waiter is waiter:
                self._verdict_waiter = None
        self._consume_verdict_signals()
        # The waiter can be answered while the turn is still on this response
        # (a decline), and the turn can END in the gap before the reader is
        # scheduled back — `release()` reads `reader_declined` for its
        # self-heal and would miss it here. `released` is level-triggered, so
        # it catches that order too, and handing the transport back is the
        # only safe answer once the consumer is done with it.
        return released or self.released.is_set()

    def _settle_verdict(self, released: bool) -> None:
        """Hand a ruling to the parked reader, or remember it for one.

        A direct hand-off, not a second event to race on. Waiting on two
        `asyncio.Event`s needs two tasks and `asyncio.wait`, which put three
        extra event-loop hops between `release()` and the reader giving
        `current` back — measured, and enough to break the existing pins that
        assert the transport is free the moment a turn ends. This costs the
        same single hop the old `await released.wait()` did.
        """

        waiter = self._verdict_waiter
        if waiter is None or waiter.done():
            # Nobody is parked: the turn ruled before the reader got here.
            self._verdict_pending = True
            return
        self._verdict_waiter = None
        waiter.set_result(released)

    async def receive_response(self):
        """Yield this response's frames until the transport stops producing.

        A response is NOT ended by its first result any more (F1, §8.1.1). A
        leftover result from a turn that already settled is byte-identical to
        this turn's own by the time it reaches a turn, and stopping there is
        precisely what swallowed the real reply queued behind it. Whether a
        terminal is this turn's verdict is decided by the consumer —
        `drive_turn`, the single authority — and announced back over
        `decline_terminal`.

        So the generator ends on exactly two things: the transport stopped
        (`None`, or a failure to raise), or the grace window opened by a
        decline ran out. The second is R1's guarantee. A human turn has no
        watchdog, so "keep reading" has to be bounded; when the window expires
        the turn settles on the downgraded verdict it recorded at decline
        time — today's behavior, reached G later, never a hang.

        The window lifts by itself as soon as anything else arrives, so the
        fast path for a healthy stream is unchanged.
        """

        while True:
            if self.declined_terminals > self._satisfied_declines:
                try:
                    message = await asyncio.wait_for(
                        self.messages.get(), DECLINED_TERMINAL_GRACE_SECONDS
                    )
                except TimeoutError:
                    logger.warning(
                        "Claude declined-terminal grace window expired "
                        "declined={} grace={}s",
                        self.declined_terminals,
                        DECLINED_TERMINAL_GRACE_SECONDS,
                    )
                    return
            else:
                message = await self.messages.get()
            if message is None:
                if self.connection.failure is not None:
                    raise self.connection.failure
                return
            # Snapshot the decline count BEFORE the yield. This generator is
            # suspended while the consumer judges the frame, and a decline
            # registered during that window belongs to THIS frame — it has to
            # leave the next get bounded. Reading the counter after the yield
            # instead would mark the decline as already satisfied and disarm
            # the window on exactly the shape it exists for.
            declines_seen = self.declined_terminals
            yield message
            self._satisfied_declines = declines_seen

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
        self._settle_verdict(True)
        if self.reader_declined:
            self.reader_declined = False
            if self.connection.drop_current(self):
                # The reader is no longer parked on this response — it took
                # `released` from an earlier decline and went back to reading,
                # so it will never run the clear-`current` step itself. Take
                # it back here or `current` is stranded for good: the idle
                # reclaim could never arm again, and every later frame,
                # including the NEXT human turn's prompt echo and a queued
                # prompt's failure, would be parked in a dead queue.
                self.connection.arm_idle()

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
    # F2: two queues with two bounds. State-bearing events (the task binding
    # and the card closure) cannot be evicted by decorative ones; see
    # `defer_event`. Plainer deques than `asyncio.Queue` because the eviction
    # rule is by importance, not by arrival, and reaching into a Queue's
    # internals to express that would be the wrong trade.
    deferred_task_events: deque[tuple[Awaitable[Any], Any, bool]] = field(
        default_factory=deque
    )
    deferred_background_events: deque[tuple[Awaitable[Any], Any, bool]] = field(
        default_factory=deque
    )
    _deferred_wakeup: asyncio.Event = field(default_factory=asyncio.Event)
    deferred_event_worker: asyncio.Task[None] | None = None
    deferred_dropped_events: int = 0
    # Counted apart from the decorative drops: a non-zero value here means a
    # task binding or a card closure was lost, which is not a cosmetic loss.
    deferred_dropped_state_events: int = 0

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

    def defer_event(
        self,
        callback: Awaitable[Any] | None,
        event: Any,
        *,
        state_bearing: bool = False,
    ) -> None:
        """Hand one projection event to the drain worker without awaiting it.

        The reader calls this instead of awaiting the callback. That is the whole
        point: the reader's job is to read the CLI's stream, and both callbacks
        end in a host upsert whose latency is the server's business, not the
        stream's. The single worker keeps arrival order, so the events this
        defers still reach the timeline in the order the CLI produced them.

        TWO QUEUES, because the two kinds of event are not equally lossy (red
        team F2, round 1). `on_background_frame` carries decorative rows — a
        subagent's thinking and tool lines — and losing one costs a row.
        `on_task_event` carries state: `task_started` is the ONLY writer of the
        task-to-card binding, and the event that closes a card is sent once and
        never again. A single FIFO let decorative traffic evict the binding, and
        the result was a subagent card stuck on `running` forever, with P2-N1's
        "killed" fold silently dead for that subagent too — a loss the pre-V9
        inline `await` could not suffer, so V9 introduced it.

        The whole `on_task_event` stream goes in the state queue, `task_progress`
        included: a progress row and the terminal closure that supersedes it are
        a pair, and draining them out of order leaves the card showing the older
        usage (`test_terminal_burst_closes_the_card_once_with_summary` is what
        catches that). Eviction inside it is by IMPORTANCE rather than by age —
        a `task_progress` row, which the next one supersedes, goes first, and a
        binding or a closure only when there is nothing else, counted apart and
        warned in words nobody can misread.

        Cross-queue order is not preserved, and does not need to be: the two
        queues write different items (subagent rows parented to a call vs the
        call's own card), and neither one's ordering is meaningful against the
        other's.
        """

        if callback is None:
            return
        worker = self.deferred_event_worker
        if worker is None or worker.done():
            worker = asyncio.create_task(self._drain_deferred_events())
            self.deferred_event_worker = worker
        state_queue = self.deferred_task_events
        queue = state_queue if state_bearing else self.deferred_background_events
        limit = (
            DEFERRED_TASK_QUEUE_MAXSIZE
            if state_bearing
            else DEFERRED_EVENT_QUEUE_MAXSIZE
        )
        droppable = not state_bearing or getattr(event, "kind", None) == "progress"
        while len(queue) >= limit:
            victim = next((i for i, item in enumerate(queue) if item[2]), 0)
            evicted = queue[victim]
            del queue[victim]
            if evicted[2] and queue is state_queue:
                # A repeatable row gave way before a state event: a normal shed.
                self.deferred_dropped_events += 1
                logger.warning(
                    "Claude deferred projection event dropped on overflow "
                    "dropped_total={} queue_max={}",
                    self.deferred_dropped_events,
                    limit,
                )
            elif queue is state_queue:
                self.deferred_dropped_state_events += 1
                logger.warning(
                    "Claude deferred TASK event dropped on overflow "
                    "dropped_total={} queue_max={}",
                    self.deferred_dropped_state_events,
                    limit,
                )
            else:
                self.deferred_dropped_events += 1
                logger.warning(
                    "Claude deferred projection event dropped on overflow "
                    "dropped_total={} queue_max={}",
                    self.deferred_dropped_events,
                    limit,
                )
        queue.append((callback, event, droppable))
        self._deferred_wakeup.set()

    def _pop_ready_deferred(self) -> tuple[Awaitable[Any], Any, bool] | None:
        """Next event, state-bearing first. No awaiting."""

        for queue in (self.deferred_task_events, self.deferred_background_events):
            if queue:
                return queue.popleft()
        return None

    def _has_ready_deferred(self) -> bool:
        """Whether anything is queued. Peeks — never consumes."""

        return bool(self.deferred_task_events or self.deferred_background_events)

    async def _next_deferred_event(self) -> tuple[Awaitable[Any], Any]:
        """Take the next event, or wait for one to arrive.

        The clear-then-recheck before waiting is what makes this safe: a
        producer landing between the clear and the re-check is seen by the
        re-check, and one landing after it re-sets the event, so a wake-up is
        never lost between the two. The re-check PEEKS — it has to, because a
        re-check that consumed would silently eat one event per wake-up, which
        is the very loss this queue's state half was rebuilt to stop.
        """

        while True:
            item = self._pop_ready_deferred()
            if item is not None:
                return item[0], item[1]
            self._deferred_wakeup.clear()
            if self._has_ready_deferred():
                continue
            await self._deferred_wakeup.wait()

    async def _drain_deferred_events(self) -> None:
        """Project queued events, one at a time, in arrival order.

        Nothing in here may mint or select a turn: these are display-only
        projections, and the worker's whole reason to exist is that they are not
        worth a round trip on the reader's hot path. A failing callback is
        logged and skipped — the L1 lesson again: nothing on this path may take
        a transport down, and a poisoned worker would silently stop projecting
        every later event too.
        """

        while True:
            callback, event = await self._next_deferred_event()
            try:
                await callback(event)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude deferred projection event failed",
                )

    async def _stop_deferred_events(self) -> None:
        """Retire the drain worker without letting the host hold the transport up.

        Cancelling first, then emptying the queues by hand: a worker cancelled
        mid-host-call leaves whatever it was holding in flight, and calling back
        into a host that is itself retiring is exactly the hang this queue was
        introduced to avoid. What is left is counted, not replayed.
        """

        worker = self.deferred_event_worker
        self.deferred_event_worker = None
        if worker is not None and worker is not asyncio.current_task():
            worker.cancel()
            await asyncio.wait(
                (worker,), timeout=DEFERRED_EVENT_WORKER_TIMEOUT_SECONDS
            )
        remaining = len(self.deferred_task_events) + len(
            self.deferred_background_events
        )
        self.deferred_task_events.clear()
        self.deferred_background_events.clear()
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
                            # `task_started` writes the task-to-card binding and
                            # the terminal event closes the card; neither may be
                            # evicted by a decorative burst (F2). A progress row
                            # is repeatable and may be dropped.
                            self.defer_event(
                                self.on_task_event,
                                agent_event,
                                state_bearing=True,
                            )
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
                    # Park until the consumer rules on this terminal (F1
                    # release protocol, §8.1.2). Until the protocol this was
                    # an unconditional `await released.wait()`, which is why a
                    # leftover result could only ever end a response: the
                    # reader held `current`, so the frames behind it had
                    # nowhere to go once the turn settled on it.
                    #
                    # `released` → the turn is done: hand the transport back,
                    # exactly as before. `terminal_declined` → the turn says
                    # this terminal is not its verdict and is still reading;
                    # `current` stays put so the frames behind the leftover
                    # reach the same response, and the reader carries on. That
                    # path can end with the turn settling without another
                    # terminal (grace window, stream end, interrupt), so
                    # `release()` takes `current` back — see `ClaudeResponse
                    # .release`. Either way the reader is released again by
                    # the next frame or by the transport closing, so the loop
                    # cannot stall here.
                    if await response.await_terminal_verdict():
                        self.current = None
                        self.selected.clear()
                        self.arm_idle()
                        if (
                            not self.streaming
                            and not self.retained
                            and self.pending is None
                        ) or self.closing:
                            break
                    else:
                        response.reader_declined = True
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
