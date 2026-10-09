from __future__ import annotations

import hashlib
import json
import re
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Any, Self

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
    task_events_from_notification_text,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.subagent_oracle import (
    ClaudeSubagentOracle,
    RawTranscriptScan,
    claude_project_key,
    claude_projects_dir,
    participation_times_ms,
    raw_only_notices,
    scan_raw_transcript,
    scan_transcript_file,
    verified_dispatch_tasks,
)
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
    ClaudeAgentTaskOverlay,
    agent_task_overlay_for_event,
    agent_task_terminal_status,
    closure_rank,
    open_agent_task_ids,
    resolve_agent_card_status,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    ClaudePendingToolCall,
    ClaudeToolBlock,
    enrich_usage,
    is_compact_summary_text,
    is_hidden_tool_name,
    is_synthetic_control_message,
    is_task_notification_message,
    message_id,
    message_model,
    message_role,
    message_text,
    message_tool_blocks,
    message_usage,
    receipt_agent_id,
    synthesized_agent_call_content,
)

UNRESOLVED_LIVE_HISTORY_IMPORT_TTL_SECONDS = 120.0


class SessionListPage(tuple):
    """A `list_sessions` result that also says what it really read.

    A plain tuple subclass, so every consumer that already iterates, indexes,
    counts or unpacks these results is untouched — what changes is that an
    empty result can finally be *interpreted*. The library rotation sweep
    (task sheet §3 T1) walks the library one window per cycle and used to
    read "empty window" as "end of the library", which is two different
    things wearing the same value (R1 P1-2):

    * a window the SDK never returned, because the read raised — reported
      here as `read_failed`, so the ladder can skip and retry it later
      instead of ending the sweep on it;
    * a window whose sessions were all dropped by the live/active filters —
      reported here as `history_scanned` larger than the page length, so the
      ladder knows the library continues past it.

    `history_scanned` also carries the page-one seam: how many history
    sessions the first page actually exposed. Page 1 is merged with the
    local overlay and then truncated, so local-only sessions push the tail of
    `history[0:limit]` out of the page entirely; those displaced sessions are
    in no window either, which is a coverage hole the ladder starts after the
    seam instead of at a fixed page boundary.

    `page_one_complete` is the first page's own verdict that it covers the
    ENTIRE library (task sheet §3 T1b): the history list read whole (fewer
    rows than the page size, so the SDK hit the end of the list rather than a
    page boundary) with every session it named represented on the merged
    page. A library that small can never prove its end from a window — every
    window past the seam is legitimately empty and an empty window is not
    proof (R1 P1-2/P1-3) — so without this verdict the sweep would read one
    empty window per cycle forever. Only the first page can report it; a
    paged window always leaves it False.
    """

    # No `__slots__`: a variable-length builtin like tuple refuses them, and a
    # per-page dict costs nothing at one page per cycle.
    def __new__(
        cls,
        sessions: tuple[SessionMeta, ...] = (),
        *,
        history_scanned: int | None = None,
        read_failed: bool = False,
        page_one_complete: bool = False,
    ) -> Self:
        page = super().__new__(cls, sessions)
        page.history_scanned = (
            len(page) if history_scanned is None else history_scanned
        )
        page.read_failed = read_failed
        page.page_one_complete = page_one_complete
        return page

    def rescanned(self, sessions: tuple[SessionMeta, ...]) -> SessionListPage:
        """The same read's sessions after filtering/truncation, flags intact.

        This is also the protocol the re-pager in `runtime_protocol` looks for
        by name (R1c): a page type MAY expose a callable ``rescanned`` to say
        "here are my flags on a re-wrapped page", and one that does not is left
        as the plain tuple it always was. It is a protocol, not a method every
        runtime has to implement — `runtime_protocol` cannot import a runtime's
        reader, so the name is the whole contract."""

        return SessionListPage(
            sessions,
            history_scanned=self.history_scanned,
            read_failed=self.read_failed,
            page_one_complete=self.page_one_complete,
        )


