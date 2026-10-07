from __future__ import annotations

import asyncio
import collections
import json
from collections.abc import Awaitable, Callable
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import pytest
from loguru import logger
from session_fixtures import create_session_with_project

from agent_server.core.events import (
    EventCursorError,
    capability_event_semantic_fingerprint,
    event_cursor,
    events_from_invalidation,
    parse_event_cursor,
    protocol_event,
    revisions_are_complete,
    timeline_events_from_items,
)
from agent_server.core.models import SessionView, TimelineItemIn
from agent_server.infra.connector_rpc import ConnectorRpcManager
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store
from agent_server.services import event_recovery
from agent_server.services.event_recovery import (
    DEFAULT_RECOVERY_BYTE_LIMIT,
    DEFAULT_RECOVERY_LIMIT,
    EventRecoveryService,
)


def test_event_cursor_is_a_strict_durable_revision_token() -> None:
    assert event_cursor(12) == "seq:12"
    assert parse_event_cursor("seq:12") == 12

    for invalid in ("12", "seq:-1", "seq:+1", "seq:01", "seq:"):
        with pytest.raises(EventCursorError):
            parse_event_cursor(invalid)


def test_capability_event_fingerprint_ignores_set_revision_and_record_order() -> None:
    first = protocol_event(
        "session-1",
        sequence=7,
        event_type="runtime.capability.updated",
        payload={
            "capabilitySet": {
                "revision": 7,
                "capabilities": [
                    {
                        "capabilityId": "session.send_message",
                        "runtimeId": "runtime-1",
                        "available": True,
                    },
                    {
                        "capabilityId": "session.interrupt",
                        "available": False,
                    },
                ],
            }
        },
    )
    reordered = protocol_event(
        "session-1",
        sequence=8,
        event_type="runtime.capability.updated",
        payload={
            "capabilitySet": {
                "revision": 99,
                "capabilities": list(
                    reversed(first.payload["capabilitySet"]["capabilities"])
                ),
            }
        },
    )
    changed_runtime = protocol_event(
        "session-1",
        sequence=8,
        event_type="runtime.capability.updated",
        payload={
            "capabilitySet": {
                "revision": 99,
                "capabilities": [
                    {
                        **first.payload["capabilitySet"]["capabilities"][0],
                        "runtimeId": "runtime-2",
                    },
                    first.payload["capabilitySet"]["capabilities"][1],
                ],
            }
        },
    )

    assert capability_event_semantic_fingerprint(first) == (
        capability_event_semantic_fingerprint(reordered)
    )
    assert capability_event_semantic_fingerprint(first) != (
        capability_event_semantic_fingerprint(changed_runtime)
    )
    assert (
        capability_event_semantic_fingerprint(
            protocol_event(
                "session-1",
                sequence=8,
                event_type="session.meta.updated",
                payload={"session": {}},
            )
        )
        is None
    )


def test_timeline_reset_invalidation_becomes_one_snapshot_event() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 4,
            "timelineReset": True,
            "items": [
                {
                    "id": "item-1",
                    "updatedSeq": 3,
                    "revision": 1,
                }
            ],
        }
    )

    assert len(events) == 1
    assert events[0].type == "timeline.snapshot"
    assert events[0].sequence == 4
    assert events[0].payload["items"][0]["id"] == "item-1"


def test_empty_timeline_reset_becomes_one_empty_snapshot_event() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 4,
            "timelineReset": True,
            "items": [],
        }
    )

    assert len(events) == 1
    assert events[0].type == "timeline.snapshot"
    assert events[0].sequence == 4
    assert events[0].payload["items"] == []


def test_notice_reset_invalidation_becomes_one_snapshot_event() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 5,
            "noticesReset": True,
            "notices": [],
        }
    )

    event_types = {event.type for event in events}
    assert event_types == {"runtime.notice.snapshot"}
    for event in events:
        assert event.payload["notices"] == []


def test_runtime_state_invalidation_emits_runtime_state_event() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 7,
            "runtimeState": {
                "sessionId": "session-1",
                "runtime": "codex",
                "status": "running",
                "selections": {"model": "sel_model"},
                "updatedSeq": 7,
            },
        }
    )

    assert len(events) == 1
    assert events[0].type == "runtime.state.updated"
    assert events[0].payload["state"]["status"] == "running"


def test_session_invalidation_emits_meta_event() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 9,
            "session": {
                "id": "session-1",
                "title": "Updated",
                "status": "idle",
                "updatedSeq": 9,
            },
        }
    )

    event_types = {event.type for event in events}
    assert "session.meta.updated" in event_types
    assert "session.status_changed" not in event_types
    meta_event = next(event for event in events if event.type == "session.meta.updated")
    assert meta_event.payload["session"]["title"] == "Updated"


