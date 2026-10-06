from __future__ import annotations

import asyncio
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

TERMINAL_STATUSES = frozenset({"completed", "failed", "stopped", "killed"})


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
    #: Set while `active_ids` is empty. This is the event-driven "background
    #: drained" signal a selection change waits on instead of refusing to
    #: rebuild the transport (2026-10-05): the terminal task frame is the
    #: signal, not a poll. It is synced on every observed lifecycle frame; a
    #: waiter checks `active_ids` itself first, so the pre-first-frame state
    #: is never mistaken for pending work.
    drained: asyncio.Event = field(default_factory=asyncio.Event)

    def observed(self, message: Any) -> bool:
        """Observe one frame and keep the drain signal in step with it."""

        handled = self._observe(message)
        self._sync_drained()
        return handled

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
            # an id is therefore not proof of a terminal: a stale id can pin
            # the connection until its terminal lands — accepted, and
            # observable through the retirement-skip warnings' task count.
            tasks = _value(message, "tasks")
            if tasks is None:
                data = _value(message, "data")
                tasks = _value(data, "tasks") if data is not None else None
            if isinstance(tasks, (list, tuple)):
                for task in tasks:
                    task_id = _value(task, "task_id")
                    if isinstance(task_id, str) and task_id:
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
            elif isinstance(status, str):
                self.active_ids.add(task_id)
        return True
