"""A durable work list of sessions whose Agent cards may still be open.

Why this module exists (2026-10-21)
-----------------------------------
Both agent-card closure paths iterate the connector's **in-memory** sessions:
the 60-second evidence sweep walks ``session_store.sessions()``, and the
startup reconciliation walks the same set. At startup that set is empty — a
session is only adopted when the connector syncs or drives it again — so a
card stranded by the previous process (a restart that killed its subagent)
stays ``running`` until the user happens to interact with that session.

This index remembers only *where to look*: the session (id, external id, cwd)
and the ids of its agent cards last published non-terminal. Content and status
are never stored — the reconciliation rebuilds them from the raw transcript and
the oracle judges them (宁缺勿假: an entry that cannot be rebuilt publishes
nothing). A card's terminal publish removes its id; a missing or unreadable
index only degrades to the pre-index behaviour.

Every write is fail-soft. The index rides the ordinary publish path, so a
storage error must never turn a timeline write into a failed turn.
"""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from connector.logging import logger
from connector.runtime_protocol import RuntimeTimelineItem
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
)

KEY = "claude/agent/open_cards"


@dataclass(slots=True)
class ClaudeOpenAgentCards:
    """Session -> the agent-card ids last seen non-terminal."""

    host: RuntimeHostClient
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    #: Lazily loaded mirror of the persisted map. ``None`` until a read
    #: succeeds; a failed read leaves it ``None`` so no later write can
    #: overwrite the stored value with an empty map.
    sessions: dict[str, dict[str, Any]] | None = field(default=None, init=False)

    async def read(self) -> dict[str, dict[str, Any]]:
        """A copy of the persisted index (empty when it cannot be read)."""

        async with self.lock:
            sessions = await self._load()
            return {
                session_id: dict(entry)
                for session_id, entry in (sessions or {}).items()
            }

    async def record(
        self,
        session: ClaudeSession,
        item: RuntimeTimelineItem,
    ) -> None:
        """Track one published item's card; terminal publishes retire it.

        Called from the publish path for every item — the in-memory mirror makes
        a repeated running upsert a no-op (agent cards are republished on every
        task event), so this costs one storage round trip per card open/close,
        not per frame.
        """

        content = item.content
        if (
            item.type != "tool"
            or not isinstance(content, Mapping)
            or content.get("kind") != "agent_call"
        ):
            return
        if not session.external_session_id or not session.cwd:
            # Without the meta the oracle's probe cannot run, so storing the
            # entry would create a work item the reconciliation could never
            # judge. The live paths still cover the card.
            return
        try:
            async with self.lock:
                sessions = await self._load()
                if sessions is None:
                    return
                entry = sessions.get(session.session_id) or {}
                ids = {
                    card_id
                    for card_id in entry.get("itemIds") or ()
                    if isinstance(card_id, str) and card_id
                }
                if item.status in AGENT_CARD_TERMINAL_STATUSES:
                    ids.discard(item.id)
                else:
                    ids.add(item.id)
                updated: dict[str, Any] = {
                    "externalSessionId": session.external_session_id,
                    "cwd": session.cwd,
                    "itemIds": sorted(ids),
                }
                if not ids:
                    sessions.pop(session.session_id, None)
                else:
                    sessions[session.session_id] = updated
                if entry == updated or (not ids and entry == {}):
                    return
                await self.host.sync_state_write(KEY, {"sessions": sessions})
        except Exception:  # noqa: BLE001
            # Display truth is rebuilt from the transcript at startup; losing an
            # index write costs a delayed closure, never a wrong one.
            logger.exception(
                "Claude open-agent-card index update failed session_id={} item={}",
                session.session_id,
                item.id,
            )

    async def _load(self) -> dict[str, dict[str, Any]] | None:
        if self.sessions is not None:
            return self.sessions
        try:
            value = await self.host.sync_state_read(KEY)
        except Exception:  # noqa: BLE001
            logger.exception("Claude open-agent-card index read failed")
            return None
        self.sessions = dict(value.get("sessions", {})) if value else {}
        return self.sessions
