from __future__ import annotations

import asyncio
import time
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

TERMINAL_STATUSES = frozenset({"completed", "failed", "stopped", "killed"})

#: How long a terminal task frame keeps maintenance off its transport.
#:
#: A terminal frame is the CLI's promise of a wake reply (the main agent is
#: woken to report the finished task). The reply starts at an unknown latency
#: after the frame — one production gap measured six seconds — and until its
#: first frame arrives no "is anything live?" gate can see it. Maintenance
#: taken in that gap holds the reader and swallows the reply's opening
#: frames, which is how one turn got two ids on 2026-11-24 (sess_ddUX1KTcAEiFrw:
#: the probe ate the first message, the live mint anchored on the second, the
#: step run split in two). The bound only delays optimisation work
#: (calibration, task reconciliation); a wake that never comes costs at most
#: this much, never a user turn.
WAKE_OWED_TIMEOUT_SECONDS = 120.0


def _value(message: Any, name: str) -> Any:
    return (
        message.get(name)
        if isinstance(message, Mapping)
        else getattr(message, name, None)
    )


def is_background_activity(message: Any) -> bool:
    """Report frames produced *inside* a background subagent.

    When a background agent runs, its internal turn frames leak into the
    parent session stream as ordinary user/assistant messages whose
    ``parent_tool_use_id`` is the dispatch tool call (real wire, 2026-10-02:
    a subagent thinking frame landed 47 ms after the dispatch reply; tool
    results followed seconds later). Those frames must never mint a scheduled
    reply from silence — no prompt was accepted for them, and the main agent's
    own wake-and-report frames all carry ``parent_tool_use_id=None``, so the
    parented ones are safe to absorb instead.
    """

    parent = _value(message, "parent_tool_use_id")
    return isinstance(parent, str) and bool(parent)