def test_notice_invalidation_emits_runtime_notice_update() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 8,
            "notices": [
                {
                    "id": "notice-1",
                    "status": "answered",
                    "revision": 2,
                    "updatedSeq": 8,
                }
            ],
        }
    )

    event_types = {event.type for event in events}
    assert event_types == {"runtime.notice.updated"}
    runtime_event = next(
        event for event in events if event.type == "runtime.notice.updated"
    )
    assert runtime_event.payload["notice"]["id"] == "notice-1"


def test_notice_invalidation_adds_event_sequence_for_live_notice() -> None:
    events = events_from_invalidation(
        {
            "sessionId": "session-1",
            "nextSeq": 8,
            "notices": [
                {
                    "noticeId": "notice-1",
                    "type": "interaction",
                    "sessionId": "session-1",
                    "title": "Approve command",
                    "status": "open",
                }
            ],
        }
    )

    assert len(events) == 1
    assert events[0].type == "runtime.notice.updated"
    assert events[0].sequence == 8
    assert events[0].payload["notice"]["updatedSeq"] == 8


def test_recovery_requires_every_durable_revision_to_be_projected() -> None:
    events = [
        protocol_event(
            "session-1",
            sequence=2,
            event_type="timeline.item_updated",
            payload={"item": {"id": "item-1"}},
        )
    ]

    assert not revisions_are_complete(
        after_sequence=0,
        current_sequence=2,
        events=events,
    )
    assert revisions_are_complete(
        after_sequence=1,
        current_sequence=2,
        events=events,
    )


def test_timeline_snapshot_replace_requires_snapshot_for_deleted_items(
    tmp_path,
) -> None:
    async def exercise() -> None:
        path = tmp_path / "events.sqlite3"
        upgrade_database(sqlite_path=path)
        store = Store(path)
        presence = ConnectorRpcManager()
        try:
            connector, _token, _prefix = await store.create_connector(
                name="dev",
                user_id="user-1",
            )
            session = await create_session_with_project(
                store,
                connector_id=connector.id,
                user_id="user-1",
                external_session_id="thread-1",
                title="Recovery",
            )
            first = _timeline_item(session.id, "item-1", 1)
            second = _timeline_item(session.id, "item-2", 2)
            await store.upsert_timeline_item(session_id=session.id, item=first)
            await store.upsert_timeline_item(session_id=session.id, item=second)
            before_replace = await store.get_session_seq(session.id)

            await store.replace_timeline_snapshot(
                session_id=session.id,
                items=[first],
            )
            recovery = await EventRecoveryService(store, presence).recover(
                session.id,
                after=event_cursor(before_replace),
                user_id="user-1",
            )

            assert recovery.snapshotRequired is True
        finally:
            await presence.close()
            await store.close()

    asyncio.run(exercise())


def test_recovery_requires_snapshot_when_the_serialized_delta_exceeds_the_byte_limit(
    tmp_path, monkeypatch
) -> None:
    """T1: ten large items cross the byte gate while the count gate is open."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_item(session.id, f"item-{index}", index, text="x" * 700_000)
                for index in range(10)
            ],
        )
        measured_bytes = await _stored_delta_bytes(store, session.id)
        assert measured_bytes > DEFAULT_RECOVERY_BYTE_LIMIT
        assert DEFAULT_RECOVERY_BYTE_LIMIT == 4 * 1024 * 1024

        serialized_items: list[str] = []
        original_serialized_payload_bytes = event_recovery._serialized_payload_bytes

        def counting_serialized_payload_bytes(payload: dict[str, Any]) -> int:
            serialized_items.append(str(payload["item"]["id"]))
            return original_serialized_payload_bytes(payload)

        monkeypatch.setattr(
            event_recovery,
            "_serialized_payload_bytes",
            counting_serialized_payload_bytes,
        )
        sequence = await store.get_session_seq(session.id)

        with captured_loguru() as messages:
            response = await EventRecoveryService(store, presence).recover(
                session.id,
                after=event_cursor(0),
                user_id="user-1",
            )

        assert response.snapshotRequired is True
        assert response.events == []
        assert response.nextCursor == event_cursor(sequence)
        # The dumped payload of every inspected item is reused for the events
        # that are actually returned, and an over-limit batch stops early.
        assert serialized_items
        assert len(serialized_items) == len(set(serialized_items))
        assert len(serialized_items) < 10

        downgrades = [
            message for message in messages if "recovery byte limit exceeded" in message
        ]
        assert len(downgrades) == 1
        line = downgrades[0]
        assert f"session_id={session.id}" in line
        assert f"byte_limit={DEFAULT_RECOVERY_BYTE_LIMIT}" in line
        assert int(line.split(" items=")[1].split(" ")[0]) == 10
        assert int(line.split("measured_items=")[1].split(" ")[0]) < 10
        assert (
            int(line.split("payload_bytes=")[1].split(" ")[0])
            > DEFAULT_RECOVERY_BYTE_LIMIT
        )

    _run_recovery_case(tmp_path, "recovery-byte-limit.sqlite3", exercise)


def test_recovery_byte_gate_measures_serialized_utf8_payload_bytes(tmp_path) -> None:
    """T2: the boundary follows the wire encoding, not a character count."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_item(
                    session.id,
                    f"item-{index}",
                    index,
                    text="会话增量长文本" * 200,
                )
                for index in range(5)
            ],
        )
        items, _has_more = await store.list_timeline_since(
            session_id=session.id,
            after_seq=0,
            limit=DEFAULT_RECOVERY_LIMIT,
        )
        payloads = [item.model_dump(mode="json") for item in items]
        measured_characters = sum(len(_recovery_payload_json(p)) for p in payloads)
        measured_bytes = sum(
            len(_recovery_payload_json(p).encode("utf-8")) for p in payloads
        )
        # A character-based metric would let this limit pass; byte count does not.
        assert measured_characters < measured_bytes - 1
        sequence = await store.get_session_seq(session.id)

        below = await EventRecoveryService(
            store,
            presence,
            byte_limit=measured_bytes + 1,
        ).recover(session.id, after=event_cursor(0), user_id="user-1")
        assert below.snapshotRequired is False
        assert len(below.events) == len(items) + 2

        at_limit = await EventRecoveryService(
            store,
            presence,
            byte_limit=measured_bytes,
        ).recover(session.id, after=event_cursor(0), user_id="user-1")
        assert at_limit.snapshotRequired is False
        assert len(at_limit.events) == len(items) + 2

        over = await EventRecoveryService(
            store,
            presence,
            byte_limit=measured_bytes - 1,
        ).recover(session.id, after=event_cursor(0), user_id="user-1")
        assert over.snapshotRequired is True
        assert over.events == []
        assert over.nextCursor == event_cursor(sequence)

    _run_recovery_case(tmp_path, "recovery-byte-boundary.sqlite3", exercise)


