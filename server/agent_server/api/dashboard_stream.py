from __future__ import annotations

import asyncio
import json
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, WebSocket
from starlette.requests import HTTPConnection

from agent_server.api.server_push_websocket import (
    run_server_push_until_disconnect,
)
from agent_server.core.device_runtime import DeviceRuntimeView
from agent_server.core.utc import utc_now
from agent_server.deps import (
    current_user_id,
    get_rpc,
    get_session_runtime_state_cache,
    get_store,
    get_timeline_broker,
)
from agent_server.infra.connector_rpc import ConnectorRpcManager
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_broker import TimelineBroker
from agent_server.infra.ws_tickets import ClientWsTicketManager
from agent_server.services.connector_presence import (
    with_effective_connector_statuses,
)
from agent_server.services.notifications import derive_dashboard_notifications
from agent_server.services.session_meta_projection import (
    project_session_meta_for_dashboard,
)
from agent_server.services.session_runtime_state_cache import SessionRuntimeStateCache

router = APIRouter(prefix="/dashboard", tags=["dashboard"])


def _get_ws_tickets(conn: HTTPConnection) -> ClientWsTicketManager:
    return conn.app.state.ws_tickets


async def _latest_assistant_text(db: Store, session_id: str) -> str:
    item = await db.timeline.latest_assistant_item(session_id)
    if item is None or not isinstance(item.content, dict):
        return ""
    text = item.content.get("text")
    return text if isinstance(text, str) else ""


async def _dashboard_snapshot(
    *,
    db: Store,
    manager: ConnectorRpcManager,
    runtime_state_cache: SessionRuntimeStateCache,
    user_id: str,
) -> dict[str, Any]:
    connectors = await db.list_connectors(user_id=user_id)
    projects = await db.list_projects(user_id=user_id)
    sessions = await db.list_session_inventory(user_id=user_id)
    sessions = await project_session_meta_for_dashboard(
        manager,
        runtime_state_cache,
        sessions,
    )
    notifications = await derive_dashboard_notifications(
        sessions,
        lambda session_id: _latest_assistant_text(db, session_id),
    )
    runtimes = await db.list_user_device_runtimes(user_id=user_id)
    return {
        "type": "dashboard.snapshot",
        "connectors": [
            connector.model_dump(mode="json")
            for connector in await with_effective_connector_statuses(
                manager,
                connectors,
            )
        ],
        "projects": [project.model_dump(mode="json") for project in projects],
        "sessions": [
            session.model_dump(mode="json")
            for session in sessions
        ],
        # Server-decided local-notification records (dedupe by id). APNs
        # later consumes the same derivation.
        "notifications": notifications,
        # Device pages render runtime lifecycle from this list, so a status
        # change reaches them without a manual refresh.
        "runtimes": [
            DeviceRuntimeView.model_validate(row).model_dump(
                mode="json",
                by_alias=True,
            )
            for row in runtimes
        ],
        "sessionPages": {
            "active": {
                "hasMore": False,
                "nextCursor": None,
            },
            "archived": {
                "hasMore": False,
                "nextCursor": None,
            },
        },
        "serverTime": utc_now(),
    }


async def _notification_payload(
    *,
    db: Store,
    manager: ConnectorRpcManager,
    runtime_state_cache: SessionRuntimeStateCache,
    user_id: str,
) -> dict[str, Any]:
    sessions = await db.list_session_inventory(user_id=user_id)
    sessions = await project_session_meta_for_dashboard(
        manager,
        runtime_state_cache,
        sessions,
    )
    notifications = await derive_dashboard_notifications(
        sessions,
        lambda session_id: _latest_assistant_text(db, session_id),
    )
    return {
        "notifications": notifications,
        # The background reader paints the keep-alive lifecycle from these
        # statuses; without them the client would need a second channel.
        "sessions": [session.model_dump(mode="json") for session in sessions],
        "serverTime": utc_now(),
    }


def _has_unseen(
    notifications: list[dict[str, Any]], known_ids: set[str]
) -> bool:
    """Whether the projection holds a record the caller has not seen."""

    return any(record["id"] not in known_ids for record in notifications)


