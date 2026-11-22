from __future__ import annotations

from dataclasses import dataclass

from connector.runtime_protocol import RuntimeTimelineItem, RuntimeTimelineSnapshot
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.open_cards import ClaudeOpenAgentCards


@dataclass(slots=True)
class ClaudeTimelineActivityHandler:
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    open_cards: ClaudeOpenAgentCards | None = None

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.session_store.record_timeline_item(item)
        await self.host.timeline_item_upsert(item)
        if self.open_cards is not None:
            # The startup reconciliation's work list: only sessions that once
            # published a non-terminal Agent card need a second look after a
            # restart (2026-10-21). Fail-soft inside — never breaks the publish.
            session = self.session_store.get(item.session_id)
            if session is not None:
                await self.open_cards.record(session, item)
        self.session_store.mark_synced(item.session_id)

    async def timeline_sync(
        self,
        snapshot: RuntimeTimelineSnapshot,
        *,
        source: str,
    ) -> None:
        await self.host.timeline_sync(
            session_id=snapshot.session_id,
            runtime=snapshot.runtime,
            external_session_id=snapshot.external_session_id,
            items=snapshot.items,
            complete=snapshot.complete,
            metadata={
                **dict(snapshot.metadata),
                "source": source,
            },
        )
