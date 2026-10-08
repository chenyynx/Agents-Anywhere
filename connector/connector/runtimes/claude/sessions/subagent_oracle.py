"""Decide an Agent card's true terminal state from engine evidence.

Why this module exists (R1/R2, ``.local-dev/subagent-status-truth-tasks.md``)
---------------------------------------------------------------------------
Two ways an Agent card could be stranded ``running`` forever:

* The CLI persists a completed background task as a ``<task-notification>``
  transcript row, but a notice whose wrapper layout the SDK's message view
  drops never reaches the fold — the card's terminal event was read from a
  surface that does not carry it (R1).
* The host process is killed (connector restart, session exit) and the CLI
  emits **no** terminal event at all — nothing can ever close the card (R2).

The engine's own bookkeeping is the missing third truth source. Alongside the
main transcript the CLI writes ``<uuid>/subagents/agent-<taskid>.jsonl`` (the
subagent's own transcript) and ``agent-<taskid>.meta.json``. Measured on the
2026-10-08 sessions, each ``agent-<taskid>.jsonl`` mtime lands within a second
of that task's true terminal time (9/9). A file that has stopped growing is a
task that has stopped running.

This module turns that into one judgement — :func:`ClaudeSubagentOracle.evidence`
— that both the history fold and the live sweep consult, so an offline rebuild
and a live turn can never disagree on whether a card is alive.

Everything the decision depends on (the clock and the filesystem probe) is
injectable, so the tests drive the judgement with a fake clock and fake files
and never touch the real disk or wall time.
"""

from __future__ import annotations

import json
import os
import re
import time
import unicodedata
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from connector.logging import logger
from connector.runtimes.claude.sdk.tasks import (
    ClaudeTaskEvent,
    task_events_from_notification_text,
)
from connector.runtimes.claude.timeline.agent_calls import agent_task_terminal_status

#: How a card was closed from engine evidence. Carried on the item's
#: ``content.metadata`` so a closure is auditable next to the status the client
#: renders.
ClosedByEvidence = Literal["terminalNotice", "agentFileStale", "neverStarted"]

#: An ``async_launched`` dispatch with no subagent transcript at all is judged
#: dead once its launch receipt is older than this. Long enough that an ordinary
#: launch (the CLI creates the transcript within a second or two) is never
#: mistaken for a never-started one, short enough to reap the ghost (S3) fast.
SUBAGENT_START_GRACE_SECONDS: float = 120.0

#: A subagent transcript that has not grown for this long, with no terminal
#: notice, is judged dead. 15 minutes of total silence while supposedly running
#: is not a long tool call — every assistant turn rewrites the transcript — so
#: the conservative reading is "the host was killed". The task sheet fixed this
#: default (宁长勿短但有界); it is deliberately generous because a false close
#: is worse than a slow one, and the value is overridable at construction.
SUBAGENT_STALE_SECONDS: float = 900.0

#: Tolerance around a terminal notice's own timestamp when comparing it to the
#: file mtime. The notice is written a beat after the last transcript append, so
#: the file may be a hair older than the notice without meaning the task was
#: reopened; anything older than the notice by more than this tolerance proves
#: nobody was writing after the notice closed the task.
SUBAGENT_MTIME_TOLERANCE_SECONDS: float = 2.0

#: The CLI names each project directory after its cwd by replacing every
#: non-alphanumeric byte with ``-`` (verified against the SDK's
#: ``project_key_for_directory``: ``/home/ubuntu`` -> ``-home-ubuntu``). This is
#: the CLI's own rule, not a local configuration, so it holds on any host.
_PROJECT_KEY_RE = re.compile(r"[^a-zA-Z0-9]")
_MAX_PROJECT_KEY_LENGTH = 200

# A terminal notice is the strongest evidence there is; a silently stopped file
# is the fallback. Both feed the same decision order below.
_DEFAULT_PROJECTS_DIR = "~/.claude/projects"


def claude_projects_dir() -> Path:
    """The CLI's transcript root, honouring ``CLAUDE_CONFIG_DIR`` like the CLI.

    Reads the environment the same way the engine does, so a connector that
    runs the CLI under a relocated config still finds the transcripts.
    """

    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    base = config_dir if config_dir else os.path.join(Path.home(), ".claude")
    return Path(unicodedata.normalize("NFC", base)) / "projects"