@dataclass(slots=True)
class ClaudeBackgroundTasks:
    """Track native work that may outlive the reply which started it."""

    active_ids: set[str] = field(default_factory=set)
    #: The task id set of the newest ``background_tasks_changed`` frame the
    #: CLI sent (F1, zombie-agent-card): the engine's *own* list of
    #: outstanding work, which is strictly stronger liveness evidence than
    #: ``active_ids`` — the register only ever loses an id to a live terminal
    #: frame, while a snapshot dropping an id means the CLI itself stopped
    #: listing the task. ``None`` until a well-formed snapshot arrives (a
    #: restart, or a connection that never saw one) — the conservative shape
    #: where every consumer falls back to the full ``active_ids`` set. The
    #: snapshot never touches ``active_ids``: keep-alive registration is this
    #: register's own job and its add/discard semantics are unchanged.
    last_snapshot_ids: frozenset[str] | None = None
    #: Set while `active_ids` is empty. This is the event-driven "background
    #: drained" signal a selection change waits on instead of refusing to
    #: rebuild the transport (2026-10-05): the terminal task frame is the
    #: signal, not a poll. It is synced on every observed lifecycle frame; a
    #: waiter checks `active_ids` itself first, so the pre-first-frame state
    #: is never mistaken for pending work.
    drained: asyncio.Event = field(default_factory=asyncio.Event)
    #: When a terminal task frame promised a wake reply that has not landed
    #: yet (monotonic; ``None`` = no reply owed). ``active_ids`` is already
    #: empty here — the work IS done — so the ordinary gate sees an idle
    #: transport while the CLI is about to send a frame nobody invited.
    wake_owed_at: float | None = None

    def observed(self, message: Any) -> bool:
        """Observe one frame and keep the drain signal in step with it."""

        handled = self._observe(message)
        self._sync_drained()
        return handled

    def release(self, task_id: str) -> None:
        """Drop one settled task from the keep-alive register (F1).

        The register's own exits (live terminal frames) are untouched: this
        is the evidence sweep's post-publication release for a card closed
        from engine evidence, where the terminal frame that would have
        discarded the id never arrived (CLI resume/notification gap —
        zombie-agent-card §0). Called only after the closure actually
        published, so a task whose card stayed open keeps its keep-alive
        entry. Discard is idempotent and syncing ``drained`` here lets the
        connection recycle the moment the last pin is lifted.
        """

        self.active_ids.discard(task_id)
        self._sync_drained()

    def note_wake_owed(self, *, now: float | None = None) -> None:
        """Record that a wake reply is now owed (a terminal task frame)."""

        self.wake_owed_at = time.monotonic() if now is None else now

    def clear_wake_owed(self) -> None:
        """The reply landed: maintenance may borrow the transport again."""

        self.wake_owed_at = None

    def wake_owed(
        self,
        *,
        now: float | None = None,
        timeout: float = WAKE_OWED_TIMEOUT_SECONDS,
    ) -> bool:
        """Whether an uninvited reply may still be in flight.

        Expiry drops the flag rather than only reporting false: a wake the
        CLI never produced must not pin maintenance off until the process
        restarts.
        """

        if self.wake_owed_at is None:
            return False
        current = time.monotonic() if now is None else now
        if current - self.wake_owed_at > timeout:
            self.wake_owed_at = None
            return False
        return True

    def _sync_drained(self) -> None:
        if self.active_ids:
            self.drained.clear()
        else:
            self.drained.set()

    def _observe(self, message: Any) -> bool:
        """Return whether this was a task lifecycle event."""
        kind = _value(message, "subtype")
        if kind == "background_tasks_changed":
            # The CLI's snapshot of outstanding work. Adding its ids keeps the
            # keep-alive signal honest even if a `task_started` frame was
            # missed; releases stay solely with terminal events, because an
            # unconfirmed task is never assumed complete. A snapshot dropping
            # an id is therefore not proof of a terminal *for this register*:
            # a stale id can still pin the connection until its terminal
            # lands — accepted, and observable through the retirement-skip
            # warnings' task count. What the snapshot IS proof of is which
            # tasks the engine still lists (F1, zombie-agent-card): the
            # exemption consumer (`live_agent_task_ids`) vouches only for ids
            # present in both sets, so a dropped id loses its exemption and
            # falls back to ordinary evidence judgement while keep-alive
            # bookkeeping above remains byte-for-byte the old behaviour.
            tasks = _value(message, "tasks")
            if tasks is None:
                data = _value(message, "data")
                tasks = _value(data, "tasks") if data is not None else None
            if isinstance(tasks, (list, tuple)):
                snapshot_ids = {
                    task_id
                    for task_id in (_value(task, "task_id") for task in tasks)
                    if isinstance(task_id, str) and task_id
                }
                # The whole frame replaces the field (an empty list is a
                # valid, meaningful empty set — the CLI has no outstanding
                # work). A *malformed* frame — entries but no parseable id
                # at all — is not a snapshot we can read, so it leaves the
                # previous value standing rather than manufacturing an empty
                # set that would strip every exemption (zombie-agent-card F1,
                # conservative-by-the-red-line).
                if not tasks or snapshot_ids:
                    self.last_snapshot_ids = frozenset(snapshot_ids)
                for task_id in snapshot_ids:
                    self.active_ids.add(task_id)
            return True
        if kind not in {
            "task_started",
            "task_progress",
            "task_updated",
            "task_notification",
        }:
            return False
        task_id = _value(message, "task_id")
        if not isinstance(task_id, str) or not task_id:
            data = _value(message, "data")
            task_id = _value(data, "task_id")
        if not isinstance(task_id, str) or not task_id:
            return True
        if kind in {"task_started", "task_progress"}:
            self.active_ids.add(task_id)
        else:
            patch = _value(message, "patch")
            status = _value(patch, "status") or _value(message, "status")
            if not isinstance(status, str):
                status = _value(_value(message, "data"), "status")
            if status in TERMINAL_STATUSES:
                self.active_ids.discard(task_id)
                # The notice is the shape the CLI emits when a finished task
                # wakes the main agent, and the frame this window is built on.
                # `task_updated` is deliberately NOT armed: the connector's
                # deferred-reconciliation path drains the register with it and
                # no reply is owed in that shape (tests pin it). Known
                # residual: the SDK documents terminal statuses that surface
                # only as `task_updated` (e.g. a stop); those wakes are not
                # gated by this flag and rely on the maintenance response
                # stepping aside at the first API frame.
                if kind == "task_notification":
                    self.note_wake_owed()
            elif isinstance(status, str):
                self.active_ids.add(task_id)
        return True
