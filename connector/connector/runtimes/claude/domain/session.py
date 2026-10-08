from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field

from connector.runtime_protocol import RuntimeTimelineItem
from connector.runtimes.claude.domain.context_report import ClaudeContextProbe
from connector.runtimes.session_identity import stable_runtime_session_id


@dataclass(slots=True)
class ClaudeExecution:
    turn_id: str
    started_at_monotonic: float = field(default_factory=time.monotonic)
    task: asyncio.Task[None] | None = None
    watchdog_task: asyncio.Task[None] | None = None
    client: object | None = None
    interrupt_source: str | None = None
    interrupt_reason: str | None = None
    finalization_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    finished: asyncio.Event = field(default_factory=asyncio.Event)
    # How much of this execution actually reached the user, counted by
    # `drive_turn` at its publish and consumption points. Both start at zero,
    # so a turn minted out of silence that never projects anything and only
    # ever sees chrome replay stays at (0, 0) — which is exactly the ghost
    # signature the scheduled-turn breaker exists to reap quickly. A turn that
    # published a timeline item, or consumed a non-chrome wire frame even when
    # every one of those frames was dropped before publication, has left the
    # fast kill and is bounded only by the absolute ceiling.
    #
    # What NEVER counts is everything the queue already held when the turn
    # was born: the reader's preamble flush and then the frame that cast the
    # turn itself (B5 finding, 2026-10-03: a re-cast's lone in-flight
    # `tool_result`/StreamEvent arrived and was booked as labour, parking
    # residue ghosts on the 600s ceiling — ten minutes of held execution lock
    # for a turn that would never settle; a stale compact marker riding in
    # front of it in the preamble could do the same). The exclusion is
    # positional, never by shape (`drive_turn` compares queue position
    # against `ClaudeResponse.cast_frame`), so no wire shape can be
    # enumerated into or out of the gate.
    #
    # Deliberately NOT the final answer text: production turn jmD_zip lost 1613
    # thinking deltas inside 30s and still published nothing, so an answer-text
    # anchor would keep killing exactly the turns this is meant to save.
    # Deliberately not `published_items` alone either: the dropped-frame turns
    # have `published_items == 0` with `consumed_frames > 0`.
    #
    # Counting is unconditional (human turns included) because a counter that
    # only moved on one branch would be a behaviour difference in itself; it
    # lives on the per-turn dataclass, so nothing leaks across turns.
    published_items: int = 0
    consumed_frames: int = 0

    @property
    def has_turn_content(self) -> bool:
        """Whether this execution left the zero-content ghost class.

        The content gate of the scheduled-turn watchdog: labour the turn did
        after its own cast, counted only from frames other than the casting
        frame. Read at the fast-kill deadline only; the absolute ceiling is
        unaffected either way.
        """

        return self.published_items > 0 or self.consumed_frames > 0


@dataclass(slots=True)
class ClaudeSession:
    session_id: str
    external_session_id: str | None = None
    title: str | None = None
    cwd: str | None = None
    ordering_time: str | None = None
    selections: dict[str, str | None] = field(default_factory=dict)
    timeline_items: dict[str, RuntimeTimelineItem] = field(default_factory=dict)
    timeline_revision: int = 0
    synced_revision: int = 0
    execution: ClaudeExecution | None = None
    queued_execution: ClaudeExecution | None = None
    execution_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # The engine's own `/context` self-report (window calibration, 2026-10-08):
    # what the running CLI declared this session's context window to be, keyed
    # to the model selection it was measured for. Lives on the session — not
    # the transport — because it describes the session's model, and every
    # usage-stamped item reads it to carry `contextWindow`/`model` without a
    # model-name guess. None until a probe lands.
    context_probe: ClaudeContextProbe | None = None

    @property
    def active_turn_id(self) -> str | None:
        execution = self.execution
        return execution.turn_id if execution is not None else None

    @property
    def active_turn_started_at_monotonic(self) -> float | None:
        execution = self.execution
        return execution.started_at_monotonic if execution is not None else None

    @property
    def active_task(self) -> asyncio.Task[None] | None:
        execution = self.execution
        return execution.task if execution is not None else None


def stable_session_id(connector_id: str, external_session_id: str) -> str:
    return stable_runtime_session_id(connector_id, "claude", external_session_id)
