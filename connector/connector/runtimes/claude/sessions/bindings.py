from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from connector.logging import logger
from connector.runtime_protocol.host import RuntimeHostClient

# Durable binding between the Connector's runtime-side session identity and the
# Server's canonical ``sessions.id``.
#
# Why this exists (root cause of the 2026-10-12 ``sess_92gAb`` 502): a
# platform-created session gets its id minted by the *Server*
# (``session.create`` carries ``sessionId=sess_...`` in the RPC params), but the
# Connector only ever derived and persisted its own id
# (``sess_claude_<hash>``) from the Claude conversation uuid. On restart the
# in-memory map was gone, so a history scan rebuilt the session under the
# derived id while the Server still knew the ``sess_...`` id; a subsequent
# ``session.state`` read then returned a mismatched ``sessionId`` and the Server
# rejected it (``connector returned sessionId that does not match the session
# binding``).
#
# Persisting the Server-authoritative id closes that gap: after a restart the
# Connector resolves a known external uuid straight to the Server's id instead
# of re-deriving a fresh one. The store is instance-scoped automatically by the
# host's ``sync_state_*`` layer (which prefixes ``claude/instances/<rti>/``),
# matching the history cursor store.
#
# Every method is fail-soft: a persistence error must never break the RPC it
# rides on. A cache miss just means the caller falls back to its prior
# behaviour, which the reader still guards against (see
# ``ClaudeSessionReader.get_session_state``).


@dataclass(frozen=True, slots=True)
class ClaudeSessionBinding:
    """One durable ``external uuid -> Server session id`` mapping."""

    session_id: str
    runtime_id: str | None
    updated_at: str


@dataclass(slots=True)
class ClaudeSessionBindingStore:
    host: RuntimeHostClient

    async def read(self, external_session_id: str) -> ClaudeSessionBinding | None:
        if not external_session_id:
            return None
        try:
            state = await self.host.sync_state_read(
                session_binding_key(external_session_id)
            )
        except Exception:  # noqa: BLE001 - persistence must never break the caller
            logger.exception(
                "claude session binding read failed external_session_id={}",
                external_session_id,
            )
            return None
        return binding_from_state(state)

    async def write(
        self,
        external_session_id: str,
        session_id: str,
        runtime_id: str | None = None,
    ) -> None:
        """Record the Server-authoritative id for one external uuid.

        Idempotent: the same ``(external, session_id)`` pair is a no-op so the
        per-read RPC path does not churn the sync-state file. A genuine change
        (the Server moved the session to a different id) is logged because it
        means identity was previously mis-bound.
        """

        if not external_session_id or not session_id:
            return
        existing = await self.read(external_session_id)
        if existing is not None and existing.session_id == session_id:
            return
        try:
            await self.host.sync_state_write(
                session_binding_key(external_session_id),
                binding_to_state(
                    ClaudeSessionBinding(
                        session_id=session_id,
                        runtime_id=runtime_id,
                        updated_at=datetime.now(UTC).isoformat(),
                    )
                ),
            )
        except Exception:  # noqa: BLE001 - persistence must never break the caller
            logger.exception(
                "claude session binding write failed external_session_id={}",
                external_session_id,
            )
            return
        if existing is not None:
            logger.warning(
                "claude session binding changed external_session_id={} "
                "previous_session_id={} next_session_id={}",
                external_session_id,
                existing.session_id,
                session_id,
            )

    async def delete(self, external_session_id: str) -> None:
        if not external_session_id:
            return
        try:
            await self.host.sync_state_delete(
                session_binding_key(external_session_id)
            )
        except Exception:  # noqa: BLE001 - persistence must never break the caller
            logger.exception(
                "claude session binding delete failed external_session_id={}",
                external_session_id,
            )


def session_binding_key(external_session_id: str) -> str:
    return f"claude/session-binding/{external_session_id}"


def binding_to_state(binding: ClaudeSessionBinding) -> dict[str, Any]:
    return {
        "version": 1,
        "sessionId": binding.session_id,
        "runtimeId": binding.runtime_id,
        "updatedAt": binding.updated_at,
    }


def binding_from_state(state: Mapping[str, Any] | None) -> ClaudeSessionBinding | None:
    if state is None:
        return None
    session_id = state.get("sessionId")
    if not isinstance(session_id, str) or not session_id:
        return None
    runtime_id = state.get("runtimeId")
    updated_at = state.get("updatedAt")
    return ClaudeSessionBinding(
        session_id=session_id,
        runtime_id=runtime_id if isinstance(runtime_id, str) else None,
        updated_at=updated_at if isinstance(updated_at, str) else "",
    )
