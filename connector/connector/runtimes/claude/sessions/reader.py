from __future__ import annotations

import hashlib
import json
import time
from collections.abc import Mapping
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Any

import asyncer

from connector.logging import logger
from connector.runtime_protocol import (
    AgentCallToolContent,
    RuntimeConfig,
    RuntimeTimelineItem,
    RuntimeTimelineSnapshot,
    SessionMeta,
    SessionState,
    timeline_content_hash,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.pending_messages import (
    ClaudeClientMessageBinding,
    ClaudeHistoryUserMessage,
    ClaudePendingClientMessageRegistry,
    attachment_echo_base_text,
)
from connector.runtimes.claude.domain.session import (
    ClaudeSession,
    stable_session_id,
)
from connector.runtimes.claude.history.cursor import (
    HISTORY_PROJECTION_VERSION,
    cursor_from_state,
)
from connector.runtimes.claude.history.state import history_cursor_key
from connector.runtimes.claude.sdk.client import SdkLoader, load_sdk
from connector.runtimes.claude.sdk.connection import (
    LEGACY_RECONCILE_PROMPT,
    RECONCILE_DONE_MARKER,
    RECONCILE_PROMPT,
)
from connector.runtimes.claude.sdk.history import (
    list_sdk_sessions,
    read_sdk_session_info,
    read_sdk_session_messages,
)
from connector.runtimes.claude.sdk.tasks import (
    ClaudeTaskEvent,
    task_event_from_notification_text,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore
from connector.runtimes.claude.timeline.agent_calls import (
    ClaudeAgentTaskOverlay,
    agent_task_overlay_for_event,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    ClaudePendingToolCall,
    is_compact_summary_text,
    is_hidden_tool_name,
    is_synthetic_control_message,
    is_task_notification_message,
    message_id,
    message_role,
    message_text,
    message_tool_blocks,
    synthesized_agent_call_content,
)

UNRESOLVED_LIVE_HISTORY_IMPORT_TTL_SECONDS = 120.0


@dataclass(slots=True)
class ClaudeSessionReader:
    config: RuntimeConfig
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    sdk_loader: SdkLoader | None
    sync_states: ClaudeSessionSyncStateStore
    pending_messages: ClaudePendingClientMessageRegistry

    async def list_sessions(
        self,
        limit: int = 100,
        cursor: str | None = None,
        force: bool = False,
    ) -> tuple[SessionMeta, ...]:
        local_sessions = self.session_store.list_sessions(limit=limit)
        history_sessions = await self._list_history_sessions(
            limit=limit,
            cursor=cursor,
            force=force,
        )
        history_sessions = _filter_history_sessions_for_unresolved_live_sessions(
            runtime_sessions=self.session_store.sessions(),
            local_sessions=local_sessions,
            history_sessions=history_sessions,
        )
        history_sessions = _filter_history_sessions_for_active_local_sessions(
            runtime_sessions=self.session_store.sessions(),
            history_sessions=history_sessions,
        )
        return _merge_session_metas(local_sessions, history_sessions)[:limit]

    async def get_session_state(
        self,
        session_id: str,
        external_session_id: str | None = None,
    ) -> SessionState | None:
        local_session = self.session_store.get(session_id, external_session_id)
        if local_session is not None:
            return SessionState(
                session_id=local_session.session_id,
                external_session_id=local_session.external_session_id,
                runtime="claude",
                status="idle",
                selections=local_session.selections,
                metadata={"source": "claude.session.local.state"},
            )
        if external_session_id is None:
            return None
        info = await self._read_history_session_info(external_session_id)
        if info is None:
            return None
        return SessionState(
            session_id=session_id,
            external_session_id=external_session_id,
            runtime="claude",
            status="idle",
            selections={},
            metadata={"source": "claude.session.history.state"},
        )

    async def get_session_snapshot(
        self,
        session_id: str,
        external_session_id: str | None = None,
        limit: int | None = None,
    ) -> RuntimeTimelineSnapshot:
        local_session = self.session_store.get(session_id, external_session_id)
        local_snapshot = self.session_store.snapshot(
            session_id=session_id,
            external_session_id=external_session_id,
            limit=limit,
        )
        if external_session_id is None:
            return local_snapshot

        history_snapshot = await self._history_snapshot(
            session_id=session_id,
            external_session_id=external_session_id,
            limit=limit,
        )
        if history_snapshot.items or local_session is None or not local_snapshot.items:
            return history_snapshot
        if local_snapshot.items:
            return local_snapshot
        return history_snapshot

    async def _list_history_sessions(
        self,
        limit: int,
        cursor: str | None,
        force: bool,
    ) -> tuple[SessionMeta, ...]:
        try:
            sdk = load_sdk(self.sdk_loader)
            sdk_sessions = await list_sdk_sessions(
                sdk,
                limit=limit,
                offset=_cursor_offset(cursor),
            )
        except Exception:  # noqa: BLE001
            logger.exception("Claude history session list failed")
            return ()

        metas: list[SessionMeta] = []
        for sdk_session in sdk_sessions:
            external_session_id = _string_attr(sdk_session, "session_id", "sessionId")
            if external_session_id is None:
                continue
            metas.append(
                await self._session_meta_from_sdk_session(
                    sdk_session,
                    external_session_id=external_session_id,
                    force=force,
                )
            )
        return tuple(metas)

    async def _session_meta_from_sdk_session(
        self,
        sdk_session: Any,
        *,
        external_session_id: str,
        force: bool,
    ) -> SessionMeta:
        session_id = stable_session_id(
            getattr(self.host, "session_namespace", self.host.connector_id),
            external_session_id,
        )
        title = _session_title(sdk_session)
        cwd = _string_attr(sdk_session, "cwd", "directory")
        ordering_time = _timestamp_from_epoch(
            _int_attr(sdk_session, "last_modified", "mtime", "updated_at")
            or _int_attr(sdk_session, "created_at")
        )
        sync_marker = _sync_marker(sdk_session)
        sync_key = _session_sync_key(external_session_id)
        previous_sync = await self.host.sync_state_read(sync_key)
        previous_marker = (
            previous_sync.get("marker") if isinstance(previous_sync, Mapping) else None
        )
        previous_cursor = cursor_from_state(
            await self.host.sync_state_read(history_cursor_key(external_session_id))
        )
        changed = force or previous_marker != sync_marker
        # A cursor written by an older projection cannot vouch for the current
        # projection's items — the terminal task fold is the first such change
        # — so its session must sync even when the transcript has not moved.
        # The rebuild writes the current version and this settles after one
        # pass: every later scan sees a current cursor again.
        projection_outdated = (
            previous_cursor is None
            or previous_cursor.projector_version != HISTORY_PROJECTION_VERSION
        )
        requires_timeline_sync = changed or projection_outdated
        sync_state = {
            "marker": sync_marker,
            "title": title,
            "cwd": cwd,
            "ordering_time": ordering_time,
            "session_id": session_id,
        }
        if requires_timeline_sync:
            self.sync_states.stage(
                external_session_id=external_session_id,
                sync_key=sync_key,
                state=sync_state,
            )
        return SessionMeta(
            session_id=session_id,
            external_session_id=external_session_id,
            runtime="claude",
            title=title,
            cwd=cwd,
            ordering_time=ordering_time,
            metadata={
                "source": "claude.session/list",
                "sync": {
                    "key": sync_key,
                    "marker": sync_marker,
                    "changed": changed,
                    "requires_timeline_sync": requires_timeline_sync,
                    "history_cursor_missing": previous_cursor is None,
                    "previous_marker": previous_marker,
                },
                "sdk": _sdk_session_metadata(sdk_session),
            },
        )

    async def _history_snapshot(
        self,
        session_id: str,
        external_session_id: str,
        limit: int | None,
    ) -> RuntimeTimelineSnapshot:
        try:
            sdk = load_sdk(self.sdk_loader)
            info = await read_sdk_session_info(
                sdk,
                session_id=external_session_id,
            )
            messages = await read_sdk_session_messages(
                sdk,
                session_id=external_session_id,
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude history snapshot failed external_session_id={}",
                external_session_id,
            )
            return RuntimeTimelineSnapshot(
                session_id=session_id,
                external_session_id=external_session_id,
                runtime="claude",
                items=(),
                complete=False,
                metadata={"source": "claude.session.history", "error": "read_failed"},
            )

        session = ClaudeSession(
            session_id=session_id,
            external_session_id=external_session_id,
            title=_session_title(info),
            cwd=_string_attr(info, "cwd", "directory"),
            ordering_time=_timestamp_from_epoch(
                _int_attr(info, "last_modified", "mtime", "updated_at")
                or _int_attr(info, "created_at")
            ),
        )
        visible_messages = _without_maintenance_messages(messages)
        # The whole chain is in scope here, same as a first sync or a rebase, so
        # pending sends match against the latest occurrences instead of
        # claiming uuids that older published turns already own.
        client_message_matches = await _match_history_client_messages(
            session=session,
            messages=visible_messages,
            pending_messages=self.pending_messages,
            prefer_latest=True,
        )
        items = await asyncer.asyncify(_history_items_from_messages)(
            session,
            visible_messages,
            client_message_matches=client_message_matches,
        )
        if limit is not None:
            items = items[-limit:] if limit > 0 else ()
        return RuntimeTimelineSnapshot(
            session_id=session_id,
            external_session_id=external_session_id,
            runtime="claude",
            items=items,
            complete=False,
            metadata={
                "source": "claude.session.history",
                "messageCount": len(messages),
                "sdk": _sdk_session_metadata(info),
            },
        )

    async def _read_history_session_info(self, external_session_id: str) -> Any | None:
        try:
            sdk = load_sdk(self.sdk_loader)
            return await read_sdk_session_info(sdk, session_id=external_session_id)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude history session state read failed external_session_id={}",
                external_session_id,
            )
            return None


def _history_items_from_messages(
    session: ClaudeSession,
    messages: tuple[Any, ...],
    client_message_matches: Mapping[str, ClaudeClientMessageBinding] | None = None,
    tool_call_lookup: Mapping[str, ClaudePendingToolCall] | None = None,
    hidden_tool_use_ids: frozenset[str] | None = None,
) -> tuple[RuntimeTimelineItem, ...]:
    projector = ClaudeMessageProjector(
        tool_call_lookup=tool_call_lookup,
        hidden_tool_use_ids=hidden_tool_use_ids,
    )
    notification_folds = _agent_task_notification_folds(
        session,
        messages,
        tool_call_lookup,
    )
    items: list[RuntimeTimelineItem] = []
    matches = client_message_matches or {}
    turn_seed: str | None = None
    turn_index = 0
    for index, message in enumerate(messages):
        role = message_role(message)
        text = message_text(message)
        native_id = message_id(message)
        synthetic_control = is_synthetic_control_message(message)
        if role == "user" and text and not synthetic_control:
            turn_index += 1
            turn_seed = native_id or f"{session.external_session_id}:{turn_index}"
        if turn_seed is None:
            turn_seed = native_id or f"{session.external_session_id}:initial"
        turn_id = _history_turn_id(session.external_session_id, turn_seed)
        items.extend(
            projector.tool_items_for_message(
                session=session,
                turn_id=turn_id,
                message=message,
            )
        )
        items.extend(
            projector.system_items_for_message(
                session=session,
                turn_id=turn_id,
                message=message,
                event="claude.history.system",
            )
        )
        client_message = matches.get(native_id or "")
        visible_text = client_message.text if client_message is not None else text
        if role == "user" and client_message is None and visible_text:
            attachment_base = attachment_echo_base_text(visible_text)
            if attachment_base is not None:
                visible_text = attachment_base
        if (
            synthetic_control
            or role not in {"user", "assistant", "system"}
            or (
                not visible_text
                and not (client_message is not None and client_message.attachments)
            )
        ):
            continue
        items.append(
            projector.message_item(
                session=session,
                turn_id=turn_id,
                role=role,
                text=visible_text,
                event=f"claude.history.{role}",
                native_item_id=native_id or f"history_{index}",
                item_id=(
                    client_message.platform_item_id
                    if client_message is not None
                    else None
                ),
                client_message_id=(
                    client_message.client_message_id
                    if client_message is not None
                    else None
                ),
                attachments=(
                    client_message.attachments if client_message is not None else ()
                ),
            )
        )
    items.extend(projector.missing_history_tool_result_items(session=session))
    # The folds come last so the dedupe merge below never lets the synthetic
    # "no tool result was recorded" row — minted for a dispatch whose receipt
    # has not been written yet — clobber the terminal overlay with its
    # boilerplate: last writer wins, and the notice is the last true writer.
    for index in sorted(notification_folds):
        fold = notification_folds[index]
        items.append(
            projector.fold_agent_task_event(
                session,
                tool_use_id=fold.tool_use_id,
                overlay=fold.overlay,
                status=fold.status,
                base=fold.base,
                turn_id=fold.turn_id,
            )
        )
    return _resequence_history_items(_dedupe_history_items(items))


@dataclass(frozen=True, slots=True)
class _AgentTaskNotificationFold:
    """One terminal fold an import window's notice will apply to its card."""

    tool_use_id: str
    overlay: ClaudeAgentTaskOverlay
    status: str | None
    base: AgentCallToolContent | None
    turn_id: str | None


def _agent_task_notification_folds(
    session: ClaudeSession,
    messages: tuple[Any, ...],
    tool_call_lookup: Mapping[str, ClaudePendingToolCall] | None,
) -> dict[int, _AgentTaskNotificationFold]:
    """Plan one terminal fold per background Agent card from the window.

    Terminal task frames never reach the transcript — only the live stream
    carries them — so a background task's completion survives as a plain
    ``<task-notification>`` user message. This scan turns those notices back
    into the same normalized event the live fold consumes, and the projection
    then closes the card the dispatch opened (import path, 2026-10-05: the
    ten stuck cards of session aba0a291 were all notices nobody folded).

    Only notices of Agent dispatches fold. A ``local_bash`` notice points at
    a Bash call and a resumed agent's notice at the SendMessage that resumed
    it — neither owns an Agent card. And a card whose last notice is followed
    by more child activity was resumed after that notice, so folding it would
    lie the card closed while its agent runs again: that notice is skipped
    and the next stop's notice closes the card.

    Returns the fold keyed by the notice's position in the window, or an
    empty mapping when the window has none.
    """

    lookup = dict(tool_call_lookup or {})
    notifications: dict[str, list[tuple[int, ClaudeTaskEvent]]] = {}
    last_activity: dict[str, int] = {}
    window_agent_tool_use_ids: set[str] = set()
    for index, message in enumerate(messages):
        # Child activity can hang off the message itself (a subagent frame the
        # SDK merged into the chain) or off a tool block (an orphaned result
        # that still names its call); either way the row belongs to that
        # call's card, and only the latest one counts per call.
        parent_tool_use_id = _string_attr(
            message, "parent_tool_use_id", "parentToolUseId"
        )
        if parent_tool_use_id is not None:
            last_activity[parent_tool_use_id] = index
        for block in message_tool_blocks(message):
            if block.parent_tool_use_id is not None:
                last_activity[block.parent_tool_use_id] = index
            if block.block_type == "tool_use" and block.tool_name == "Agent":
                window_agent_tool_use_ids.add(block.tool_use_id)
        if not is_task_notification_message(message):
            continue
        event = task_event_from_notification_text(
            message_text(message),
            timestamp_ms=_message_timestamp_ms(message),
        )
        if event is not None and event.tool_use_id is not None:
            notifications.setdefault(event.tool_use_id, []).append((index, event))

    folds: dict[int, _AgentTaskNotificationFold] = {}
    for tool_use_id, candidates in notifications.items():
        if not _is_agent_dispatch(
            tool_use_id,
            lookup,
            window_agent_tool_use_ids,
        ):
            continue
        # Resume rounds notify once per stop; the last notice carries the
        # final status, summary and usage, so it alone folds (an earlier one
        # would only be overwritten by these same fields).
        index, event = candidates[-1]
        activity = last_activity.get(tool_use_id)
        if activity is not None and activity >= index:
            logger.debug(
                "Claude history notification fold skipped for resumed agent "
                "tool_use_id={} notice_index={} activity_index={}",
                tool_use_id,
                index,
                activity,
            )
            continue
        call = lookup.get(tool_use_id)
        overlay, status = agent_task_overlay_for_event(event)
        folds[index] = _AgentTaskNotificationFold(
            tool_use_id=tool_use_id,
            overlay=overlay,
            status=status,
            base=(
                synthesized_agent_call_content(session, call)
                if call is not None
                else None
            ),
            turn_id=call.turn_id if call is not None else None,
        )
    return folds


def _is_agent_dispatch(
    tool_use_id: str,
    lookup: Mapping[str, ClaudePendingToolCall],
    window_agent_tool_use_ids: set[str],
) -> bool:
    """Whether the notice's id names an Agent dispatch that owns a card.

    The lookup covers the whole visible chain when the caller built one (the
    sync path), so it answers for dispatches that sit outside the window; a
    full-chain snapshot has no lookup and recognises its own dispatches from
    the messages alone.
    """

    call = lookup.get(tool_use_id)
    if call is not None:
        return call.block.tool_name == "Agent"
    return tool_use_id in window_agent_tool_use_ids


def _message_timestamp_ms(message: Any) -> int | None:
    """The transcript message's wall-clock time in epoch milliseconds.

    The SDK's top-level ``SessionMessage`` exposes no timestamp today (its
    conversion drops the transcript's ISO field; verified on 0.2.162/0.2.163),
    so this stays attribute-first: fixtures and any future SDK that carry it
    give the fold its ``endTime``; without one the fold omits it, exactly like
    the live notification frame, which carries no end time either.
    """

    value = _attr(message, "timestamp")
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        return int(value)
    if isinstance(value, str):
        try:
            # Python 3.11+ parses the transcript's trailing "Z" natively.
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return int(parsed.timestamp() * 1000)
    return None


def _without_maintenance_messages(messages: tuple[Any, ...]) -> tuple[Any, ...]:
    """Hide the internal CronList exchange when rebuilding a native transcript.

    The marker is the exact prompt persisted by Claude, so it also works after
    a connector restart without relying on in-memory response flags.
    """
    visible: list[Any] = []
    maintenance = False
    for message in messages:
        role = message_role(message)
        text = message_text(message)
        blocks = message_tool_blocks(message)
        if role == "user" and text is not None and text.strip() in {
            RECONCILE_PROMPT,
            LEGACY_RECONCILE_PROMPT,
        }:
            maintenance = True
            continue
        if maintenance:
            # A real user prompt or a native scheduled-task notification starts
            # a new turn. Tool results from CronList are not user prompts.
            if is_synthetic_control_message(message) or (
                role == "user" and text and not blocks
            ):
                maintenance = False
            elif role == "assistant" and not any(
                block.block_type == "tool_use" for block in blocks
            ):
                # Without the marker this may be a new scheduled reply, even
                # if the maintenance call had no visible final answer.
                maintenance = False
                if text is not None and text.strip() == RECONCILE_DONE_MARKER:
                    continue
            else:
                continue
        visible.append(message)
    return tuple(visible)


def _history_tool_call_context(
    session: ClaudeSession,
    messages: tuple[Any, ...],
) -> tuple[dict[str, ClaudePendingToolCall], frozenset[str]]:
    calls: dict[str, ClaudePendingToolCall] = {}
    hidden_tool_use_ids: set[str] = set()
    turn_seed: str | None = None
    turn_index = 0
    for message in messages:
        role = message_role(message)
        text = message_text(message)
        native_id = message_id(message)
        if role == "user" and text and not is_synthetic_control_message(message):
            turn_index += 1
            turn_seed = native_id or f"{session.external_session_id}:{turn_index}"
        if turn_seed is None:
            turn_seed = native_id or f"{session.external_session_id}:initial"
        turn_id = _history_turn_id(session.external_session_id, turn_seed)
        for block in message_tool_blocks(message):
            if block.block_type != "tool_use":
                continue
            if is_hidden_tool_name(block.tool_name):
                hidden_tool_use_ids.add(block.tool_use_id)
                continue
            calls[block.tool_use_id] = ClaudePendingToolCall(
                block=block,
                turn_id=turn_id,
            )
    return calls, frozenset(hidden_tool_use_ids)


async def _match_history_client_messages(
    *,
    session: ClaudeSession,
    messages: tuple[Any, ...],
    pending_messages: ClaudePendingClientMessageRegistry | None,
    prefer_latest: bool = True,
) -> dict[str, ClaudeClientMessageBinding]:
    if pending_messages is None or session.external_session_id is None:
        return {}
    user_messages = await asyncer.asyncify(_history_user_messages)(messages)
    return pending_messages.match_history_messages(
        session_id=session.session_id,
        external_session_id=session.external_session_id,
        messages=user_messages,
        prefer_latest=prefer_latest,
    )


def _history_user_messages(
    messages: tuple[Any, ...],
) -> tuple[ClaudeHistoryUserMessage, ...]:
    return tuple(
        ClaudeHistoryUserMessage(native_message_id=native_id, text=text)
        for message in messages
        for role in (message_role(message),)
        for native_id in (message_id(message),)
        for text in (message_text(message),)
        if (
            role == "user"
            and native_id is not None
            and text is not None
            and not is_synthetic_control_message(message)
        )
    )


def _resequence_history_items(
    items: tuple[RuntimeTimelineItem, ...],
) -> tuple[RuntimeTimelineItem, ...]:
    return tuple(replace(item, order_seq=index) for index, item in enumerate(items, 1))


def _dedupe_history_items(
    items: list[RuntimeTimelineItem],
) -> tuple[RuntimeTimelineItem, ...]:
    deduped: list[RuntimeTimelineItem] = []
    index_by_id: dict[str, int] = {}
    for item in items:
        existing_index = index_by_id.get(item.id)
        if existing_index is None:
            index_by_id[item.id] = len(deduped)
            deduped.append(item)
            continue
        deduped[existing_index] = _merge_duplicate_history_item(
            deduped[existing_index],
            item,
        )
    return tuple(deduped)


def _merge_duplicate_history_item(
    existing: RuntimeTimelineItem,
    incoming: RuntimeTimelineItem,
) -> RuntimeTimelineItem:
    if existing.type != "tool" or incoming.type != "tool":
        return incoming

    content = {**existing.content, **incoming.content}
    return replace(
        incoming,
        order_seq=existing.order_seq,
        content=content,
        content_hash=timeline_content_hash(
            item_type=incoming.type,  # type: ignore[arg-type]
            status=incoming.status,  # type: ignore[arg-type]
            role=incoming.role,  # type: ignore[arg-type]
            content=content,
        ),
    )


def _merge_session_metas(
    local_sessions: tuple[SessionMeta, ...],
    history_sessions: tuple[SessionMeta, ...],
) -> tuple[SessionMeta, ...]:
    merged: list[SessionMeta] = []
    index_by_session_id: dict[str, int] = {}
    index_by_external_id: dict[str, int] = {}
    for session in (*local_sessions, *history_sessions):
        existing_index = index_by_session_id.get(session.session_id)
        if existing_index is None and session.external_session_id is not None:
            existing_index = index_by_external_id.get(session.external_session_id)
        if existing_index is not None:
            merged[existing_index] = _merge_session_meta(
                merged[existing_index],
                session,
            )
            continue

        index_by_session_id[session.session_id] = len(merged)
        if session.external_session_id is not None:
            index_by_external_id[session.external_session_id] = len(merged)
        merged.append(session)
    return tuple(
        sorted(
            merged,
            key=lambda item: item.ordering_time or "",
            reverse=True,
        )
    )


def _filter_history_sessions_for_unresolved_live_sessions(
    *,
    runtime_sessions: tuple[ClaudeSession, ...],
    local_sessions: tuple[SessionMeta, ...],
    history_sessions: tuple[SessionMeta, ...],
) -> tuple[SessionMeta, ...]:
    barriers = _unresolved_live_session_barriers(runtime_sessions)
    if not barriers:
        return history_sessions

    local_session_ids = {session.session_id for session in local_sessions}
    local_external_session_ids = {
        session.external_session_id
        for session in local_sessions
        if session.external_session_id is not None
    }
    filtered: list[SessionMeta] = []
    for session in history_sessions:
        if _session_meta_source(session) != "claude.session/list":
            filtered.append(session)
            continue
        if session.session_id in local_session_ids:
            filtered.append(session)
            continue
        if (
            session.external_session_id is not None
            and session.external_session_id in local_external_session_ids
        ):
            filtered.append(session)

    return tuple(filtered)


def _filter_history_sessions_for_active_local_sessions(
    *,
    runtime_sessions: tuple[ClaudeSession, ...],
    history_sessions: tuple[SessionMeta, ...],
) -> tuple[SessionMeta, ...]:
    active_session_ids = {
        session.session_id
        for session in runtime_sessions
        if session.execution is not None
    }
    active_external_session_ids = {
        session.external_session_id
        for session in runtime_sessions
        if session.execution is not None and session.external_session_id is not None
    }
    if not active_session_ids and not active_external_session_ids:
        return history_sessions
    return tuple(
        session
        for session in history_sessions
        if session.session_id not in active_session_ids
        and session.external_session_id not in active_external_session_ids
    )


def _unresolved_live_session_barriers(
    sessions: tuple[ClaudeSession, ...],
) -> tuple[str, ...]:
    now = time.monotonic()
    barriers: list[str] = []
    for session in sessions:
        if session.external_session_id is not None:
            continue
        if session.execution is None:
            continue
        started_at = session.active_turn_started_at_monotonic
        if started_at is None:
            continue
        age = now - started_at
        if age > UNRESOLVED_LIVE_HISTORY_IMPORT_TTL_SECONDS:
            continue
        barriers.append(session.session_id)
    return tuple(barriers)


def _session_meta_source(session: SessionMeta) -> str:
    source = session.metadata.get("source")
    return str(source) if source is not None else "-"


def _merge_session_meta(primary: SessionMeta, secondary: SessionMeta) -> SessionMeta:
    metadata = dict(primary.metadata)
    secondary_metadata = dict(secondary.metadata)
    primary_sync = metadata.get("sync")
    secondary_sync = secondary_metadata.get("sync")
    if isinstance(primary_sync, Mapping) and isinstance(secondary_sync, Mapping):
        metadata["sync"] = {
            **primary_sync,
            "sources": _sync_sources(primary, secondary),
            "history": dict(secondary_sync)
            if secondary.metadata.get("source") == "claude.session/list"
            else primary_sync.get("history"),
            "requires_timeline_sync": (
                primary_sync.get("requires_timeline_sync") is True
                or secondary_sync.get("requires_timeline_sync") is True
            ),
            "changed": (
                primary_sync.get("changed") is True
                or secondary_sync.get("changed") is True
            ),
        }
    return SessionMeta(
        session_id=primary.session_id,
        external_session_id=primary.external_session_id
        or secondary.external_session_id,
        runtime=primary.runtime,
        title=primary.title or secondary.title,
        cwd=primary.cwd or secondary.cwd,
        ordering_time=max(
            primary.ordering_time or "",
            secondary.ordering_time or "",
        )
        or None,
        metadata=metadata,
    )


def _sync_sources(primary: SessionMeta, secondary: SessionMeta) -> tuple[str, ...]:
    sources: list[str] = []
    for session in (primary, secondary):
        source = session.metadata.get("source")
        if isinstance(source, str) and source not in sources:
            sources.append(source)
    return tuple(sources)


def _session_sync_key(external_session_id: str) -> str:
    return f"claude/session-sync/{external_session_id}"


def _cursor_offset(cursor: str | None) -> int:
    if cursor is None:
        return 0
    try:
        offset = int(cursor)
    except ValueError:
        return 0
    return max(offset, 0)


def _session_title(session: Any) -> str | None:
    # Claude SDK-created sessions may update `summary` to the latest user
    # prompt after every turn. `first_prompt` is the stable fallback title;
    # `custom_title` also contains persisted Claude Code AI titles when present.
    # A compaction restarts the chain from a summary prompt, so skip a
    # candidate that only carries that continuation text instead of showing it.
    for name in ("custom_title", "first_prompt", "summary", "title"):
        value = _string_attr(session, name)
        if value is not None and not is_compact_summary_text(value):
            return value
    return None


def _sync_marker(session: Any) -> str:
    payload = {
        "lastModified": _int_attr(session, "last_modified", "mtime", "updated_at"),
        "fileSize": _int_attr(session, "file_size"),
    }
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return "sha256:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _sdk_session_metadata(session: Any) -> dict[str, Any]:
    if session is None:
        return {}
    metadata: dict[str, Any] = {}
    for key in (
        "last_modified",
        "file_size",
        "created_at",
        "git_branch",
        "tag",
    ):
        value = _attr(session, key)
        if value is not None:
            metadata[key] = value
    return metadata


def _history_turn_id(
    external_session_id: str | None,
    turn_seed: str,
) -> str:
    digest = hashlib.sha256(
        f"{external_session_id or 'unknown'}:{turn_seed}".encode()
    ).hexdigest()[:24]
    return f"turn_claude_{digest}"


def _timestamp_from_epoch(value: int | None) -> str | None:
    if value is None:
        return None
    seconds = value / 1000 if value > 10_000_000_000 else value
    return datetime.fromtimestamp(seconds, tz=UTC).isoformat().replace("+00:00", "Z")


def _int_attr(item: Any, *names: str) -> int | None:
    for name in names:
        value = _attr(item, name)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            try:
                return int(value)
            except ValueError:
                continue
    return None


def _string_attr(item: Any, *names: str) -> str | None:
    for name in names:
        value = _attr(item, name)
        if isinstance(value, str) and value:
            return value
    return None


def _attr(item: Any, name: str) -> Any:
    if isinstance(item, Mapping):
        return item.get(name)
    return getattr(item, name, None)
