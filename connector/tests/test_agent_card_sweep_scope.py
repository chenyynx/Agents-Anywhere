"""The 60s sweep's work list and the history-path open-card index."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from connector.runtime_protocol import RuntimeTimelineItem, RuntimeTimelineSnapshot
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.notifications.timeline_activity import (
    ClaudeTimelineActivityHandler,
)
from connector.runtimes.claude.sessions.open_cards import ClaudeOpenAgentCards
from connector.runtimes.claude.turns.lifecycle import ClaudeTurnRunner


def _item(item_id: str, status: str, *, kind: str = "agent_call") -> RuntimeTimelineItem:
    return RuntimeTimelineItem(
        id=item_id,
        session_id="s1",
        type="tool",
        status=status,
        order_seq=1,
        content_hash="h",
        content={"kind": kind},
    )


def _session(session_id: str = "s1") -> ClaudeSession:
    return ClaudeSession(
        session_id=session_id,
        external_session_id="ext-1",
        cwd="/tmp/project",
    )


class _FakeHost:
    def __init__(self, value: dict[str, Any] | None = None) -> None:
        self.value = value or {}
        self.writes: list[dict[str, Any]] = []
        self.timeline_calls = 0

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.value

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.value = value
        self.writes.append(value)

    async def timeline_sync(self, **kwargs: Any) -> None:
        self.timeline_calls += 1


def test_record_many_writes_agent_cards_once_and_retires_terminals() -> None:
    async def run() -> _FakeHost:
        host = _FakeHost()
        cards = ClaudeOpenAgentCards(host)  # type: ignore[arg-type]
        session = _session()
        await cards.record_many(session, [_item("a", "running"), _item("b", "running")])
        await cards.record_many(session, [_item("a", "done")])
        return host

    host = asyncio.run(run())
    assert len(host.writes) == 2
    assert host.value["sessions"]["s1"]["itemIds"] == ["b"]


def test_timeline_sync_records_history_rebuilt_cards() -> None:
    class _Store:
        def get(self, session_id: str, external_session_id: str | None = None) -> ClaudeSession:
            return _session(session_id)

    class _Activity(ClaudeTimelineActivityHandler):
        pass

    async def run() -> list[list[str]]:
        recorded: list[list[str]] = []

        class _OpenCards:
            async def record_many(
                self,
                session: ClaudeSession,
                items: tuple[RuntimeTimelineItem, ...],
            ) -> None:
                recorded.append([item.id for item in items])

        handler = _Activity(
            host=_FakeHost(),  # type: ignore[arg-type]
            session_store=_Store(),  # type: ignore[arg-type]
            open_cards=_OpenCards(),  # type: ignore[arg-type]
        )
        snapshot = RuntimeTimelineSnapshot(
            session_id="s1",
            external_session_id="ext-1",
            runtime="claude",
            items=(_item("a", "running"), _item("b", "running")),
        )
        await handler.timeline_sync(snapshot, source="claude.history.sync")
        return recorded

    assert asyncio.run(run()) == [["a", "b"]]


def test_sweep_candidates_include_open_cards_plus_a_rotation_slice() -> None:
    sessions = [_session(f"s{i}") for i in range(10)]
    open_cards = SimpleNamespace(read=lambda: _read_open())

    async def _read_open() -> dict[str, dict[str, Any]]:
        return {
            "s-open": {
                "externalSessionId": "ext-open",
                "cwd": "/tmp/open",
                "itemIds": ["card"],
            }
        }

    class _Store:
        def sessions(self) -> list[ClaudeSession]:
            return sessions

        def ensure(self, **kwargs: Any) -> ClaudeSession:
            return ClaudeSession(
                session_id=kwargs["session_id"],
                external_session_id=kwargs["external_session_id"],
                cwd=kwargs["cwd"],
            )

    runner = SimpleNamespace(
        open_cards=open_cards,
        session_store=_Store(),
        _sweep_rotation_cursor=0,
    )

    first = asyncio.run(ClaudeTurnRunner._agent_card_sweep_candidates(runner, sessions))  # type: ignore[arg-type]
    second = asyncio.run(ClaudeTurnRunner._agent_card_sweep_candidates(runner, sessions))  # type: ignore[arg-type]

    assert [session.session_id for session in first[:1]] == ["s-open"]
    assert len(first) == 9  # open card + 8 rotation slots
    assert [session.session_id for session in second[1:]] == [
        "s8",
        "s9",
        "s0",
        "s1",
        "s2",
        "s3",
        "s4",
        "s5",
    ]


def test_sweep_candidates_without_an_index_keep_all_sessions() -> None:
    sessions = [_session(f"s{i}") for i in range(3)]
    runner = SimpleNamespace(
        open_cards=None,
        session_store=SimpleNamespace(sessions=lambda: sessions),
        _sweep_rotation_cursor=0,
    )
    candidates = asyncio.run(
        ClaudeTurnRunner._agent_card_sweep_candidates(runner, sessions)  # type: ignore[arg-type]
    )
    assert candidates == sessions
