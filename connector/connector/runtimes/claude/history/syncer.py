from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass

import asyncer

from connector.logging import logger
from connector.runtime_protocol import (
    PreparedSessionTimelineSync,
    RuntimeConfig,
    RuntimeTimelineSnapshot,
    RuntimeUpstreamError,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.context_report import (
    ClaudeContextProbe,
)
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.history.cursor import cursor_for, messages_after_cursor
from connector.runtimes.claude.history.state import ClaudeHistoryCursorStore
from connector.runtimes.claude.sdk.client import SdkLoader, load_sdk
from connector.runtimes.claude.sdk.history import (
    read_sdk_session_info,
    read_sdk_session_messages,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    _history_tool_call_context,
    _match_history_client_messages,
    _sdk_session_metadata,
    _session_title,
    _string_attr,
    _timestamp_from_epoch,
    _without_maintenance_messages,
)
from connector.runtimes.claude.sessions.sync_state import (
    ClaudePendingSessionSync,
    ClaudeSessionSyncStateStore,
)


@dataclass(slots=True)
class ClaudeHistorySyncer:
    config: RuntimeConfig
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    sdk_loader: SdkLoader | None
    cursor_store: ClaudeHistoryCursorStore
    sync_states: ClaudeSessionSyncStateStore
    pending_messages: ClaudePendingClientMessageRegistry

    async def sync_session_timeline(
        self,
        session_id: str,
        external_session_id: str | None,
    ) -> bool:
        prepared = await self.prepare_session_timeline_sync(
            session_id,
            external_session_id,
        )
        if prepared is None:
            return False
        if prepared.snapshot is not None:
            snapshot = prepared.snapshot
            await self.host.timeline_sync(
                session_id=snapshot.session_id,
                runtime=snapshot.runtime,
                external_session_id=snapshot.external_session_id,
                items=snapshot.items,
                complete=snapshot.complete,
                metadata=snapshot.metadata,
            )
        if prepared.commit is not None:
            await prepared.commit()
        return True

    async def prepare_session_timeline_sync(
        self,
        session_id: str,
        external_session_id: str | None,
    ) -> PreparedSessionTimelineSync | None:
        if external_session_id is None:
            snapshot = self.session_store.snapshot(session_id=session_id)

            async def commit_local_snapshot() -> None:
                self.session_store.mark_synced(session_id)

            return PreparedSessionTimelineSync(
                snapshot=snapshot,
                commit=commit_local_snapshot,
            )
        pending_session_sync = self.sync_states.pending_for(external_session_id)

        local_session = self.session_store.get(session_id, external_session_id)
        if local_session is not None and local_session.active_turn_id is not None:
            logger.debug(
                "Claude history sync skipped active session session_id={} external_session_id={}",
                session_id,
                external_session_id,
            )
            return PreparedSessionTimelineSync(snapshot=None)
        if local_session is not None and (
            local_session.timeline_revision > local_session.synced_revision
        ):
            snapshot = self.session_store.snapshot(
                session_id=session_id,
                external_session_id=external_session_id,
            )

            async def commit_local_retry() -> None:
                self.session_store.mark_synced(session_id, external_session_id)

            return PreparedSessionTimelineSync(
                snapshot=snapshot,
                commit=commit_local_retry,
            )

        try:
            info, messages = await self._read_history(external_session_id)
        except Exception as exc:
            logger.exception(
                "Claude history sync failed external_session_id={}",
                external_session_id,
            )
            raise RuntimeUpstreamError(
                f"Claude history sync failed for session {external_session_id}"
            ) from exc

        cursor = cursor_for(info, messages)
        previous_cursor = await self.cursor_store.read(external_session_id)
        if previous_cursor == cursor:
            return PreparedSessionTimelineSync(
                snapshot=None,
                commit=self.session_sync_commit(pending_session_sync),
            )

        # The cursor classifies the window itself. A compaction rewrites the chain
        # and leaves the stored uuid dangling, so it rebases onto the whole
        # transcript, and so does the first sync of a session. Republishing every
        # item is idempotent (stable ids + server-side merge), and matching
        # pending client messages against the latest text keeps send order after a
        # rebuild.
        window = messages_after_cursor(messages, previous_cursor)
        sync_messages = window.messages
        rebased = window.rebased
        if rebased and previous_cursor is not None:
            logger.info(
                "Claude history cursor rebased after chain rewrite "
                "external_session_id={} reason={} previous_uuid={} "
                "previous_count={} count={}",
                external_session_id,
                window.reason,
                previous_cursor.last_message_uuid,
                previous_cursor.message_count,
                len(messages),
            )
        visible_messages = _without_maintenance_messages(messages)
        visible_ids = {id(message) for message in visible_messages}
        sync_messages = tuple(
            message for message in sync_messages if id(message) in visible_ids
        )
        live_session = self.session_store.get(session_id, external_session_id)
        session = _history_session(
            session_id,
            external_session_id,
            info,
            context_probe=(
                live_session.context_probe if live_session is not None else None
            ),
        )
        tool_call_lookup, hidden_tool_use_ids = await asyncer.asyncify(
            _history_tool_call_context
        )(
            session,
            visible_messages,
        )
        client_message_matches = await _match_history_client_messages(
            session=session,
            messages=sync_messages,
            pending_messages=self.pending_messages,
            prefer_latest=rebased,
        )
        items = await asyncer.asyncify(_history_items_from_messages)(
            session,
            sync_messages,
            client_message_matches=client_message_matches,
            tool_call_lookup=tool_call_lookup,
            hidden_tool_use_ids=hidden_tool_use_ids,
        )
        snapshot = RuntimeTimelineSnapshot(
            session_id=session_id,
            runtime="claude",
            external_session_id=external_session_id,
            items=items,
            complete=False,
            metadata={
                "source": "claude.history.sync",
                "messageCount": len(messages),
                "syncedMessageCount": len(sync_messages),
                "rebased": rebased,
                "sdk": _sdk_session_metadata(info),
            },
        )

        async def commit() -> None:
            # `cursor` describes the chain we just read, so a rebased sync lands
            # on the new tail and the next pass is incremental again.
            await self.cursor_store.write(external_session_id, cursor)
            if pending_session_sync is not None:
                await self.sync_states.commit(pending_session_sync)
            self.session_store.mark_synced(session_id, external_session_id)

        return PreparedSessionTimelineSync(snapshot=snapshot, commit=commit)

    def session_sync_commit(
        self,
        pending_session_sync: ClaudePendingSessionSync | None,
    ) -> Callable[[], Awaitable[None]] | None:
        if pending_session_sync is None:
            return None

        async def commit() -> None:
            await self.sync_states.commit(pending_session_sync)

        return commit

    async def _read_history(
        self,
        external_session_id: str,
        cwd: str | None = None,
    ) -> tuple[object | None, tuple[object, ...]]:
        sdk = load_sdk(self.sdk_loader)
        info = await read_sdk_session_info(
            sdk,
            session_id=external_session_id,
            directory=cwd,
        )
        messages = await read_sdk_session_messages(
            sdk,
            session_id=external_session_id,
            directory=cwd,
        )
        return info, messages


def _history_session(
    session_id: str,
    external_session_id: str,
    info: object | None,
    *,
    context_probe: ClaudeContextProbe | None = None,
) -> ClaudeSession:
    """The read-only projection session for one history rebuild.

    `context_probe` is the live session's engine report, carried over by the
    caller: this rebuild republishes the same item ids the live stream wrote
    (stable ids, last write wins), so a projection session without the probe
    would strip the calibrated `contextWindow` off every settled row — the
    client's context ring flashed during a turn and vanished at its settle
    (live symptom, 2026-10-08).
    """

    return ClaudeSession(
        session_id=session_id,
        external_session_id=external_session_id,
        title=_session_title(info),
        cwd=_string_attr(info, "cwd", "directory"),
        ordering_time=_timestamp_from_epoch(
            _sdk_session_metadata(info).get("last_modified")
        ),
        context_probe=context_probe,
    )
