from __future__ import annotations

from agent_server.core.models import SessionView
from agent_server.services.connector_presence import ConnectorPresencePort
from agent_server.services.session_runtime_state_cache import SessionRuntimeStateCache


async def project_session_meta_for_dashboard(
    presence: ConnectorPresencePort,
    runtime_state_cache: SessionRuntimeStateCache,
    sessions: list[SessionView],
) -> list[SessionView]:
    connector_statuses = await connector_online_statuses(presence, sessions)
    runtime_states = await runtime_state_cache.get_many([session.id for session in sessions])
    projected_sessions: list[SessionView] = []
    for session in sessions:
        connector_status = (
            "online" if connector_statuses.get(session.connectorId, False) else "offline"
        )
        projected = session.model_copy(update={"connectorStatus": connector_status})
        runtime_state = runtime_states.get(session.id)
        if runtime_state is not None:
            try:
                background_tasks = max(
                    0, int(runtime_state.metadata.get("backgroundTasks", 0))
                )
            except (TypeError, ValueError):
                background_tasks = 0
            assistant_text = runtime_state.metadata.get("assistantText")
            if not isinstance(assistant_text, bool):
                assistant_text = None
            notice_id = runtime_state.metadata.get("notice_id")
            if not isinstance(notice_id, str) or not notice_id:
                notice_id = None
            projected = projected.model_copy(
                update={
                    "externalSessionId": (
                        runtime_state.externalSessionId
                        or projected.externalSessionId
                    ),
                    "status": runtime_state.status,
                    "backgroundTasks": background_tasks,
                    "assistantText": assistant_text,
                    "noticeId": notice_id,
                }
            )
        projected_sessions.append(projected)
    return projected_sessions


async def connector_online_statuses(
    presence: ConnectorPresencePort,
    sessions: list[SessionView],
) -> dict[str, bool]:
    connector_ids = [session.connectorId for session in sessions]
    batch = getattr(presence, "online_statuses", None)
    if callable(batch):
        return await batch(connector_ids)
    unique_ids = list(dict.fromkeys(connector_ids))
    return {
        connector_id: await presence.is_online(connector_id)
        for connector_id in unique_ids
    }