def test_recovery_serves_a_490_item_delta_and_the_count_gate_still_bounds_it(
    tmp_path,
) -> None:
    """T3: both gates compose, so the effective limit is the smaller one."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_item(session.id, f"item-{index}", index, text=f"p {index}")
                for index in range(490)
            ],
        )
        measured_bytes = await _stored_delta_bytes(store, session.id)
        assert measured_bytes < DEFAULT_RECOVERY_BYTE_LIMIT

        response = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(0),
            user_id="user-1",
        )
        event_types = collections.Counter(event.type for event in response.events)
        assert response.snapshotRequired is False
        assert event_types["timeline.item_created"] == 490
        assert event_types["timeline.item_updated"] == 0
        assert event_types["session.meta.updated"] == 1
        assert event_types["runtime.capability.updated"] == 1
        assert response.nextCursor == event_cursor(490)

        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_item(
                    session.id,
                    f"item-extra-{index}",
                    1000 + index,
                    text="extra",
                )
                for index in range(11)
            ],
        )
        over_count = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(0),
            user_id="user-1",
        )
        assert over_count.snapshotRequired is True
        assert over_count.events == []
        assert over_count.nextCursor == event_cursor(501)

    _run_recovery_case(tmp_path, "recovery-count-gate.sqlite3", exercise)


def test_recovery_small_delta_keeps_event_construction_and_cursor(tmp_path) -> None:
    """T4: an ordinary delta is built and cursored exactly as before."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                _timeline_item(session.id, f"item-{index}", index) for index in range(3)
            ],
        )
        items, _has_more = await store.list_timeline_since(
            session_id=session.id,
            after_seq=0,
            limit=DEFAULT_RECOVERY_LIMIT,
        )
        sequence = await store.get_session_seq(session.id)

        response = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(0),
            user_id="user-1",
        )

        timeline_types = {"timeline.item_created", "timeline.item_updated"}
        actual_items = [
            event for event in response.events if event.type in timeline_types
        ]
        expected_items = timeline_events_from_items(
            session.id,
            [item.model_dump(mode="json") for item in items],
        )
        assert [_event_shape(event) for event in actual_items] == [
            _event_shape(event) for event in expected_items
        ]
        trailing_events = [
            event for event in response.events if event.type not in timeline_types
        ]
        assert sorted(event.type for event in trailing_events) == [
            "runtime.capability.updated",
            "session.meta.updated",
        ]
        assert {event.sequence for event in trailing_events} == {sequence}
        assert response.events == sorted(
            response.events,
            key=lambda event: (event.sequence, event.eventId),
        )
        assert response.snapshotRequired is False
        assert response.nextCursor == event_cursor(sequence)
        assert revisions_are_complete(
            after_sequence=0,
            current_sequence=sequence,
            events=response.events,
        )
        assert await _stored_delta_bytes(store, session.id) < DEFAULT_RECOVERY_BYTE_LIMIT

    _run_recovery_case(tmp_path, "recovery-normal-delta.sqlite3", exercise)


