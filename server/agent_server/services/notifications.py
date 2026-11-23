"""Dashboard notification decisions.

The decision lives on the server so the same record can later drive a remote
push: the client only displays what this module derives. Records are derived
from the session projection rather than stored — the stable id
(``type:session:turn``) is the dedupe key, and a new turn changes it. This
keeps the v1 rollout migration-free; persistence arrives with APNs.

Rules (kept in one place, mirrored by the client only as display logic):

* ``waiting_approval`` — always notify.
* ``waiting`` with a blocking ``noticeId`` — the runtime is parked on a
  user-input question; always notify. A bare ``waiting`` (turn start) is not
  a request.
* ``error`` / ``blocked`` — always notify.
* ``idle`` — notify when ``backgroundTasks == 0``, or when the finished turn
  published assistant text (``assistantText``). A text reply is final for the
  user even while unrelated background work still runs; a turn that ended
  without text waits for its wake turn, which is what the old
  ``backgroundTasks == 0`` gate was protecting against.
* Unread is ``latestTurnEndSeq > lastReadSeq`` — the same fact the session
  list paints as a dot.

Approval and question records are identified by the blocking notice id rather
than the turn-end sequence: one turn can ask more than once, and ``turn:seq``
gave those requests the same id, so the client's dedupe dropped every prompt
after the first.
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
    "question": "需要你的回答",
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
    if session.status == "waiting" and session.noticeId:
        return "question"
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
        if kind == "completed" and session.assistantText is not False:
            # A turn that ended without text keeps the summary only: the
            # latest assistant text in the timeline belongs to an earlier
            # reply, and showing it would misrepresent this completion.
            preview = preview_text(await latest_assistant_text(session.id))
        identity = (
            session.noticeId
            if kind in ("approval", "question") and session.noticeId
            else str(session.latestTurnEndSeq)
        )
        notifications.append(
            {
                "id": f"{kind}:{session.id}:{identity}",
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
