from __future__ import annotations

from datetime import datetime, timedelta, timezone

import asyncio


from agent_server.core.models import SessionView
from agent_server.services.notifications import (
    derive_dashboard_notifications,
    notification_kind,
    preview_text,
)


def _recent() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session(**overrides) -> SessionView:
    values = {
        "id": "sess_1",
        "connectorId": "conn_1",
        "projectId": None,
        "connectorStatus": "online",
        "runtime": "claude",
        "status": "idle",
        "takeover": False,
        "backgroundTasks": 0,
        "unread": True,
        "lastReadSeq": 4,
        "latestTurnEndSeq": 9,
        "lastActivityAt": _recent(),
        "updatedSeq": 9,
    }
    values.update(overrides)
    return SessionView(**values)


def test_idle_without_background_work_is_a_completion() -> None:
    assert notification_kind(_session()) == "completed"


def test_background_work_holds_the_completion() -> None:
    """A turn that ends while an agent runs is not the final reply."""

    assert notification_kind(_session(backgroundTasks=1)) is None


def test_approval_ignores_background_work() -> None:
    assert (
        notification_kind(_session(status="waiting_approval", backgroundTasks=2))
        == "approval"
    )


def test_error_is_reported() -> None:
    assert notification_kind(_session(status="error")) == "error"


def test_archived_and_read_and_old_sessions_stay_quiet() -> None:
    assert notification_kind(_session(archived=True)) is None
    assert notification_kind(_session(lastReadSeq=9)) is None
    old = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    assert notification_kind(_session(lastActivityAt=old)) is None


def test_error_also_respects_the_recency_window() -> None:
    old = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
    assert notification_kind(_session(status="error", lastActivityAt=old)) is None


def test_preview_strips_markdown_and_truncates() -> None:
    raw = "## 标题\n\n**粗体** 和 `code`\n```swift\nlet x = 1\n```\n" + "长" * 400
    text = preview_text(raw)
    assert "```" not in text
    assert "**" not in text
    assert len(text) <= 160


def test_derive_completed_record_uses_turn_scoped_id_and_preview() -> None:
    async def assistant_text(session_id: str) -> str:
        assert session_id == "sess_1"
        return "已经修好了，原因是页脚状态机。"

    records = asyncio.run(
        derive_dashboard_notifications([_session()], assistant_text)
    )
    assert len(records) == 1
    record = records[0]
    assert record["id"] == "completed:sess_1:9"
    assert record["type"] == "completed"
    assert record["preview"] == "已经修好了，原因是页脚状态机。"
    assert record["deepLink"] == "agents-anywhere://session/sess_1"


def test_derive_skips_sessions_whose_work_is_still_running() -> None:
    async def assistant_text(_session_id: str) -> str:
        raise AssertionError("preview must not be read while background work runs")

    assert (
        asyncio.run(
            derive_dashboard_notifications(
                [_session(backgroundTasks=1)], assistant_text
            )
        )
        == []
    )
