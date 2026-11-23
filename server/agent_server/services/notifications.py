"""Dashboard notification decisions.

The decision lives on the server so the same record can later drive a remote
push: the client only displays what this module derives. Records are derived
from the session projection rather than stored — the stable id
(``type:session:turn``) is the dedupe key, and a new turn changes it. This
keeps the v1 rollout migration-free; persistence arrives with APNs.

Rules (kept in one place, mirrored by the client only as display logic):

* ``waiting_approval`` — always notify.
* ``error`` / ``blocked`` — always notify.
* ``idle`` — notify when ``backgroundTasks == 0``, or when the finished turn
  published assistant text (``assistantText``). A text reply is final for the
  user even while unrelated background work still runs; a turn that ended
  without text waits for its wake turn, which is what the old
  ``backgroundTasks == 0`` gate was protecting against.
* Unread is ``latestTurnEndSeq > lastReadSeq`` — the same fact the session
  list paints as a dot.
"""

from __future__ import annotations

import re
from collections.abc import Awaitable, Callable, Sequence
from datetime import datetime, timedelta, timezone
from typing import Any

from agent_server.core.models import SessionView

PREVIEW_LIMIT = 160
# Old unread sessions must not rain notifications onto a fresh install; a
# terminal state older than this is left to the session list's unread dot.
RECENT_WINDOW = timedelta(minutes=10)

_SUMMARIES = {
    "completed": "回复已完成",
    "approval": "需要你的审批",
    "error": "任务出错了",
}

_CODE_FENCE = re.compile(r"```.*?```", re.S)
_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_MARKDOWN = re.compile(r"[`*_>#]+")


def preview_text(raw: str) -> str:
    """First readable line of an assistant reply, safe for a lock screen."""

    text = _CODE_FENCE.sub(" ", raw)
    text = _LINK.sub(r"\1", text)
    text = _MARKDOWN.sub("", text)
    text = " ".join(text.split())
    return text[:PREVIEW_LIMIT]


def _is_recent(value: str | None) -> bool:
    if not value:
        return True
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return True
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - stamp <= RECENT_WINDOW


def notification_kind(session: SessionView) -> str | None:
    """The notification this session currently deserves, if any."""

    if session.archived:
        return None
    background_tasks = max(0, int(session.backgroundTasks or 0))
    if session.status == "waiting_approval":
        return "approval"
    if session.status in ("error", "blocked"):
        return "error" if _is_recent(session.lastActivityAt or session.lastItemAt) else None
    if (
        session.status == "idle"
        and (background_tasks == 0 or session.assistantText is True)
        and session.latestTurnEndSeq > session.lastReadSeq
        and _is_recent(session.lastActivityAt or session.lastItemAt)
    ):
        return "completed"
    return None


async def derive_dashboard_notifications(
    sessions: Sequence[SessionView],
    latest_assistant_text: Callable[[str], Awaitable[str]],
) -> list[dict[str, Any]]:
    """Build the dashboard's notification list for the current projection.

    ``latest_assistant_text`` is injected rather than reached for so this
    service stays free of Store imports (the server's layering rule).
    """

    notifications: list[dict[str, Any]] = []
    for session in sessions:
        kind = notification_kind(session)
        if kind is None:
            continue
        preview = ""
        if kind == "completed":
            preview = preview_text(await latest_assistant_text(session.id))
        notifications.append(
            {
                "id": f"{kind}:{session.id}:{session.latestTurnEndSeq}",
                "sessionId": session.id,
                "type": kind,
                "title": session.title or "Agents Anywhere",
                "preview": preview,
                "summary": _SUMMARIES[kind],
                "deepLink": f"agents-anywhere://session/{session.id}",
                "createdAt": session.lastActivityAt or session.lastItemAt or "",
            }
        )
    return notifications
