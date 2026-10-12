from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from connector.runtime_protocol import (
    RuntimeSessionStateCache,
    RuntimeStatus,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.bindings import ClaudeSessionBindingStore


@dataclass(slots=True)
class ClaudeSessionStateHandler:
    host: RuntimeHostClient
    session_states: RuntimeSessionStateCache
    bindings: ClaudeSessionBindingStore | None = None

    async def session_meta_upsert(
        self,
        session: ClaudeSession,
        *,
        source: str,
    ) -> None:
        if self.bindings is not None and session.external_session_id:
            # The external uuid is now known for this session. For a
            # platform-created session ``session.session_id`` is the Server id;
            # for a locally resumed one it is the Connector's derived id. Mark
            # the write non-authoritative so a derived id never overwrites a
            # binding the Server already established (see bindings.py).
            await self.bindings.write(
                session.external_session_id,
                session.session_id,
                authoritative=False,
            )
        await self.host.session_meta_upsert(
            session_id=session.session_id,
            runtime="claude",
            external_session_id=session.external_session_id,
            title=session.title,
            cwd=session.cwd,
            ordering_time=session.ordering_time,
            metadata={"source": source},
        )

    async def session_state_update(
        self,
        session: ClaudeSession,
        status: RuntimeStatus,
        *,
        selections: Mapping[str, str | None] | None = None,
        error: Mapping[str, Any] | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> None:
        await self.session_states.update(
            session_id=session.session_id,
            external_session_id=session.external_session_id,
            status=status,
            selections=selections,
            error=error,
            metadata=metadata,
        )
