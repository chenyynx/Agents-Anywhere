from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass

import asyncer

from connector.logging import logger
from connector.runtime_protocol import (
    PreparedSessionTimelineSync,
    RuntimeConfig,
    RuntimeTimelineItem,
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
    _read_raw_transcript_scan,
    _sdk_session_metadata,
    _session_title,
    _string_attr,
    _timestamp_from_epoch,
    _without_maintenance_messages,
)
from connector.runtimes.claude.sessions.subagent_oracle import ClaudeSubagentOracle
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
    oracle: ClaudeSubagentOracle | None = None
    #: Tasks the live transport vouches for, per session (F2). See
    #: ``ClaudeSessionReader.live_task_ids``.
    live_task_ids: Callable[[ClaudeSession], frozenset[str]] | None = None

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
        # D-A (zombie-agent-card §9): the evidence sweep iterates the STORE's
        # sessions (``session_store.sessions()``), so a session this connector
        # has only ever read through history — never driven live — must have a
        # store entry or the sweep is blind to it and its stale cards never
        # close. The history read is the one path that knows the cwd and the
        # external id the oracle's probe needs.
        #
        # Adopt the entry only for a session that actually carries an Agent card
        # (see the gated call after ``items`` is computed): the sweep judges
        # cards, so a session with none has nothing to heal, and adopting every
        # history session would balloon the store and perturb the library
        # rotation's page accounting. A value the live transport already
        # authored stays authoritative (the G1 guard): ``ensure`` overwrites a
        # truthy field, so pass None for any value the store already holds.
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
            raw_scan=_read_raw_transcript_scan(session),
            oracle=self.oracle,
            live_task_ids=(
                self.live_task_ids(session) if self.live_task_ids else frozenset()
            ),
            # D-B (zombie-agent-card §9): an incremental pass is bounded by the
            # previous cursor, so a raw-only notice written after that cursor
            # must be admitted even though its (raw-file) anchor is a row the
            # SDK view already surfaced. A rebase / first sync covers the whole
            # transcript and passes None — no boundary, so the old gate holds.
            window_origin_uuid=(
                previous_cursor.last_message_uuid
                if not rebased and previous_cursor is not None
                else None
            ),
        )
        # D-A: adopt a store entry when this session carries an Agent card and
        # the store has none (or the entry is missing the cwd/external id the
        # oracle's probe needs). Cards only ever reach the store through the
        # live timeline-activity path, so a history-only session's card is
        # invisible to the sweep without this. Gated on "has an agent card" so
        # the store stays exactly as wide as the set the sweep must judge.
        self._adopt_store_entry_for_cards(
            session_id=session_id,
            external_session_id=external_session_id,
            session=session,
            items=items,
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

    def _adopt_store_entry_for_cards(
        self,
        *,
        session_id: str,
        external_session_id: str | None,
        session: ClaudeSession,
        items: tuple[RuntimeTimelineItem, ...],
    ) -> None:
        """Ensure a store entry exists for a session that carries an Agent card.

        D-A (zombie-agent-card §9): the 60s evidence sweep iterates
        ``session_store.sessions()``, and an Agent card only ever reaches the
        store through the live timeline-activity path — so a history-only
        session (never live-driven) has no store entry, its card is invisible
        to the sweep, and a stale card never closes. Adopt one here, carrying
        the very meta the oracle's probe needs (cwd + external id).

        Gated on "this session published an Agent card": a session with no such
        card has nothing the sweep can heal, and adopting every history session
        would widen the store (and perturb the library rotation's page
        accounting) for no benefit. A value the live transport already authored
        stays authoritative — ``ensure`` overwrites a truthy field, so only a
        MISSING one is filled (the G1 guard). ``ensure`` is a no-op on the
        idempotent repeat, so the adopt runs once per session that needs it.
        """

        if not any(_carries_agent_card(item) for item in items):
            return
        stored = self.session_store.get(session_id, external_session_id)
        self.session_store.ensure(
            session_id=session_id,
            external_session_id=(
                external_session_id
                if stored is None or not stored.external_session_id
                else None
            ),
            cwd=(session.cwd if stored is None or not stored.cwd else None),
            title=(session.title if stored is None or not stored.title else None),
            ordering_time=(
                session.ordering_time
                if stored is None or not stored.ordering_time
                else None
            ),
        )

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


def _carries_agent_card(item: RuntimeTimelineItem) -> bool:
    """Whether this published item is an Agent call card (kind == agent_call).

    Inlined rather than imported from ``timeline.messages`` to keep this
    history module free of a reader→timeline import edge: the predicate is one
    field and the shape is fixed by the protocol.
    """

    if item.type != "tool":
        return False
    content = item.content
    return isinstance(content, Mapping) and content.get("kind") == "agent_call"


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