@router.get("/notifications")
async def dashboard_notifications(
    user_id: str = Depends(current_user_id),
    db: Store = Depends(get_store),
    manager: ConnectorRpcManager = Depends(get_rpc),
    runtime_state_cache: SessionRuntimeStateCache = Depends(
        get_session_runtime_state_cache
    ),
    broker: TimelineBroker = Depends(get_timeline_broker),
    wait: int = Query(0, ge=0, le=25),
    known: str = Query(
        "",
        description="Comma-separated record ids the client already holds",
    ),
) -> dict[str, Any]:
    """Server-decided notification records, with optional long polling.

    ``wait`` holds the request open until a record the client has not seen
    (``known``) appears or the wait expires, then answers with the fresh
    projection (records + session statuses). Waiting on *unseen* records
    rather than on any dashboard event is what keeps the request rate at a
    couple per minute: a live turn emits dashboard events every second, and
    returning on those made the client re-request in a tight loop whenever an
    unread record stayed in the recent window. Unknown ids (an old client, an
    empty set) return immediately, as before. A cancelled request (app
    foregrounded, process gone) unregisters its queue on the way out.
    """

    # Bound the work a hostile or stale query can ask for; ids beyond the
    # newest 128 only lose dedupe for records the client would discard anyway.
    known_ids = {item for item in known.split(",")[-128:] if item}

    async def fresh_payload() -> dict[str, Any]:
        return await _notification_payload(
            db=db,
            manager=manager,
            runtime_state_cache=runtime_state_cache,
            user_id=user_id,
        )

    if wait <= 0:
        return await fresh_payload()

    # Register before the first read: a record derived while that read runs
    # must wake this request instead of waiting out the full timeout.
    queue = await broker.register_dashboard(user_id)
    try:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + wait
        payload = await fresh_payload()
        while not _has_unseen(payload["notifications"], known_ids):
            remaining = deadline - loop.time()
            if remaining <= 0:
                break
            try:
                await asyncio.wait_for(queue.get(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            payload = await fresh_payload()
    finally:
        await broker.unregister_dashboard(user_id, queue)
    return payload


@router.websocket("/ws")
async def dashboard_ws(
    websocket: WebSocket,
    db: Annotated[Store, Depends(get_store)],
    broker: Annotated[TimelineBroker, Depends(get_timeline_broker)],
    manager: Annotated[ConnectorRpcManager, Depends(get_rpc)],
    runtime_state_cache: Annotated[
        SessionRuntimeStateCache,
        Depends(get_session_runtime_state_cache),
    ],
    tickets: Annotated[ClientWsTicketManager, Depends(_get_ws_tickets)],
) -> None:
    ticket_value = websocket.query_params.get("ticket")
    if not isinstance(ticket_value, str) or not ticket_value:
        await websocket.close(code=1008, reason="missing ticket")
        return
    ticket = await tickets.consume_scope(ticket_value, scope="dashboard")
    if ticket is None:
        await websocket.close(code=1008, reason="invalid ticket")
        return

    await websocket.accept()
    await websocket.app.state.usage_recorder.touch_user(ticket.user_id)
    queue = await broker.register_dashboard(ticket.user_id)
    recovery_signal = broker.recovery_signal

    async def send_dashboard_updates() -> None:
        await websocket.send_json(
            await _dashboard_snapshot(
                db=db,
                manager=manager,
                runtime_state_cache=runtime_state_cache,
                user_id=ticket.user_id,
            )
        )
        while True:
            try:
                message = await asyncio.wait_for(queue.get(), timeout=15.0)
            except TimeoutError:
                await websocket.send_json(
                    {"type": "keepalive", "serverTime": utc_now()}
                )
                continue
            # A Dashboard invalidation requests a full current snapshot. Retain
            # only the newest queued request while a previous build/send ran.
            while not queue.empty():
                message = queue.get_nowait()
            try:
                invalidation = json.loads(message)
            except json.JSONDecodeError:
                continue
            if not isinstance(invalidation, dict):
                continue
            if invalidation.get("type") != "dashboard.changed":
                continue

            async def build_snapshot() -> str:
                snapshot = await _dashboard_snapshot(
                    db=db, manager=manager, runtime_state_cache=runtime_state_cache,
                    user_id=ticket.user_id,
                )
                return json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"), allow_nan=False)

            await websocket.send_text(await message.prepared(build_snapshot))

    try:
        await run_server_push_until_disconnect(
            websocket,
            send_dashboard_updates(),
            recovery_signal=recovery_signal,
        )
    finally:
        await broker.unregister_dashboard(ticket.user_id, queue)