def claude_project_key(directory: str) -> str:
    """The CLI's directory name for a project cwd (its ``_sanitize_path`` rule).

    Byte-for-byte the SDK's ``project_key_for_directory``: realpath + NFC
    normalization, then every non-alphanumeric character becomes ``-``. Kept
    local (rather than imported) because the rule is the CLI's on-disk format,
    not part of the SDK's public session API.
    """

    absolute = os.path.realpath(os.path.expanduser(directory))
    sanitized = _PROJECT_KEY_RE.sub("-", unicodedata.normalize("NFC", absolute))
    if len(sanitized) <= _MAX_PROJECT_KEY_LENGTH:
        return sanitized
    return f"{sanitized[:_MAX_PROJECT_KEY_LENGTH]}-{_simple_hash(absolute)}"


def _simple_hash(value: str) -> str:
    # The CLI's djb2-variant, base36; only reached for pathologically long
    # paths (>200 chars), where a collision would be far more surprising than
    # the loss of exactness. Mirrors the SDK helper of the same name.
    digest = 0
    for char in value:
        digest = (digest << 5) - digest + ord(char)
        digest &= 0xFFFFFFFF
        if digest >= 0x80000000:
            digest -= 0x100000000
    digest = abs(digest)
    if digest == 0:
        return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out: list[str] = []
    while digest > 0:
        out.append(digits[digest % 36])
        digest //= 36
    return "".join(reversed(out))


@dataclass(frozen=True, slots=True)
class AgentFileInfo:
    """What the filesystem could say about one subagent's transcript."""

    exists: bool
    mtime_ms: int | None = None
    #: False when the project directory could not be located (unknown cwd, no
    #: transcript root). A "missing" file we never looked for is not evidence
    #: of death, so the no-notice path declines to judge in that case.
    path_known: bool = True


@dataclass(frozen=True, slots=True)
class AgentTaskEvidence:
    """A closure the oracle can justify, with the status and time to publish."""

    closure_status: str
    closed_by: ClosedByEvidence
    end_time_ms: int | None
    #: Status to write into the card's per-task ``agents`` map entry. It is the
    #: notice's own wire status for a terminal notice (``completed`` etc.), and
    #: the closure's item status otherwise — so the per-task detail never keeps
    #: claiming ``running``/``async_launched`` on a card the oracle just closed.
    agent_status: str | None = None


def probe_agent_file(
    *,
    projects_dir: Path,
    project_key: str,
    external_session_id: str,
    task_id: str,
) -> AgentFileInfo:
    """The default probe: stat ``<root>/<key>/<session>/subagents/agent-<id>.jsonl``.

    Subagent transcripts may sit directly in ``subagents/`` or nested one level
    down (``workflows/<runId>/``), so a direct hit is tried first and a bounded
    recursive search second. The newest match wins — an id should be unique to
    one file, but paths merged from an old run must not shadow the live one.
    """

    base = projects_dir / project_key / external_session_id / "subagents"
    if not base.is_dir():
        session_dir = projects_dir / project_key / external_session_id
        if not session_dir.is_dir():
            # Neither the session directory nor the subagents tree exists:
            # most often a wrong project key or an unknown session, and
            # reading that as "the file is gone" would manufacture a
            # never-started closure out of a path bug (N5b). Decline instead.
            return AgentFileInfo(exists=False, path_known=False)
        # The session directory is real but has no subagents tree yet (the CLI
        # creates it lazily on the session's first dispatch): a missing file
        # here is genuine evidence the task never started (red-team N5b
        # refinement).
        return AgentFileInfo(exists=False, path_known=True)
    direct = base / f"agent-{task_id}.jsonl"
    candidates = [direct] if direct.is_file() else []
    if not candidates:
        try:
            candidates = list(base.rglob(f"agent-{task_id}.jsonl"))
        except OSError:
            candidates = []
    mtimes = []
    for candidate in candidates:
        try:
            mtimes.append(int(candidate.stat().st_mtime * 1000))
        except OSError:
            continue
    if not mtimes:
        return AgentFileInfo(exists=False, path_known=True)
    return AgentFileInfo(exists=True, mtime_ms=max(mtimes), path_known=True)


FileProbe = Callable[..., AgentFileInfo]


