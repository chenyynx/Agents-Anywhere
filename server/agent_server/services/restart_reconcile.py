"""Reconcile a connector reconnect against the turn the server still believes runs.

A connector process dying mid-turn (SIGTERM, OOM, reboot) takes the Runtime
subprocess with it, and the SDK can never emit ``turn.completed`` for that
turn. The server is left holding ``sessions.status = 'running'`` and one or
more ``timeline_items`` rows still ``running``: the composer stays locked and
every client keeps its turn phase at "using tool" until the user sends
another message.

The reconnect itself is evidence that *some* previous turn is dead, but it is
not proof that every session the server calls active is dead — a reconnect
after a network blip leaves live turns running on the connector. So this
sweep asks the connector for each still-active session
(``session.state``) and writes only when the connector answers that nothing
is running there (``idle``, or no state at all) *and* the session has no
active run. Timeouts, RPC errors, and any other state are skips: the rule is
"rather leave residue than kill a live turn".

What it repairs is bounded to the residue it can prove:

- every ``running`` tool row in the session becomes ``interrupted`` with
  ``closedByEvidence = connectorRestarted`` (the same write shape as the age
  janitor, shared through the repository helper);
- the session status falls back to ``idle`` for the in-flight statuses.

Messages, transcripts and agent context are never touched.
"""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass

from loguru import logger

from agent_server.core.models import SessionStatus, SessionView
from agent_server.core.runtime_identity import (
    SessionRuntimeBindingError,
    resolve_session_runtime_binding,
)
from agent_server.infra.connector_rpc import (
    ConnectorOfflineError,
    ConnectorRpcError,
    ConnectorRpcManager,
)
from agent_server.services.repository_ports import RestartReconcileRepository

CLOSED_BY_EVIDENCE = "connectorRestarted"
DEFAULT_MAX_SESSIONS = 50
DEFAULT_PROBE_TIMEOUT_SECONDS = 10.0

ENV_ENABLED = "AGENT_SERVER_RESTART_RECONCILE_ENABLED"

# Statuses this sweep may settle back to ``idle``. ``error`` and ``blocked``
# are deliberately excluded: the connector can prove no process is running,
# but those statuses are still the diagnosis the user needs; only their
# residue rows are closed.
SETTLE_STATUSES: frozenset[SessionStatus] = frozenset(
    {"waiting", "pending", "running", "stopping", "waiting_approval"}
)

# Connector answers that prove nothing is running for that session. ``none``
# is ``{"state": None}``: the Runtime has no record of the session at all.
_NOT_RUNNING_STATES = frozenset({"idle", "none"})


@dataclass(frozen=True)
class RestartReconcileSummary:
    connector_id: str
    sessions: int = 0
    sessions_changed: int = 0
    tool_items_closed: int = 0


def _enabled_from_environment() -> bool:
    """Read the kill switch; malformed values stand the sweep down.

    ``from_environment`` runs at application startup, so a bad value must not
    take the server down: it disables the reconciliation and is logged.
    """

    raw = os.environ.get(ENV_ENABLED)
    if raw is None:
        return True
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    logger.warning(
        "restart reconcile disabled by malformed configuration variable={} "
        "value={!r}",
        ENV_ENABLED,
        raw,
    )
    return False


