from __future__ import annotations

import asyncio
import os
import secrets
import time
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, replace
from typing import Any, Literal

from connector.logging import logger
from connector.runtime_protocol import (
    RuntimeAttachment,
    RuntimeConfig,
    RuntimeTimelineItem,
    SessionNotice,
    timeline_content_hash,
)
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.catalogs.reader import ClaudeCatalogReader
from connector.runtimes.claude.domain.context_report import ClaudeContextProbe
from connector.runtimes.claude.domain.models import model_selection_from_selection_id
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
    client_message_text_matches,
)
from connector.runtimes.claude.domain.permissions import (
    permission_mode_from_selection_id,
)
from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.notifications.projector import (
    ClaudeNotificationProjector,
)
from connector.runtimes.claude.sdk.client import (
    ClaudeClientFactory,
    SdkLoader,
    client_supports_set_model,
    client_supports_set_permission_mode,
    connect_client,
    load_sdk,
    new_sdk_client,
    query_client,
    receive_response_messages,
    set_model_client,
    set_permission_mode_client,
)
from connector.runtimes.claude.sdk.connection import (
    ClaudeConnection,
    ClaudeResponse,
    _is_wire_chrome,
)
from connector.runtimes.claude.sdk.events import (
    ClaudeTerminalEvent,
    failed_terminal_event,
    interrupted_terminal_event,
    terminal_event_from_message,
)
from connector.runtimes.claude.sdk.settings import (
    create_gateway_settings_file,
    remove_gateway_settings_file,
)
from connector.runtimes.claude.sdk.stderr import ClaudeStderrBuffer
from connector.runtimes.claude.sdk.stop_affordance import (
    client_declares_per_task_stop,
    sdk_supports_stop_task,
)
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sdk.title_tool import build_change_title_tool
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.open_cards import ClaudeOpenAgentCards
from connector.runtimes.claude.sessions.reader import (
    _history_turn_id,
    scan_agent_call_cards,
)
from connector.runtimes.claude.sessions.scheduled import ClaudeScheduledSessions
from connector.runtimes.claude.sessions.subagent_oracle import (
    ClaudeSubagentOracle,
    RawTranscriptScan,
    participation_times_ms,
    subagent_token_usage,
)
from connector.runtimes.claude.timeline.agent_calls import (
    agent_task_overlay_for_event,
    agent_task_terminal_status,
)
from connector.runtimes.claude.timeline.markers import (
    ClaudeTimelineMarkers,
    claude_compact_event,
    is_compaction_control_message,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    is_synthetic_control_message,
    message_id,
    message_model,
    message_role,
    message_session_id,
    message_text,
    message_usage,
    stable_message_item_id,
    stable_tool_item_id,
    terminal_publish_superseded,
)
from connector.runtimes.claude.timeline.stream import (
    ClaudeStreamAccumulator,
    is_stream_event,
)
from connector.runtimes.claude.turns import context_probe
from connector.runtimes.claude.turns.attachments import (
    content_with_attachment_notes,
    materialize_claude_attachments,
)
from connector.runtimes.claude.turns.interactions import ClaudeInteractionController
from connector.runtimes.claude.turns.selections import SelectionApplyResult


def _turn_anchor_from_frame(frame: Any) -> str | None:
    """The transcript-stable id a live frame contributes as a turn anchor.

    This is the live half of the turn-id contract; history reads the same
    strings off the persisted rows (``reader._history_turn_ids``).

    * ``message_start`` stream event: ``event.message.id``. It is the first
      frame of the reply and already carries the id every persisted row of
      that API message shares, so even the partial rows published before the
      full ``assistant`` frame are keyed by the final id.
    * full assistant frame: ``message_id`` (prefers the Anthropic
      ``message.id``; the row uuid is the fallback).

    A user frame contributes nothing on purpose: a turn cast by an injected
    user frame (peer/channel message) has no AA user item, and history can
    only anchor such a turn on its first assistant row as well. Anything
    else has no anchor: the caller keeps the provisional id and binds on a
    later frame (see ``drive_turn``).
    """

    if frame is None:
        return None
    if is_stream_event(frame):
        event = getattr(frame, "event", None)
        if isinstance(event, Mapping):
            payload = event.get("message")
            if isinstance(payload, Mapping):
                value = payload.get("id")
                if isinstance(value, str) and value:
                    return value
        return None
    if message_role(frame) != "assistant":
        return None
    value = message_id(frame)
    return value if isinstance(value, str) and value else None


# The execution-lock circuit breaker (pp verdict, 2026-10-02, product-level):
# guarding a minted-from-silence turn is invariant-shaped, not trigger-shaped,
# so the deadline is a fixed budget any unknown wire shape falls into.
#
# This budget governs the ZERO-CONTENT class only (claude-watchdog-longrun-
# tasks.md §2 G1/G3). A turn that published a timeline item or consumed a
# non-chrome wire frame is a real long-running turn — the shape a subagent
# wake-up or a post-compaction resume takes — and the pure timer used to kill
# it at 30.002s regardless (production 17/17 firings), which retired the
# transport, killed the host CLI and every subagent in it, and lost the reply.
POLLED_TURN_WATCHDOG_SECONDS = 30.0

# The absolute ceiling for a turn that left the zero-content class. It exists
# so the content gate cannot become "long turns never settle" — the red line
# in §5 — and it is deliberately on the same magnitude as the CLI's own tool
# timeouts (Bash 600s, 420s; `idleTimeoutSeconds=600`). The longest tool this
# product has ever been observed running is 223.4s (AskUserQuestion), so the
# headroom is wide; the timing is measured from the cast, not from when the
# content showed up.
#
# STOPGAP (2026-10-09, pp-approved): raised 600.0 -> 1800.0. The 600s value
# was calibrated on the longest single TOOL, not on the longest work CYCLE:
# the autonomous wake-cycles (a subagent notification mints a turn) run
# 10-15 minutes of continuous productive work, so the 600s knife cut live
# turns mid-flight — 8 host-process kills in the week, 7 of them in the last
# 30 hours across live sessions (thinking-orb, alias-lineage, ...). 1800s
# keeps every observed real cycle inside the window while preserving the
# absolute bound. The root fix — progress arbitration (a contenting turn is
# killed on labour-frame STALL, not on absolute age) — is specced in
# `.local-dev/claude-watchdog-liveness-tasks.md` and replaces this number.
CONTENTING_TURN_WATCHDOG_SECONDS = 1800.0

# G4: why the breaker fired. The two values are the whole diagnosis of a
# watchdog log line, so they are named once and reused by the fire line, the
# retirement-skip line and the fatal-close line.
# F1: the `terminalReason` a turn carries when its `completed` was downgraded
# because the result could not be attributed to it. It reaches the client's turn
# ledger verbatim, so the condition is visible rather than silently rewritten.
STALE_COMPLETION_REASON = "unowned_result_no_content"

# Context-window calibration: how long the probe waits for a just-settled
# transport to hand its response back (`ClaudeConnection.wait_settled`). The
# reader clears `current` one event-loop step after a response that received
# its terminal is released, so the grace is scheduling slack, not a policy
# window; the ceiling only bounds a reader that stopped running. It is never
# paid while a turn is live, and never for an interrupted turn's response —
# that one keeps `current` until its late terminal arrives, which is not a
# settle the probe may wait for (a stop must not queue behind anything).
CONTEXT_PROBE_SETTLE_GRACE_SECONDS = 0.02
CONTEXT_PROBE_SETTLE_CEILING_SECONDS = 0.5

# Context-window calibration trigger: a low-frequency background sweep that
# probes every session whose transport is live and idle and whose current model
# selection has no cached window yet. The probe used to have only two triggers
# (a settled turn, a model-selection rebuild), so a connector restart left every
# session that ran no new turn with no window — the client's context ring had no
# denominator and stopped rendering at all (2026-10-08 incident). The sweep is
# the race-free shape: it never runs inside a turn's path, so it can never make a
# starting turn wait behind a probe, and `covers()` makes it self-limiting — at
# most one probe per (session, selection) until a window is learned, after which
# it is a near-no-op (one dict lookup per tick). A handful of seconds: long
# enough that a busy connector pays almost nothing, short enough that a freshly
# restarted connector repopulates a session's ring well inside the window a user
# would notice. A failed attempt backs off through `attempt_allowed`, so the
# sweep never spins a tight retry loop.
CONTEXT_PROBE_SWEEP_INTERVAL_SECONDS = 5.0

# R2: how often the engine-evidence agent-card sweep runs. The stop path and
# the connector-startup reconciliation cover the common cases; this periodic
# pass is the safety net for a task whose host process died while the connector
# stayed up, or a live fold that dropped the terminal frame — every open card of
# every known session is re-judged against the subagent transcripts. Sixty
# seconds is far below the 15-minute staleness deadline and cheap (a stat per
# open task), so a stranded card closes promptly without hammering the disk.
AGENT_CARD_EVIDENCE_SWEEP_INTERVAL_SECONDS = 60.0

# F1 (zombie-agent-card): the kill switch for the snapshot vouch. When on
# (default), the exemption set `live_agent_task_ids` vouches only for tasks
# present in BOTH the keep-alive register (`background.active_ids`) and the
# CLI's newest `background_tasks_changed` snapshot — a task the engine stopped
# listing loses its exemption and falls back to ordinary evidence judgement.
# `0`/`off` restores the byte-for-byte old behaviour: the register's full set
# vouches. Read per call so a test (or an operator) can flip it without a
# restart. The spec defines exactly those two off-spellings; any other value
# — garbage included — keeps the default on rather than silently honoring a
# typo as a kill switch.
LIVE_VOUCH_ENV: str = "AA_SUBAGENT_LIVE_VOUCH"


def _live_vouch_enabled() -> bool:
    """Whether the CLI snapshot co-signs the live-task exemption (F1)."""

    raw = os.environ.get(LIVE_VOUCH_ENV)
    if raw is None:
        return True
    return raw.strip().lower() not in {"0", "off"}


WATCHDOG_REASON_ZERO_CONTENT = "zero_content_fast_kill"
WATCHDOG_REASON_CONTENT_CEILING = "containing_turn_ceiling"

# G4's client-visible half (pp verdict, 2026-10-04, product-level —
# .local-dev/ratelimit-fatal-retirement-notice-order.md §2 A). A killed process
# needs its own code: `claude_scheduled_turn_timeout` reads "no result within
# N seconds", which the user takes as "the model was slow", while the truth is
# "the CLI process was terminated and every task running inside it ended". They
# retry nothing and rescue nothing, because nothing in the old text says work
# was lost.
#
# The disclosure is driven by the FACT that close() happened — never by the
# ledger slot — so the watchdog limiter may be spent or not and the message
# still reaches the user. `claude_scheduled_turn_timeout` keeps its own text and
# its own path: a turn that timed out WITHOUT a close is a different incident.
CLAUDE_PROCESS_RETIRED_CODE = "claude_process_retired"
CLAUDE_PROCESS_RETIRED_SOURCE = "claude.process.retired"

# Kept in the connector so a client that has not shipped the localized copy yet
# still shows something true rather than an empty or raw-JSON error.
PROCESS_RETIRED_MESSAGE = (
    "The Claude process was terminated after failing to respond. This turn "
    "produced no result and any running background tasks have ended. Please "
    "try again."
)
# close() raised: the kill was attempted but never confirmed. Downgraded, not
# silent — the turn is lost either way; only the certainty changed.
PROCESS_RETIRED_UNCONFIRMED_MESSAGE = (
    "The Claude process was terminated after failing to respond, but the "
    "shutdown could not be confirmed. This turn produced no result. Please "
    "try again."
)

# In-process selection change: the deferral disclosure
# (model-switch-in-process-tasks.md §3.1b). When a model / permission change
# cannot be applied to the live transport (no SDK seam, an effort change, or
# the `bypassPermissions` exception) AND that transport hosts live background
# work a rebuild would kill, the change is deferred until the work drains and
# the user is told rather than the change going silent.
#
# The notice id is stable per session so re-issuing the deferral for a second
# change (or the give-up disclosure below) updates the same row instead of
# stacking duplicates, and the resolve can retire it by id.
SELECTION_DEFERRED_SOURCE = "claude.selection.deferred"
SELECTION_DEFERRED_MESSAGE = (
    "有后台任务在跑。切换到「完全访问权限」将在任务结束后生效。"
)
SELECTION_RESTART_DEFERRED_MESSAGE = (
    "有后台任务在跑。本次切换将在任务结束后生效。"
)
# A neutral deferral disclosure for a change that could NOT be applied in place
# and is NOT (any longer) blocked by background work — the give-up path, whose
# reason may be the bounded-retry ceiling rather than live background. It names
# no cause (and, for the bypass case, no mode: the selection is already visible
# in the session UI), so it can never assert a reason that has stopped holding.
SELECTION_UNLANDED_MESSAGE = "切换尚未生效。会话空闲后将自动生效。"

# Why a deferral notice is being issued. The call site decides it from the
# LIVE fact at that moment, never a stale one (a drain can land between two
# checks): "background" = background work is live now; "unlanded" = it is not,
# the change is deferred for another reason (the retry ceiling).
SelectionDeferredCause = Literal["background", "unlanded"]

# In-process selection change: a transient refusal
# (model-switch-in-process-tasks.md §3.1, real-CLI probe 2026-10-15). The SDK
# answers `set_model` only after a 1-token `model_validation` probe against the
# API (15 s deadline); when that probe stalls the CLI refuses with
# `"Couldn't confirm model …" (retryable: true)`. The refusal is THEREFORE NOT
# the same fact as "this transport cannot take the change": rebuilding would
# kill the background work this whole change exists to protect, for a failure
# that a later attempt clears. So a retryable refusal keeps the session on the
# old selection, records the pending target, and retries at the next event
# (background drain, or the next turn) — bounded, event-driven, never a poll.
# Real-CLI evidence: 4 bounded attempts were enough to settle reliably.
SELECTION_IN_PROCESS_MAX_ATTEMPTS = 4
# Between two in-place attempts of a transiently-refused change. The refusal
# is time-bounded (~5 s, the CLI's own model-validation deadline), so a short
# spacing clears it in a couple of tries; the loop is bounded by the attempt
# ceiling, so this is a bounded backoff, not an idle poll.
SELECTION_IN_PROCESS_RETRY_DELAY_SECONDS = 2.0
SELECTION_PENDING_SOURCE = "claude.selection.pending"


@dataclass(slots=True)
class _PendingSelection:
    """One selection change whose in-place apply is still being retried.

    `attempts` counts the in-place attempts already spent; the ceiling
    (`SELECTION_IN_PROCESS_MAX_ATTEMPTS`) is what keeps the retry from
    becoming an unbounded loop. `target` is the selection the user asked for,
    retained so a retry applies the request even after `session.selections`
    moved on under a newer change.
    """

    target: dict[str, str | None]
    attempts: int = 0


def _selection_deferred_notice_id(session_id: str) -> str:
    return f"notice_claude_selection_deferred_{session_id}"


def _selection_deferred_notice(
    session: ClaudeSession,
    *,
    cause: SelectionDeferredCause,
    switching_bypass: bool,
) -> SessionNotice:
    # The message must state a reason that still holds. `cause="background"`
    # means background work is live RIGHT NOW (checked at the call site);
    # `cause="unlanded"` means it is not, so the neutral text is used instead —
    # claiming "有后台任务在跑" there would be a lie (the drain can land inside
    # the retry interval between the active-ids check and the give-up).
    if cause == "unlanded":
        message = SELECTION_UNLANDED_MESSAGE
    elif switching_bypass:
        message = SELECTION_DEFERRED_MESSAGE
    else:
        message = SELECTION_RESTART_DEFERRED_MESSAGE
    return SessionNotice(
        notice_id=_selection_deferred_notice_id(session.session_id),
        session_id=session.session_id,
        runtime="claude",
        type="notification",
        title="切换已延后",
        message=message,
        severity="info",
        status="open",
        source={
            "kind": "selection_deferred",
            "cause": cause,
            "bypass": switching_bypass,
            **(
                {"sessionId": session.external_session_id}
                if session.external_session_id
                else {}
            ),
        },
        context={"sessionId": session.session_id},
    )


def _resolved_selection_notice(session: ClaudeSession) -> SessionNotice:
    # This notice is NEVER RENDERED by any client: all four render
    # `type="notification"` notices only when `status == "open"`
    # (ios/.../Models/Chat/SessionNoticeStore.swift:25,
    # android/.../feature/sessiondetail/SessionRuntimeState.kt:157,
    # web-next/src/components/session-detail.tsx:2837,
    # desktop-workbench/renderer/src/components/session-detail.tsx:2817). Its
    # ONLY effect is to close the still-shown `status="open"` deferral card,
    # which it does by reusing that card's notice id (readers key by id and
    # drop terminal statuses). Do not spend effort polishing this title/message
    # — nobody sees it; keep it only so the terminal upsert is well-formed.
    return SessionNotice(
        notice_id=_selection_deferred_notice_id(session.session_id),
        session_id=session.session_id,
        runtime="claude",
        type="notification",
        title="切换已生效",
        message="会话现在使用新的设置。",
        severity="success",
        status="resolved",
        source={"kind": "selection_deferred"},
        context={"sessionId": session.session_id},
    )


def _raw_transcript_scan(session: ClaudeSession) -> RawTranscriptScan | None:
    """Scan this session's raw transcript for the evidence sweep (D2).

    Single entry point: delegates to the projector's own default seam
    (`messages._read_session_raw_scan`), which wraps the reader's memoized
    scanner — keyed by ``(path, size, mtime)`` — so repeating it every sweep
    against an unchanged transcript costs one dict lookup, and the sweep and
    the folds can never disagree about what the file says. A scan failure is
    never evidence — it returns ``None`` and the sweep proceeds with whatever
    else it has.
    """

    try:
        # Delayed import for the same cycle reason as the projector seam.
        from connector.runtimes.claude.timeline.messages import (
            _read_session_raw_scan,
        )

        return _read_session_raw_scan(session)
    except Exception:  # noqa: BLE001
        logger.exception(
            "Claude sweep raw transcript scan failed session_id={}",
            session.session_id,
        )
        return None


def _terminal_events_by_task(
    scan: RawTranscriptScan | None,
) -> dict[str, tuple[tuple[int | None, ClaudeTaskEvent], ...]]:
    """Group a raw transcript scan's notices by task id (D2).

    Only the engine's own notices survive in the raw file when the SDK
    message view drops them (red team F7: the live sweep never read any
    terminal notice). Every notice rides through in transcript order; the
    oracle filters them to terminal statuses and picks the newest itself.
    """

    grouped: dict[str, list[tuple[int | None, ClaudeTaskEvent]]] = {}
    for notice in scan.notices if scan is not None else ():
        grouped.setdefault(notice.event.task_id, []).append(
            (notice.timestamp_ms, notice.event)
        )
    return {task_id: tuple(events) for task_id, events in grouped.items()}


def _receipt_ages_by_task(
    scan: RawTranscriptScan | None,
    *,
    now_ms: int,
) -> dict[str, float]:
    """Age (seconds) of each task's newest *participation* evidence (D2, P9).

    The anchor is the newer of the dispatch receipt and the task's most recent
    SendMessage resume row (``participation_times_ms``): a resume relaunches
    the task, so the receipt alone would let a legitimate stop notice — it
    post-dates the dispatch — be attributed to the incarnation the transport
    is now driving (the P9 false closure on the real incident timeline).
    Same clamp as the history path's ``_history_receipt_ages``. A newer (closer)
    anchor is the conservative direction for every consumer: the F4 notice
    arbitration supersedes more readily (sparing live tasks), and the
    never-started grace judges later, so a resumed task is never mistaken for
    one that never launched.
    """

    if scan is None:
        return {}
    return {
        task_id: max((now_ms - time_ms) / 1000.0, 0.0)
        for task_id, time_ms in participation_times_ms(scan).items()
    }