@dataclass(slots=True)
class ClaudeSubagentOracle:
    """Judge one Agent task's liveness from its transcript file's stillness.

    ``clock`` and ``file_probe`` are the injection seams: the tests supply a
    fake clock and a probe backed by in-memory files, so no judgement depends on
    the wall clock or the real filesystem.
    """

    projects_dir: Path | None = None
    clock: Callable[[], float] = time.time
    file_probe: FileProbe = probe_agent_file
    start_grace_seconds: float = SUBAGENT_START_GRACE_SECONDS
    stale_seconds: float = SUBAGENT_STALE_SECONDS
    mtime_tolerance_seconds: float = SUBAGENT_MTIME_TOLERANCE_SECONDS

    def _resolve_projects_dir(self) -> Path:
        return self.projects_dir if self.projects_dir is not None else claude_projects_dir()

    def _probe(self, *, session: Mapping[str, object] | None) -> AgentFileInfo:
        session = session or {}
        external_session_id = _string(session.get("external_session_id"))
        cwd = _string(session.get("cwd"))
        task_id = _string(session.get("task_id"))
        if external_session_id is None or cwd is None or task_id is None:
            return AgentFileInfo(exists=False, path_known=False)
        try:
            return self.file_probe(
                projects_dir=self._resolve_projects_dir(),
                project_key=claude_project_key(cwd),
                external_session_id=external_session_id,
                task_id=task_id,
            )
        except Exception:  # noqa: BLE001
            # A filesystem hiccup must never sink a fold; decline to judge.
            logger.exception(
                "Claude subagent oracle probe failed task_id={} session={}",
                task_id,
                external_session_id,
            )
            return AgentFileInfo(exists=False, path_known=False)

    def evidence(
        self,
        *,
        task_id: str,
        external_session_id: str | None,
        cwd: str | None,
        terminal_events: Sequence[tuple[int | None, ClaudeTaskEvent]] = (),
        receipt_age_seconds: float | None = None,
        attached_live: bool = False,
        now_ms: int | None = None,
    ) -> AgentTaskEvidence | None:
        """The terminal state this task's evidence justifies, or ``None``.

        Decision order (``tasks.md`` §3.1):

        1. A terminal notice whose task had no writes after it (file silent, or
           no file) closes the card with that notice's status.
        2. Otherwise, an ``attached`` task (a live turn is driving the process)
           is never closed on file silence alone — a long tool call writes
           nothing for a while and must not be mistaken for dead.
        3. No terminal notice: a missing transcript past the start grace closes
           as ``interrupted`` (never started); a transcript silent past the
           stale deadline closes as ``interrupted``; a fresh transcript stays
           running.
        """

        current_ms = now_ms if now_ms is not None else int(self.clock() * 1000)
        info = self._probe(
            session={
                "task_id": task_id,
                "external_session_id": external_session_id,
                "cwd": cwd,
            }
        )
        tolerance_ms = int(self.mtime_tolerance_seconds * 1000)

        terminal = _latest_terminal(terminal_events)
        if terminal is not None:
            notice_time_ms, event = terminal
            status = agent_task_terminal_status(event.status)
            if status is not None:
                file_silent = _file_silent_after(
                    info, notice_time_ms, tolerance_ms=tolerance_ms
                )
                if file_silent:
                    return AgentTaskEvidence(
                        closure_status=status,
                        closed_by="terminalNotice",
                        end_time_ms=notice_time_ms if notice_time_ms is not None else _event_time_ms(event),
                        agent_status=event.status,
                    )

        # No notice that closes the task. Now the file decides — but only when
        # nobody is actively driving the process.
        if attached_live:
            return None
        if not info.path_known:
            return None
        if not info.exists:
            if (
                receipt_age_seconds is not None
                and receipt_age_seconds > self.start_grace_seconds
            ):
                # The end time is the receipt time (F2b): the task was never
                # seen again after its launch, so that instant is the most
                # honest "ended at" we have. Falls back to now only when the
                # callers could not date the receipt at all.
                return AgentTaskEvidence(
                    closure_status="interrupted",
                    closed_by="neverStarted",
                    end_time_ms=int(current_ms - receipt_age_seconds * 1000),
                    agent_status="interrupted",
                )
            return None
        if info.mtime_ms is None:
            return None
        silent_seconds = (current_ms - info.mtime_ms) / 1000.0
        if silent_seconds > self.stale_seconds:
            return AgentTaskEvidence(
                closure_status="interrupted",
                closed_by="agentFileStale",
                end_time_ms=info.mtime_ms,
                agent_status="interrupted",
            )
        return None


def _latest_terminal(
    events: Sequence[tuple[int | None, ClaudeTaskEvent]],
) -> tuple[int | None, ClaudeTaskEvent] | None:
    terminal = [
        (time_ms, event)
        for time_ms, event in events
        if agent_task_terminal_status(event.status) is not None
    ]
    if not terminal:
        return None
    # Latest by notice time; events with no time sort oldest so a timed notice
    # always wins the "most recent" slot.
    return max(
        terminal,
        key=lambda item: (item[0] if item[0] is not None else -1),
    )


