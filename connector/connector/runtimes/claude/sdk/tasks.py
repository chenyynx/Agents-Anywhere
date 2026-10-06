from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Literal

from connector.logging import logger

ClaudeTaskEventKind = Literal["started", "progress", "updated", "notification"]

# The CLI persists a background task's completion as a plain user message
# whose whole body is this wrapper (real transcript aba0a291, 2026-10-05).
# The live wire's `task_notification` frame never reaches the transcript, so
# the file-sync import path reads the notice back from the text.
TASK_NOTIFICATION_OPEN_TAG = "<task-notification>"
TASK_NOTIFICATION_CLOSE_TAG = "</task-notification>"

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


def is_task_notification_text(text: str | None) -> bool:
    """Whether a transcript message body is one persisted background notice.

    Same judgement ``is_synthetic_control_message`` has applied since the
    ghost-turn incident (the message must never mint a user bubble); naming it
    here lets the terminal fold and the bubble suppression share one answer
    instead of drifting apart.
    """

    if text is None:
        return False
    normalized = text.strip()
    return normalized.startswith(TASK_NOTIFICATION_OPEN_TAG) and normalized.endswith(
        TASK_NOTIFICATION_CLOSE_TAG
    )


def task_events_from_notification_text(
    text: str | None,
    *,
    timestamp_ms: int | None = None,
) -> tuple[ClaudeTaskEvent, ...]:
    """Normalize every task named by one persisted notification wrapper.

    A normal completion names one task and a ``tool-use-id``; a session-teardown
    wrapper can name several ``task-id`` values and omit the tool id entirely.
    The history projector resolves each task id back to its original Agent card.
    Live frame parsing remains on ``task_event_from_message`` and is unchanged.
    """

    if not is_task_notification_text(text):
        return ()
    task_ids = tuple(
        dict.fromkeys(
            match.group(1).strip()
            for match in re.finditer(r"<task-id>(.*?)</task-id>", text or "", re.DOTALL)
            if match.group(1).strip()
        )
    )
    status = _notification_tag(text, "status")
    if not task_ids or status is None:
        logger.warning(
            "Claude task notification skipped missing required tags "
            "task_ids={} status={} preview={!r}",
            task_ids,
            status,
            (text or "")[:120],
        )
        return ()
    tool_use_id = _notification_tag(text, "tool-use-id")
    summary = _notification_tag(text, "result") or _notification_tag(text, "summary")
    usage = _notification_usage(text)
    return tuple(
        ClaudeTaskEvent(
            kind="notification",
            task_id=task_id,
            tool_use_id=tool_use_id,
            status=status,
            summary=summary,
            end_time=timestamp_ms,
            usage=usage,
        )
        for task_id in task_ids
    )


def task_event_from_notification_text(
    text: str | None,
    *,
    timestamp_ms: int | None = None,
) -> ClaudeTaskEvent | None:
    """Compatibility helper for one directly-addressed task notification.

    New import-path code should use ``task_events_from_notification_text`` so
    task-id-only and batched teardown notices are not silently discarded.
    This older singular helper intentionally keeps its stricter contract.
    """

    events = task_events_from_notification_text(text, timestamp_ms=timestamp_ms)
    if len(events) != 1 or events[0].tool_use_id is None:
        return None
    return events[0]


def _notification_tag(text: str, name: str) -> str | None:
    match = re.search(rf"<{name}>(.*?)</{name}>", text, re.DOTALL)
    if match is None:
        return None
    value = match.group(1).strip()
    return value or None


def _notification_usage(text: str) -> Mapping[str, int] | None:
    # The result is user-authored subagent output and may quote a literal
    # `<usage>` example. Only parse the outer notification usage that follows
    # the result body; otherwise a test/report fixture can overwrite real
    # counters (redteam evidence O, 2026-10-06).
    result_open = re.search(r"<result>", text)
    if result_open is None:
        usage_region = text
    else:
        result_closes = tuple(
            re.finditer(r"</result>", text[result_open.end() :])
        )
        if not result_closes:
            return None
        last_close = result_open.end() + result_closes[-1].end()
        usage_region = text[last_close:]
    block = _notification_tag(usage_region, "usage")
    if block is None:
        return None
    fields = {
        "total_tokens": _notification_tag_int(block, "subagent_tokens"),
        "tool_uses": _notification_tag_int(block, "tool_uses"),
        "duration_ms": _notification_tag_int(block, "duration_ms"),
    }
    usage = {key: value for key, value in fields.items() if value is not None}
    return usage or None


def _notification_tag_int(text: str, name: str) -> int | None:
    value = _notification_tag(text, name)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


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