@dataclass(slots=True)
class ClaudeTurnRunner:
    config: RuntimeConfig
    host: RuntimeHostClient
    session_store: ClaudeSessionStore
    timeline: ClaudeMessageProjector
    notifications: ClaudeNotificationProjector
    interactions: ClaudeInteractionController
    pending_messages: ClaudePendingClientMessageRegistry
    catalogs: ClaudeCatalogReader
    sdk_loader: SdkLoader | None = None
    client_factory: ClaudeClientFactory | None = None
    #: The subagent-transcript liveness oracle (R1/R2). Injectable so tests can
    #: drive the closure decision with a fake clock and fake files.
    oracle: ClaudeSubagentOracle | None = None
    #: The durable "sessions with open Agent cards" work list. The startup
    #: reconciliation reads it so a card stranded by a previous process is
    #: judged even in a session this connector never touches again.
    open_cards: ClaudeOpenAgentCards | None = None
    connections: dict[str, ClaudeConnection] = field(default_factory=dict, init=False)
    # Cron* bookkeeping handed over by a transport that was retired before its
    # replacement was built. `close()` drops the retired connection from
    # `connections`, so without this a breaker (or any failed turn) would
    # silently untrack a session's scheduled tasks.
    carried_task_ids: dict[str, set[str]] = field(default_factory=dict, init=False)
    # L2 subagent progress: task_started binds (session_id, task_id) to the
    # dispatch tool_use id — the double key verified against the wire (L2 A1
    # findings §2) — because task_updated carries no tool_use_id at all. In
    # memory only: task frames live and die with the transport that hosts the
    # work (findings §8.7 on the pipeline's own dedup).
    agent_task_calls: dict[tuple[str, str], str] = field(
        default_factory=dict, init=False
    )
    #: Lazy, cached probe of the loaded SDK's ``stop_task`` presence (the
    #: ``session.subagent_control`` supported fact). None until first read.
    _subagent_control_supported: bool | None = field(default=None, init=False)
    # B: terminal frames the start gate refused to settle this turn on. Read by
    # the post-deploy observation window alongside `ClaudeConnection
    # .absorbed_terminal_frames`: the two are the same leak seen at its two
    # entry points (the reader refusing to mint, the turn refusing to settle).
    foreign_terminal_frames: int = field(default=0, init=False)
    # F1/F6: turns whose `completed` was downgraded to `interrupted` because
    # they settled on a result they could not attribute. After the release
    # protocol this is the FALLBACK number: the turn declined the leftover and
    # kept reading, and nothing of its own ever arrived, so it settled on the
    # downgraded verdict instead. Zero in normal operation; non-zero means the
    # fix did not catch this one and the session is back to reporting "this
    # round produced nothing" — read it together with
    # `stale_terminal_recoveries`, which counts the ones it did catch.
    stale_completion_downgrades: int = field(default=0, init=False)
    # F1 release protocol: turns that met an unowned terminal, declined it,
    # kept reading, and DID get their own result behind it. This is the
    # "the reply reached the timeline in the turn that asked for it" counter —
    # the P1 shape being closed, not merely re-labelled. Its counterpart is
    # `stale_completion_downgrades`: recoveries + downgrades is every time the
    # gate saw an unowned terminal and settled the turn by one of the two
    # rules, so a falling downgrade count with a rising recovery count is the
    # fix working, and not a disappearing symptom.
    stale_terminal_recoveries: int = field(default=0, init=False)
    stopping: bool = False
    markers: ClaudeTimelineMarkers = field(init=False)
    scheduled_sessions: ClaudeScheduledSessions = field(init=False)
    #: The background context-window calibration sweep (see
    #: `CONTEXT_PROBE_SWEEP_INTERVAL_SECONDS`). None until `start_sweep`
    #: creates it, and cleared on `stop`; owned by the lifecycle, started and
    #: torn down with it.
    sweep_task: asyncio.Task[None] | None = field(default=None, init=False)
    #: R2 safety-net sweep (see `AGENT_CARD_EVIDENCE_SWEEP_INTERVAL_SECONDS`).
    #: None until `start_sweep` creates it, cleared on `stop`.
    agent_card_sweep_task: asyncio.Task[None] | None = field(
        default=None, init=False
    )
    #: Deferred selection-change landings (model-switch-in-process-tasks.md
    #: §3.1b): one background task per session, armed when a selection change
    #: could not be applied to the live transport because it still hosts
    #: background work. The task waits — event-driven — for that work to drain
    #: and then lands the change by rebuilding. Cancelled on `stop`.
    _selection_landing_tasks: dict[str, asyncio.Task[None]] = field(
        default_factory=dict, init=False
    )
    #: Selection changes whose in-place apply is still being retried, keyed by
    #: session. A transient refusal (the CLI's model-validation probe stalled,
    #: `retryable: true`) is NOT a capability failure: it is kept here and
    #: retried at the next event with a bounded attempt count, never by
    #: rebuilding the process under live background work.
    _pending_selections: dict[str, _PendingSelection] = field(
        default_factory=dict, init=False
    )

    def __post_init__(self) -> None:
        # One allocator for the whole timeline: a compaction separator must
        # never reuse an order_seq a projected message already published.
        self.markers = ClaudeTimelineMarkers(
            order_allocator=self.timeline.order_seq_for,
        )
        self.scheduled_sessions = ClaudeScheduledSessions(self.host)

    def start_sweep(self) -> None:
        """Start the periodic context-window calibration sweep.

        Idempotent, and a no-op once `stopping` is set, so the caller may arm
        it unconditionally at runtime start without racing `stop`.
        """
        if self.stopping or (
            self.sweep_task is not None and not self.sweep_task.done()
        ):
            return
        self.sweep_task = asyncio.create_task(self._context_probe_sweep())
        if self.oracle is not None and (
            self.agent_card_sweep_task is None
            or self.agent_card_sweep_task.done()
        ):
            self.agent_card_sweep_task = asyncio.create_task(
                self._agent_card_evidence_sweep()
            )

    async def stop(self) -> None:
        self.stopping = True
        sweep = self.sweep_task
        self.sweep_task = None
        card_sweep = self.agent_card_sweep_task
        self.agent_card_sweep_task = None
        if sweep is not None and not sweep.done():
            sweep.cancel()
            await asyncio.gather(sweep, return_exceptions=True)
        if card_sweep is not None and not card_sweep.done():
            card_sweep.cancel()
            await asyncio.gather(card_sweep, return_exceptions=True)
        landings = tuple(self._selection_landing_tasks.values())
        self._selection_landing_tasks.clear()
        for landing in landings:
            if not landing.done():
                landing.cancel()
        if landings:
            await asyncio.gather(*landings, return_exceptions=True)
        for connection in tuple(self.connections.values()):
            await connection.close()

    async def _agent_card_evidence_sweep(self) -> None:
        """Periodically close Agent cards the engine proves finished (R2).

        Separate from the startup reconciliation because a host process can die
        long after the connector came up: the periodic pass is the only thing
        that re-judges an open card whose terminal event never arrived. It runs
        every `AGENT_CARD_EVIDENCE_SWEEP_INTERVAL_SECONDS` and never touches the
        execution lock, so it cannot make a starting turn wait; one poisoned
        tick must not retire the sweep for the process's life.
        """

        while not self.stopping:
            try:
                await asyncio.sleep(AGENT_CARD_EVIDENCE_SWEEP_INTERVAL_SECONDS)
                if self.stopping:
                    return
                for session in self.session_store.sessions():
                    if self.stopping:
                        return
                    await self.sweep_agent_cards_by_evidence(session)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.exception("Claude agent-card evidence sweep tick failed")


    async def reconnect_sessions(self) -> None:
        """Resume only AA sessions previously observed to have scheduled tasks."""
        if self.stopping:
            return
        for session_id, saved in (await self.scheduled_sessions.read()).items():
            session = self.session_store.ensure(
                session_id=session_id,
                external_session_id=saved["externalSessionId"],
                cwd=saved["cwd"],
            )
            if session.execution is not None or session_id in self.connections:
                continue
            session.selections = dict(saved["selections"])
            try:
                connection = await self.connection_for(
                    session, ClaudeStderrBuffer(session.session_id)
                )
                connection.task_ids.update(saved["taskIds"])
                connection.queried.set()
                await connection.connect()
            except Exception as exc:  # noqa: BLE001
                await self.notifications.session_state.session_state_update(
                    session,
                    "error",
                    error={
                        "code": "claude_schedule_resume_failed",
                        "message": str(exc),
                    },
                    metadata={"source": "claude.scheduled.resume"},
                )

    async def scheduled_activity(
        self, session: ClaudeSession, response: ClaudeResponse
    ) -> None:
        async with session.execution_lock:
            if self.stopping:
                return
            if response.execution is not None:
                return
            session.queued_execution = session.execution
            # A user-less turn is anchored on its FIRST assistant message.
            # The reader stamps the frame that cast this turn before calling
            # here, and for the normal wire that frame is the reply's
            # ``message_start`` (or the full assistant frame on a resume that
            # joined mid-message): both expose the id every persisted row of
            # that message carries. If the cast frame is one that carries no
            # anchor, the turn keeps an opaque id and `drive_turn` binds it on
            # the first anchor-bearing frame instead.
            anchor = _turn_anchor_from_frame(response.cast_frame)
            execution = ClaudeExecution(
                turn_id=(
                    _history_turn_id(session.session_id, anchor)
                    if anchor is not None
                    else f"turn_claude_{secrets.token_urlsafe(12)}"
                )
            )
            session.execution = execution
            response.execution = execution
            try:
                await self.notifications.session_state.session_state_update(
                    session,
                    "running",
                    metadata={"source": "claude.scheduled.running"},
                )
                execution.task = asyncio.create_task(
                    self.drive_turn(
                        session,
                        execution,
                        "",
                        (),
                        None,
                        scheduled=True,
                        response=response,
                    )
                )
                self.arm_scheduled_watchdog(session, execution, response)
            except BaseException:
                self.disarm_scheduled_watchdog(execution)
                session.execution = session.queued_execution
                session.queued_execution = None
                execution.finished.set()
                raise

    def arm_scheduled_watchdog(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
    ) -> None:
        """Arm the execution-lock circuit breaker for one scheduled turn.

        This is the main defense against the ghost turn (pp verdict, 2026-10-02,
        product-level and highest priority). The trigger cannot be enumerated:
        a scheduled turn may be minted by any wire shape the connector reader
        has never seen before. What is invariant is what a stuck turn looks
        like: it holds `session.execution`, it never sees a terminal event, and
        it publishes nothing. After a silence deadline we force a failed
        terminal, release the lock and surface a one-line WARNING. The worst
        possible user experience is capped at one failed bubble instead of a
        session that is permanently running with the composer disabled.

        The deadline this used to apply unconditionally is now two-stage
        (§2 G1–G3 of claude-watchdog-longrun-tasks.md). The zero-content class
        keeps the original budget, so the P0 above is untouched; a turn that
        published items or consumed non-chrome frames leaves the fast kill and
        is only bounded by an absolute ceiling. Both counts exclude everything
        the queue held up to and including the cast frame — preamble flush +
        cast, by position, because passive arrival is not labour — so a
        re-cast's lone residue frame (B5: in-flight `tool_result`,
        StreamEvent), with or without stale preamble in front of it, still
        lands in the fast kill it had before B3a instead of buying the ghost
        ten minutes of held lock. The exemption is on the FAST KILL only — a
        long turn can never become "never settled".
        """

        execution.watchdog_task = asyncio.create_task(
            self._scheduled_watchdog(
                session,
                execution,
                response,
                POLLED_TURN_WATCHDOG_SECONDS,
            )
        )

    def disarm_scheduled_watchdog(self, execution: ClaudeExecution) -> None:
        task = execution.watchdog_task
        execution.watchdog_task = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()

    @staticmethod
    async def _await_watchdog_deadlines(
        execution: ClaudeExecution,
        timeout: float,
        ceiling: float,
    ) -> str | None:
        """Wait out both deadlines; return why the breaker has to fire.

        `None` means the turn settled on its own and there is nothing to do.

        The two deadlines are sequential rather than concurrent, which is what
        "absolute ceiling" means: the fast kill is measured from the cast, and
        the ceiling is a second wait covering only the time the first one left.
        A turn that produces content at t=1s is re-armed for the remaining
        570s; one that produces it at t=599s still has to settle by t=600s.
        """

        try:
            await asyncio.wait_for(execution.finished.wait(), timeout)
            return None
        except TimeoutError:
            pass
        if not execution.has_turn_content:
            return WATCHDOG_REASON_ZERO_CONTENT
        try:
            await asyncio.wait_for(
                execution.finished.wait(), max(0.0, ceiling - timeout)
            )
            return None
        except TimeoutError:
            return WATCHDOG_REASON_CONTENT_CEILING

    async def _scheduled_watchdog(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        timeout: float,
        ceiling: float | None = None,
    ) -> None:
        if ceiling is None:
            ceiling = CONTENTING_TURN_WATCHDOG_SECONDS
        reason = await self._await_watchdog_deadlines(execution, timeout, ceiling)
        if reason is None:
            return
        connection = response.connection
        active_tasks = len(connection.background.active_ids)
        logger.warning(
            "Claude scheduled turn watchdog fired reason={} "
            "published_items={} consumed_frames={} active_tasks={} "
            "no terminal within {}s (absolute ceiling {}s), "
            "forcing failed terminal session_id={} turn_id={}",
            reason,
            execution.published_items,
            execution.consumed_frames,
            active_tasks,
            timeout if reason == WATCHDOG_REASON_ZERO_CONTENT else ceiling,
            ceiling,
            session.session_id,
            execution.turn_id,
        )
        async with connection.stuck_report_lock:
            publish = connection.stuck_timeout_reports == 0
            if publish:
                # Reserve the single client-visible slot atomically (R2): a
                # watchdog firing concurrently must not double-report.
                connection.stuck_timeout_reports += 1

        async def release_reserved_slot() -> None:
            if publish:
                async with connection.stuck_report_lock:
                    connection.stuck_timeout_reports -= 1

        # The budget the turn actually ran out of. Named once because three
        # consumers depend on it agreeing: the failed terminal's text, the fire
        # line, and the process-retirement disclosure's `stuckSeconds`.
        stuck_budget = timeout if reason == WATCHDOG_REASON_ZERO_CONTENT else ceiling
        try:
            settled = await self.finish_execution(
                session=session,
                execution=execution,
                terminal=failed_terminal_event(
                    code="claude_scheduled_turn_timeout",
                    message=(
                        "Scheduled work did not report a result within "
                        f"{int(stuck_budget)}"
                        " seconds"
                    ),
                    reason="scheduled_watchdog_timeout",
                ),
                response=response,
                publish=publish,
            )
        except BaseException:
            # A publication that raised (host I/O) must not leak the reserved
            # slot: a later genuine timeout still has to reach the ledger (R3).
            await release_reserved_slot()
            raise
        if not settled:
            # The turn settled by itself inside the race window; its own exit
            # path already decided what happens to the transport. Release the
            # reserved slot so a later genuine timeout can still report.
            await release_reserved_slot()
            return
        await self.retire_stuck_transport(
            session,
            execution,
            response,
            reason=reason,
            client_reported=publish,
            stuck_seconds=stuck_budget,
        )

    async def retire_stuck_transport(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        response: ClaudeResponse,
        *,
        reason: str | None = None,
        client_reported: bool = True,
        stuck_seconds: float | None = None,
    ) -> None:
        """Retire everything the stuck turn left behind on its connection.

        Releasing `session.execution` is only half of the circuit breaker. The
        turn also owns the reader's `current` response, its own `drive_turn`
        task, and the transport they share — and each one outlives the release:

        * the zombie task keeps draining the reader's queue, so the next human
          message is answered into it and lost;
        * when a terminal finally arrives the zombie's `finish_execution`
          returns early on the flag this watchdog just set, so
          `response.release()` never runs and the reader parks on `released`
          forever.

        Left alone, the session looks unlocked while being permanently
        unusable, which is worse than the ghost it replaced. So the breaker
        finishes the job the turn could not: the response is already released
        by `finish_execution`, the zombie task is cancelled, and the transport
        is retired the same way any failed turn retires it — a native prompt
        cannot be retracted one turn at a time. The next turn rebuilds the
        connection from stored session state, which is the only recovery that
        does not depend on guessing what the CLI thought it was doing.

        The transport kill is withheld while `has_live_background_work` is
        true — background subagents/commands exist nowhere else, and upstream
        never replays in-flight work after process loss. The ghost response is
        dropped instead so the reader can route again.
        """

        connection = response.connection
        zombie = execution.task
        execution.task = None
        if zombie is not None and zombie is not asyncio.current_task():
            zombie.cancel()
        if connection.has_live_background_work:
            # Do-not-retire invariant (pp verdict, 2026-10-02, product-level):
            # the CLI process is the only place live background work exists.
            # Upstream keeps the transport for exactly this reason
            # (docs/claude-session-lifecycle.md: the connection is not
            # reclaimed while a background task is active, and in-flight
            # background work is not replayed after process loss). The breaker
            # has already released the lock through `finish_execution`; the
            # only action withheld here is killing the host process the
            # running subagents/commands live in. The zombie cancel above
            # still runs so the next human turn is not answered into it, and
            # the ghost response is dropped so the reader can route again.
            logger.warning(
                "Claude stuck-turn retirement skipped: background work is live "
                "session_id={} turn_id={} active_tasks={} published_items={} "
                "consumed_frames={}",
                session.session_id,
                execution.turn_id,
                len(connection.background.active_ids),
                execution.published_items,
                execution.consumed_frames,
            )
            connection.drop_current(response)
            return
        task_ids = set(connection.task_ids)
        if task_ids:
            self.carried_task_ids[session.session_id] = task_ids
            try:
                await self.scheduled_sessions.save(session, task_ids)
            except Exception as exc:  # noqa: BLE001
                logger.exception(
                    "Claude scheduled task handover failed session_id={}: {}",
                    session.session_id,
                    exc,
                )
        # G4: this is the only branch that kills the host CLI process, and with
        # it every subagent running inside that process. It is logged on its own
        # line, BEFORE the close, and deliberately outside the client-visible
        # limiter above: the limiter only decides whether the failed turn reaches
        # the ledger, but a process death is not a ledger event, and on 2026-10-03
        # 13:49 exactly this branch fired on a rate-limited watchdog
        # (`stuck_timeout_reports` already spent) and left no server-side trace
        # of a killed process anywhere. Server WARNING, not a ledger report.
        #
        # Snapshotted before the close so the disclosure below reports what was
        # in the process at the moment it was killed. It is 0 on the ordinary
        # path — the L1 gate above already returned when background work was
        # live — and non-zero only when the transport was failing or closing,
        # which is exactly when the user needs to be told work was cut.
        interrupted_background_tasks = len(connection.background.active_ids)
        logger.warning(
            "Claude stuck transport retirement is FATAL: closing the host CLI "
            "process and every subagent in it session_id={} turn_id={} "
            "reason={} published_items={} consumed_frames={} active_tasks=0 "
            "client_reported={}",
            session.session_id,
            execution.turn_id,
            reason,
            execution.published_items,
            execution.consumed_frames,
            client_reported,
        )
        try:
            await connection.close()
        except Exception as exc:  # noqa: BLE001
            logger.exception(
                "Claude stuck transport retirement failed session_id={}: {}",
                session.session_id,
                exc,
            )
            # Not confirmed, not silent: the turn is lost either way, and a
            # user who is told "still working" when the kill was attempted is
            # worse off than one told the truth.
            await self._disclose_process_retirement(
                session,
                stuck_seconds=stuck_seconds,
                interrupted_background_tasks=interrupted_background_tasks,
                confirmed=False,
            )
            return
        await self._disclose_process_retirement(
            session,
            stuck_seconds=stuck_seconds,
            interrupted_background_tasks=interrupted_background_tasks,
            confirmed=True,
        )

    async def _disclose_process_retirement(
        self,
        session: ClaudeSession,
        *,
        stuck_seconds: float | None,
        interrupted_background_tasks: int | None,
        confirmed: bool,
    ) -> None:
        """Tell the user the host process died, whatever the limiters decided.

        This sits outside every gate on the retirement path, and that is the
        whole point of it. `publish` decides whether a failed TURN reaches the
        ledger; `update_state` decides who owns the session status. Neither has
        anything to do with "the CLI process was just killed", and on
        2026-10-03 13:49 that gap produced a killed process whose only trace
        was a WARNING line no user will ever read. So this disclosure is driven
        by the close itself and therefore fires on every retirement: with the
        ledger slot spent or not, and for a queued execution that never owned
        the status (`update_state=False`).

        It is deliberately NOT reached when the L1 gate withholds the kill —
        `retire_stuck_transport` returns before the close, so nothing was
        retired and nothing is disclosed. A disclosure that fires when the
        process survived would teach users to distrust it.

        Failures are logged and swallowed: by the time this runs the turn is
        already settled and the process already dead, so a host I/O error must
        not escalate into a second incident on top of the first.
        """

        params: dict[str, Any] = {"retirementConfirmed": confirmed}
        if stuck_seconds is not None:
            params["stuckSeconds"] = int(stuck_seconds)
        if interrupted_background_tasks is not None:
            params["interruptedBackgroundTaskCount"] = interrupted_background_tasks
        try:
            await self.notifications.session_state.session_state_update(
                session,
                "error",
                error={
                    "code": CLAUDE_PROCESS_RETIRED_CODE,
                    "message": (
                        PROCESS_RETIRED_MESSAGE
                        if confirmed
                        else PROCESS_RETIRED_UNCONFIRMED_MESSAGE
                    ),
                    "params": params,
                },
                metadata={"source": CLAUDE_PROCESS_RETIRED_SOURCE},
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude process retirement disclosure failed session_id={}",
                session.session_id,
            )

    async def reclaim_idle_connection(
        self, session: ClaudeSession, connection: ClaudeConnection
    ) -> None:
        async with session.execution_lock:
            if (
                self.connections.get(session.session_id) is not connection
                or self.stopping
                or connection.closing
                or session.execution is not None
                or session.queued_execution is not None
                or connection.current is not None
                or connection.pending is not None
                or connection.task_ids
                or connection.background.active_ids
            ):
                return
            await connection.close()

    async def reconcile_after_background(
        self, session: ClaudeSession, connection: ClaudeConnection
    ) -> None:
        try:
            async with session.execution_lock:
                if (
                    self.stopping
                    or self.connections.get(session.session_id) is not connection
                    or connection.closing
                    or session.execution is not None
                    or connection.current is not None
                    or connection.pending is not None
                    or connection.background.active_ids
                    or not connection.reconcile_needed
                    or not connection.retained
                    or connection.reconciling
                ):
                    return
            # The SDK reader can discover a scheduled reply while this prompt is
            # queued. Its on_activity callback needs execution_lock to own that
            # reply, so never hold the lock across the SDK round trip.
            await connection.reconcile_tasks()
            async with session.execution_lock:
                if (
                    self.stopping
                    or self.connections.get(session.session_id) is not connection
                    or connection.closing
                ):
                    return
                await self.scheduled_sessions.save(session, connection.task_ids)
                connection.arm_idle()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude deferred task reconciliation failed session_id={}",
                session.session_id,
            )

    async def fold_agent_task_event(
        self,
        session: ClaudeSession,
        event: ClaudeTaskEvent,
    ) -> None:
        """Fold one CLI task event into its Agent call card (L2 progress).

        Aggregation is display state: it must never break the reader that
        routes the session's frames (the L1 lesson — nothing on this path may
        take a transport down), so every failure is logged and swallowed.

        `local_bash` tasks — including the background Bash a subagent itself
        runs — never surface: their tool ids point *inside* a subagent and
        there is no card to fold them into (L2 §3.4, findings §8.11).
        """

        try:
            key = (session.session_id, event.task_id)
            if event.kind == "started":
                # task_type exists only on task_started (the later frames
                # name the task, not its kind), so the local_bash filter runs
                # here and only a local_agent task is ever bound.
                if event.task_type != "local_agent" or event.tool_use_id is None:
                    return
                # The double key (findings §2): task_started.tool_use_id is
                # the dispatch call (== the card's metadata.toolUseId) and
                # task_id is the receipt agentId (== the card's agents-map
                # key). Binding here is what lets task_updated — which carries
                # no tool_use_id at all — find its card.
                self.agent_task_calls[key] = event.tool_use_id
            # Every non-started frame resolves through the binding alone —
            # never through its own tool_use_id, which for a local_bash task
            # points *inside* the subagent and would attach a Bash row to a
            # task that has no card (findings §8.11). An unbound task (its
            # task_started was filtered or missed) used to be silently
            # dropped here even when the card it belongs to exists.
            tool_use_id = self.agent_task_calls.get(key)
            if tool_use_id is None:
                # F3 (zombie-agent-card, binding gap): the exemption the
                # background register grants is wider than this binding —
                # observed() vouches on any task frame while only a
                # local_agent task_started *with* a tool_use_id ever binds —
                # so a terminal frame for a card whose binding was never
                # written (task_started missed, or filtered) used to vanish.
                # Reverse-lookup the card through its own agents map (the
                # task id is the key); a task with no card — local_bash and
                # friends — still returns nothing and stays unprojected.
                tool_use_id = self.timeline.tool_use_id_for_task(
                    session, event.task_id
                )
            if tool_use_id is None:
                return
            if (
                event.session_id is not None
                and session.external_session_id != event.session_id
            ):
                # The fold can run before the turn projection has adopted the
                # native session id (the reader and the turn consume the same
                # stream through different queues), and the card's stable item
                # id is scoped by that id — adopting it here too keeps the
                # event and the dispatch on one card instead of two.
                await self._update_external_session_id(session, event.session_id)
            overlay, status = agent_task_overlay_for_event(event)
            # The wire's single total_tokens is the last call's context, not
            # what the run consumed (2026-10-21). The task's transcript has the
            # real split; keep it current on every event (throttled inside) so
            # a RUNNING card shows ↑/↓ too, and force the final read at
            # closure.
            usage = subagent_token_usage(
                cwd=session.cwd,
                external_session_id=session.external_session_id,
                task_id=event.task_id,
                force=agent_task_terminal_status(event.status) is not None,
            )
            if usage:
                overlay.usage.update(usage)
            items = self.timeline.fold_agent_task_items(
                session,
                tool_use_id=tool_use_id,
                overlay=overlay,
                status=status,
            )
            for item in items:
                if self._publish_gate_skips(session, item):
                    # Idempotent closure (L2 §3.4): the terminal burst repeats
                    # itself — an identical card is not republished here — and
                    # the N1 time order refuses a terminal item no newer than
                    # the published one. The batch coalesce / server dedup /
                    # content-hash no-op behind this still catches anything
                    # that does reach it (findings §8.7). A sibling item is
                    # compared on its own, so an unchanged canonical never
                    # masks a sibling that moved (T1 B).
                    continue
                await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude task event folding failed session_id={} task_id={}",
                session.session_id,
                event.task_id,
            )

    async def publish_stopped_subagents(
        self,
        session: ClaudeSession,
        task_ids: Iterable[str],
        *,
        reason: str | None = None,
    ) -> int:
        """Tell the agent card, at the stop, which subagents the stop killed.

        P2-N1 (claude-stale-frame-turn-tasks.md §4/§11). The gap this closes is
        measured, not hypothetical: on 2026-10-04 12:18 the agent kept reporting
        "still running in the background" 20 s after the user hit stop, the
        client card did not flip for 4m41s, and the CLI's own notification for
        the same events came 4m43s late. The information was never missing — the
        CLI emits `task_notification` for every task it kills, and the L2 fold
        already binds `task_id -> card` — it simply arrived after anyone was
        still looking at the turn.

        So the connector stops waiting for it. A stop knows exactly which tasks
        it killed: `ClaudeBackgroundTasks.active_ids` is the live set on that
        transport, and every id in it is bound to a card by the L2 fold (killed
        tasks are 100% capturable — findings §8.7). Each is re-folded as the
        `task_updated`/killed event the CLI itself would have sent, which is the
        point: the same normalizer, the same overlay table
        (`AGENT_TASK_TERMINAL_STATUSES` maps killed -> interrupted), the same
        idempotent closure. The CLI's late notification then finds a card
        already in the state it would have set, and publishes nothing.

        Only ids the caller vouches for are folded, because that is the one
        guard this needs: a "killed" overlay on a card the CLI already closed
        as `done` would walk a finished card backwards. The caller reads the
        live set, so finished cards are never in it.

        Nothing here changes what a stop does — it only says what already
        happened, on a surface that is already there. A notification into the
        model's own context would mean sending a prompt to the process the user
        just killed, which is the one thing a stop must not do.
        """

        stopped = 0
        for task_id in task_ids:
            await self.fold_agent_task_event(
                session,
                ClaudeTaskEvent(
                    kind="updated",
                    task_id=task_id,
                    session_id=session.external_session_id,
                    status="killed",
                ),
            )
            stopped += 1
        if stopped:
            logger.warning(
                "Claude subagents reported stopped session_id={} tasks={} "
                "reason={}",
                session.session_id,
                stopped,
                reason,
            )
        return stopped

    def _publish_gate_skips(
        self,
        session: ClaudeSession,
        item: RuntimeTimelineItem,
    ) -> bool:
        """Whether this item must not be published over the current state (N1).

        One gate for both publication loops (the fold's and the sweep's), so
        the two can never disagree about what may land. Besides the exact
        no-op comparison, a terminal item that is not strictly newer than the
        already-published terminal state of the same id is dropped (red team
        P10): the sweep computes its items synchronously and publishes them
        across awaits, so its stale verdict could otherwise land after a
        fold's honest terminal and persist a divergence nothing re-judges —
        the next sweep's candidates treat a terminal published state as
        closing the id. ``terminal_publish_superseded`` holds the rule; this
        only pairs it with the record it must compare against.
        """

        previous = session.timeline_items.get(item.id)
        if previous is None:
            return False
        if (
            previous.status == item.status
            and dict(previous.content) == dict(item.content)
        ):
            return True
        return terminal_publish_superseded(item, previous)

    async def close_open_agent_cards(
        self,
        session: ClaudeSession,
        *,
        reason: str | None = None,
        evidence: bool = False,
    ) -> int:
        """Judge every open Agent card the stop left without a live task.

        The ghost fix (2026-10-05, `ghost-card-findings.md`): a dispatch
        aborted inside the "dispatch window" (the tool_use frame is out, the
        CLI never created the task) closes no card through task events — there
        is no task — and the one frame that could close it (the aborted
        call's tool_result) is discarded by the stop. So the stop itself is
        the last moment that can judge the card, and this is that judgment:
        open cards with no live agent entry fold to ``interrupted``.

        ``evidence=True`` switches to the R1/R2 judgment: instead of closing
        every open card, the subagent-transcript oracle decides each one from
        the engine's own files (a terminal notice the SDK view dropped, a task
        killed under the process, a never-started launch, a stale transcript).
        Only a card the oracle can justify closing is closed; anything it
        leaves running stays put. Used by the process-exit / restart /
        periodic sweeps, where a false close is worse than a slow one — the
        stop keeps the unconditional ghost closure above.

        Display only, and never the reason a stop fails: the projector sweep
        is pure state, and a failure here is logged and swallowed like every
        other fold on this path (the L1 lesson). Publication reuses the
        fold's own no-op comparison, so a re-run (or a card a task event
        already closed) publishes nothing.

        I-G2 is the safety valve: a card whose agents map still holds a live
        entry is skipped, and should the spared dispatch start after the
        sweep, the next task_started fold re-opens it (the fold clamp in
        `timeline.messages`). The sweep therefore cannot lie about a live
        agent, and cannot strand a dead card.

        G3 (`.local-dev/subagent-alias-durability-tasks.md`): the evidence
        pass also receives the session's raw terminal notices (D2) — the
        provenance the sweep never had — and reads them from the transcript's
        own file; the projector judges the published cards alongside the
        in-memory ones and treats `live_task_ids` as an attachment rather
        than a hard skip (D3), so a task the engine itself reported finished
        closes even while a transport still vouches for it, while file
        silence alone never touches it.
        """

        if evidence and self.oracle is None:
            # An evidence sweep without an oracle would fall back to the
            # unconditional stop-path closure — the opposite of what it asked
            # for. Decline instead of closing cards the engine never judged.
            return 0
        try:
            kwargs: dict[str, Any] = {}
            if evidence and self.oracle is not None:
                oracle = self.oracle
                clock = getattr(oracle, "clock", None)
                now_ms = (
                    int(clock() * 1000)
                    if callable(clock)
                    else int(time.time() * 1000)
                )
                scan = _raw_transcript_scan(session)
                kwargs = {
                    "oracle": oracle,
                    "attached_task_ids": self._attached_agent_task_ids(session),
                    "live_task_ids": self.live_agent_task_ids(session),
                    "terminal_events": _terminal_events_by_task(scan),
                    "receipt_ages": _receipt_ages_by_task(scan, now_ms=now_ms),
                    # A card stranded across a restart never re-enters the
                    # in-memory timeline, so the raw transcript is the only
                    # surface that still describes it (2026-10-21).
                    "scan_cards": scan_agent_call_cards(session, scan),
                    # Pin the sweep's "now" to the same instant the ages were
                    # computed against, so the grace and the file deadline
                    # judge one clock.
                    "now_ms": now_ms,
                }
            items = self.timeline.close_open_agent_cards(session, **kwargs)
            published = 0
            for item in items:
                if self._publish_gate_skips(session, item):
                    # The synchronous judgment above ran against the
                    # pre-await state; by the time this awaited publish runs
                    # a fold may have landed a newer terminal on the same id
                    # (N1), and this gate refuses to overwrite it.
                    continue
                await self.notifications.timeline_activity.timeline_item_upsert(item)
                published += 1
                if evidence:
                    # F1 release (zombie-agent-card): the closure just
                    # published, so the register's pin on these tasks is now
                    # provably stale — drop it or the exemption set (and with
                    # it arm_idle) stays wedged by ids whose terminal frame
                    # will never come. Only after a successful upsert, and
                    # only for judged evidence closures: the stop path's own
                    # semantics are untouched.
                    self._release_evidence_tasks(session, item)
            if published:
                logger.warning(
                    "Claude open subagent cards closed without a task "
                    "session_id={} cards={} reason={}",
                    session.session_id,
                    published,
                    reason,
                )
            return published
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude open-agent-card sweep failed session_id={}",
                session.session_id,
            )
            return 0

    def _release_evidence_tasks(
        self,
        session: ClaudeSession,
        item: RuntimeTimelineItem,
    ) -> None:
        """Release the closed card's task ids from the keep-alive register.

        The item just published is an evidence closure: every open task on
        that card was judged terminal by the oracle, so any id still sitting
        in ``background.active_ids`` for one of them is the stale pin this
        batch exists to lift (zombie-agent-card §0 — a terminal frame the
        resume/notification gap swallowed never discards it, and the pinned
        id then keeps both the exemption set and arm_idle wedged forever).
        The agents map is keyed by task id; ids absent from the register
        discard as a no-op, and a missing connection (session already
        detached) simply skips — releasing is a bonus, never a dependency.
        """

        raw_agents = item.content.get("agents")
        if not isinstance(raw_agents, Mapping):
            return
        connection = self.connections.get(session.session_id)
        if connection is None:
            return
        for task_id in raw_agents:
            if isinstance(task_id, str) and task_id:
                connection.background.release(task_id)

    def live_agent_task_ids(self, session: ClaudeSession) -> frozenset[str]:
        """Tasks the live transport vouches for (the F2 provider, F1 filtered).

        A connection that is alive and not closing is the qualification; the
        task set itself is now the intersection of two registers (F1,
        zombie-agent-card):

        * ``background.active_ids`` — the transport's keep-alive register.
          Still deliberately NOT gated on ``session.execution`` (a background
          subagent runs while the main session sits idle) and never
          ``connection.task_ids`` (the broader reconciliation set that
          retains finished ids);
        * ``background.last_snapshot_ids`` — the CLI's own newest snapshot of
          outstanding work, when one has been seen. The register only ever
          loses an id to a live terminal frame, so a task whose terminal the
          resume/notification gap swallowed stays pinned there forever and
          used to blind every evidence closure behind this exemption. The
          snapshot is the engine's stronger liveness word: a task it no
          longer lists loses the exemption and falls back to ordinary
          evidence judgement. When no snapshot has ever arrived
          (``last_snapshot_ids is None`` — a fresh connection, or the env
          kill switch ``AA_SUBAGENT_LIVE_VOUCH`` = ``0``/``off``), this
          returns the full register set: byte-for-byte the old, conservative
          behaviour.

        The snapshot never edits the register — keep-alive bookkeeping
        (arm_idle, drain waits) keeps its own semantics; only this exemption
        consumer narrows. A card closed from evidence then *releases* its
        task ids (``background.release``) so the pin cannot outlive the
        judgement.

        Wired to the reader/syncer as their ``live_task_ids`` provider so a
        history rebuild never closes a card whose task the transport still
        vouches for (red team F2), and used directly by the sweeps.
        """

        connection = self.connections.get(session.session_id)
        if connection is None or connection.closing:
            return frozenset()
        background = connection.background
        active = frozenset(background.active_ids)
        if not _live_vouch_enabled():
            return active
        snapshot = background.last_snapshot_ids
        if snapshot is None:
            return active
        return active & snapshot

    def _attached_agent_task_ids(self, session: ClaudeSession) -> frozenset[str]:
        """The ``attached`` set the oracle exempts from the file-staleness closure.

        Identical to ``live_agent_task_ids`` by design: while this connector is
        driving the process, a long tool call writing nothing for a while must
        not be mistaken for death. A terminal notice still closes these tasks.
        """

        return self.live_agent_task_ids(session)

    async def sweep_agent_cards_by_evidence(
        self,
        session: ClaudeSession,
    ) -> int:
        """Run the evidence-only closure sweep for one session (R2).

        Called on process exit, reconnect, and periodic passes: unlike the
        stop-path sweep it closes only the cards the oracle can justify, so a
        live task is never mistaken for a dead one. Failures are the caller's
        to log — this mirrors ``close_open_agent_cards`` and swallows too.
        """

        return await self.close_open_agent_cards(
            session,
            reason="evidence",
            evidence=True,
        )

    async def reconcile_agent_cards_from_evidence(self) -> int:
        """Close stranded Agent cards on the runtime's first pass after restart.

        A previous connector that exited without settling a background task
        leaves its card ``running`` forever (R2): the killed process emitted no
        terminal event, so nothing folds it. This is the connector-startup
        reconciliation the task sheet asks for (SHOULD): every known session's
        open cards are judged once against the subagent-transcript oracle, so a
        card whose task actually finished or was killed is closed on the next
        startup instead of waiting for a 6-hour client-side fuse.

        Never fatal: a failure is logged and the next session continues, so one
        bad transcript cannot stop the runtime from coming up.

        The store starts empty, so a session the connector never touches again
        would never be judged; the durable open-card index (``open_cards``,
        2026-10-21) names those sessions and is consulted first. Entries are
        only *locations* — the sweep rebuilds each card from the raw transcript
        and the oracle decides, so a stale index entry publishes nothing it
        cannot prove.
        """

        if self.oracle is None:
            return 0
        reconciled = 0
        if self.open_cards is not None:
            for session_id, entry in (await self.open_cards.read()).items():
                if self.stopping:
                    return reconciled
                if self.session_store.get(session_id) is not None:
                    # Already in the store: the loop below covers it.
                    continue
                external = entry.get("externalSessionId")
                cwd = entry.get("cwd")
                if not isinstance(external, str) or not external:
                    continue
                if not isinstance(cwd, str) or not cwd:
                    continue
                session = self.session_store.ensure(
                    session_id=session_id,
                    external_session_id=external,
                    cwd=cwd,
                )
                try:
                    reconciled += await self.sweep_agent_cards_by_evidence(session)
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "Claude startup agent-card reconciliation failed "
                        "session_id={}",
                        session_id,
                    )
        for session in self.session_store.sessions():
            if self.stopping:
                return reconciled
            try:
                reconciled += await self.sweep_agent_cards_by_evidence(session)
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude startup agent-card reconciliation failed session_id={}",
                    session.session_id,
                )
        return reconciled

    async def project_background_frame(
        self,
        session: ClaudeSession,
        message: Any,
    ) -> None:
        """Project one subagent frame that reached silence into the timeline.

        L1 absorbs these frames so they can never mint a scheduled reply; L2
        captures them at the same guard so the subagent's thinking, text and
        tool rows become visible instead of dropped. The shared projector is
        what already owns this session's item ids and order slots, so the rows
        converge with the in-turn projection and the history rebuild — and
        every row is attributed to the card the frame is parented to
        (`content.parentItemId`; messages.py tags tool rows, helper below the
        reasoning/message rows). Nothing here mints a turn.
        """

        try:
            native_session_id = message_session_id(message)
            if (
                native_session_id is not None
                and session.external_session_id != native_session_id
            ):
                # Same scope-adoption rule as the task fold: captured rows
                # must hash under the native session id the turn uses.
                await self._update_external_session_id(session, native_session_id)
            parent_tool_use_id = _parent_tool_use_id(message)
            parent_item_id = (
                stable_tool_item_id(session, parent_tool_use_id)
                if parent_tool_use_id is not None
                else None
            )
            turn_id = self._subagent_turn_id(session, parent_tool_use_id)
            items: list[RuntimeTimelineItem] = [
                *self.timeline.tool_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                ),
                *self.timeline.system_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    event="claude.subagent.system",
                ),
            ]
            role = message_role(message)
            text = message_text(message)
            if (
                role in {"assistant", "system"}
                and text
                and not is_synthetic_control_message(message)
            ):
                items.append(
                    self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role=role,
                        text=text,
                        event=f"claude.subagent.{role}",
                        native_item_id=message_id(message),
                    )
                )
            for item in items:
                await self.notifications.timeline_activity.timeline_item_upsert(
                    _with_parent_card(item, parent_item_id)
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude subagent frame projection failed session_id={}",
                session.session_id,
            )

    def _subagent_turn_id(
        self,
        session: ClaudeSession,
        parent_tool_use_id: str | None,
    ) -> str:
        """Pick the turn id for a row projected from a captured subagent frame.

        The frames land while the dispatch turn has already settled, so the
        value is bookkeeping (no client sections by it): the parent card's own
        turn is inherited when it has been projected, and the deterministic
        fallback keeps one subagent's rows together under a stable id.
        """

        if parent_tool_use_id is None:
            return "turn_claude_subagent_orphan"
        parent_item_id = stable_tool_item_id(session, parent_tool_use_id)
        parent = session.timeline_items.get(parent_item_id)
        if parent is not None and parent.turn_id:
            return parent.turn_id
        return f"turn_claude_subagent_{parent_item_id}"

    async def wait_for_selection_change(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> None:
        """Wait out a transport's background work before landing a rebuild.

        This is now the DEFERRED-LANDING wait, not the message path: since
        `model-switch-in-process-tasks.md` (2026-10-15) a selection change is
        applied to the live transport in place (`apply_selection_to_live`), and
        when it cannot be — no SDK seam, an effort change, or the
        `bypassPermissions` exception — the user's next turn runs on the live
        transport with the selections it already carries
        (`connection_for` never blocks). This method is only called by the
        landing task that fires once the transport's background work drains,
        so it can no longer pin a user's message; it waits, then the caller
        (`_land_selection_after_background`) rebuilds on the new selection.

        - the drain is event-driven — the last terminal task frame is the
          signal (`ClaudeBackgroundTasks.drained`);
        - both phases are bounded by `selectionChangeDrainCeilingSeconds`
          (red team F-B): a real background task that keeps working is
          waited for as long as its terminal frames keep coming, but an id
          that never drains — a stale snapshot id, a lost terminal — cannot
          pin the landing forever. On either ceiling the wait logs and
          returns; the caller re-checks before rebuilding;
        - a second switch during the wait is seen on the next pass, and the
          caller re-checks the selections when this returns (a switch back to
          what the transport already carries needs no rebuild);
        - the wait is cancellable: a runtime stop cancels the landing task and
          the `CancelledError` propagates.
        """

        settle = float(self.config.values.get("selectionChangeSettleSeconds", 1.0))
        ceiling = float(
            self.config.values.get("selectionChangeDrainCeilingSeconds", 600.0)
        )
        while connection.background.active_ids:
            if self.stopping or connection.closing:
                raise asyncio.CancelledError
            if not await connection.wait_background_drained(ceiling=ceiling):
                logger.warning(
                    "Claude selection change landing without drained "
                    "background work session_id={} background_tasks={}",
                    session.session_id,
                    len(connection.background.active_ids),
                )
                return
            if self.stopping or connection.closing:
                raise asyncio.CancelledError
            if not await connection.wait_settled(grace=settle, ceiling=ceiling):
                logger.warning(
                    "Claude selection change landing without a settled "
                    "transport session_id={} background_tasks={}",
                    session.session_id,
                    len(connection.background.active_ids),
                )
                return
            if dict(session.selections) == connection.selections:
                # The user switched back while this waited; the caller reuses
                # the transport.
                return
            # Otherwise loop: the wake turn may have dispatched fresh
            # background work, and that new batch owns the transport too.

    async def apply_selection_to_live(
        self,
        session: ClaudeSession,
        selections: Mapping[str, str | None],
    ) -> SelectionApplyResult:
        """Apply a selection change to this session's live transport in place.

        The main path of `model-switch-in-process-tasks.md` §3.1: a model /
        permission change reaches the running CLI process through the SDK's
        `set_model` / `set_permission_mode` control requests, so the next turn
        runs on the new selection with no process rebuild and no message held.

        The three-way outcome (`SelectionApplyResult`) is the whole point of
        the real-CLI probe of 2026-10-15: a refusal the CLI marks retryable
        (its model-validation probe stalled) must NOT be answered by rebuilding
        the process — that kills the background work this change protects — so
        it is kept as a bounded retry, while a genuine capability failure (no
        seam / effort change / bypass) falls back as before. Never blocks,
        never rebuilds here.
        """

        connection = self.connections.get(session.session_id)
        if connection is None or connection.closing:
            return SelectionApplyResult.UNAVAILABLE
        target = dict(selections)
        if connection.selections == target:
            # Nothing selection-relevant changed: the transport already
            # carries the target.
            self._pending_selections.pop(session.session_id, None)
            return SelectionApplyResult.APPLIED
        if not self._selection_applies_in_process(connection, target, session):
            # The change cannot be applied in place at all. A pending retry
            # makes no sense here (no attempt can ever succeed), so drop it.
            self._pending_selections.pop(session.session_id, None)
            if connection.background.active_ids:
                # The transport hosts background work the do-not-retire
                # invariant protects, so it cannot be rebuilt without killing
                # it. Disclose the deferral and arm the landing; the caller's
                # next turn runs on the live transport as-is (AC2). The cause
                # is "background" — `active_ids` was checked just above.
                await self._defer_selection_change(
                    session, connection, target, cause="background"
                )
                self._ensure_selection_landing(session, connection)
            return SelectionApplyResult.UNAVAILABLE
        result = await self._apply_selection_in_process(connection, target, session)
        if result is SelectionApplyResult.APPLIED:
            self._pending_selections.pop(session.session_id, None)
            return SelectionApplyResult.APPLIED
        # DEFERRED: the CLI refused a change it is allowed to take (its
        # model-validation probe stalled, `retryable: true`). A rebuild would
        # kill any live background work for a refusal a later attempt clears,
        # so it is only acceptable when there is no background work to lose.
        if not connection.background.active_ids:
            # Cheap, side-effect-free: let the controller's idle rebuild land
            # the selection instead of holding a retry for a transport nobody
            # is protecting.
            return SelectionApplyResult.UNAVAILABLE
        self._pending_selections[session.session_id] = _PendingSelection(target=target)
        await self._pending_selection_status(session, target)
        # Retry at the next event: the background drain (event-driven), or the
        # next turn (`connection_for`). Bounded by SELECTION_IN_PROCESS_MAX_ATTEMPTS.
        self._ensure_selection_landing(session, connection)
        return SelectionApplyResult.DEFERRED

    def _selection_applies_in_process(
        self,
        connection: ClaudeConnection,
        target: Mapping[str, str | None],
        session: ClaudeSession,
    ) -> bool:
        """Whether the whole `target` can be applied to the live transport.

        Both halves must be applicable — a model change the CLI accepts still
        cannot stand in for an effort change (the SDK has no seam for effort),
        and `bypassPermissions` is refused in place by upstream. When any half
        is not, the caller falls back rather than applying a partial one. This
        is purely the CAPABILITY question (the SDK seam + the launch-argument
        shapes); a transient upstream refusal discovered while calling the seam
        is `DEFERRED`, not this.
        """

        client = connection.client
        return self._model_applies_in_process(
            connection, target, session
        ) and self._permission_applies_in_process(connection, target, client)

    def _model_applies_in_process(
        self,
        connection: ClaudeConnection,
        target: Mapping[str, str | None],
        session: ClaudeSession,
    ) -> bool:
        if target.get("model") == connection.selections.get("model"):
            return True
        if not client_supports_set_model(connection.client):
            return False
        try:
            target_selection = model_selection_from_selection_id(
                target.get("model"),
                self.catalogs.custom_models,
                self.catalogs.cli_models,
            )
            current_selection = model_selection_from_selection_id(
                connection.selections.get("model"),
                self.catalogs.custom_models,
                self.catalogs.cli_models,
            )
        except Exception:  # noqa: BLE001 - unknown selection: fall back
            return False
        # `set_model` carries the model only. An effort change needs the launch
        # argument, so it is not applicable in place.
        target_effort = target_selection.effort_id if target_selection else None
        current_effort = current_selection.effort_id if current_selection else None
        return target_effort == current_effort

    def _permission_applies_in_process(
        self,
        connection: ClaudeConnection,
        target: Mapping[str, str | None],
        client: Any,
    ) -> bool:
        if target.get("permission") == connection.selections.get("permission"):
            return True
        if not client_supports_set_permission_mode(client):
            return False
        try:
            mode = permission_mode_from_selection_id(target.get("permission"))
        except Exception:  # noqa: BLE001 - unknown selection: fall back
            return False
        # Upstream refuses to enter all-permissions in place on a process that
        # was not launched with `--dangerously-skip-permissions`; that is a
        # capability shape (§3.2), handled by the caller's deferral/rebuild.
        return mode != "bypassPermissions"

    async def _apply_selection_in_process(
        self,
        connection: ClaudeConnection,
        target: Mapping[str, str | None],
        session: ClaudeSession,
    ) -> SelectionApplyResult:
        """Run the SDK control requests and update `connection.selections`.

        The model and permission halves are applied CONCURRENTLY. Each control
        request is bounded by `CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS`
        (`sdk/client.py`), and a single PATCH can carry both; running them in
        sequence would stack two full timeouts (~40 s) past the server's 30 s
        RPC budget (`server/agent_server/services/session_run.py`). Gather
        keeps one PATCH inside a single bounded window.

        A refusal on either half is not extrapolated into a lie — the
        connection records only what the CLI actually accepted. A refusal is
        retryable (`DEFERRED`): the pending target is recorded for a bounded
        retry rather than a rebuild, and the session stays usable on whatever
        the transport actually carries.
        """

        client = connection.client
        applied_model = target.get("model") == connection.selections.get("model")
        applied_permission = (
            target.get("permission") == connection.selections.get("permission")
        )
        model_call = self._set_model_call(client, target) if not applied_model else None
        permission_call = (
            self._set_permission_call(client, target)
            if not applied_permission
            else None
        )
        calls = [call for call in (model_call, permission_call) if call is not None]
        if calls:
            results = await asyncio.gather(*calls)
            index = 0
            if model_call is not None:
                applied_model = results[index]
                index += 1
            if permission_call is not None:
                applied_permission = results[index]
        if applied_model and applied_permission:
            connection.selections = dict(target)
            logger.info(
                "Claude selection change applied in process session_id={}",
                session.session_id,
            )
            return SelectionApplyResult.APPLIED
        # A half-applied pair is a partial success: record what the CLI truly
        # accepted so `connection_for` sees the remaining mismatch.
        applied = dict(connection.selections)
        if applied_model:
            applied["model"] = target.get("model")
        if applied_permission:
            applied["permission"] = target.get("permission")
        connection.selections = applied
        # The caller gated this call on `_selection_applies_in_process`, so
        # every mismatched half was attempted through a present seam. A refusal
        # is therefore the transient, retryable shape (real-CLI probe
        # 2026-10-15): the caller records the pending target and retries; this
        # core never rebuilds and never manages the pending state itself.
        logger.warning(
            "Claude in-process selection change refused session_id={} "
            "model_applied={} permission_applied={}",
            session.session_id,
            applied_model,
            applied_permission,
        )
        return SelectionApplyResult.DEFERRED

    async def _set_model_call(
        self,
        client: Any,
        target: Mapping[str, str | None],
    ) -> bool:
        model_selection = model_selection_from_selection_id(
            target.get("model"),
            self.catalogs.custom_models,
            self.catalogs.cli_models,
        )
        return await set_model_client(
            client,
            model_selection.cli_model if model_selection else None,
        )

    async def _set_permission_call(
        self,
        client: Any,
        target: Mapping[str, str | None],
    ) -> bool:
        mode = permission_mode_from_selection_id(target.get("permission"))
        return await set_permission_mode_client(client, mode)

    async def _pending_selection_status(
        self,
        session: ClaudeSession,
        target: Mapping[str, str | None],
    ) -> None:
        """Publish machine-readable "selection not yet in effect" state.

        A marker for diagnostics: the metadata carries `selectionPending`, the
        pending `selectionTarget`, and a `statusReason`. The session's own
        status is preserved verbatim (never a fabricated idle — AC2). No client
        consumes these keys today (nothing reads them, and claude's
        `session_state_update` has no `status_reason` parameter, so the reason
        never reaches a top-level field); the user-facing signal is the notice
        (`_defer_selection_change`), not this.
        """

        state = self.notifications.session_states.get(session.session_id)
        await self.notifications.session_state.session_state_update(
            session,
            state.status if state is not None else "idle",
            metadata={
                "source": SELECTION_PENDING_SOURCE,
                "selectionPending": True,
                "selectionTarget": dict(target),
                "statusReason": "selection_change_retrying",
            },
        )

    async def _clear_pending_selection_status(
        self,
        session: ClaudeSession,
    ) -> None:
        """Retire the "selection not yet in effect" runtime state.

        Metadata merges stickily (`runtime_protocol/state_cache.py`), so
        flipping `selectionPending` alone would leave `selectionTarget` /
        `statusReason` behind forever, re-announcing a deferral on every later
        update. All three keys are therefore overwritten explicitly (to `None`
        for the two that carry a value).
        """

        state = self.notifications.session_states.get(session.session_id)
        await self.notifications.session_state.session_state_update(
            session,
            state.status if state is not None else "idle",
            metadata={
                "source": SELECTION_PENDING_SOURCE,
                "selectionPending": False,
                "selectionTarget": None,
                "statusReason": None,
            },
        )

    async def _resolve_selection_notice(self, session: ClaudeSession) -> None:
        """Retire an OPEN deferral notice once the selection is in effect.

        The deferral notice (capability / bypass) is resolved wherever the
        change actually lands — the in-place retry, the landing task's rebuild,
        OR the next turn's `connection_for` rebuild. Centralizing it here
        (gated on an open notice) is what keeps that last path from leaving a
        `status=open` row hanging forever (red team Q-4).
        """

        for notice in self.notifications.notices.current_for_session(
            session.session_id
        ):
            if notice.source.get("kind") == "selection_deferred":
                await self.notifications.notice_handler.notice_upsert(
                    _resolved_selection_notice(session)
                )
                return

    async def _defer_selection_change(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
        target: Mapping[str, str | None],
        *,
        cause: SelectionDeferredCause,
    ) -> None:
        """Disclose a selection change that cannot land yet, and why.

        `cause` is decided by the CALLER from the live fact at its own moment,
        so the message can never assert a reason that has stopped holding (a
        background drain can land inside the retry interval). "background" =
        background work is live now; "unlanded" = it is not. The notice names
        the deferral; the landing (or the next turn's rebuild) lands it.
        """

        bypass = target.get("permission") != connection.selections.get(
            "permission"
        )
        try:
            permission_mode = permission_mode_from_selection_id(
                target.get("permission")
            )
        except Exception:  # noqa: BLE001
            permission_mode = None
        switching_bypass = bypass and permission_mode == "bypassPermissions"
        await self.notifications.notice_handler.notice_upsert(
            _selection_deferred_notice(
                session,
                cause=cause,
                switching_bypass=switching_bypass,
            )
        )

    def _ensure_selection_landing(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> None:
        """Arm the one background task that lands a deferred selection change.

        Idempotent per session: a second turn arriving while the change is
        still deferred must not spawn a parallel landing.
        """

        if self.stopping:
            return
        existing = self._selection_landing_tasks.get(session.session_id)
        if existing is not None and not existing.done():
            return
        self._selection_landing_tasks[session.session_id] = asyncio.create_task(
            self._land_selection_after_background(session, connection)
        )

    async def _land_selection_after_background(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> None:
        """Land a deferred selection change without ever blocking a message.

        Bounded and event-driven — never an idle poll. Two phases, by the kind
        of deferral:

        * Phase 1 (transient refusal, `_pending_selections`): retry the
          in-place apply WHILE background work is still live — the whole
          reason a retryable refusal must not rebuild. The CLI's refusal is
          time-bounded (its model-validation probe), so attempts are spaced by
          `SELECTION_IN_PROCESS_RETRY_DELAY_SECONDS` and capped by
          `SELECTION_IN_PROCESS_MAX_ATTEMPTS`: a finite, bounded retry that a
          persistently-refusing CLI cannot turn into a spin. On success (or the
          ceiling) the pending state is cleared.
        * Phase 2 (capability deferral): wait for the transport's background
          work to drain (event-driven, `wait_for_selection_change`), then
          rebuild on the new selection via the idle refresh.

        If the transport changed under it, the user switched back, or the drain
        ceiling is reached with work still live, this returns and leaves the
        mismatch to the next `connection_for` — which rebuilds once the
        background work is gone. A STALE id (a terminal frame that never
        arrives) blocks that too; that case is an accepted, observable legacy
        documented at the ceiling branch below.
        """

        started = time.monotonic()
        try:
            # Phase 1: bounded in-place retry of a transient refusal, only
            # while background work is still live (the reason not to rebuild).
            while self._pending_selections.get(session.session_id) is not None:
                if not self._selection_landing_transport_intact(session, connection):
                    return
                if not connection.background.active_ids:
                    # Background drained while a refusal stood: fall through
                    # to phase 2, where a rebuild lands the change cheaply.
                    break
                await asyncio.sleep(
                    float(
                        self.config.values.get(
                            "selectionInProcessRetryDelaySeconds",
                            SELECTION_IN_PROCESS_RETRY_DELAY_SECONDS,
                        )
                    )
                )
                if not self._selection_landing_transport_intact(session, connection):
                    return
                await self._attempt_pending_selection(session, connection)
            # Phase 2: land any remaining mismatch by rebuilding, but only once
            # the background work the rebuild would kill is gone.
            if not self._selection_landing_transport_intact(session, connection):
                return
            if connection.selections == dict(session.selections):
                return
            if connection.background.active_ids:
                await self.wait_for_selection_change(session, connection)
                if not self._selection_landing_transport_intact(
                    session, connection
                ):
                    return
            if connection.background.active_ids:
                # The drain ceiling was reached with work still live. Do not
                # rebuild under it (that would kill the work). `connection_for`
                # will land it on a later turn ONLY IF `active_ids` has emptied
                # by then — it re-checks the same condition before rebuilding.
                #
                # ACCEPTED RESIDUAL (pp 2026-10-15, decision recorded here;
                # this comment is the tracked record). A genuinely-running task
                # drains and the change lands later. But a STALE id — one whose
                # terminal frame never arrives (CLI resume/notification gap) —
                # never empties, and blocks the landing at all three points that
                # gate on `active_ids`:
                #   * this phase 2,
                #   * `connection_for`'s rebuild (it too requires no active
                #     background),
                #   * idle reclaim (`reclaim_idle_connection` lists
                #     `connection.background.active_ids` among its keep-alive
                #     conditions), so the transport is never recycled either.
                # The session then runs its OLD selection while the client
                # shows the new one and this deferral notice stays `open`.
                # The id CAN still be released by three existing paths, none of
                # which rebuild: (1) the task's real terminal frame finally
                # arriving; (2) the zombie-card evidence sweep's
                # `ClaudeBackgroundTasks.release` (sdk/background.py); (3)
                # session stop / connector restart, which ends the process.
                # ACCEPTED, not hidden: the alternative (force-rebuild on the
                # ceiling) would kill live background work, which pp judged far
                # worse than a late switch. The only cost control is this
                # observability (red team P2-3): the WARNING below.
                logger.warning(
                    "Claude selection landing deferred: drain ceiling reached "
                    "with live background work session_id={} active_ids={} "
                    "elapsed_s={:.1f}",
                    session.session_id,
                    len(connection.background.active_ids),
                    time.monotonic() - started,
                )
                return
            if connection.selections == dict(session.selections):
                return
            await self.refresh_idle_connection(session)
            landed = self.connections.get(session.session_id)
            if landed is not None and landed.selections == dict(session.selections):
                self._pending_selections.pop(session.session_id, None)
                # The change is now in effect; clear the honest "not yet
                # applied" state. The notice is retired by `connection_for`
                # (the rebuild this delegates to), so it is resolved there.
                await self._clear_pending_selection_status(session)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude deferred selection landing failed session_id={}",
                session.session_id,
            )
        finally:
            if (
                self._selection_landing_tasks.get(session.session_id)
                is asyncio.current_task()
            ):
                self._selection_landing_tasks.pop(session.session_id, None)

    def _selection_landing_transport_intact(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> bool:
        """Whether the landing may still act on this transport."""

        return not (
            self.stopping
            or connection.closing
            or self.connections.get(session.session_id) is not connection
        )

    async def _attempt_pending_selection(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
    ) -> None:
        """Make ONE bounded re-attempt of a transiently-refused change.

        The attempt counter is the ceiling; when it is spent (or the target
        stopped being applicable in place) the pending state is dropped, so a
        persistently-refusing CLI cannot spin. The caller spaces attempts and
        bounds their number.
        """

        pending = self._pending_selections.get(session.session_id)
        if pending is None:
            return
        if connection.selections == pending.target:
            self._pending_selections.pop(session.session_id, None)
            await self._clear_pending_selection_status(session)
            return
        if pending.attempts >= SELECTION_IN_PROCESS_MAX_ATTEMPTS:
            await self._give_up_pending_selection(
                session,
                connection,
                reason="attempt_ceiling",
                attempts=pending.attempts,
            )
            return
        if not self._selection_applies_in_process(
            connection, pending.target, session
        ):
            # The target is no longer applicable in place at all (e.g. it
            # became an effort change under a newer request): stop retrying,
            # but do not go silent about the mismatch.
            await self._give_up_pending_selection(
                session,
                connection,
                reason="no_longer_applicable",
                attempts=pending.attempts,
            )
            return
        pending.attempts += 1
        result = await self._apply_selection_in_process(
            connection, pending.target, session
        )
        # Only APPLIED falls through to a retry-ending action here; any
        # non-APPLIED outcome is DEFERRED (`_apply_selection_in_process`
        # returns exactly APPLIED or DEFERRED — a seam failure surfaces as
        # DEFERRED and the real backstop is the attempt ceiling above, not a
        # rebuild). So there is deliberately no UNAVAILABLE branch: it would be
        # dead code.
        if result is SelectionApplyResult.APPLIED:
            self._pending_selections.pop(session.session_id, None)
            await self._clear_pending_selection_status(session)

    async def _give_up_pending_selection(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection,
        *,
        reason: str,
        attempts: int,
    ) -> None:
        """Stop retrying a refused change, visibly.

        Two obligations, both from the red-team P2-2: the sticky pending state
        must be cleared (or `selectionPending` and its reason would ride every
        future update), and the user must be TOLD — the controller already
        published the new selection at PATCH time, so the client shows the new
        model while the transport still runs the old one. Silence there is the
        "displays new, runs old" lie this whole change exists to avoid.

        The disclosure's cause is read from the LIVE `active_ids` here, not
        assumed: the retry loop that leads here sleeps for
        `SELECTION_IN_PROCESS_RETRY_DELAY_SECONDS` between the active-ids check
        and this point, so background work can drain in that gap. Claiming
        "有后台任务在跑" then would be false (red team: this exact race).
        """

        self._pending_selections.pop(session.session_id, None)
        await self._clear_pending_selection_status(session)
        logger.warning(
            "Claude in-process selection change abandoned session_id={} "
            "reason={} attempts={}",
            session.session_id,
            reason,
            attempts,
        )
        # Disclose the still-standing deferral (the in-place path could not
        # land it). The transport keeps running the old selection until the
        # next `connection_for` rebuilds once no background work blocks it.
        await self._defer_selection_change(
            session,
            connection,
            session.selections,
            cause=(
                "background" if connection.background.active_ids else "unlanded"
            ),
        )

    def subagent_control_supported(self) -> bool:
        """Whether the loaded SDK offers the per-task stop control at all.

        Probed once, lazily, fail-soft (no loader / no SDK = no support).
        Lives on the runner because loading the SDK is a collaborator's job
        — the architecture test keeps it out of the runtime module.
        """

        if self._subagent_control_supported is None:
            try:
                sdk = load_sdk(self.sdk_loader)
            except Exception:  # noqa: BLE001 - fail-soft by contract
                supported = False
            else:
                supported = sdk_supports_stop_task(sdk)
            self._subagent_control_supported = supported
        return self._subagent_control_supported

    def has_live_connection(self, session_id: str) -> bool:
        """Whether a live transport currently hosts this session's work.

        The per-task stop rides this connection, so it is the fact behind
        ``session.subagent_control`` availability: true while the connection
        is open, regardless of whether a turn is running (background
        subagents keep their transport alive through idle).
        """

        connection = self.connections.get(session_id)
        return connection is not None and not connection.closing

    async def connection_for(
        self,
        session: ClaudeSession,
        stderr: ClaudeStderrBuffer,
    ) -> ClaudeConnection:
        existing = self.connections.get(session.session_id)
        if existing is not None:
            if not existing.closing and existing.selections == session.selections:
                existing.cancel_idle()
                return existing
            if (
                not existing.closing
                and existing.background.active_ids
                and existing.selections != session.selections
            ):
                # The transport carries a different selection and hosts live
                # background work a rebuild would kill. Since the in-process
                # path (model-switch-in-process-tasks.md, 2026-10-15) applied
                # every applicable change to the live transport at update time,
                # a mismatch here is one of:
                #   * a transient refusal waiting on a bounded retry
                #     (`_pending_selections`, retried by the event-driven
                #     landing task — NOT on this message path), or
                #   * a change that cannot be applied in place (no seam / effort
                #     change / the bypass exception).
                #
                # Either way the user's message must not be held behind the
                # background work (AC2, pp's hard requirement), and no retry
                # belongs on this path: an in-place attempt here could block
                # the turn for up to the seam's control timeout. Run this turn
                # on the live transport as-is; the landing task lands the
                # change on its own once the work drains.
                logger.warning(
                    "Claude turn running on a transport with a pending "
                    "selection change session_id={} background_tasks={}",
                    session.session_id,
                    len(existing.background.active_ids),
                )
                existing.cancel_idle()
                return existing
            await existing.close()
        # A transport retired out of band (the scheduled-turn circuit breaker)
        # is already gone from `connections`, so its Cron* bookkeeping arrives
        # here by handover instead of by the registry entry above.
        carried = self.carried_task_ids.pop(session.session_id, None)
        # Scheduled reconnect bypasses the normal start/update selection path.
        # Resolve its saved CLI-only selection before constructing SDK options.
        await self.catalogs.resolve_model_selection(session.selections.get("model"))
        sdk = load_sdk(self.sdk_loader)
        settings_path = create_gateway_settings_file(self.config.values)

        async def approval(tool_name, tool_input, context):
            await connection.prepare_approval()
            return await self.interactions.approval_callback(
                sdk,
                session,
                session.active_turn_id,
            )(tool_name, tool_input, context)

        async def tool_result(data, *args):
            result = await connection.tool_result(data, *args)
            native_id = data.get("session_id")
            if session.external_session_id is None and isinstance(native_id, str):
                await self._update_external_session_id(session, native_id)
            await self.scheduled_sessions.save(session, connection.task_ids)
            return result

        def cleanup():
            remove_gateway_settings_file(settings_path)
            if self.connections.get(session.session_id) is connection:
                self.connections.pop(session.session_id)

        async def apply_agent_title(title: str) -> None:
            # The agent named its own session. Keep the local record in sync
            # and publish immediately; the periodic inventory sync re-reads
            # the custom-title entry from Claude Code itself, so nothing here
            # has to survive a connector restart.
            self.session_store.update_meta(session, title=title)
            await self.notifications.session_state.session_meta_upsert(
                session,
                source="claude.session.agent_title",
            )

        title_control = build_change_title_tool(
            sdk,
            session_id=session.session_id,
            current_title=lambda: session.title,
            external_session_id=lambda: session.external_session_id,
            cwd=lambda: session.cwd,
            on_applied=apply_agent_title,
        )
        try:
            client = new_sdk_client(
                sdk=sdk,
                config_values=self.config.values,
                session=session,
                client_factory=self.client_factory,
                can_use_tool=approval,
                stderr=stderr.record,
                settings_path=settings_path,
                cli_models=self.catalogs.cli_models,
                on_tool_result=tool_result,
                before_tool=lambda data: connection.before_tool(data),
                title_control=title_control,
            )
        except BaseException:
            remove_gateway_settings_file(settings_path)
            raise
        connection = ClaudeConnection(
            client=client,
            on_activity=lambda response: self.scheduled_activity(session, response),
            on_idle=lambda current: self.reclaim_idle_connection(session, current),
            on_background_done=lambda current: self.reconcile_after_background(
                session, current
            ),
            # L2 subagent progress (claude-subagent-progress-tasks.md §3.4):
            # both routes publish items through the projector this runtime
            # already shares (`self.timeline`), so ids and order slots stay
            # convergent with the live turn projection and the history rebuild.
            on_task_event=lambda event: self.fold_agent_task_event(session, event),
            on_background_frame=lambda message: self.project_background_frame(
                session, message
            ),
            cleanup=cleanup,
            idle_timeout_seconds=self.config.values.get("idleTimeoutSeconds", 600),
            per_task_stop_declared=client_declares_per_task_stop(client),
            selections=dict(session.selections),
            task_ids=(
                set(existing.task_ids) | set(carried or ())
                if existing is not None
                else set(carried or ())
            ),
        )
        self.connections[session.session_id] = connection
        # The rebuild carries the new selection, so any pending marker / open
        # deferral notice for this session is now stale: clear both here,
        # whether the rebuild was reached from the idle refresh, the next turn,
        # or the landing task (red team Q-4 — this is the path where a notice
        # would otherwise hang open forever). With no pending state and no open
        # deferral notice this is a no-op, so a routine rebuild pays nothing.
        if self._pending_selections.pop(session.session_id, None) is not None:
            await self._clear_pending_selection_status(session)
        await self._resolve_selection_notice(session)
        return connection

    async def refresh_idle_connection(self, session: ClaudeSession) -> None:
        async with session.execution_lock:
            existing = self.connections.get(session.session_id)
            if (
                self.stopping
                or session.execution is not None
                or existing is None
                or existing.selections == session.selections
                or existing.background.active_ids
            ):
                return
            try:
                connection = await self.connection_for(
                    session,
                    ClaudeStderrBuffer(session.session_id),
                )
                connection.queried.set()
                await connection.connect()
                await self.scheduled_sessions.save(session, connection.task_ids)
            except Exception as exc:  # noqa: BLE001
                connection = self.connections.get(session.session_id)
                if connection is not None:
                    await connection.close()
                await self.notifications.session_state.session_state_update(
                    session,
                    "error",
                    error={
                        "code": "claude_connection_refresh_failed",
                        "message": str(exc),
                    },
                    metadata={"source": "claude.connection.refresh"},
                )

    async def _context_probe_sweep(self) -> None:
        """Periodically probe every session whose window is still uncovered.

        This is the third calibration trigger (T1/T2/T3), and the one that
        survives a connector restart: on the first tick a session whose
        transport is already live and idle is probed without any user action,
        and a session that has never run a turn since the process came up
        stops waiting for the turn-settle instant to happen to fire.

        It runs OUTSIDE every turn's path and never touches the execution lock
        itself — `calibrate_context_window` takes the lock only when it is
        free — so it can never make a starting turn wait. Failures are already
        swallowed inside `calibrate_context_window`; the only thing left to
        guard here is the loop itself, which must survive an unexpected error
        (one poisoned tick must not retire the sweep for the process's life).
        """

        while not self.stopping:
            try:
                await asyncio.sleep(CONTEXT_PROBE_SWEEP_INTERVAL_SECONDS)
                if self.stopping:
                    return
                await self._sweep_uncovered_sessions()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.exception("Claude context probe sweep tick failed")

    async def _sweep_uncovered_sessions(self) -> None:
        """One sweep pass: calibrate each session whose selection is uncovered.

        Cheap by construction. A session with no transport, or whose cached
        probe already `covers` the current selection, is skipped with a dict
        lookup and no logging — the common case on every tick. Only a session
        that is actually a candidate for a probe wakes `calibrate_context_window`,
        which applies the four safety gates itself.
        """

        for session in self.session_store.sessions():
            if self.stopping:
                return
            connection = self.connections.get(session.session_id)
            if connection is None:
                # No transport: this sweep never force-creates one just to
                # probe (a session nobody is using has nothing to calibrate).
                continue
            selection = session.selections.get("model")
            probe = session.context_probe
            if probe is not None and probe.covers(selection):
                continue
            await self.calibrate_context_window(session)

    async def calibrate_context_window(self, session: ClaudeSession) -> None:
        """Ask the engine for its own context window while the transport idles.

        The window a client sizes its context ring with comes from the running
        engine's `/context` self-report, never from the model name (a gateway
        serves its own models under Claude Code's `default` entry). This runs
        whenever the session's transport is connected, idle and known to carry
        the current model: after a turn settles, after a model-selection
        rebuild, and from the periodic sweep that repopulates a session which
        ran no turn since the connector restarted. It is an optimization for
        the clients — every gate below skips it rather than costing the turn
        machinery anything, and the report is cached per model selection, so a
        session pays for it once.

        Serialization is the machinery that already exists: the probe runs
        under `session.execution_lock` — the lock ``start_turn`` registers a
        turn under — so no turn can start mid-probe, the probe never runs
        while one is live, and the lock is only taken when free (a starting
        turn is never made to wait behind a probe). A transport that hosts
        scheduled tasks or background work is skipped outright: its stream can
        carry an uninvited wake, and a probe holding the reader would swallow
        that reply.

        Every gate that skips a calibration logs which one rejected and for
        which session (T5). The skips used to be silent, so the 2026-10-08
        incident's 16:42/16:49 misses could not be diagnosed from the log at
        all; the line is DEBUG (the sweep calls this often on idle sessions,
        where a skip is the ordinary, correct outcome) and costs nothing when
        DEBUG is off.
        """

        if self.stopping:
            self._log_calibration_skip(session.session_id, "stopping")
            return
        connection = self.connections.get(session.session_id)
        if not self._calibration_transport(session, connection):
            self._log_calibration_skip(session.session_id, "transport")
            return
        # Keep the idle reclaim off this transport for the calibration's whole
        # window. The reclaim's gate cannot see a probe coming — it reads
        # `current`, which stays None until the claim — so a timer that fires
        # in the settle gap below would retire the very transport the probe is
        # about to borrow (measured: idleTimeoutSeconds small enough for the
        # tests' reclaim). Re-armed in the `finally`; the reader arms it too
        # whenever it hands a settled response back, so the reclaim is only
        # ever delayed by a probe, never lost.
        connection.cancel_idle()
        try:
            if not self._calibration_idle(session, connection):
                if not self._calibration_settling(connection):
                    self._log_calibration_skip(session.session_id, "settling")
                    return
                # A turn that just ended has released the response it received
                # its terminal on, but the reader clears that response's
                # `current` on its own task a step later — so a calibration
                # asked for at the turn's end would always lose that race.
                # Wait for the settle (bounded) instead, and do it OUTSIDE the
                # execution lock so a starting turn never waits behind it.
                if not await connection.wait_settled(
                    grace=CONTEXT_PROBE_SETTLE_GRACE_SECONDS,
                    ceiling=CONTEXT_PROBE_SETTLE_CEILING_SECONDS,
                ):
                    self._log_calibration_skip(session.session_id, "wait_settled")
                    return
                if not self._calibration_idle(session, connection):
                    self._log_calibration_skip(session.session_id, "idle")
                    return
            selection = session.selections.get("model")
            state = session.context_probe
            if state is not None and not state.attempt_allowed(
                selection,
                now=time.monotonic(),
                limit=context_probe.CONTEXT_PROBE_RETRY_LIMIT,
                backoff_seconds=context_probe.CONTEXT_PROBE_RETRY_BACKOFF_SECONDS,
            ):
                self._log_calibration_skip(session.session_id, "attempt_allowed")
                return
            try:
                async with session.execution_lock:
                    if not self._calibration_idle(session, connection):
                        self._log_calibration_skip(session.session_id, "idle")
                        return
                    probe = session.context_probe
                    if probe is None:
                        probe = ClaudeContextProbe()
                        session.context_probe = probe
                    now = time.monotonic()
                    if not probe.attempt_allowed(
                        selection,
                        now=now,
                        limit=context_probe.CONTEXT_PROBE_RETRY_LIMIT,
                        backoff_seconds=(
                            context_probe.CONTEXT_PROBE_RETRY_BACKOFF_SECONDS
                        ),
                    ):
                        self._log_calibration_skip(
                            session.session_id, "attempt_allowed"
                        )
                        return
                    probe.begin_attempt(selection, now=now)
                    report = await context_probe.probe_context_window(
                        connection,
                        session_id=session.session_id,
                        timeout_seconds=(
                            context_probe.CONTEXT_PROBE_TIMEOUT_SECONDS
                        ),
                    )
                    if report is None:
                        logger.warning(
                            "Claude context probe produced no report "
                            "session_id={} attempts={}",
                            session.session_id,
                            probe.attempts,
                        )
                        return
                    model, window, used = report
                    probe.record(model, window, used)
                    logger.info(
                        "Claude context window calibrated session_id={} "
                        "model={} window={} used={}",
                        session.session_id,
                        model,
                        window,
                        used,
                    )
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                logger.exception(
                    "Claude context calibration failed session_id={}",
                    session.session_id,
                )
        finally:
            connection.arm_idle()

    @staticmethod
    def _log_calibration_skip(session_id: str, gate: str) -> None:
        """Name the gate that declined one calibration (T5).

        DEBUG, not INFO: the sweep calls `calibrate_context_window` every few
        seconds for every uncovered session, so on an idle connector a skip is
        the ordinary, correct outcome and must not flood the log. The line
        exists precisely so that when a window is *not* learned, the next
        blackout can be read off the log — which gate declined, for which
        session — instead of being invisible as it was on 2026-10-08.
        """

        logger.debug(
            "Claude context calibration skipped session_id={} gate={}",
            session_id,
            gate,
        )

    def _calibration_transport(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection | None,
    ) -> bool:
        """The gate's session-level half: this transport may be borrowed.

        The reader must be live (`streaming` + `queried`, or its stream is not
        being read at all), no turn may be registered, and no source that can
        send this session a frame nobody invited — background work or a
        scheduled task — may exist. A probe taken under any of those would
        hold the reader while their frames arrived, and those frames would be
        swallowed with it.
        """

        return bool(
            connection is not None
            and not connection.closing
            and connection.streaming
            and connection.queried.is_set()
            and session.execution is None
            and session.queued_execution is None
            and not connection.background.active_ids
            and not connection.task_ids
        )

    def _calibration_settling(self, connection: ClaudeConnection) -> bool:
        """The one not-yet-idle shape worth waiting for: a settled response.

        `current` is released and kept its terminal (`discard` false), so the
        reader is merely a scheduling step away from handing the transport
        back. Two other non-idle shapes are deliberately NOT waited for: a
        response still owned by a live turn (nothing to do but return), and an
        interrupted turn's response, which holds `current` until its late
        terminal arrives — that wait would put a user's stop behind the probe,
        which the drain-after-interrupt red line forbids.
        """

        current = connection.current
        return (
            current is not None
            and current.released.is_set()
            and not current.discard
            and connection.pending is None
            and not connection.reconciling
        )

    def _calibration_idle(
        self,
        session: ClaudeSession,
        connection: ClaudeConnection | None,
    ) -> bool:
        """The gate's moment-level half: the transport is idle right now."""

        return self._calibration_transport(session, connection) and bool(
            connection is not None
            and connection.current is None
            and connection.pending is None
            and not connection.reconciling
        )

    async def drive_turn(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        content: str,
        attachments: tuple[RuntimeAttachment, ...],
        client_message_id: str | None,
        scheduled: bool = False,
        response: ClaudeResponse | None = None,
        command: str | None = None,
        prompt_uuid: str | None = None,
    ) -> None:
        turn_id = execution.turn_id
        # A scheduled turn whose cast frame carried no anchor binds on the
        # first anchor-bearing frame; a turn whose id is already anchored (or
        # a user/command turn) never rebinds.
        scheduled_anchor = (
            _turn_anchor_from_frame(response.cast_frame)
            if scheduled and response
            else None
        )
        turn_anchor_bound = not scheduled or scheduled_anchor is not None
        turn_bind_warned = False
        stderr = ClaudeStderrBuffer(session.session_id)
        client = response
        connection = response.connection if response is not None else None
        terminal: ClaudeTerminalEvent | None = None
        reserved_user_item = None
        attachment_mappings: tuple[dict[str, object], ...] = ()
        replayed_user_message: tuple[str, str] | None = None
        response_external_session_confirmed = False
        # A native command is CLI chrome rather than a message the user sent:
        # Claude never echoes it back, so no user item is reserved, published or
        # replayed. The compaction marker is the whole surface of the turn.
        user_message_published = scheduled or command is not None
        published_user_item_id: str | None = None
        stream_accumulator = ClaudeStreamAccumulator()
        # F1 release protocol state, seeded HERE rather than beside the read
        # loop below: the `finally` consults them, and anything raised between
        # the loop's opening and its body would otherwise leave them unbound —
        # which raises out of `finally` and replaces the real error with a
        # name error. `terminal` above follows the same rule.
        #
        # `declined_any` says at least one terminal was ruled out of this turn;
        # `downgraded_verdict` holds the exact verdict object recorded for
        # that case, so the settle path can tell "this turn fell back to the
        # downgrade" from "this turn recovered and overwrote it" by identity,
        # without a second judgement about the frames.
        declined_any = False
        downgraded_verdict: ClaudeTerminalEvent | None = None
        # The frame that was deferred, kept so the fallback can still publish
        # its text if the read ends without anything better. See the publish
        # below the read loop.
        declined_message: Any = None
        try:
            if command is not None:
                # The user asked for this compaction: publish the running
                # separator before the prompt leaves, so a silent CLI settles
                # a visible marker instead of leaving the turn invisible. The
                # marker is the session's, because the CLI's verdict for it
                # usually arrives on a later turn than this one.
                await self.open_command_compact_marker(session, turn_id, execution)
            if client is None:
                connection = await self.connection_for(session, stderr)
                maintenance = connection.background_done_task
                if maintenance is not None and not maintenance.done():
                    # Keep the queued maintenance response's native user id in
                    # pending until it completes (or its 30-second timeout).
                    # Cancelling this user turn must not cancel shared upkeep.
                    await asyncio.shield(maintenance)
                    if self.stopping:
                        raise asyncio.CancelledError
                    if connection.closing:
                        task_ids = set(connection.task_ids)
                        connection = await self.connection_for(session, stderr)
                        connection.task_ids.update(task_ids)
                client = connection.response_for(execution)
            execution.client = client
            await connect_client(client)
            materialized_attachments = await materialize_claude_attachments(
                self.host,
                session.session_id,
                attachments,
            )
            effective_content = content_with_attachment_notes(
                content,
                materialized_attachments,
            )
            if not scheduled:
                await self.notifications.session_state.session_state_update(
                    session,
                    "running",
                    metadata={"source": "claude.turn.running"},
                )
            attachment_mappings = tuple(
                attachment.to_mapping() for attachment in materialized_attachments
            )
            if not scheduled:
                if command is None and prompt_uuid is None:
                    prompt_uuid = client.ensure_prompt_uuid()
                if prompt_uuid is not None:
                    # Bind the identity the submit path already committed to
                    # (or the one just pre-assigned above) before ANY row is
                    # published: the user item, every assistant/tool/reasoning
                    # row of this turn and the history projection all hash
                    # this same uuid. `user_id` is the field the reader
                    # matches the prompt echo against, so a response that HAS
                    # one (a retained/queried transport) takes the same uuid.
                    # A first-turn response intentionally keeps `user_id=None`:
                    # the reader's silence routing treats None as "every frame
                    # belongs to the pending", and setting it would make an
                    # unowned `interrupted` terminal get absorbed instead.
                    client.prompt_uuid = prompt_uuid
                    if client.user_id is not None:
                        client.user_id = prompt_uuid
                    turn_id = _history_turn_id(session.session_id, prompt_uuid)
                    execution.turn_id = turn_id
                if command is None and (
                    client_message_id is not None
                    or session.external_session_id is not None
                ):
                    # Identity is known up front: publish the user item now so
                    # clients confirm the sent bubble without waiting for the
                    # first response byte. The SDK replay, the transcript and
                    # history all derive this exact item id from prompt_uuid.
                    # The registry binding is completed by the replay
                    # confirmation below, so it always follows the UUID the
                    # SDK actually used.
                    user_item = self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role="user",
                        text=content,
                        event="claude.turn.user",
                        client_message_id=client_message_id,
                        native_item_id=prompt_uuid,
                        item_id=stable_message_item_id(session, prompt_uuid),
                        attachments=attachment_mappings,
                    )
                    reserved_user_item = user_item
                    published_user_item_id = user_item.id
                    try:
                        await self.publish_user_message(
                            session=session,
                            item=user_item,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            native_message_id=None,
                        )
                        user_message_published = True
                    except Exception:  # noqa: BLE001
                        # Fall back to the content-gated publish; the turn still
                        # reaches Claude and the item is retried below.
                        logger.exception(
                            "Claude early user publish failed session_id={}",
                            session.session_id,
                        )
                elif command is None:
                    reserved_user_item = self.timeline.message_item(
                        session=session,
                        turn_id=turn_id,
                        role="user",
                        text=content,
                        event="claude.turn.user",
                        client_message_id=client_message_id,
                        attachments=attachment_mappings,
                    )
                await query_client(client, effective_content)

            # The frame that cast this turn out of silence, stamped by the
            # reader's mint branch on the response itself. It is a structural
            # fact — "was this the frame the cast arrived on" — never a frame
            # type, because the trigger chain is not enumerable (C3).
            #
            # The gate is positional, covering BOTH halves of what was already
            # in the queue when the turn was born: the reader's preamble flush
            # (chrome parked at silence, delivered ahead of the cast frame)
            # and the cast frame itself. Neither is this turn's own labour —
            # the turn neither produced them nor chose to consume them, they
            # arrived passively. Only what comes AFTER the turn's own cast
            # counts, which is what separates the two ghosts the content gate
            # must tell apart: re-cast residue (one in-flight tool's
            # `tool_result` or a StreamEvent — with or without stale preamble
            # in front of it — then nothing ever → stays (0, 0) → 30s fast
            # kill) from a wake that keeps working (13:49: 248.6s, 155
            # timeline items → leaves the fast kill, bounded only by the
            # ceiling). Human/pending turns are never stamped
            # (`cast_frame is None`) so `cast_reached` starts True and every
            # post-cast frame is judged by the single `_is_wire_chrome`
            # authority, exactly as a scheduled turn's are.
            # Silence itself still proves nothing either way — no frame-based
            # reset exists, so a legal `sleep 75` (72.003s of zero-frame
            # silence) is never re-armed into a short deadline.
            cast_frame = client.cast_frame
            cast_reached = cast_frame is None
            # B · start gate (claude-stale-frame-turn-tasks.md §4/§11, D1).
            #
            # The consume loop drains a session-scoped stream: whatever the CLI
            # is still emitting when this turn takes the lock is in this queue,
            # including frames that belong to a turn which already settled. The
            # 12:23 ghost is exactly that — the interrupted turn's residual
            # result was still on the wire when the next message started (real
            # session sess_tPcEDi0z9xJYxQ, 2026-10-04). I1 refuses such a frame
            # to MINT a turn; B is the second half of the same invariant, on the
            # SETTLE side: a terminal only ends a turn that has shown a start
            # it owns, and one that cannot is counted and named.
            #
            # A turn's start, by kind:
            #
            #   cast turn      — the cast frame's own position (`message is
            #                   cast_frame`): the B1 content gate's positional
            #                   rule promoted to settlement. The cast frame and
            #                   everything flushed ahead of it are passive, so a
            #                   terminal there cannot settle the turn (it is
            #                   skipped; `counts_as_labour` is false there).
            #   prompted turn  — the prompt echo the `prompt_uuid` facility binds
            #                   above, or any other non-terminal frame: once the
            #                   turn has spoken, a later result is its own.
            #   command /
            #     maintenance  — no prompt uuid exists to pair with (the CLI does
            #                   not echo those), so there is no start evidence to
            #                   wait for and the gate starts open.
            #
            # WHAT HAPPENS TO AN UNOWNED TERMINAL, and why it is not simply
            # settled (claude-stale-frame-f1-release-protocol.md §8.1).
            #
            # An unowned terminal cannot be told apart from a legitimate empty
            # reply: by the time a result is the turn's first terminal, the
            # leftover and an empty answer are the same shape on the same
            # queue (stage-1 findings §7.1), and the turn's own result is
            # indistinguishable from a leftover by construction. So the turn
            # cannot WAIT for a better frame to prove itself — that would hang
            # every empty reply until the ceiling (R1's false kill).
            #
            # It does not have to. The reason the read could not simply
            # continue used to be structural — `ClaudeResponse
            # .receive_response` ended a response at its first result, and the
            # reader held `current` until the turn released it, so "keep
            # reading for the real one" needed the release protocol rewritten.
            # That protocol now exists (F1, §8.1.2):
            #
            #   * a `completed` unowned terminal is DECLINED — recorded, never
            #     published, and the read continues;
            #   * `receive_response` bounds that continued read with
            #     `DECLINED_TERMINAL_GRACE_SECONDS`, because a human turn has
            #     no watchdog and an unbounded read is R1's worst outcome;
            #   * if the turn's own result arrives inside the window, the turn
            #     settles on it — `completed`, reply delivered
            #     (`stale_terminal_recoveries`);
            #   * if the window expires or the stream ends, the turn settles
            #     on the downgraded verdict recorded at decline time — exactly
            #     the pre-protocol behavior, G later
            #     (`stale_completion_downgrades`). The downgrade is the
            #     FALLBACK, not the verdict.
            #
            # `failed` and `interrupted` are NOT declined: they are already
            # honest about a round that went nowhere, and holding a turn open
            # past them would bury a failure the user needs to see.
            #
            # I1 still holds and is still the first line: a residual result can
            # no longer enter a queue at all from silence, which is the only
            # shape stage 1 ever reproduced (3/3). This gate is the second
            # line, and its residue stays measurable (the counters and the
            # WARN) and out of the labour count.
            turn_started = cast_frame is None and client.prompt_uuid is None
            emitted_final_assistant_content = False
            async for message in receive_response_messages(client):
                if scheduled and not turn_anchor_bound:
                    # Deferred half of the scheduled anchor: the cast frame
                    # was one that carries no transcript id (a reconnect can
                    # start on a mid-message delta), so the first assistant
                    # frame that does carry one fixes the turn. Binding is
                    # only legal while nothing has been published — every row
                    # of the turn must share the id, and a rebind after a
                    # publish would split the turn.
                    deferred_anchor = _turn_anchor_from_frame(message)
                    if deferred_anchor is not None:
                        if execution.published_items == 0:
                            turn_id = _history_turn_id(
                                session.session_id, deferred_anchor
                            )
                            execution.turn_id = turn_id
                            turn_anchor_bound = True
                        elif not turn_bind_warned:
                            turn_bind_warned = True
                            logger.warning(
                                "Claude scheduled turn kept its provisional "
                                "turn id: the anchor arrived after rows were "
                                "published session_id={} turn_id={}",
                                session.session_id,
                                turn_id,
                            )
                            turn_anchor_bound = True
                # Position, not shape: the same payload would count one frame
                # later.
                counts_as_labour = cast_reached
                if message is cast_frame:
                    cast_reached = True
                external_session_id = message_session_id(message)
                if external_session_id is not None:
                    await self._update_external_session_id(session, external_session_id)
                    response_external_session_confirmed = True
                    user_message_published = await self.publish_replayed_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                        replayed_user_message=replayed_user_message,
                        already_published=user_message_published,
                    )
                role = message_role(message)
                text = message_text(message)
                native_message_id = message_id(message)
                # The card this frame is parented to. Read after the native
                # session id is adopted, so the item id hashes under the same
                # scope the capture route would (recon findings §1.2).
                #
                # A turn active period does not sort frames by parent — every
                # frame the connection hands to the consume loop is projected
                # here, so a subagent frame that lands before this turn's result
                # used to publish its reasoning and text rows with no
                # `parentItemId` and the SubAgent panel let them into the main
                # chat (pp session sess_k4g1dE968ahtWg, seq 10/14/16/41). A
                # main-agent frame has no parent and stays byte-identical.
                frame_parent_tool_use_id = _parent_tool_use_id(message)
                frame_parent_item_id = (
                    stable_tool_item_id(session, frame_parent_tool_use_id)
                    if frame_parent_tool_use_id is not None
                    else None
                )
                if role == "assistant":
                    # Keep the turn's last concrete per-call usage around: the
                    # result-envelope fallback republishes this item id after
                    # `reset()` and must still carry usage (see
                    # `_publish_result_text`). `message_usage` returns None for
                    # sidechain frames on its own, so the stash stays main-chain
                    # only. The frame's model is stashed beside it, so the
                    # fallback's rows can name the model too.
                    stream_accumulator.remember_usage(
                        message_usage(message),
                        message_model(message),
                    )
                synthetic_control = is_synthetic_control_message(message)
                # Compaction is reported through the same events whether the CLI
                # compacted a `/compact` prompt or its own context window, so the
                # mapping stays on this shared path.
                compact_event = claude_compact_event(message)
                suppressed_control = (
                    synthetic_control or is_compaction_control_message(message)
                )
                if (
                    role == "user"
                    and text
                    and native_message_id
                    and not suppressed_control
                ):
                    replayed_user_message = (native_message_id, text)
                    if user_message_published:
                        if (
                            client.prompt_uuid is not None
                            and native_message_id != client.prompt_uuid
                        ):
                            logger.warning(
                                "Claude prompt uuid was not adopted by the SDK replay "
                                "session_id={} prompt_uuid={} replayed_uuid={}",
                                session.session_id,
                                client.prompt_uuid,
                                native_message_id,
                            )
                        self._confirm_replayed_user_binding(
                            session=session,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            replayed_user_message=replayed_user_message,
                            platform_item_id=published_user_item_id,
                        )
                    if response_external_session_confirmed:
                        user_message_published = (
                            await self.publish_replayed_user_message(
                                session=session,
                                turn_id=turn_id,
                                content=content,
                                attachments=attachment_mappings,
                                client_message_id=client_message_id,
                                reserved_user_item=reserved_user_item,
                                replayed_user_message=replayed_user_message,
                                already_published=user_message_published,
                            )
                        )
                stream_item = stream_accumulator.item_from_stream_event(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    projector=self.timeline,
                )
                # A message boundary (`message_stop`, or a new `message_start`
                # id) closes every block the just-ended message left open and
                # buffers the done rows there, because that one event can close
                # more than one. PEEK them now so they publish with this frame,
                # rather than waiting for the settle-time flush — that flush is
                # a whole-turn-late backstop, and a provider that never sends
                # the block's own stop (LiteLLM's thinking block) would leave
                # the row "running" until then. They are only CONFIRMED (dropped
                # from the buffer) after the publish below succeeds, so a failed
                # send leaves them recoverable by the settle-time flush.
                boundary_items = stream_accumulator.peek_pending_items()
                terminal_message = terminal_event_from_message(message)
                if terminal_message is not None and not counts_as_labour:
                    # B1's position rule promoted to settlement: the cast frame
                    # and everything the reader flushed ahead of it are passive
                    # arrival, so a terminal there is not this turn's verdict and
                    # does not end it. I1 already refuses to let a terminal
                    # cast a turn, so this is the second line — reachable only
                    # if that guard ever regresses. Skipped, not counted as
                    # foreign: it is not another turn's frame, it is simply not
                    # this turn's result.
                    #
                    # The decline is defensive, and it has to be here anyway:
                    # since the release protocol the reader parks on a verdict
                    # after EVERY terminal, so a path that skips a terminal
                    # without answering would leave it waiting on a `released`
                    # only a settled turn can set. Unreachable under I1, fatal
                    # without this line if I1 ever regresses.
                    client.decline_terminal()
                    continue
                unowned_terminal = terminal_message is not None and not turn_started
                if unowned_terminal:
                    # This turn has shown no work of its own, so this result
                    # cannot be shown to be its own. Counted and named, and not
                    # credited as labour (the same rule the cast frame follows:
                    # a passive arrival is not evidence the turn worked).
                    #
                    # A `completed` one does not settle the turn at all: it is
                    # DECLINED. The verdict is recorded first and the frame is
                    # then skipped completely — no result text published, no
                    # stream accumulator touched — because that text belongs to
                    # the turn that already settled, and publishing it would
                    # show the user a second copy of an answer they have. What
                    # follows it on the queue (the real reply, this turn's own
                    # result) is consumed normally and reaches the timeline.
                    #
                    # The recorded verdict is the fallback, not the outcome: if
                    # this turn's own result arrives inside the grace window it
                    # overwrites `terminal` below and the turn settles
                    # `completed`. If nothing arrives, the loop ends and the
                    # downgrade is what the user is told — "this round produced
                    # nothing" — which is both honest and re-sendable.
                    #
                    # `failed` and `interrupted` are deliberately NOT declined.
                    # They are already honest, they are not the shape this
                    # protocol was written for, and holding a turn open past
                    # them would bury the failure visibility the pending branch
                    # exists to preserve. They fall through to the settle block
                    # below, which breaks the turn.
                    self.foreign_terminal_frames += 1
                    logger.warning(
                        "Claude unowned terminal frame in-turn "
                        "session_id={} turn_id={} scheduled={} "
                        "foreign_total={} status={} reason={}",
                        session.session_id,
                        turn_id,
                        scheduled,
                        self.foreign_terminal_frames,
                        terminal_message.status,
                        terminal_message.reason,
                    )
                    if terminal_message.status == "completed":
                        downgraded_verdict = self._verdict_for_terminal(
                            execution=execution,
                            terminal=terminal_message,
                            unowned=True,
                        )
                        terminal = downgraded_verdict
                        declined_any = True
                        declined_message = message
                        client.decline_terminal()
                        continue
                elif message is cast_frame or (
                    counts_as_labour
                    and not _is_wire_chrome(message)
                    and not (
                        role == "user"
                        and client.prompt_uuid is not None
                        and native_message_id == client.prompt_uuid
                    )
                ):
                    # A cast turn starts at its cast; a prompted turn starts at
                    # the first frame of WORK it owns. Two kinds of frame are
                    # excluded on purpose, and neither of them is the turn
                    # speaking:
                    #
                    #   * the prompt echo — the connector's own prompt coming
                    #     back, with a leftover result able to arrive right
                    #     behind it (the reconnect replay);
                    #   * wire chrome — the CLI's handshake and bookkeeping
                    #     (`_is_wire_chrome`, the single authority the reader
                    #     itself gates minting on). This is §9 of the F1
                    #     release protocol, and it is what makes the gate fire
                    #     on the REAL wire. The observed order there is
                    #     [init, status, echo, residual, …]: without the
                    #     exclusion the handshake opened the gate before the
                    #     echo was even seen, the leftover counted as owned,
                    #     and the turn settled `completed` ~2 s before its own
                    #     model request — the P1 report, unfixed. 31/31 real
                    #     captures put `init` first
                    #     (recon/stale-frame/f1-preamble-gate-finding.md).
                    #
                    # "Once the turn has done real work" is the proof. Neither
                    # an echo nor a handshake is that.
                    turn_started = True
                # Everything downstream that asks "did this frame prove the turn
                # did work" must also answer no for an unowned arrival: passive
                # by definition, exactly like the cast frame above.
                counts_this_frame = counts_as_labour and not unowned_terminal
                tool_items = self.timeline.tool_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                )
                system_items = self.timeline.system_items_for_message(
                    session=session,
                    turn_id=turn_id,
                    message=message,
                    event="claude.turn.system",
                    reasoning_revision=stream_accumulator.next_thinking_final_revision(),
                )
                has_visible_message = (
                    not suppressed_control
                    and role in {"assistant", "system"}
                    and bool(text)
                )
                # Content-gate consumption point (§2 G1).
                #
                # The six-way test below IS a second authority on "did this turn
                # produce something" — the first being `drive_turn`'s own branches.
                # That duplication is deliberate and must stay in sync; it is
                # pinned from the outside by
                # `test_content_gate_counts_every_shape_that_projects_something`
                # (property over the SDK frame corpus: a shape that projects an
                # item MUST move the counter), so a future `drive_turn` branch that
                # projects without matching one of these six shapes turns the suite
                # red instead of silently under-counting into a false kill.
                #
                # DO NOT "de-duplicate" it into
                # `counts_as_labour and not _is_wire_chrome(message)`. That form is
                # shorter and looks like the obvious cleanup; it is wrong. It
                # exempts any turn that receives a single non-chrome frame after the
                # cast, which pushes a zero-content ghost out of the 30s fast kill
                # and into the 600s ceiling — and a held execution lock refuses
                # user messages outright (`turns/actions.py`:
                # `claude_turn_already_running`), so that is ten minutes of an
                # unusable session, bought to remove a hypothetical.
                #
                # The gate also trusts two structural facts — the frame is this turn's
                # labour (past the cast: everything the queue held BEFORE and AT
                # the cast is passive, set positionally by `counts_as_labour`) and
                # the frame is not chrome (`_is_wire_chrome`, the single authority
                # the reader itself gates minting on).
                #
                # DO NOT collapse this into `counts_as_labour and not
                # _is_wire_chrome(message)`. That form is simpler and would remove
                # the apparent duplication with `drive_turn` below — and it is
                # wrong: it exempts any turn that receives one non-chrome frame
                # after the cast, which pushes a zero-content ghost from the 30s
                # fast kill out to the 600s ceiling. A held execution lock refuses
                # user messages outright (`turns/actions.py`: `claude_turn_already_running`),
                # so that is ten minutes of an unusable session, bought to remove a
                # hypothetical. The duplication is instead pinned from the outside
                # by `test_content_gate_counts_every_shape_that_projects_something`
                # (property over the SDK frame corpus: projects an item ⇒ counts),
                # so a future `drive_turn` branch that projects without counting
                # turns the suite red instead of silently under-counting into a
                # false kill.
                if (
                    counts_this_frame
                    and not _is_wire_chrome(message)
                    and (
                        is_stream_event(message)
                        or stream_item is not None
                        or terminal_message is not None
                        or bool(tool_items)
                        or bool(system_items)
                        or has_visible_message
                    )
                ):
                    execution.consumed_frames += 1
                if not user_message_published and (
                    stream_item is not None
                    or terminal_message is not None
                    or bool(tool_items)
                    or bool(system_items)
                    or has_visible_message
                ):
                    await self.publish_fallback_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                    )
                    user_message_published = True
                if stream_item is not None:
                    # The row already carries the parent of the frame that
                    # produced it (stream.py `_partial_item` /
                    # `_thinking_partial_item`), so no ambient parent is applied
                    # here: the `content_block_stop` route hands a reasoning row
                    # straight back through this publish, and a subagent frame
                    # could be the one consumed at that moment.
                    await self.publish_items(
                        execution,
                        (stream_item,),
                        counted=counts_this_frame,
                    )
                if boundary_items:
                    await self.publish_items(
                        execution,
                        boundary_items,
                        counted=counts_this_frame,
                    )
                    # Only now that the send has not raised is it safe to drop
                    # them: a failure here leaves them buffered for the
                    # settle-time flush, instead of losing a closed row.
                    stream_accumulator.confirm_pending_items(len(boundary_items))
                if is_stream_event(message):
                    continue
                if terminal_message is not None:
                    terminal = self._verdict_for_terminal(
                        execution=execution,
                        terminal=terminal_message,
                        unowned=unowned_terminal,
                    )
                    if not emitted_final_assistant_content:
                        emitted_final_assistant_content = await self._publish_result_text(
                            execution=execution,
                            session=session,
                            turn_id=turn_id,
                            message=message,
                            stream_accumulator=stream_accumulator,
                            counted=counts_this_frame,
                        )
                    if declined_any and not unowned_terminal:
                        # The turn's verdict was NOT the frame it would have
                        # settled on: a leftover was declined, the read
                        # continued, and this turn's own result arrived behind
                        # it. The reply reached the timeline in the turn that
                        # asked for it — the P1 shape closed, not relabelled.
                        self.stale_terminal_recoveries += 1
                        logger.info(
                            "Claude stale terminal declined, turn recovered "
                            "turn_id={} recoveries={}",
                            execution.turn_id,
                            self.stale_terminal_recoveries,
                        )
                    if counts_as_labour:
                        # Every case where this terminal is NOT the turn's
                        # verdict has already left the loop above: the cast
                        # position, or an unowned `completed` declined. So
                        # arriving here always ends the turn. The condition
                        # used to also name `not unowned_terminal`, because an
                        # unowned terminal used to fall through HERE to settle;
                        # it is the `continue` that decides that now. Leaving
                        # this out would read past the turn's own verdict into
                        # whatever the next turn sends — the generator no longer
                        # stops at its first result, so nothing else stops it.
                        break
                await self.publish_items(
                    execution, tool_items, counted=counts_this_frame
                )
                await self.publish_items(
                    execution,
                    _with_parent_cards(system_items, frame_parent_item_id),
                    counted=counts_this_frame,
                )
                if compact_event is not None:
                    await self.publish_items(
                        execution,
                        (
                            self.markers.item_for_event(
                                session=session,
                                turn_id=turn_id,
                                event=compact_event,
                            ),
                        ),
                        counted=counts_this_frame,
                    )
                if suppressed_control:
                    continue
                if role not in {"assistant", "system"}:
                    continue
                if not text:
                    continue
                # The per-call usage of this reply. The final frame is
                # authoritative when it carries one; the streamed seed is the
                # fallback so this last write for the item id cannot strip the
                # usage the partial items already carried. Both are per-call
                # values — `ResultMessage.usage` is turn-cumulative and is not
                # read here. Sidechain rows stay without usage entirely.
                assistant_usage: dict[str, int] | None = None
                assistant_usage_model: str | None = None
                if role == "assistant" and frame_parent_tool_use_id is None:
                    assistant_usage = (
                        message_usage(message) or stream_accumulator.partial_usage
                    )
                    assistant_usage_model = (
                        message_model(message) or stream_accumulator.partial_model
                    )
                await self.publish_items(
                    execution,
                    (
                        _with_parent_card(
                            self.timeline.message_item(
                                session=session,
                                turn_id=turn_id,
                                role=role,
                                text=text,
                                event=f"claude.turn.{role}",
                                native_item_id=message_id(message),
                                item_id=stream_accumulator.final_item_id(
                                    session, turn_id
                                )
                                if role == "assistant"
                                else None,
                                revision=stream_accumulator.next_final_revision()
                                if role == "assistant"
                                else 1,
                                usage=assistant_usage,
                                usage_model=assistant_usage_model,
                            ),
                            frame_parent_item_id,
                        ),
                    ),
                    counted=counts_this_frame,
                )
                if role == "assistant" and frame_parent_tool_use_id is None:
                    # Only a MAIN-chain assistant frame ends the turn's streamed
                    # message. A subagent's aggregated frame is published above
                    # (with its card) but must NOT touch the main stream's state:
                    # `reset()` nulls `partial_message_id`, so letting a
                    # background subagent's frame run it destroyed the identity
                    # of the message the MAIN chain was still streaming, and
                    # every later main thinking/text delta was dropped as
                    # "without message_start id" until the main chain opened its
                    # next message (2026-10-15; the live incident published a
                    # parented assistant row 0.42s before the drop wave, and the
                    # fix's red test reproduces both journal lines). The same
                    # guard also keeps `emitted_final_assistant_content` honest:
                    # set by a subagent frame it suppressed the main turn's
                    # result-text fallback, losing the reply outright. The
                    # `assistant_usage` block above already guards exactly this
                    # way; the reset and the flag simply never got the guard.
                    emitted_final_assistant_content = True
                    # The final assistant frame ends the streamed message, so
                    # resetting is a boundary: close (and publish) any thinking
                    # block the message left open, rather than dropping it.
                    # This is the point the LiteLLM frame order forced — the
                    # aggregated frame arrives BEFORE `message_stop`, so a
                    # boundary close that only watched `message_stop` would
                    # find the block already cleared here.
                    settled_items = stream_accumulator.reset(
                        session, turn_id, self.timeline, reason="assistant_frame"
                    )
                    if settled_items:
                        # `reset()` closes only this message's own open thinking
                        # blocks, each already carrying the parent of the frame
                        # that opened it — no ambient parent is applied here
                        # (a subagent frame can be the one that launched the
                        # reset, and stamping its card on a main-chain row is
                        # exactly the 2026-10-14 mis-attribution).
                        await self.publish_items(
                            execution,
                            settled_items,
                            counted=counts_this_frame,
                        )

            if (
                declined_message is not None
                and not emitted_final_assistant_content
                and terminal is downgraded_verdict
            ):
                # The decline was a DEFERRAL, and the read ended without
                # anything better, so the frame the turn deferred is now its
                # verdict — text included. Publishing it here is what the
                # pre-protocol path did; staying silent would drop a
                # legitimate empty reply's answer on the floor, which is a
                # worse failure than the one the protocol fixes. When a real
                # reply did arrive, this branch is skipped and the leftover's
                # text is never published at all.
                await self._publish_result_text(
                    execution=execution,
                    session=session,
                    turn_id=turn_id,
                    message=declined_message,
                    stream_accumulator=stream_accumulator,
                    counted=False,
                )
            if terminal is None:
                terminal = failed_terminal_event(
                    code="claude_stream_ended_without_result",
                    message="Claude response stream ended without a terminal result",
                    reason="stream_exhausted",
                )
        except asyncio.CancelledError:
            terminal = interrupted_terminal_event(
                execution.interrupt_reason or "cancelled"
            )
        except Exception as exc:  # noqa: BLE001
            terminal = failed_terminal_event(
                code=exc.__class__.__name__,
                message=stderr.failure_message(exc),
            )
        finally:
            if execution.interrupt_source is not None:
                terminal = interrupted_terminal_event(execution.interrupt_reason)
            if reserved_user_item is not None and not user_message_published:
                try:
                    user_message_published = await self.publish_replayed_user_message(
                        session=session,
                        turn_id=turn_id,
                        content=content,
                        attachments=attachment_mappings,
                        client_message_id=client_message_id,
                        reserved_user_item=reserved_user_item,
                        replayed_user_message=replayed_user_message,
                        already_published=False,
                    )
                    if not user_message_published:
                        await self.publish_fallback_user_message(
                            session=session,
                            turn_id=turn_id,
                            content=content,
                            attachments=attachment_mappings,
                            client_message_id=client_message_id,
                            reserved_user_item=reserved_user_item,
                        )
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "Claude user message publish failed session_id={}",
                        session.session_id,
                    )
            reconciled = False
            if connection is not None and client is not None:
                if (
                    scheduled
                    and terminal is not None
                    and terminal.status == "completed"
                ):
                    connection.reconcile_needed = True
                if (
                    connection.reconcile_needed
                    and connection.retained
                    and not connection.reconciling
                    and not connection.background.active_ids
                    and connection.pending is None
                    and not connection.closing
                    and not self.stopping
                    and terminal is not None
                    and terminal.status == "completed"
                ):
                    try:
                        reconciled = await connection.reconcile_tasks(client)
                    except asyncio.CancelledError:
                        terminal = interrupted_terminal_event(
                            execution.interrupt_reason
                        )
            if connection is not None and (connection.retained or reconciled):
                try:
                    await self.scheduled_sessions.save(session, connection.task_ids)
                except Exception as exc:  # noqa: BLE001
                    terminal = failed_terminal_event(
                        code="claude_schedule_save_failed", message=str(exc)
                    )
            execution.client = None
            if terminal is None:
                terminal = failed_terminal_event(
                    code="claude_turn_missing_terminal_state",
                    message="Claude turn stopped without a terminal state",
                )
            # F1: commit the downgrade only now, and only if it is still the
            # verdict. Identity is the test — a decline recorded the exact
            # object, and every path that replaced the verdict since (this
            # turn's own result, a failure, an interrupt, an exhausted stream)
            # left a different object behind. So a recovered turn never lands
            # here with the downgrade, and the counter keeps its narrowed
            # meaning: "the fix did not catch this one".
            if downgraded_verdict is not None and terminal is downgraded_verdict:
                self._record_stale_completion_downgrade(execution)
            await self.settle_compact_markers(session, turn_id, execution)
            try:
                await self.finish_execution(
                    session=session,
                    execution=execution,
                    terminal=terminal,
                    response=client,
                )
            finally:
                if connection is not None:
                    if terminal.status == "failed":
                        if connection.has_live_background_work:
                            # Do-not-retire invariant: a failed turn retires
                            # its transport because the CLI state is no longer
                            # trusted — but never while background work lives
                            # in that process; killing it would destroy work
                            # upstream cannot replay. The next turn reuses the
                            # transport; real breakage still surfaces as its
                            # own failed turn.
                            logger.warning(
                                "Claude failed-turn transport close skipped: "
                                "background work is live session_id={} "
                                "turn_id={} active_tasks={}",
                                session.session_id,
                                turn_id,
                                len(connection.background.active_ids),
                            )
                        else:
                            await connection.close()
                    else:
                        if (
                            not connection.streaming
                            and not connection.retained
                            and connection.pending is None
                        ):
                            await connection.close()
                        else:
                            connection.arm_idle()
                        await self.refresh_idle_connection(session)
            try:
                settled_batch = stream_accumulator.finalize_pending_thinking(
                    session,
                    turn_id,
                    self.timeline,
                )
                # Each settled row already carries the parent of the frame that
                # opened its block (stream.py), so no ambient parent is applied
                # — `stream_parent_item_id` was a turn-scoped single variable
                # overwritten by every stream frame, and an unrelated subagent
                # frame could be the last one before this flush.
                await self.publish_items(
                    execution,
                    settled_batch,
                )
            except Exception:  # noqa: BLE001
                settled_batch = ()
                logger.exception(
                    "Claude reasoning flush failed session_id={}",
                    session.session_id,
                )
            if settled_batch:
                # L3b, second half (red team F4). The first request for this
                # session's refresh went out from `finish_execution`, which runs
                # BEFORE this block — so the snapshot it asked for could not
                # contain the rows this block is about to publish, and the very
                # batch L3b was raised for (12:24: a dozen rows formed at settle
                # and shipped on the next global beat) still waited a whole
                # interval. Ask again now that they are out. Only when there is
                # a batch: a turn that published nothing extra must not pay for
                # a second transcript read.
                await self._request_settled_session_sync(session)
            if connection is not None:
                # The turn is fully settled (terminal state published, rows
                # flushed), and the transport that just ran it is idle: the
                # natural moment to calibrate the context window. Runs last so
                # it can never delay anything the turn owed its user, and it
                # swallows its own failures (a turn must never fail over a
                # probe).
                await self.calibrate_context_window(session)

    def _verdict_for_terminal(
        self,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        *,
        unowned: bool,
    ) -> ClaudeTerminalEvent:
        """Downgrade a `completed` this turn cannot own, and say why.

        The invariant a turn settles on: a terminal frame ends exactly one turn,
        the one that can prove it started it. When the proof is missing,
        `completed` is a lie with consequences — the
        client shows the turn succeeded, the reply that is still behind the
        swallowed frame never arrives, and the user is looking at an idle
        session with an empty composer. That is the 2026-10-04 P1 report
        verbatim, and it survived I1 because I1 only guards the MINT path: this
        frame was already inside a live turn.

        So the verdict is degraded, not suppressed. `interrupted` with a
        structured reason says exactly what happened — this round produced
        nothing — and it is a state the user can act on (re-send) rather than
        one that invites them to wait for a reply that is never coming. The
        reason string is what the client's `terminalReason` carries, so the
        condition is visible in the turn ledger instead of being swallowed here.

        This is a PURE function of the frame: it decides the verdict and counts
        nothing. Since F1 the verdict is recorded at DECLINE time, long before
        the turn knows whether it will be the one it settles on, so the
        counter moved to `_record_stale_completion_downgrade`, which only runs
        where the downgrade is actually committed.

        Cost, stated plainly: a genuine empty reply — a turn whose whole stream
        is its own result — is indistinguishable from this and is degraded too.
        That is the deliberate trade (pp, red team F1): to the user both are
        "this round produced nothing", and reporting one of them as a success
        is the failure mode being fixed. Under the release protocol that trade
        is now bounded by the grace window rather than permanent: the empty
        reply settles on this verdict G seconds late instead of at once, and
        the reply that does exist behind a leftover is no longer lost.

        THE CASCADE this can still create, measured (red team round 2 §5.3).
        The release protocol removes the everyday path: a leftover no longer
        ends the turn, so the frames behind it — the prompt echo, the real
        reply, the real result — are consumed by the turn that asked for
        them. But it is bounded by `DECLINED_TERMINAL_GRACE_SECONDS`, and a
        leftover whose real frames arrive later than that still falls back to
        settling here. Then the turn breaks on the frame it could not attribute,
        the frames behind it are left in the reader's queue with nobody holding
        them, and at silence the echo is a user frame, which mints a scheduled
        turn: that phantom consumes the rest and settles `completed` carrying
        the answer. As measured it is benign — two bubbles, `completed`,
        session back to idle, no error state, nothing left running — and the
        user-visible cost is one answer split across two bubbles, the first
        marked "interrupted / this round produced nothing".

        The honest edge: the "phantom with only the echo and nothing after it"
        variant could NOT be constructed by the red team, so whether that one
        would sit zero-content until the 30 s fast kill and flip the session to
        an error is UNVERIFIED. Mechanically it is the same shape as a genuinely
        hung turn (zero content, no terminal), which is why it is on the stage-3
        watch list rather than dismissed.

        Only `completed` is degraded. `failed` and `interrupted` are already
        honest about a round that went nowhere, and rewriting them would destroy
        the failure visibility the pending branch exists to preserve. Only
        `completed` is declined, too — see the gate's note in `drive_turn` for
        why a failure must not be waited out.
        """

        if terminal.status != "completed" or not unowned:
            return terminal
        # No separate "and the turn produced nothing" test, and that is a
        # measured decision rather than an omission: it cannot be reached. Any
        # frame that counts as work also opens the start gate above (every
        # counted shape is a non-terminal one), so an unowned terminal already
        # implies a turn that consumed nothing. Writing the check anyway made
        # it a guard with no failing input — the thing red team F7 flagged in B
        # — and a guard nobody can trip is a comment that lies about what the
        # code guarantees.
        return interrupted_terminal_event(STALE_COMPLETION_REASON)

    async def _publish_result_text(
        self,
        *,
        execution: ClaudeExecution,
        session: ClaudeSession,
        turn_id: str,
        message: Any,
        stream_accumulator: ClaudeStreamAccumulator,
        counted: bool,
    ) -> bool:
        """Publish a terminal frame's own text as this turn's final bubble.

        The fallback for a turn whose reply never arrived as a separate
        assistant frame — the CLI put the words in the result envelope
        instead. It is reached in exactly two shapes: an ordinary empty reply,
        and a turn that declined a leftover and then got nothing better, where
        the declined frame becomes the verdict after all (see the publish
        below the read loop).

        The item id it shares with the assistant frame is NOT a "a later reply
        replaces this text by revision" promise. Within a turn the read is
        over by the time this runs, so there is no later reply to do any
        replacing; and a reply that arrives in a LATER turn is that turn's own
        bubble — if the same answer is ever seen in two bubbles, the second is
        a phantom, not a revision.

        Returns whether anything was published, so the caller can keep its
        "final content already emitted" flag honest.
        """

        text = message_text(message)
        if not text:
            return False
        # The frame that carries this text (a ResultMessage envelope) reports
        # turn-cumulative totals, not one call's usage and not this item's. The
        # item id, though, is the streamed assistant message's — the partial
        # items already published usage on it — so the last per-call usage the
        # accumulator holds rides along and the fallback's later write cannot
        # publish over the item without one.
        await self.publish_items(
            execution,
            (
                self.timeline.message_item(
                    session=session,
                    turn_id=turn_id,
                    role="assistant",
                    text=text,
                    event="claude.turn.result",
                    native_item_id=message_id(message),
                    item_id=stream_accumulator.final_item_id(
                        session,
                        turn_id,
                    ),
                    revision=stream_accumulator.next_final_revision(),
                    usage=stream_accumulator.result_text_usage(),
                    usage_model=stream_accumulator.result_usage_model(),
                ),
            ),
            counted=counted,
        )
        # The turn's final text is out; the streamed message is over, so close
        # (and publish) any thinking block still open rather than dropping it.
        settled_items = stream_accumulator.reset(
            session, turn_id, self.timeline, reason="result_text"
        )
        if settled_items:
            await self.publish_items(
                execution,
                settled_items,
                counted=counted,
            )
        return True

    def _record_stale_completion_downgrade(self, execution: ClaudeExecution) -> None:
        """Count a turn that really did settle on a result it could not own.

        Called only where that verdict is COMMITTED — after the read ends, once
        nothing better has replaced it. A turn that declined a leftover and
        then received its own result never reaches here with the downgraded
        verdict, which is what makes this counter and
        `stale_terminal_recoveries` a control pair: one counts the frames the
        release protocol saved, the other the ones it did not, and the raw
        `foreign_terminal_frames` counts every unowned terminal either way
        (F6: it cannot carry this job — a legitimate empty reply increments
        it too).
        """

        self.stale_completion_downgrades += 1
        logger.warning(
            "Claude completed downgraded to interrupted: turn settled on a "
            "result it could not attribute turn_id={} downgrades={}",
            execution.turn_id,
            self.stale_completion_downgrades,
        )

    async def publish_items(
        self,
        execution: ClaudeExecution,
        items: Iterable[RuntimeTimelineItem],
        *,
        counted: bool = True,
    ) -> None:
        """Upsert one turn's projected items and count them for the content gate.

        Every publish point inside `drive_turn` goes through here so
        `published_items` cannot drift from what the user actually saw. The
        count is bookkeeping only: nothing reads it unless a scheduled watchdog
        is armed, and no human turn is.

        `counted=False` is the cast-frame gate: items projected while
        processing the frame that cast this turn still reach the user (the
        projection itself must not change), but they are not evidence that the
        turn did work — that frame arrived passively. Publication outside the
        consume loop (compact markers, the reasoning flush) is the turn's own
        action and always counts.
        """

        for item in items:
            await self.notifications.timeline_activity.timeline_item_upsert(item)
            if counted:
                execution.published_items += 1

    async def open_command_compact_marker(
        self,
        session: ClaudeSession,
        turn_id: str,
        execution: ClaudeExecution | None = None,
    ) -> None:
        """Publish the running marker a command turn owes before dispatch."""

        try:
            items = self.markers.open_command_marker(
                session=session,
                turn_id=turn_id,
            )
            if execution is not None:
                await self.publish_items(execution, items)
            else:
                for item in items:
                    await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude compaction marker open failed session_id={}",
                session.session_id,
            )

    async def settle_compact_markers(
        self,
        session: ClaudeSession,
        turn_id: str,
        execution: ClaudeExecution | None = None,
    ) -> None:
        """Close a compaction marker this turn never proved complete.

        A command turn opens its marker before dispatch, and compaction
        otherwise reports success through its own events. Either way a turn
        that ends without proof of completion — failed, interrupted, or
        resolved without compacting — must not leave the client showing a
        running separator.

        The marker belongs to the session but only its opening turn may settle
        it. The CLI streams the frames that finish a compaction after that turn
        has ended, so this runs on the scheduled reader turn too; settling there
        would fail a separator whose success is already on the wire. Evidence
        that arrives after a settle corrects the marker instead.
        """

        try:
            items = self.markers.settle_turn(session=session, turn_id=turn_id)
            if execution is not None:
                await self.publish_items(execution, items)
            else:
                for item in items:
                    await self.notifications.timeline_activity.timeline_item_upsert(item)
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude compaction marker settle failed session_id={}",
                session.session_id,
            )

    async def publish_replayed_user_message(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        reserved_user_item: RuntimeTimelineItem,
        replayed_user_message: tuple[str, str] | None,
        already_published: bool,
    ) -> bool:
        """Publish the live user item once Claude confirms its native identity."""

        if already_published:
            return True
        if session.external_session_id is None or replayed_user_message is None:
            return False
        native_message_id, text = replayed_user_message
        if not client_message_text_matches(text, content):
            return False
        item_id = stable_message_item_id(session, native_message_id)
        self.timeline.move_reserved_order(reserved_user_item.id, item_id)
        user_item = self.timeline.message_item(
            session=session,
            turn_id=turn_id,
            role="user",
            text=content,
            event="claude.turn.user",
            client_message_id=client_message_id,
            native_item_id=native_message_id,
            item_id=item_id,
            attachments=attachments,
        )
        await self.publish_user_message(
            session=session,
            item=user_item,
            content=content,
            attachments=attachments,
            client_message_id=client_message_id,
            native_message_id=native_message_id,
        )
        return True

    def _confirm_replayed_user_binding(
        self,
        *,
        session: ClaudeSession,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        replayed_user_message: tuple[str, str] | None,
        platform_item_id: str | None,
    ) -> None:
        """Bind the live user item to the UUID the SDK actually replayed.

        The early publish only pre-assigned a UUID; the replay is the
        authority. With a client message id this promotes the pending
        registry binding; without one it records a native-to-platform bridge
        so history keeps reusing the live item id.
        """

        if replayed_user_message is None or session.external_session_id is None:
            return
        native_message_id, text = replayed_user_message
        if not client_message_text_matches(text, content):
            return
        try:
            if client_message_id is not None:
                self.pending_messages.bind_live_native_message(
                    session_id=session.session_id,
                    external_session_id=session.external_session_id,
                    client_message_id=client_message_id,
                    native_message_id=native_message_id,
                    text=content,
                )
            elif platform_item_id is not None:
                self.pending_messages.record_replayed_platform_id(
                    session_id=session.session_id,
                    external_session_id=session.external_session_id,
                    native_message_id=native_message_id,
                    platform_item_id=platform_item_id,
                    text=content,
                    attachments=attachments,
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude user message identity binding failed session_id={}",
                session.session_id,
            )

    async def publish_fallback_user_message(
        self,
        *,
        session: ClaudeSession,
        turn_id: str,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        reserved_user_item: RuntimeTimelineItem,
    ) -> None:
        """Publish the reserved ID when the SDK omits a replayed user UUID."""

        fallback_user_item = self.timeline.message_item(
            session=session,
            turn_id=turn_id,
            role="user",
            text=content,
            event="claude.turn.user",
            client_message_id=client_message_id,
            item_id=reserved_user_item.id,
            attachments=attachments,
        )
        await self.publish_user_message(
            session=session,
            item=fallback_user_item,
            content=content,
            attachments=attachments,
            client_message_id=client_message_id,
            native_message_id=None,
        )

    async def publish_user_message(
        self,
        *,
        session: ClaudeSession,
        item: RuntimeTimelineItem,
        content: str,
        attachments: tuple[dict[str, object], ...],
        client_message_id: str | None,
        native_message_id: str | None,
    ) -> None:
        """Publish one user item and retain bounded history reconciliation data."""

        await self.notifications.timeline_activity.timeline_item_upsert(item)
        try:
            self.pending_messages.register_live_message(
                session_id=session.session_id,
                external_session_id=session.external_session_id,
                client_message_id=client_message_id,
                platform_item_id=item.id,
                text=content,
                attachments=attachments,
            )
            if native_message_id is None or session.external_session_id is None:
                return
            self.pending_messages.bind_live_native_message(
                session_id=session.session_id,
                external_session_id=session.external_session_id,
                client_message_id=client_message_id,
                native_message_id=native_message_id,
                text=content,
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude user message identity persistence failed session_id={}",
                session.session_id,
            )

    async def finish_execution(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        response: ClaudeResponse | None = None,
        *,
        publish: bool = True,
    ) -> bool:
        """Publish one terminal state and release this exact execution.

        `publish=False` keeps the terminal off the client-visible turn ledger
        while every lock/release guarantee still runs — the circuit breaker's
        one-report-per-window limiter uses it for repeat timeouts.
        """

        async with execution.finalization_lock:
            self.disarm_scheduled_watchdog(execution)
            if execution.finished.is_set():
                return False
            async with session.execution_lock:
                queued = session.queued_execution is execution
                if session.execution is not execution and not queued:
                    if response is not None:
                        response.release(interrupted=terminal.status == "interrupted")
                    execution.finished.set()
                    return False
                try:
                    if not queued:
                        await self.interactions.close_open_interaction_notices(
                            session,
                            status="closed",
                            reason=terminal.status,
                        )
                    await self.publish_terminal_state(
                        session,
                        execution,
                        terminal,
                        update_state=not queued,
                        publish=publish,
                    )
                    if not queued:
                        # L3b: ask the connector to refresh this session's
                        # timeline now instead of at the next global sync beat.
                        # The push above already carried this turn's rows; what
                        # this buys is the snapshot that catches anything the
                        # push published late, reordered, or missed — which on
                        # 2026-10-04 was the difference between a reply and 30
                        # to 50 seconds of an idle-looking session.
                        #
                        # Fire-and-forget by contract: `on_turn_settled` returns
                        # immediately, so this costs the turn nothing. And it is
                        # display plumbing, so it can never fail a turn that has
                        # already been correctly settled.
                        await self._request_settled_session_sync(session)
                finally:
                    if response is not None:
                        response.release(interrupted=terminal.status == "interrupted")
                    if queued:
                        session.queued_execution = None
                    else:
                        session.execution = session.queued_execution
                        session.queued_execution = None
                    if not queued and session.execution is not None:
                        await self.notifications.session_state.session_state_update(
                            session,
                            "running",
                            metadata={"source": "claude.turn.running"},
                        )
                    execution.finished.set()
            return True

    async def _request_settled_session_sync(self, session: ClaudeSession) -> None:
        """Tell the connector this session settled, so it can refresh it now.

        L3b. A no-op on any host that does not implement the signal (the
        protocol default), which is what keeps a runtime built for tests or for
        an older connector behaving exactly as before. Failures are logged and
        swallowed: the turn has already published its verdict by the time this
        runs, and nothing about a follow-up refresh is worth failing it for.
        """

        try:
            await self.host.on_turn_settled(
                session.session_id, session.external_session_id
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "Claude settled session sync request failed session_id={}",
                session.session_id,
            )

    async def publish_terminal_state(
        self,
        session: ClaudeSession,
        execution: ClaudeExecution,
        terminal: ClaudeTerminalEvent,
        *,
        update_state: bool = True,
        publish: bool = True,
    ) -> None:
        reason = terminal.reason or execution.interrupt_reason
        if terminal.status == "failed":
            metadata = {
                "source": "claude.turn.failed",
                **({"terminalReason": reason} if reason else {}),
            }
            if publish:
                await self.host.session_turn_ended(
                    session_id=session.session_id,
                    runtime="claude",
                    external_session_id=session.external_session_id,
                    turn_id=execution.turn_id,
                    outcome="failed",
                    metadata=metadata,
                )
            else:
                logger.warning(
                    "Claude repeat scheduled-timeout failure kept off the "
                    "client ledger session_id={} turn_id={}",
                    session.session_id,
                    execution.turn_id,
                )
            if not update_state:
                return
            await self.notifications.session_state.session_state_update(
                session,
                "error",
                error={
                    "code": terminal.error_code or "claude_turn_failed",
                    "message": terminal.error_message or "Claude turn failed",
                },
                metadata=metadata,
            )
            return
        source = "claude.turn.completed"
        if terminal.status == "interrupted":
            source = execution.interrupt_source or "claude.turn.interrupted"
        metadata = {
            "source": source,
            **({"terminalReason": reason} if reason else {}),
        }
        await self.host.session_turn_ended(
            session_id=session.session_id,
            runtime="claude",
            external_session_id=session.external_session_id,
            turn_id=execution.turn_id,
            outcome=terminal.status,
            metadata=metadata,
        )
        if not update_state:
            return
        await self.notifications.session_state.session_state_update(
            session,
            "idle",
            metadata=metadata,
        )

    async def _update_external_session_id(
        self,
        session: ClaudeSession,
        external_session_id: str,
    ) -> None:
        if not self.session_store.update_external_session_id(
            session,
            external_session_id,
        ):
            return
        self.pending_messages.bind_external_session(
            session.session_id,
            external_session_id,
        )
        await self.notifications.session_state.session_meta_upsert(
            session,
            source="claude.session.external_id",
        )


