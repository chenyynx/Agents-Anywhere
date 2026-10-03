from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Literal

ClaudeTaskEventKind = Literal["started", "progress", "updated", "notification"]

_TASK_EVENT_KINDS: Mapping[str, ClaudeTaskEventKind] = {
    "task_started": "started",
    "task_progress": "progress",
    "task_updated": "updated",
    "task_notification": "notification",
}


@dataclass(frozen=True, slots=True)
class ClaudeTaskEvent:
    """One normalized CLI task-lifecycle frame for the L2 progress display.

    The SDK parses the four task frames into typed dataclasses, but keeps the
    untouched wire payload in ``.data``; ``subagent_type``, ``prompt``,
    ``is_backgrounded`` and ``spawn_depth`` exist nowhere else (L2 A1
    findings, ``.local-dev/recon/l2-a1-findings.md`` §8.3), so the normalizer
    reads every field as typed-attribute-first with a ``.data`` fallback.

    ``task_updated`` is the one frame with no ``tool_use_id`` at all — its
    card is found through the task_started binding instead (findings §2).
    """

    kind: ClaudeTaskEventKind
    task_id: str
    task_type: str | None = None
    session_id: str | None = None
    tool_use_id: str | None = None
    description: str | None = None
    subagent_type: str | None = None
    prompt: str | None = None
    is_backgrounded: bool | None = None
    spawn_depth: int | None = None
    status: str | None = None
    summary: str | None = None
    end_time: int | None = None
    usage: Mapping[str, Any] | None = None
    last_tool_name: str | None = None


def task_event_from_message(message: Any) -> ClaudeTaskEvent | None:
    """Normalize one of the four task frames; ``None`` for anything else.

    Deliberately narrower than ``ClaudeBackgroundTasks.observe``: that one
    also tracks ``background_tasks_changed`` snapshots for the keep-alive
    signal, which carry no task to fold into a card.
    """

    kind = _TASK_EVENT_KINDS.get(_value(message, "subtype"))
    if kind is None:
        return None
    task_id = _field(message, "task_id")
    if not isinstance(task_id, str) or not task_id:
        return None
    patch = _value(message, "patch")
    return ClaudeTaskEvent(
        kind=kind,
        task_id=task_id,
        task_type=_string(_field(message, "task_type")),
        session_id=_string(_field(message, "session_id")),
        tool_use_id=_string(_field(message, "tool_use_id")),
        description=_string(_field(message, "description")),
        subagent_type=_string(_field(message, "subagent_type")),
        prompt=_string(_field(message, "prompt")),
        is_backgrounded=_bool(_field(message, "is_backgrounded")),
        spawn_depth=_int(_field(message, "spawn_depth")),
        status=_string(_field(message, "status"))
        or _string(_value(patch, "status")),
        summary=_string(_field(message, "summary")),
        end_time=_int(_value(patch, "end_time")),
        usage=_mapping(_field(message, "usage")),
        last_tool_name=_string(_field(message, "last_tool_name")),
    )


def _value(message: Any, name: str) -> Any:
    if isinstance(message, Mapping):
        return message.get(name)
    return getattr(message, name, None)


def _field(message: Any, name: str) -> Any:
    """Typed attribute first, then the raw wire payload the SDK keeps in `.data`."""

    value = _value(message, name)
    if value is not None:
        return value
    data = _value(message, "data")
    return _value(data, name) if data is not None else None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    return value if isinstance(value, int) else None