def test_recovery_snapshot_for_a_cursor_ahead_of_the_durable_sequence(tmp_path) -> None:
    """T5: the existing after > current branch is unchanged."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[_timeline_item(session.id, "item-1", 0)],
        )
        sequence = await store.get_session_seq(session.id)

        response = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(sequence + 1),
            user_id="user-1",
        )

        assert response.snapshotRequired is True
        assert response.events == []
        assert response.nextCursor == event_cursor(sequence)

    _run_recovery_case(tmp_path, "recovery-cursor-ahead.sqlite3", exercise)


def test_recovery_at_the_current_cursor_returns_meta_and_capability(tmp_path) -> None:
    """T5: the existing after == current branch is unchanged."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[_timeline_item(session.id, "item-1", 0)],
        )
        sequence = await store.get_session_seq(session.id)

        response = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(sequence),
            user_id="user-1",
        )

        assert response.snapshotRequired is False
        assert sorted(event.type for event in response.events) == [
            "runtime.capability.updated",
            "session.meta.updated",
        ]
        assert {event.sequence for event in response.events} == {sequence}
        assert response.nextCursor == event_cursor(sequence)

    _run_recovery_case(tmp_path, "recovery-current-cursor.sqlite3", exercise)


def test_recovery_snapshot_when_the_cursor_precedes_the_timeline_reset(tmp_path) -> None:
    """T5: the existing reset branch keeps its nextCursor contract."""

    async def exercise(
        store: Store,
        presence: ConnectorRpcManager,
        session: SessionView,
    ) -> None:
        first = _timeline_item(session.id, "item-1", 0)
        second = _timeline_item(session.id, "item-2", 1)
        await store.sync_timeline_items(session_id=session.id, items=[first, second])
        cursor_before_reset = await store.get_session_seq(session.id)

        await store.replace_timeline_snapshot(session_id=session.id, items=[first])
        reset_sequence = await store.get_timeline_reset_seq(session.id)
        current_sequence = await store.get_session_seq(session.id)
        assert cursor_before_reset < reset_sequence

        response = await EventRecoveryService(store, presence).recover(
            session.id,
            after=event_cursor(cursor_before_reset),
            user_id="user-1",
        )

        assert response.snapshotRequired is True
        assert response.events == []
        assert response.nextCursor == event_cursor(
            max(current_sequence, reset_sequence)
        )

    _run_recovery_case(tmp_path, "recovery-reset.sqlite3", exercise)


@contextmanager
def captured_loguru():
    """Collect loguru records so recovery downgrade assertions need no log file."""

    messages: list[str] = []
    sink_id = logger.add(messages.append, level="INFO", format="{message}")
    try:
        yield messages
    finally:
        logger.remove(sink_id)


def _run_recovery_case(
    tmp_path: Path,
    filename: str,
    action: Callable[[Store, ConnectorRpcManager, SessionView], Awaitable[None]],
) -> None:
    async def exercise() -> None:
        path = tmp_path / filename
        upgrade_database(sqlite_path=path)
        store = Store(path)
        presence = ConnectorRpcManager()
        try:
            connector, _token, _prefix = await store.create_connector(
                name="dev",
                user_id="user-1",
            )
            session = await create_session_with_project(
                store,
                connector_id=connector.id,
                user_id="user-1",
                external_session_id="thread-1",
                title="Recovery",
            )
            await action(store, presence, session)
        finally:
            await presence.close()
            await store.close()

    asyncio.run(exercise())


def _recovery_payload_json(item: dict[str, Any]) -> str:
    """One recovery event payload in the encoding the response serializes."""

    return json.dumps(
        {"item": item},
        ensure_ascii=False,
        separators=(",", ":"),
        default=str,
    )


async def _stored_delta_bytes(store: Store, session_id: str) -> int:
    """Bytes of the stored delta measured through the judged serialization."""

    items, _has_more = await store.list_timeline_since(
        session_id=session_id,
        after_seq=0,
        limit=DEFAULT_RECOVERY_LIMIT,
    )
    return sum(
        len(_recovery_payload_json(item.model_dump(mode="json")).encode("utf-8"))
        for item in items
    )


def _event_shape(event) -> tuple[str, int, str, str, dict[str, Any]]:
    return (event.type, event.sequence, event.cursor, event.sessionId, event.payload)


def _timeline_item(
    session_id: str,
    item_id: str,
    order_seq: int,
    *,
    text: str | None = None,
) -> TimelineItemIn:
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": item_id if text is None else text},
            "source": {
                "runtime": "codex",
                "sessionId": "thread-1",
                "itemId": item_id,
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        }
    )