def _file_silent_after(
    info: AgentFileInfo,
    notice_time_ms: int | None,
    *,
    tolerance_ms: int,
) -> bool:
    """Whether the subagent wrote nothing after the notice that closed it.

    With no measurable file (missing, or an unknown project directory) there is
    nothing that contradicts the notice, so the notice stands.
    """

    if not info.exists or info.mtime_ms is None:
        return True
    if notice_time_ms is None:
        return True
    return info.mtime_ms <= notice_time_ms + tolerance_ms


def _event_time_ms(event: ClaudeTaskEvent) -> int | None:
    return event.end_time


def _string(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


# ---------------------------------------------------------------------------
# Raw transcript scanning (R1)
# ---------------------------------------------------------------------------
#
# The SDK's message view is a projection that drops some persisted transcript
# rows. The clearest case is the ``queue-operation`` line the CLI writes when a
# background task's terminal notice is enqueued: measured on 2026-10-08, both
# research cards completed with a ``<task-notification>`` wrapper present in
# the raw file but absent from ``read_sdk_session_messages`` — and a notice the
# SDK never surfaces can never close its card. Reading the raw JSONL is the fix.
#
# Each keep-line is stored with an opaque ``anchor`` (its own uuid when it has
# one). The anchor is what lets a caller place a raw-only notice back in the
# transcript order — ``_history_items_from_messages`` matches the preceding
# anchor to position the terminal fold — without a second disk read.


@dataclass(frozen=True, slots=True)
class RawTranscriptNotice:
    """One terminal notice parsed out of the raw transcript JSONL."""

    event: ClaudeTaskEvent
    timestamp_ms: int | None
    #: uuid of the row this notice came from, when it has one. A notice whose
    #: own row uuid the SDK already exposes is not raw-only and is dropped.
    row_uuid: str | None
    #: The uuid that locates this notice in the transcript's uuid space: the
    #: row's own uuid when it has one, else the nearest preceding row that
    #: does. ``raw_only_notices`` only folds a notice whose anchor is inside
    #: the projected window (N1).
    anchor: str | None
    #: 0-based index of the notice's row in ``raw_lines``.
    line_index: int


@dataclass(frozen=True, slots=True)
class RawTranscriptScan:
    """What one transcript's raw lines say about Agent tasks."""

    notices: tuple[RawTranscriptNotice, ...]
    #: task_id -> epoch ms of the newest ``agentId: <id>`` mention in the
    #: transcript. The CLI writes that receipt when an Agent call is
    #: dispatched, so it is the closest thing the transcript has to a launch
    #: time — the input the never-started grace needs (F5). The SDK message
    #: view exposes no timestamps at all, which is why this comes from the raw
    #: file.
    receipt_times_ms: Mapping[str, int] = field(default_factory=dict)


def scan_raw_transcript(
    raw_lines: Sequence[str],
) -> RawTranscriptScan:
    """Pull every terminal notice and receipt time out of a transcript.

    Two row shapes carry the notice wrapper, and both are read because the CLI
    writes them at different moments and keeps them independently:

    * ``type == "user"`` — the notice as a driver message. This is what the SDK
      message view surfaces (when it surfaces it at all).
    * ``type == "queue-operation"`` with ``operation == "enqueue"`` — the CLI
      recording the notice being queued for delivery. On 2026-10-08 both
      research cards completed with this row and **no** user row beside it, so
      it is the only artifact the completion ever left on disk. Enqueue means
      the task had already finished and its notice was being staged; the queue
      is a delivery detail, so the notice is a completion either way.

    ``attachment`` rows repeat the same wrapper as rendering chrome and are
    skipped. The same pass also collects each task's newest ``agentId:``
    mention (its dispatch receipt time), so callers get both facts for one
    read of the file.
    """

    notices: list[RawTranscriptNotice] = []
    receipt_times: dict[str, int] = {}
    last_anchor: str | None = None
    for line_index, line in enumerate(raw_lines):
        wants_notice = "<task-notification>" in line
        wants_receipt = "agentId:" in line
        wants_uuid = '"uuid"' in line
        if not wants_notice and not wants_receipt and not wants_uuid:
            continue
        try:
            row = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(row, Mapping):
            continue
        row_uuid = _string(row.get("uuid"))
        if row_uuid is not None:
            last_anchor = row_uuid
        if not wants_notice and not wants_receipt:
            continue
        timestamp_ms = _parse_iso_ms(row.get("timestamp"))
        if wants_receipt and timestamp_ms is not None:
            for match in _AGENT_ID_RE.finditer(line):
                task_id = match.group(1)
                if (receipt_times.get(task_id) or -1) < timestamp_ms:
                    receipt_times[task_id] = timestamp_ms
        if not wants_notice:
            continue
        row_type = row.get("type")
        if row_type == "user":
            message = row.get("message")
            text = message.get("content") if isinstance(message, Mapping) else None
        elif row_type == "queue-operation" and row.get("operation") == "enqueue":
            text = row.get("content")
        else:
            continue
        if not isinstance(text, str):
            continue
        for event in task_events_from_notification_text(
            text,
            timestamp_ms=timestamp_ms,
        ):
            notices.append(
                RawTranscriptNotice(
                    event=event,
                    timestamp_ms=timestamp_ms,
                    row_uuid=row_uuid,
                    anchor=row_uuid if row_uuid is not None else last_anchor,
                    line_index=line_index,
                )
            )
    return RawTranscriptScan(
        notices=tuple(notices),
        receipt_times_ms=receipt_times,
    )


_AGENT_ID_RE = re.compile(r"agentId:\s*([0-9a-zA-Z]+)")


def raw_only_notices(
    scan: RawTranscriptScan,
    *,
    sdk_uuid_order: Mapping[str, int],
) -> tuple[tuple[int, ClaudeTaskEvent], ...]:
    """The ``(placement_index, event)`` of the raw notices the SDK dropped.

    A notice whose own row uuid the SDK already exposes is not raw-only — the
    SDK fold already knows it, and folding it twice would double-count.

    Of the rest, only the notices whose **anchor lies inside the projected
    window** take part, and each is placed at its anchor's index. The window is
    the transcript range this projection covers; a notice older than it belongs
    to an earlier projection that already folded it, and one newer than it
    belongs to a later window that will fold it in turn. Re-injecting an
    out-of-window notice was the round-2 regression (red team F4's residual):
    a notice older than the window sat at a placement that outranked the
    window's own signals, so *every* settle window after a resume re-closed a
    card whose task was demonstrably running.

    Anchoring also removes the index-0 tie of the previous cut: a window whose
    first row is the resume places the notice at its own, later position (or
    drops it), so the fold's strict "latest signal wins" comparison is decided
    by the transcript's real order. A notice with no anchor at all — no uuid on
    its row and none before it — cannot be located and is declined.

    One signal per task is kept (the newest by timestamp), since two placements
    for one task would only add an ambiguous tie.
    """

    newest_by_task: dict[str, RawTranscriptNotice] = {}
    for notice in scan.notices:
        if notice.row_uuid is not None and notice.row_uuid in sdk_uuid_order:
            continue
        if notice.anchor is None or notice.anchor not in sdk_uuid_order:
            continue
        task_id = notice.event.task_id
        current = newest_by_task.get(task_id)
        if current is None or (notice.timestamp_ms or -1) >= (
            current.timestamp_ms or -1
        ):
            newest_by_task[task_id] = notice
    return tuple(
        (sdk_uuid_order[notice.anchor], notice.event)
        for notice in newest_by_task.values()
        if notice.anchor is not None
    )


#: A scan cache keyed by (path, size, mtime_ns). One sync settles a session by
#: rebuilding its whole window, and the same transcript is read again on the
#: next settle; caching the parsed scan (not the raw lines) keeps the repeated
#: cost at one dict lookup and a few KB. Bounded because the connector serves
#: many sessions over its life. Least-recently-used: a hit is re-inserted so a
#: session that keeps syncing is not evicted by one-off readers (N4).
_SCAN_CACHE: dict[tuple[str, int, int], RawTranscriptScan] = {}
_SCAN_CACHE_LIMIT = 16


def scan_transcript_file(path: Path) -> RawTranscriptScan | None:
    """Scan a transcript file, memoized by (path, size, mtime_ns).

    Returns ``None`` when the file cannot be stat'ed or read — absence of a raw
    transcript is never evidence and must not raise. A changed file (size or
    mtime) inherently misses the cache, so no invalidation is needed.
    """

    try:
        stat = os.stat(path)
    except OSError:
        return None
    key = (str(path), stat.st_size, stat.st_mtime_ns)
    cached = _SCAN_CACHE.pop(key, None)
    if cached is not None:
        _SCAN_CACHE[key] = cached  # re-insert: most recently used
        return cached
    try:
        with open(path, encoding="utf-8") as handle:
            lines = tuple(handle.read().splitlines())
    except OSError:
        return None
    scan = scan_raw_transcript(lines)
    while len(_SCAN_CACHE) >= _SCAN_CACHE_LIMIT:
        _SCAN_CACHE.pop(next(iter(_SCAN_CACHE)))
    _SCAN_CACHE[key] = scan
    return scan


def _parse_iso_ms(value: Any) -> int | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        # Python 3.11+ parses the transcript's trailing "Z" natively.
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return int(parsed.timestamp() * 1000)
