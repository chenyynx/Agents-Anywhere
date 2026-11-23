from __future__ import annotations

from datetime import datetime, timedelta, timezone

import asyncio
import time

from agent_server.api import dashboard_stream
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
    """A turn that ends without text while an agent runs is not the final reply."""

    assert notification_kind(_session(backgroundTasks=1)) is None


def test_text_reply_notifies_even_while_background_work_runs() -> None:
    """A long background command must not swallow a reply the user can read."""

    assert (
        notification_kind(_session(backgroundTasks=1, assistantText=True))
        == "completed"
    )


def test_no_text_turn_still_waits_for_its_wake_turn() -> None:
    assert (
        notification_kind(_session(backgroundTasks=1, assistantText=False))
        is None
    )


def test_approval_ignores_background_work() -> None:
    assert (
        notification_kind(_session(status="waiting_approval", backgroundTasks=2))
        == "approval"
    )


def test_blocking_question_notifies_but_turn_start_waiting_does_not() -> None:
    assert (
        notification_kind(_session(status="waiting", noticeId="notice_1"))
        == "question"
    )
    # `waiting` is also the transient turn-start state; only a blocking notice
    # makes it a request.
    assert notification_kind(_session(status="waiting")) is None


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


def test_two_approvals_in_one_turn_get_distinct_ids() -> None:
    async def assistant_text(_session_id: str) -> str:
        raise AssertionError("approvals do not read a preview")

    first = asyncio.run(
        derive_dashboard_notifications(
            [_session(status="waiting_approval", noticeId="notice_1")],
            assistant_text,
        )
    )
    second = asyncio.run(
        derive_dashboard_notifications(
            [_session(status="waiting_approval", noticeId="notice_2")],
            assistant_text,
        )
    )
    repeated = asyncio.run(
        derive_dashboard_notifications(
            [_session(status="waiting_approval", noticeId="notice_1")],
            assistant_text,
        )
    )
    assert first[0]["id"] == "approval:sess_1:notice_1"
    assert second[0]["id"] == "approval:sess_1:notice_2"
    assert first[0]["id"] != second[0]["id"]
    assert repeated[0]["id"] == first[0]["id"]


def test_no_text_completion_keeps_the_summary_only() -> None:
    async def assistant_text(_session_id: str) -> str:
        raise AssertionError("a no-text turn must not read an older reply")

    records = asyncio.run(
        derive_dashboard_notifications(
            [_session(assistantText=False)],
            assistant_text,
        )
    )
    assert len(records) == 1
    assert records[0]["preview"] == ""
    assert records[0]["summary"] == "回复已完成"


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


# --- Long-poll endpoint: wait on unseen records, not on any dashboard event ---


def _payload(*ids: str) -> dict:
    return {
        "notifications": [{"id": item, "sessionId": "sess_1"} for item in ids],
        "sessions": [],
        "serverTime": "",
    }


class _FakeBroker:
    def __init__(self) -> None:
        self.queue: asyncio.Queue = asyncio.Queue(maxsize=8)
        self.registered: list[str] = []
        self.unregistered: list[str] = []

    async def register_dashboard(self, user_id: str):
        self.registered.append(user_id)
        return self.queue

    async def unregister_dashboard(self, user_id: str, queue) -> None:
        self.unregistered.append(user_id)


def test_has_unseen_compares_ids() -> None:
    assert not dashboard_stream._has_unseen([{"id": "a"}], {"a"})
    assert dashboard_stream._has_unseen([{"id": "a"}, {"id": "b"}], {"a"})
    assert dashboard_stream._has_unseen([{"id": "a"}], set())


def test_long_poll_wakes_and_returns_the_unseen_record(monkeypatch) -> None:
    """A dashboard event must not answer with the same known set: the client
    would re-request immediately and loop once a second while an unread
    record stayed in the recent window. Only an unseen id may answer."""

    calls = {"n": 0}

    async def fake_payload(**_kwargs):
        calls["n"] += 1
        return _payload("a") if calls["n"] == 1 else _payload("a", "b")

    monkeypatch.setattr(dashboard_stream, "_notification_payload", fake_payload)
    broker = _FakeBroker()

    async def run():
        broker.queue.put_nowait("dashboard.changed")
        return await dashboard_stream.dashboard_notifications(
            user_id="u",
            db=None,
            manager=None,
            runtime_state_cache=None,
            broker=broker,
            wait=25,
            known="a",
        )

    started = time.monotonic()
    payload = asyncio.run(run())
    assert [item["id"] for item in payload["notifications"]] == ["a", "b"]
    assert time.monotonic() - started < 1
    assert calls["n"] == 2
    assert broker.registered == ["u"]
    assert broker.unregistered == ["u"]


def test_long_poll_holds_while_every_record_is_known(monkeypatch) -> None:
    async def fake_payload(**_kwargs):
        return _payload("a")

    monkeypatch.setattr(dashboard_stream, "_notification_payload", fake_payload)
    broker = _FakeBroker()
    started = time.monotonic()
    payload = asyncio.run(
        dashboard_stream.dashboard_notifications(
            user_id="u",
            db=None,
            manager=None,
            runtime_state_cache=None,
            broker=broker,
            wait=1,
            known="a",
        )
    )
    assert [item["id"] for item in payload["notifications"]] == ["a"]
    assert time.monotonic() - started >= 0.9
    assert broker.unregistered == ["u"]


def test_long_poll_without_known_returns_immediately(monkeypatch) -> None:
    async def fake_payload(**_kwargs):
        return _payload("a")

    monkeypatch.setattr(dashboard_stream, "_notification_payload", fake_payload)
    broker = _FakeBroker()
    started = time.monotonic()
    payload = asyncio.run(
        dashboard_stream.dashboard_notifications(
            user_id="u",
            db=None,
            manager=None,
            runtime_state_cache=None,
            broker=broker,
            wait=25,
            known="",
        )
    )
    assert [item["id"] for item in payload["notifications"]] == ["a"]
    assert time.monotonic() - started < 1
    assert broker.unregistered == ["u"]