class RestartReconcileService:
    def __init__(
        self,
        store: RestartReconcileRepository,
        rpc: ConnectorRpcManager,
        *,
        enabled: bool = True,
        max_sessions: int = DEFAULT_MAX_SESSIONS,
        probe_timeout_seconds: float = DEFAULT_PROBE_TIMEOUT_SECONDS,
    ) -> None:
        self._store = store
        self._rpc = rpc
        self.enabled = bool(enabled)
        self._max_sessions = max(1, int(max_sessions))
        self._probe_timeout_seconds = float(probe_timeout_seconds)

    @classmethod
    def from_environment(
        cls,
        store: RestartReconcileRepository,
        rpc: ConnectorRpcManager,
    ) -> RestartReconcileService:
        return cls(store, rpc, enabled=_enabled_from_environment())

    async def reconcile_connector(
        self,
        connector_id: str,
    ) -> RestartReconcileSummary:
        """Ask the connector about, and settle, every active session it owns."""

        if not self.enabled:
            return RestartReconcileSummary(connector_id=connector_id)
        sessions = await self._store.list_sessions_for_restart_reconcile(
            connector_id=connector_id,
            limit=self._max_sessions,
        )
        changed = 0
        closed_items = 0
        for session in sessions:
            try:
                session_changed, session_closed = await self._reconcile_session(
                    connector_id,
                    session,
                )
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - keep healing other sessions
                logger.warning(
                    "restart reconcile session deferred session_id={} error={}",
                    session.id,
                    exc,
                )
                continue
            changed += int(session_changed)
            closed_items += session_closed
        summary = RestartReconcileSummary(
            connector_id=connector_id,
            sessions=len(sessions),
            sessions_changed=changed,
            tool_items_closed=closed_items,
        )
        if sessions:
            logger.info(
                "restart reconcile summary connector_id={} sessions={} "
                "sessions_changed={} tool_items_closed={}",
                connector_id,
                summary.sessions,
                summary.sessions_changed,
                summary.tool_items_closed,
            )
        return summary

    async def _reconcile_session(
        self,
        connector_id: str,
        session: SessionView,
    ) -> tuple[bool, int]:
        previous_status = session.status
        connector_state = await self._probe_connector_state(connector_id, session)
        closed_items = 0
        session_changed = False
        if connector_state in _NOT_RUNNING_STATES:
            if await self._store.get_active_run(session.id) is not None:
                connector_state = f"{connector_state}:active_run"
            else:
                try:
                    result = await self._store.close_running_tool_items(
                        session_id=session.id,
                        closed_by_evidence=CLOSED_BY_EVIDENCE,
                    )
                    closed_items = len(result.items)
                except KeyError:
                    connector_state = f"{connector_state}:session_missing"
                else:
                    if previous_status in SETTLE_STATUSES:
                        session_changed = await self._settle_status(
                            session,
                            previous_status=previous_status,
                        )
                    else:
                        session_changed = bool(closed_items)
        logger.info(
            "restart reconcile session_id={} tool_items_closed={} "
            "previous_status={} connector_state={}",
            session.id,
            closed_items,
            previous_status,
            connector_state,
        )
        return session_changed, closed_items

    async def _settle_status(
        self,
        session: SessionView,
        *,
        previous_status: SessionStatus,
    ) -> bool:
        # The close above ran under the timeline lock, but a new turn may have
        # been accepted right after it; re-check before overwriting the status
        # so a just-started turn is never reported idle.
        if await self._store.get_active_run(session.id) is not None:
            return False
        try:
            await self._store.set_session_status(
                session.id,
                "idle",
                expected_status=previous_status,
            )
        except (KeyError, ValueError):
            # The session vanished or its status moved under the same fence a
            # live writer owns; that writer's value is newer evidence.
            return False
        return True

    async def _probe_connector_state(
        self,
        connector_id: str,
        session: SessionView,
    ) -> str:
        """Return the connector's own answer for one session.

        Only ``idle``/``none`` authorise a write; every failure mode resolves
        to a distinct string that the caller treats as a skip, and the string
        is what the per-session log line reports.
        """

        params: dict[str, object] = {
            "sessionId": session.id,
            "runtime": session.runtime,
            "runtimeId": session.runtimeId or session.runtime,
        }
        if session.externalSessionId:
            params["externalSessionId"] = session.externalSessionId
        try:
            result = await self._rpc.request(
                connector_id,
                "session.state",
                params,
                timeout=self._probe_timeout_seconds,
            )
        except TimeoutError:
            return "timeout"
        except ConnectorOfflineError:
            return "offline"
        except ConnectorRpcError as exc:
            return f"rpc_error:{exc.code}"
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - one probe must not stop the sweep
            return f"error:{type(exc).__name__}"
        if not isinstance(result, dict):
            return "invalid"
        state = result.get("state")
        if state is None:
            return "none"
        if not isinstance(state, dict):
            return "invalid"
        try:
            resolve_session_runtime_binding(
                state,
                session_id=session.id,
                runtime_type=session.runtime,
                runtime_id=session.runtimeId or session.runtime,
            )
        except SessionRuntimeBindingError:
            return "binding_mismatch"
        status = state.get("status")
        if not isinstance(status, str) or not status:
            return "invalid"
        return status