def _parent_tool_use_id(message: Any) -> str | None:
    """Read the dispatch tool call a captured subagent frame is parented to."""

    if isinstance(message, Mapping):
        value = message.get("parent_tool_use_id")
    else:
        value = getattr(message, "parent_tool_use_id", None)
    return value if isinstance(value, str) and value else None


def _with_parent_card(
    item: RuntimeTimelineItem,
    parent_item_id: str | None,
) -> RuntimeTimelineItem:
    """Attach the parentItemId convention to a subagent reasoning/message row.

    Tool rows already carry it from the projector (messages.py); the rows the
    projector cannot reach — reasoning (thinking) and message (text) rows —
    get the same free-JSON key here so the SubAgent panel can attribute them
    (claude-subagent-progress-tasks.md §3.3).

    Two routes reach this, because a subagent frame is projected by whichever
    one the frame's arrival time selects: the capture route (frames that reach
    silence) and the in-turn projection (frames that land while a turn or a
    scheduled turn is active — recon findings §1.2). The history rebuild and
    nested Agent rows keep their exact content, and so does every row of a
    frame with no parent: `parent_item_id is None` returns the item itself.
    """

    if parent_item_id is None or item.type not in {"system", "message"}:
        return item
    content = {**dict(item.content), "parentItemId": parent_item_id}
    return replace(
        item,
        content=content,
        content_hash=timeline_content_hash(
            item_type=item.type,  # type: ignore[arg-type]
            status=item.status,  # type: ignore[arg-type]
            role=item.role,  # type: ignore[arg-type]
            content=content,
        ),
    )


def _with_parent_cards(
    items: Iterable[RuntimeTimelineItem],
    parent_item_id: str | None,
) -> tuple[RuntimeTimelineItem, ...]:
    """`_with_parent_card` over a batch, for the projection's batched rows.

    The in-turn projection publishes two batches rather than single items — the
    frame's reasoning rows and the settle-time thinking flush — so this keeps
    the same call at both instead of rebuilding a tuple per site. It stays the
    identity transform (the very same item objects) when there is no parent, so
    a main-agent turn publishes exactly what it published before.
    """

    if parent_item_id is None:
        return tuple(items)
    return tuple(_with_parent_card(item, parent_item_id) for item in items)
