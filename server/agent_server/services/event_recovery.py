from __future__ import annotations

import json
from typing import Any, Protocol

from loguru import logger

from agent_server.core.events import (
    event_cursor,
    parse_event_cursor,
    protocol_event,
    timeline_events_from_items,
)
from agent_server.core.models import SessionView, TimelineItem
from agent_server.core.protocol import ProtocolEventRecoveryResponse
from agent_server.core.utc import utc_now
from agent_server.services.connector_presence import ConnectorPresencePort
from agent_server.services.effective_capabilities import (
    SessionCapabilityRepository,
    project_session_capabilities,
)
from agent_server.services.timeline_payload import (
    SlimStats,
    log_slim_stats,
    normalize_item_payload,
)
from agent_server.services.timeline_write_buffer import TimelineWriteBuffer

DEFAULT_RECOVERY_LIMIT = 500
#: The recovery response is one atomic batch on the client. 3 MiB leaves room
#: for the session/capability events that ride with the items while staying
#: below the 4 MiB body that once stalled a client for 19 hours.
DEFAULT_RECOVERY_BYTE_LIMIT = 3 * 1024 * 1024
DEFAULT_STABILITY_ATTEMPTS = 3


def _serialized_response_bytes(response: ProtocolEventRecoveryResponse) -> int:
    """Byte size of the complete response as the endpoint serializes it.

    The gate covers the whole envelope — item events plus the session and
    capability projections and the cursor fields — because the client applies
    the response as one batch.
    """

    return len(
        json.dumps(
            response.model_dump(mode="json"),
            ensure_ascii=False,
            separators=(",", ":"),
            default=str,
        ).encode("utf-8")
    )


class EventRecoveryRepository(SessionCapabilityRepository, Protocol):
    async def get_session(
        self,
        session_id: str,
        *,
        user_id: str | None = None,
    ) -> SessionView: ...

    async def list_timeline_since(
        self,
        *,
        session_id: str,
        after_seq: int,
        limit: int,
    ) -> tuple[list[TimelineItem], bool]: ...

    async def get_timeline_reset_seq(self, session_id: str) -> int: ...


class EventRecoveryService:
    def __init__(
        self,
        store: EventRecoveryRepository,
        presence: ConnectorPresencePort,
        timeline_write_buffer: TimelineWriteBuffer | None = None,
        *,
        limit: int = DEFAULT_RECOVERY_LIMIT,
        byte_limit: int = DEFAULT_RECOVERY_BYTE_LIMIT,
        stability_attempts: int = DEFAULT_STABILITY_ATTEMPTS,
    ) -> None:
        self._store = store
        self._presence = presence
        self._timeline_write_buffer = timeline_write_buffer
        self._limit = limit
        self._byte_limit = byte_limit
        self._stability_attempts = stability_attempts

    async def recover(
        self,
        session_id: str,
        *,
        after: str,
        user_id: str,
    ) -> ProtocolEventRecoveryResponse:
        after_sequence = parse_event_cursor(after)
        await self._store.get_session(session_id, user_id=user_id)
        if self._timeline_write_buffer is not None:
            async with self._timeline_write_buffer.session_fence(session_id):
                return await self._recover_durable(
                    session_id,
                    after_sequence=after_sequence,
                    user_id=user_id,
                )
        return await self._recover_durable(
            session_id,
            after_sequence=after_sequence,
            user_id=user_id,
        )

    async def _recover_durable(
        self,
        session_id: str,
        *,
        after_sequence: int,
        user_id: str,
    ) -> ProtocolEventRecoveryResponse:
        current_sequence = await self._store.get_session_seq(session_id)
        if after_sequence > current_sequence:
            return self._snapshot_required(current_sequence)
        if after_sequence == current_sequence:
            session = await self._store.get_session(session_id, user_id=user_id)
            session, _runtime_capabilities, effective_capabilities = (
                await project_session_capabilities(
                    self._store,
                    self._presence,
                    session,
                    user_id=user_id,
                )
            )
            return ProtocolEventRecoveryResponse(
                events=[
                    protocol_event(
                        session_id,
                        sequence=current_sequence,
                        event_type="session.meta.updated",
                        payload={"session": session.model_dump(mode="json")},
                    ),
                    protocol_event(
                        session_id,
                        sequence=current_sequence,
                        event_type="runtime.capability.updated",
                        payload={
                            "capabilitySet": effective_capabilities.model_dump(
                                mode="json"
                            )
                        },
                    ),
                ],
                nextCursor=event_cursor(current_sequence),
                snapshotRequired=False,
                serverTime=utc_now(),
            )

        for _attempt in range(self._stability_attempts):
            start_sequence = await self._store.get_session_seq(session_id)
            timeline_reset_sequence = await self._store.get_timeline_reset_seq(
                session_id
            )
            if after_sequence < timeline_reset_sequence:
                return self._snapshot_required(
                    max(start_sequence, timeline_reset_sequence)
                )
            session = await self._store.get_session(session_id, user_id=user_id)
            session, _runtime_capabilities, effective_capabilities = (
                await project_session_capabilities(
                    self._store,
                    self._presence,
                    session,
                    user_id=user_id,
                )
            )
            items, has_more = await self._store.list_timeline_since(
                session_id=session_id,
                after_seq=after_sequence,
                limit=self._limit,
            )
            current_sequence = await self._store.get_session_seq(session_id)
            if start_sequence == current_sequence:
                break
        else:
            return self._snapshot_required(current_sequence)

        if has_more:
            return self._snapshot_required(current_sequence)

        item_payloads: list[dict[str, Any]] = []
        slim_stats = SlimStats()
        for item in items:
            dumped_item = item.model_dump(mode="json")
            dumped_item, saved_bytes = normalize_item_payload(dumped_item)
            slim_stats = slim_stats.add(saved_bytes)
            item_payloads.append(dumped_item)

        events = timeline_events_from_items(session_id, item_payloads)
        if session.updatedSeq > after_sequence:
            session_payload = session.model_dump(mode="json")
            events.append(
                protocol_event(
                    session_id,
                    sequence=session.updatedSeq,
                    event_type="session.meta.updated",
                    payload={"session": session_payload},
                )
            )
            events.append(
                protocol_event(
                    session_id,
                    sequence=session.updatedSeq,
                    event_type="runtime.capability.updated",
                    payload={"capabilitySet": effective_capabilities.model_dump(mode="json")},
                )
            )
        events.sort(key=lambda event: (event.sequence, event.eventId))
        response = ProtocolEventRecoveryResponse(
            events=events,
            nextCursor=event_cursor(current_sequence),
            snapshotRequired=False,
            serverTime=utc_now(),
        )
        log_slim_stats(
            surface="recovery",
            session_id=session_id,
            stats=slim_stats,
        )
        payload_bytes = _serialized_response_bytes(response)
        if payload_bytes > self._byte_limit:
            logger.info(
                "recovery byte limit exceeded session_id={} items={} "
                "measured_items={} payload_bytes={} byte_limit={} "
                "normalized_items={} saved_bytes={}",
                session_id,
                len(items),
                len(item_payloads),
                payload_bytes,
                self._byte_limit,
                slim_stats.normalized,
                slim_stats.saved_bytes,
            )
            return self._snapshot_required(current_sequence)
        return response

    @staticmethod
    def _snapshot_required(current_sequence: int) -> ProtocolEventRecoveryResponse:
        return ProtocolEventRecoveryResponse(
            events=[],
            nextCursor=event_cursor(current_sequence),
            snapshotRequired=True,
            serverTime=utc_now(),
        )