@dataclass(slots=True)
class ClaudeSessionReader:
    config: RuntimeConfig
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    sdk_loader: SdkLoader | None
    sync_states: ClaudeSessionSyncStateStore
    pending_messages: ClaudePendingClientMessageRegistry
    oracle: ClaudeSubagentOracle | None = None
    #: Tasks the live transport vouches for, per session (F2). A session whose
    #: process the connector is actively driving must not have its cards closed
    #: by file staleness during a history rebuild — a long tool call writes
    #: nothing for a while. Wired to the runner at runtime assembly; None (e.g.
    #: in tests) means "nothing is live", so the staleness logic runs as before.
    live_task_ids: Callable[[ClaudeSession], frozenset[str]] | None = None

    async def list_sessions(
        self,
        limit: int = 100,
        cursor: str | None = None,
        force: bool = False,
    ) -> SessionListPage:
        # Kept separate from the filtered list below: the page's flags
        # describe the READ, and the filters must not erase them.
        history_page = await self._list_history_sessions(
            limit=limit,
            cursor=cursor,
            force=force,
        )
        history_sessions = _filter_history_sessions_for_unresolved_live_sessions(
            runtime_sessions=self.session_store.sessions(),
            local_sessions=self.session_store.list_sessions(limit=limit),
            history_sessions=history_page,
        )
        history_sessions = _filter_history_sessions_for_active_local_sessions(
            runtime_sessions=self.session_store.sessions(),
            history_sessions=history_sessions,
        )
        if cursor is not None:
            # A paged window — any explicit cursor, including 0, where the
            # ladder starts when page 1 displaced its whole exposed range
            # (T1b) — is the library-coverage window (the rotating scan that
            # reaches sessions beyond the first page). The local overlay is
            # liveness freshness and belongs to page 1, which is fetched
            # unchanged every cycle: merging it into a paged window would pull
            # page-1 sessions up and then `[:limit]` would cut the tail of the
            # window — dropping exactly the sessions a coverage sweep exists to
            # reach. A paged window is therefore the raw history window, still
            # guarded by the live/active filters above so an actively driven
            # session is never rebuilt behind the live writer.
            return history_page.rescanned(history_sessions[:limit])
        local_sessions = self.session_store.list_sessions(limit=limit)
        merged = _merge_session_metas(local_sessions, history_sessions)[:limit]
        # Page 1's seam: the merged prefix is sorted by ordering time, so the
        # history sessions that survived truncation are exactly a prefix of the
        # history list. Count them so the rotation ladder can start past them.
        return SessionListPage(
            merged,
            history_scanned=_history_seam_for_page_one(
                merged,
                local_sessions=local_sessions,
            ),
            # A failed history read must reach the page-1 result too: the
            # merged page then holds local-only sessions (or nothing), and
            # without this flag a seam of 0 would be indistinguishable from
            # "the whole exposed history was displaced" (T1b) — which starts
            # the ladder at a position the failed read never proved.
            read_failed=history_page.read_failed,
            page_one_complete=_page_one_covers_library(
                merged_page=merged,
                history_page=history_page,
                history_sessions=history_sessions,
                limit=limit,
            ),
        )

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
    ) -> SessionListPage:
        try:
            sdk = load_sdk(self.sdk_loader)
            sdk_sessions = await list_sdk_sessions(
                sdk,
                limit=limit,
                offset=_cursor_offset(cursor),
            )
        except Exception:  # noqa: BLE001
            # The read did not happen. Say so (R1 P1-2): returning a bare `()`
            # here is indistinguishable from an empty library, and a caller
            # that walks windows would read a failed read as "past the end".
            logger.exception("Claude history session list failed")
            return SessionListPage((), history_scanned=0, read_failed=True)

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
        # `history_scanned` is the count BEFORE the live/active filters below,
        # which is what makes "this window was emptied by filtering" visible —
        # and before the id-extraction skip above, which is what makes "the SDK
        # filled this window but not one row carried an id we can key on"
        # visible. Counting `metas` here reported the *survivors* of both
        # filters, so a window the SDK really filled could reach the ladder as
        # `history_scanned == 0`: byte-identical to "a clean read proved the
        # library ends here", with a hundred unreadable sessions sitting past
        # it (R1b R2-3).
        return SessionListPage(tuple(metas), history_scanned=len(sdk_sessions))

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
                    # Whether the stored cursor was produced by an older
                    # projection (or is missing entirely). This is the natural
                    # signal a projection version bump leaves behind, and the
                    # connector's library-scan rotation reads it to decide when
                    # old sessions need a rebuild pass.
                    "projection_outdated": projection_outdated,
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

        live_session = self.session_store.get(session_id, external_session_id)
        session = ClaudeSession(
            session_id=session_id,
            external_session_id=external_session_id,
            title=_session_title(info),
            cwd=_string_attr(info, "cwd", "directory"),
            ordering_time=_timestamp_from_epoch(
                _int_attr(info, "last_modified", "mtime", "updated_at")
                or _int_attr(info, "created_at")
            ),
            # The projection session must enrich usage exactly like the live
            # one: this snapshot's rows republish the same item ids the live
            # stream wrote (stable ids, last write wins), so without the
            # engine probe it would drop the calibrated `contextWindow` off
            # every settled row (live symptom, 2026-10-08).
            context_probe=(
                live_session.context_probe if live_session is not None else None
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
        raw_scan = _read_raw_transcript_scan(session)
        items = await asyncer.asyncify(_history_items_from_messages)(
            session,
            visible_messages,
            client_message_matches=client_message_matches,
            raw_scan=raw_scan,
            oracle=self.oracle,
            live_task_ids=self.live_task_ids(session) if self.live_task_ids else frozenset(),
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
    raw_lines: tuple[str, ...] = (),
    raw_scan: RawTranscriptScan | None = None,
    oracle: ClaudeSubagentOracle | None = None,
    live_task_ids: frozenset[str] = frozenset(),
) -> tuple[RuntimeTimelineItem, ...]:
    """Project one transcript window into timeline items.

    ``raw_lines`` (tests) and ``raw_scan`` (production, already cached) are
    alternative ways to supply the raw transcript facts; ``raw_scan`` wins when
    both are given.
    """

    projector = ClaudeMessageProjector(
        tool_call_lookup=tool_call_lookup,
        hidden_tool_use_ids=hidden_tool_use_ids,
    )
    if raw_scan is None and raw_lines:
        raw_scan = scan_raw_transcript(raw_lines)
    raw_notices = _raw_history_notices(messages, raw_scan)
    notification_folds = _agent_task_notification_folds(
        session,
        messages,
        tool_call_lookup,
        raw_notices=raw_notices,
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
                # The transcript's assistant message carries the per-call
                # usage; attaching it here makes a replayed item converge with
                # the live one, which published the same numbers under the same
                # stable id (the main chain's context stays measurable on old
                # sessions too). Non-assistant roles never carry usage. The
                # transcript's own `message.model` is the model fallback; the
                # session's engine probe, when it has landed, overrides it.
                usage=message_usage(message) if role == "assistant" else None,
                usage_model=message_model(message) if role == "assistant" else None,
            )
        )
    items.extend(projector.missing_history_tool_result_items(session=session))
    # The folds come last so the dedupe merge below never lets the synthetic
    # "no tool result was recorded" row — minted for a dispatch whose receipt
    # has not been written yet — clobber the terminal overlay with its
    # boilerplate: last writer wins, and the notice is the last true writer.
    for index in sorted(notification_folds):
        for fold in notification_folds[index]:
            items.extend(
                projector.fold_agent_task_items(
                    session,
                    tool_use_id=fold.tool_use_id,
                    overlay=fold.overlay,
                    status=fold.status,
                    base=fold.base,
                    turn_id=fold.turn_id,
                )
            )
    resequenced = _resequence_history_items(_dedupe_history_items(items))
    if oracle is None:
        return resequenced
    raw_participation = participation_times_ms(raw_scan) if raw_scan else {}
    return _apply_oracle_closures(
        session,
        resequenced,
        messages=messages,
        raw_notices=raw_notices,
        # R1 P1-1: the newest survival evidence, not the dispatch receipt alone.
        # A SendMessage resume leaves the receipt sitting at the original
        # dispatch, so anchoring there makes the history rebuild close a task
        # that was re-driven five minutes ago (the P9 false close the live
        # sweep already avoids). `participation_times_ms` is the live side's
        # own helper, so both sides now judge the same engine facts the same
        # way, and the anchor only ever moves newer — the conservative
        # direction for a ceiling.
        raw_receipt_times=raw_participation,
        # R1c R3-2: which of those anchors the scan can tie to a real dispatch
        # call. Only those keep the fold from overruling them with the message
        # view; a bare `tool_result` anchor (F5) is still an anchor, it just is
        # not the engine's word about which call it answered.
        verified_dispatch_roots=(
            verified_dispatch_tasks(raw_scan) if raw_scan else frozenset()
        ),
        # ...and the ceiling reads the raw transcript's own times, with no
        # message-view supplement at all: for a hard closure a newer mention
        # from free text is not a tie to be broken, it is the closure deferred.
        raw_ceiling_times=raw_participation,
        oracle=oracle,
        live_task_ids=live_task_ids,
    )


def _apply_oracle_closures(
    session: ClaudeSession,
    items: tuple[RuntimeTimelineItem, ...],
    *,
    messages: tuple[Any, ...],
    raw_notices: tuple[tuple[int, ClaudeTaskEvent], ...],
    raw_receipt_times: Mapping[str, int] | None = None,
    verified_dispatch_roots: frozenset[str] = frozenset(),
    raw_ceiling_times: Mapping[str, int] | None = None,
    oracle: ClaudeSubagentOracle,
    now_ms: int | None = None,
    live_task_ids: frozenset[str] = frozenset(),
) -> tuple[RuntimeTimelineItem, ...]:
    """Close every still-open card the engine can prove finished (R1/R2).

    The history fold is the last writer for a rebuild: it republishes each card
    with the state the transcript names. Where the transcript says nothing —
    a completion the SDK view dropped, or a task killed under the process — the
    card stays running, and this pass consults the subagent-transcript oracle to
    finish it. Only a justified closure is published; a card the oracle leaves
    running is returned untouched (idempotent with the history sync's own
    no-change comparison).
    """

    resolved_now_ms = now_ms if now_ms is not None else int(oracle.clock() * 1000)
    terminal_by_task = _history_terminal_events(messages, raw_notices)
    receipt_age_by_task = _history_receipt_ages(
        messages,
        now_ms=resolved_now_ms,
        raw_receipt_times=raw_receipt_times,
        verified_dispatch_roots=verified_dispatch_roots,
    )
    # R1c: the ceiling's anchor, from the raw transcript alone. The age above is
    # what the never-started grace and the F4 arbitration judge on; this is the
    # age the hard ceiling judges on, because for that rule a newer bogus anchor
    # is not a harmless tie — it defers the closure for as long as the session
    # keeps being written.
    ceiling_age_by_task = (
        {
            task_id: max((resolved_now_ms - time_ms) / 1000.0, 0.0)
            for task_id, time_ms in raw_ceiling_times.items()
        }
        if raw_ceiling_times is not None
        else None
    )
    closed: list[RuntimeTimelineItem] = []
    for item in items:
        content = item.content
        if item.type != "tool" or content.get("kind") != "agent_call":
            closed.append(item)
            continue
        already_terminal = item.status in AGENT_CARD_TERMINAL_STATUSES
        agents = content.get("agents")
        if not isinstance(agents, Mapping):
            closed.append(item)
            continue
        task_ids = tuple(
            str(agent_id)
            for agent_id in agents
            if isinstance(agent_id, str) and agent_id
        )
        if not task_ids:
            closed.append(item)
            continue
        if already_terminal:
            # A card the transcript already closed (a live/wire outcome) must
            # never be walked back by a file-staleness judgement; only a
            # terminal notice may annotate a closed card, and it does not
            # change the status. This is the provenance pass, not a closure.
            verdicts = {
                task_id: verdict
                for task_id, verdict in _card_oracle_verdicts(
                    oracle,
                    task_ids=task_ids,
                    session=session,
                    terminal_by_task=terminal_by_task,
                    receipt_age_by_task=receipt_age_by_task,
                    ceiling_age_by_task=ceiling_age_by_task,
                    now_ms=resolved_now_ms,
                    live_task_ids=live_task_ids,
                ).items()
                if verdict.closed_by == "terminalNotice"
            }
            if not verdicts:
                closed.append(item)
                continue
            best = _best_closure_verdict(verdicts)
            new_content = _evidence_closed_content(
                content,
                verdicts=verdicts,
                closed_by=best.closed_by,
                end_time_ms=best.end_time_ms,
            )
            new_status = item.status
        else:
            # A closure needs EVERY open task judged (F1/F6): a sibling the
            # oracle declines (a fresh file, a live task) keeps the whole card
            # open, so a running task is never hidden behind a dead sibling's
            # closure.
            open_task_ids = open_agent_task_ids(agents)
            if not open_task_ids:
                # Every entry is status-less or unknown while the card is not
                # terminal: nothing vouches for liveness, so judge the tasks
                # nothing else would settle instead of stranding the card (N3).
                # Entries that already name a terminal outcome are left out —
                # re-judging them from a file could only walk a finished task
                # backwards.
                open_task_ids = frozenset(
                    task_id
                    for task_id in task_ids
                    if agent_task_terminal_status(
                        _agent_entry_status(agents.get(task_id))
                    )
                    is None
                )
            if not open_task_ids or open_task_ids & live_task_ids:
                closed.append(item)
                continue
            verdicts = _card_oracle_verdicts(
                oracle,
                task_ids=tuple(open_task_ids),
                session=session,
                terminal_by_task=terminal_by_task,
                receipt_age_by_task=receipt_age_by_task,
                ceiling_age_by_task=ceiling_age_by_task,
                now_ms=resolved_now_ms,
                live_task_ids=live_task_ids,
            )
            if len(verdicts) != len(open_task_ids):
                closed.append(item)
                continue
            best = _best_closure_verdict(verdicts)
            if best is None:
                closed.append(item)
                continue
            new_content = _evidence_closed_content(
                content,
                verdicts=verdicts,
                closed_by=best.closed_by,
                end_time_ms=best.end_time_ms,
            )
            new_status = resolve_agent_card_status(item.status, best.closure_status)
        # Provenance rides flat on the content, exactly like the live fold's
        # own metadata (`closedByEvidence`/`endTime` are free JSON keys the
        # client reads beside `kind`), so a history rebuild and the live
        # projection publish one content shape. The per-task agents map is
        # rewritten too — judged tasks only — so a card judged finished stops
        # claiming `running` while an untouched sibling keeps its state.
        if new_status == item.status and dict(new_content) == dict(content):
            closed.append(item)
            continue
        closed.append(
            replace(
                item,
                status=new_status,
                content=new_content,
                content_hash=timeline_content_hash(
                    item_type="tool",
                    status=new_status,
                    role=item.role,
                    content=new_content,
                ),
            )
        )
    return tuple(closed)


def _card_oracle_verdicts(
    oracle: ClaudeSubagentOracle,
    *,
    task_ids: Sequence[str],
    session: ClaudeSession,
    terminal_by_task: Mapping[str, tuple[int | None, ClaudeTaskEvent]],
    receipt_age_by_task: Mapping[str, float],
    ceiling_age_by_task: Mapping[str, float] | None = None,
    now_ms: int | None = None,
    live_task_ids: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    """One evidence verdict per judged task; declined tasks are absent.

    ``live_task_ids`` are the tasks the live transport still vouches for (F2):
    they are never judged, so a card with a live task can never be closed by a
    stale sibling's verdict. A task in that set is `attached` as well — the
    connector is driving its process — so even its own file silence cannot
    close it (a terminal notice still can).

    ``ceiling_age_by_task`` is the age ceiling's own anchor (R1c): the one the
    raw transcript vouches for, without the free-text supplement the other two
    rules tolerate. A task it has no entry for gets no ceiling judgement rather
    than a borrowed one.
    """

    verdicts: dict[str, Any] = {}
    for task_id in sorted(task_ids):
        if task_id in live_task_ids:
            continue
        terminal = terminal_by_task.get(task_id)
        verdict = oracle.evidence(
            task_id=task_id,
            external_session_id=session.external_session_id,
            cwd=session.cwd,
            terminal_events=(terminal,) if terminal is not None else (),
            receipt_age_seconds=receipt_age_by_task.get(task_id),
            ceiling_age_seconds=(ceiling_age_by_task or {}).get(task_id),
            ceiling_anchored=ceiling_age_by_task is not None,
            attached_live=task_id in live_task_ids,
            now_ms=now_ms,
        )
        if verdict is not None:
            verdicts[task_id] = verdict
    return verdicts


def _best_closure_verdict(verdicts: Mapping[str, Any]) -> Any | None:
    if not verdicts:
        return None
    return max(
        verdicts.values(),
        key=lambda verdict: _closure_rank(
            (
                verdict.closure_status,
                verdict.closed_by,
                verdict.end_time_ms,
                None,
            )
        ),
    )


def _agent_entry_status(entry: Any) -> str | None:
    """The wire status of one agents-map entry, when it names one."""

    if not isinstance(entry, Mapping):
        return None
    status = entry.get("status")
    return status if isinstance(status, str) and status else None


def _evidence_closed_content(
    content: Mapping[str, Any],
    *,
    verdicts: Mapping[str, Any],
    closed_by: str,
    end_time_ms: int | None,
) -> dict[str, Any]:
    """Rewrite a history card's content for an evidence closure.

    Mirrors the live sweep's ``_apply_evidence_closure``: the judged tasks'
    agents entries carry their own closure status so the panel stops showing
    ``running``, while any *unjudged* sibling entry rides through untouched
    (F6). ``closedByEvidence``/``endTime`` ride flat beside ``kind``.
    """

    new_content = {**dict(content), "closedByEvidence": closed_by}
    if end_time_ms is not None:
        new_content["endTime"] = end_time_ms
    agents = content.get("agents")
    if isinstance(agents, Mapping):
        merged: dict[str, Any] = {
            agent_id: dict(entry) if isinstance(entry, Mapping) else entry
            for agent_id, entry in agents.items()
        }
        for task_id, verdict in verdicts.items():
            existing = merged.get(task_id)
            entry = dict(existing) if isinstance(existing, Mapping) else {}
            status = verdict.agent_status or verdict.closure_status
            if status is not None:
                entry["status"] = status
            merged[task_id] = entry
        new_content["agents"] = merged
    return new_content


def _history_terminal_events(
    messages: tuple[Any, ...],
    raw_notices: tuple[tuple[int, ClaudeTaskEvent], ...],
) -> dict[str, tuple[int | None, ClaudeTaskEvent]]:
    """The latest terminal notice per task id, SDK-visible and raw alike."""

    best: dict[str, tuple[int | None, ClaudeTaskEvent]] = {}

    def consider(task_id: str, time_ms: int | None, event: ClaudeTaskEvent) -> None:
        current = best.get(task_id)
        if current is None or (time_ms or -1) >= (current[0] or -1):
            best[task_id] = (time_ms, event)

    for message in messages:
        if not is_task_notification_message(message):
            continue
        time_ms = _message_timestamp_ms(message)
        for event in task_events_from_notification_text(
            message_text(message), timestamp_ms=time_ms
        ):
            consider(event.task_id, event.end_time, event)
    for _, event in raw_notices:
        consider(event.task_id, event.end_time, event)
    return best


_AGENT_ID_RE = re.compile(r"agentId:\s*([0-9a-zA-Z]+)")


def _history_receipt_ages(
    messages: tuple[Any, ...],
    *,
    now_ms: float,
    raw_receipt_times: Mapping[str, int] | None = None,
    verified_dispatch_roots: frozenset[str] = frozenset(),
) -> dict[str, float]:
    """The age (in seconds) of a task's newest agentId receipt in the transcript.

    The CLI writes the receipt — with the task's ``agentId`` — into the
    transcript when the Agent call is dispatched (an ``async_launched`` launch
    records the id immediately). Its wall-clock stamp is the closest thing the
    transcript has to a launch time, so the age of the newest such row feeds the
    never-started grace. ``now_ms`` is supplied by the caller (the oracle's own
    clock) so the age stays injectable.

    The raw transcript's receipt times are the primary source and the SDK
    message view is the supplement (F5): the SDK's messages carry no timestamps
    at all, so before this the age was unknowable and the never-started closure
    unreachable on real data.

    Who wins when both surfaces have an anchor is decided by PROVENANCE, not by
    order (R1c R3-2). A message is free text: an assistant can quote
    ``agentId: <task>`` in a sentence about an old run without the task being
    alive, and the fold used to take the newest mention per task, so one stray
    sentence re-stamped the clock of a task that died a day ago. R1b closed that
    by making the scanner absolute — which is one way too far, because the
    scanner's anchor is not always the better evidence. Where the raw file has
    only a bare ``tool_result`` (F5's shape, its call row trimmed away) nothing
    ties that anchor to a call, and a genuinely newer receipt in the message
    view was discarded in favour of a stale one: a task that launched five
    minutes ago was closed on a 26-hour-old echo.

    So a scanner anchor whose roots the scan verified against a real dispatch
    call keeps it — that is the engine's own word, and the rule R1b wanted. Any
    other scanner anchor yields to a strictly newer message-view receipt. Only
    *newer* mentions displace one, so this can move an anchor later (deferring a
    judgement, the direction that cannot lie about a live agent) and never
    manufacture an older launch.
    """

    newest_ms: dict[str, int] = {
        task_id: time_ms for task_id, time_ms in (raw_receipt_times or {}).items()
    }
    for message in messages:
        text = message_text(message)
        if not text or "agentId" not in text:
            continue
        time_ms = _message_timestamp_ms(message)
        if time_ms is None:
            continue
        for match in _AGENT_ID_RE.finditer(text):
            task_id = match.group(1)
            current = newest_ms.get(task_id)
            if current is not None and (
                task_id in verified_dispatch_roots or time_ms <= current
            ):
                # The scanner's own verified receipt, or nothing newer to say:
                # either way the anchor stands.
                continue
            newest_ms[task_id] = time_ms
    return {
        task_id: max((now_ms - time_ms) / 1000.0, 0.0)
        for task_id, time_ms in newest_ms.items()
    }


def _closure_rank(candidate: tuple[str, str, int | None, str | None]) -> tuple[int, int]:
    return closure_rank(candidate[0])


@dataclass(frozen=True, slots=True)
class _AgentTaskNotificationFold:
    """One final history-derived state for an Agent card in this window."""

    tool_use_id: str
    overlay: ClaudeAgentTaskOverlay
    status: str | None
    base: AgentCallToolContent | None
    turn_id: str | None


def _agent_task_notification_folds(
    session: ClaudeSession,
    messages: tuple[Any, ...],
    tool_call_lookup: Mapping[str, ClaudePendingToolCall] | None,
    *,
    raw_notices: tuple[tuple[int, ClaudeTaskEvent], ...] = (),
) -> dict[int, list[_AgentTaskNotificationFold]]:
    """Resolve transcript terminal/resume events through Agent task-id lineage.

    A terminal wrapper can point at the original Agent call, at a SendMessage
    that resumes it, or contain only one or more task ids after session teardown.
    The stable join is task id ↔ receipt agentId ↔ SendMessage input.to. Unknown
    or conflicting links fail closed; no id is guessed from summary text.

    ``raw_notices`` are terminal notices the SDK message view dropped (R1): the
    CLI persists some completions only as ``queue-operation`` rows, so they are
    read from the raw transcript and merged here at their true position. A task
    whose notice reached the fold from either surface closes the same way.
    """

    calls = dict(tool_call_lookup or {})
    window_calls, _ = _history_tool_call_context(session, messages)
    for tool_use_id, call in window_calls.items():
        existing = calls.get(tool_use_id)
        if existing is None or (
            existing.result_block is None and call.result_block is not None
        ):
            calls[tool_use_id] = call

    root_calls = {
        tool_use_id: call
        for tool_use_id, call in calls.items()
        if call.block.tool_name == "Agent"
    }
    task_roots: dict[str, set[str]] = {}
    for tool_use_id, call in root_calls.items():
        task_id = _agent_task_id_from_receipt(call)
        if task_id is not None:
            task_roots.setdefault(task_id, set()).add(tool_use_id)

    notices: list[tuple[int, ClaudeTaskEvent]] = list(raw_notices)
    send_messages: list[tuple[int, str, str]] = []
    child_activity: list[tuple[int, str]] = []
    for index, message in enumerate(messages):
        parent_tool_use_id = _string_attr(
            message, "parent_tool_use_id", "parentToolUseId"
        )
        if parent_tool_use_id is not None:
            child_activity.append((index, parent_tool_use_id))
        for block in message_tool_blocks(message):
            if block.parent_tool_use_id is not None:
                child_activity.append((index, block.parent_tool_use_id))
            if block.block_type == "tool_use" and block.tool_name == "SendMessage":
                target = _send_message_target(block)
                if target is not None:
                    send_messages.append((index, block.tool_use_id, target))
        if is_task_notification_message(message):
            notices.extend(
                (index, event)
                for event in task_events_from_notification_text(
                    message_text(message),
                    timestamp_ms=_message_timestamp_ms(message),
                )
            )

    # A directly-addressed Agent notice is also a valid task-id join when an
    # older/sidechain receipt did not carry an agentId. It must agree with any
    # receipt identity already present, otherwise the mapping is ambiguous.
    for _, event in notices:
        if event.tool_use_id is None:
            continue
        call = calls.get(event.tool_use_id)
        if call is None or call.block.tool_name != "Agent":
            continue
        receipt_task_id = _agent_task_id_from_receipt(call)
        if receipt_task_id is not None and receipt_task_id != event.task_id:
            logger.warning(
                "Claude history Agent task link conflicts with receipt "
                "tool_use_id={} notice_task_id={} receipt_task_id={}",
                event.tool_use_id,
                event.task_id,
                receipt_task_id,
            )
            continue
        task_roots.setdefault(event.task_id, set()).add(event.tool_use_id)

    # Map each SendMessage alias to its single unambiguous original Agent card.
    send_aliases: dict[str, set[str]] = {}
    for _, send_tool_use_id, task_id in send_messages:
        roots = task_roots.get(task_id, set())
        if len(roots) == 1:
            send_aliases.setdefault(task_id, set()).add(send_tool_use_id)

    task_activity: dict[str, list[int]] = {}
    for index, send_tool_use_id, task_id in send_messages:
        roots = task_roots.get(task_id, set())
        if len(roots) == 1 and send_tool_use_id in send_aliases.get(task_id, set()):
            task_activity.setdefault(task_id, []).append(index)

    # Activity rows from a resumed child can name either the original Agent
    # tool id or the SendMessage alias. Only unambiguous aliases count.
    tool_id_tasks: dict[str, set[str]] = {}
    for task_id, roots in task_roots.items():
        if len(roots) == 1:
            root_id = next(iter(roots))
            tool_id_tasks.setdefault(root_id, set()).add(task_id)
            for alias in send_aliases.get(task_id, set()):
                tool_id_tasks.setdefault(alias, set()).add(task_id)
    for index, parent_tool_use_id in child_activity:
        for task_id in tool_id_tasks.get(parent_tool_use_id, set()):
            task_activity.setdefault(task_id, []).append(index)

    terminal_events: dict[str, list[tuple[int, ClaudeTaskEvent]]] = {}
    for index, event in notices:
        task_id = event.task_id
        roots = task_roots.get(task_id, set())
        if len(roots) != 1:
            logger.debug(
                "Claude history notification has no unique Agent task link "
                "task_id={} roots={}",
                task_id,
                sorted(roots),
            )
            continue
        root_id = next(iter(roots))
        if event.tool_use_id is not None:
            pointed_call = calls.get(event.tool_use_id)
            # A tool id that resolves on the visible chain is a second address
            # to cross-check; one that does not (trimmed or sidechain calls,
            # other providers' id shapes) carries no addressable target and is
            # treated like a notice without a tool id — the task-id lineage
            # above is the join that folds it.
            if pointed_call is not None:
                if pointed_call.block.tool_name == "Agent":
                    if event.tool_use_id != root_id:
                        continue
                    receipt_task_id = _agent_task_id_from_receipt(pointed_call)
                    if receipt_task_id is not None and receipt_task_id != task_id:
                        continue
                elif pointed_call.block.tool_name == "SendMessage":
                    target = _send_message_target(pointed_call.block)
                    if target != task_id or event.tool_use_id not in send_aliases.get(task_id, set()):
                        continue
                else:
                    # A known Bash or other tool notification must never close an Agent.
                    continue
        terminal_events.setdefault(task_id, []).append((index, event))

    # For each task id, the last transcript signal wins: a later SendMessage
    # or child row reopens the task; a later terminal notice closes it again.
    latest_by_task: dict[str, tuple[int, ClaudeTaskEvent | None]] = {}
    for task_id, events in terminal_events.items():
        latest_by_task[task_id] = max(events, key=lambda item: item[0])
    for task_id, indices in task_activity.items():
        latest_activity = max(indices)
        terminal = latest_by_task.get(task_id)
        if terminal is None or latest_activity > terminal[0]:
            latest_by_task[task_id] = (latest_activity, None)

    states_by_root: dict[str, list[tuple[int, str, ClaudeTaskEvent | None]]] = {}
    for task_id, (index, event) in latest_by_task.items():
        roots = task_roots.get(task_id, set())
        if len(roots) != 1:
            continue
        root_id = next(iter(roots))
        states_by_root.setdefault(root_id, []).append((index, task_id, event))

    folds: dict[int, list[_AgentTaskNotificationFold]] = {}
    for root_id, states in states_by_root.items():
        call = root_calls.get(root_id)
        if call is None:
            continue
        overlay = ClaudeAgentTaskOverlay()
        statuses: list[tuple[int, str | None]] = []
        for index, task_id, event in sorted(states, key=lambda item: item[0]):
            normalized = event or ClaudeTaskEvent(
                kind="progress",
                task_id=task_id,
                status="running",
            )
            part, status = agent_task_overlay_for_event(normalized)
            overlay.merge(part)
            statuses.append((index, status))
        status = (
            "running"
            if any(state is None for _, _, state in states)
            else max(statuses, key=lambda item: item[0])[1]
        )
        index = max(state_index for state_index, _, _ in states)
        folds.setdefault(index, []).append(
            _AgentTaskNotificationFold(
                tool_use_id=root_id,
                overlay=overlay,
                status=status,
                base=synthesized_agent_call_content(session, call),
                turn_id=call.turn_id,
            )
        )
    return folds


def _read_raw_transcript_scan(session: ClaudeSession) -> RawTranscriptScan | None:
    """Scan this session's raw transcript JSONL, or ``None`` when unreadable.

    The SDK message view drops some persisted rows (R1); the raw file is where
    the dropped terminal notices — and the only launch timestamps (F5) —
    survive. The scan is cached by (path, size, mtime) so the settle sync's
    repeated reads of an unchanged file cost one dict lookup (F8).
    """

    if not session.cwd or not session.external_session_id:
        return None
    path = (
        claude_projects_dir()
        / claude_project_key(session.cwd)
        / f"{session.external_session_id}.jsonl"
    )
    try:
        return scan_transcript_file(path)
    except Exception:  # noqa: BLE001
        logger.exception(
            "Claude raw transcript read failed external_session_id={}",
            session.external_session_id,
        )
        return None


def _raw_history_notices(
    messages: tuple[Any, ...],
    scan: RawTranscriptScan | None,
) -> tuple[tuple[int, ClaudeTaskEvent], ...]:
    """Raw-only terminal notices the SDK view dropped, placed at their anchor.

    Empty ``scan`` (no raw transcript) means no raw notices — the fold then
    behaves exactly as before. A notice participates only when its raw-file
    anchor resolves inside this window (see ``raw_only_notices``); it is folded
    at the anchor's index so the window's own later signals still win.
    """

    if scan is None or not scan.notices:
        return ()
    sdk_uuid_order: dict[str, int] = {}
    for index, message in enumerate(messages):
        # Each notice's anchor is the raw transcript row's `uuid`. The SDK
        # message view exposes that uuid under `.uuid`, while `message_id`
        # prefers the nested Anthropic `message.id` — a *different* string on
        # assistant rows. Key BOTH id spaces, or every notice anchored on an
        # assistant row silently drops out of the fold (red-team P0: keying
        # `message_id` alone placed 0 of 41 real notices).
        for key in (message_id(message), getattr(message, "uuid", None)):
            if isinstance(key, str) and key and key not in sdk_uuid_order:
                sdk_uuid_order[key] = index
    try:
        return raw_only_notices(scan, sdk_uuid_order=sdk_uuid_order)
    except Exception:  # noqa: BLE001
        logger.exception("Claude raw transcript notification scan failed")
        return ()


def _send_message_target(block: ClaudeToolBlock) -> str | None:
    tool_input = block.tool_input
    if not isinstance(tool_input, Mapping):
        return None
    target = tool_input.get("to")
    return target if isinstance(target, str) and target else None


def _agent_task_id_from_receipt(call: ClaudePendingToolCall) -> str | None:
    receipt = call.result_block
    if receipt is None or receipt.block_type != "tool_result":
        return None
    return receipt_agent_id(receipt.tool_result_metadata, None)


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
    result_blocks: dict[str, ClaudeToolBlock] = {}
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
        # Carried onto the call block so a rebase from this lookup (a window
        # whose tool_use frame falls outside it) rebuilds the same tool rows
        # the full import minted — usage included — instead of stripping it.
        # Enriched exactly like the live tool rows, so a history rebuild and
        # the live projection publish one shape.
        usage = (
            enrich_usage(
                message_usage(message),
                model=message_model(message),
                probe=session.context_probe,
            )
            if role == "assistant"
            else None
        )
        for block in message_tool_blocks(message):
            if block.block_type == "tool_result":
                result_blocks[block.tool_use_id] = block
                continue
            if block.block_type != "tool_use":
                continue
            if is_hidden_tool_name(block.tool_name):
                hidden_tool_use_ids.add(block.tool_use_id)
                continue
            calls[block.tool_use_id] = ClaudePendingToolCall(
                block=(
                    replace(block, usage=usage)
                    if usage is not None
                    else block
                ),
                turn_id=turn_id,
            )
    for tool_use_id, result_block in result_blocks.items():
        pending = calls.get(tool_use_id)
        if pending is not None:
            calls[tool_use_id] = replace(pending, result_block=result_block)
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


def _history_seam_for_page_one(
    merged_page: tuple[SessionMeta, ...],
    *,
    local_sessions: tuple[SessionMeta, ...],
) -> int:
    """How many history sessions page 1 actually exposed (R1 P2-6).

    Page 1 is `(_merge(local, history))[:limit]`, and the merge sorts by
    ordering time, so the history entries that survived truncation are the
    first N of the history list. Every local-only session in the page pushes
    one history entry off the end, and those displaced entries are in no
    rotation window either — the sweep would step over them at every page
    boundary. The ladder therefore starts at the seam (the first index page 1
    did not expose) rather than at a fixed page multiple.

    An entry counts as history-derived when no local session carries its id:
    a session present in both was merged into one entry, which page 1
    already covers under its local identity, so counting it as covered is
    the conservative choice (the ladder may re-read it; it may not skip it).
    """

    if not local_sessions:
        return len(merged_page)
    local_ids = {
        identifier
        for session in local_sessions
        for identifier in (session.session_id, session.external_session_id)
        if identifier
    }
    return sum(
        1
        for session in merged_page
        if session.session_id not in local_ids
        and (
            session.external_session_id is None
            or session.external_session_id not in local_ids
        )
    )


def _page_one_covers_library(
    *,
    merged_page: tuple[SessionMeta, ...],
    history_page: SessionListPage,
    history_sessions: tuple[SessionMeta, ...],
    limit: int,
) -> bool:
    """Whether page 1 provably covers the entire library (T1b).

    The rotation ladder walks window after window until a read proves where
    the library ends. A library whose whole list fits inside the first page
    can never prove that from a window — every window past the seam is
    legitimately empty, and an empty window is not proof (R1 P1-2/P1-3) — so
    the sweep would read one empty window per cycle forever. The page that
    DOES cover such a library says so instead, on three conditions that
    together make the claim sound:

    * the history read succeeded (`read_failed` is False);
    * the SDK returned fewer rows than the page size, so this read reached
      the end of the list rather than a page boundary (a full window is
      unprovable either way: the library may be exactly one page, or longer
      — the residual the ladder still has to walk);
    * every row the read returned was keyed (a row without an id cannot be
      found on the page either) and every session this page would have
      compared is on the merged page, claimed by session id or external id
      — so a session merged with its local overlay counts as covered.

    The checked list is the FILTERED history list. Sessions the live/active
    filters dropped are excluded on purpose: a paged window applies the same
    filters, so the sweep could never rebuild them either, and their own
    sync paths (or page 1, once they settle) own them. Any session that was
    displaced off the merged page is still checked — none of the conditions
    above may be skipped, so the flag stays False exactly when the ladder
    still has something to walk.
    """

    if history_page.read_failed:
        return False
    if history_page.history_scanned >= limit:
        # The SDK filled the window: a full page is a page boundary, not the
        # end of the library.
        return False
    if len(history_page) != history_page.history_scanned:
        # Rows the reader could not key on are rows it cannot vouch for.
        return False
    covered = {
        identifier
        for session in merged_page
        for identifier in (session.session_id, session.external_session_id)
        if identifier
    }
    return all(
        session.session_id in covered
        or (
            session.external_session_id is not None
            and session.external_session_id in covered
        )
        for session in history_sessions
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
            # The local overlay never carries this flag; the history side does.
            # It must survive the merge exactly like the two above, or a session
            # that is both live and history-backed would hide its outdated
            # projection from the library sweep.
            "projection_outdated": (
                primary_sync.get("projection_outdated") is True
                or secondary_sync.get("projection_outdated") is True
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
