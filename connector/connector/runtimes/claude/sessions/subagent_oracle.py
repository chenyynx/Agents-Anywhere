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
from dataclasses import dataclass
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
                return AgentTaskEvidence(
                    closure_status="interrupted",
                    closed_by="neverStarted",
                    end_time_ms=current_ms,
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
    #: uuid of the nearest preceding row that carried one, used to order a
    #: raw-only notice against the SDK messages. None when unknown.
    anchor: str | None
    #: 0-based index of the notice's row in ``raw_lines``.
    line_index: int


@dataclass(frozen=True, slots=True)
class RawTranscriptScan:
    """The raw terminal notices of one transcript, in file order."""

    notices: tuple[RawTranscriptNotice, ...]


def scan_raw_transcript(
    raw_lines: Sequence[str],
) -> RawTranscriptScan:
    """Pull every terminal notice out of a transcript's raw lines.

    Two row shapes carry the wrapper, and both are read because the CLI writes
    them at different moments and keeps them independently:

    * ``type == "user"`` — the notice as a driver message. This is what the SDK
      message view surfaces (when it surfaces it at all).
    * ``type == "queue-operation"`` with ``operation == "enqueue"`` — the CLI
      recording the notice being queued for delivery. On 2026-10-08 both
      research cards completed with this row and **no** user row beside it, so
      it is the only artifact the completion ever left on disk. Enqueue means
      the task had already finished and its notice was being staged; the queue
      is a delivery detail, so the notice is a completion either way.

    ``attachment`` rows repeat the same wrapper as rendering chrome and are
    skipped. A notice's own row uuid and its nearest preceding uuid anchor are
    kept so a caller can place it against the SDK's uuid-ordered messages.
    """

    notices: list[RawTranscriptNotice] = []
    last_anchor: str | None = None
    for line_index, line in enumerate(raw_lines):
        # The uuid is tracked on every row, not only the notice rows, so an
        # enqueue row (which carries none) still anchors to the nearest
        # preceding uuid the SDK view also knows.
        if '"uuid"' in line:
            try:
                row = json.loads(line)
            except (ValueError, TypeError):
                row = None
            if isinstance(row, Mapping):
                row_uuid = _string(row.get("uuid"))
                if row_uuid is not None:
                    last_anchor = row_uuid
        if "<task-notification>" not in line:
            continue
        try:
            row = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(row, Mapping):
            continue
        row_uuid = _string(row.get("uuid"))
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
        timestamp_ms = _parse_iso_ms(row.get("timestamp"))
        for event in task_events_from_notification_text(
            text,
            timestamp_ms=timestamp_ms,
        ):
            notices.append(
                RawTranscriptNotice(
                    event=event,
                    timestamp_ms=timestamp_ms,
                    row_uuid=row_uuid,
                    anchor=last_anchor,
                    line_index=line_index,
                )
            )
    return RawTranscriptScan(notices=tuple(notices))


def raw_only_notices(
    raw_lines: Sequence[str],
    *,
    sdk_uuid_order: Mapping[str, int],
) -> tuple[tuple[int, ClaudeTaskEvent], ...]:
    """The ``(placement_index, event)`` of every terminal notice the SDK dropped.

    A notice whose own row uuid the SDK already exposes is not raw-only — the
    SDK fold already knows it, and folding it twice would double-count. Every
    other notice is placed at the SDK-order index of the nearest preceding row
    that IS in the SDK view (walking back through the raw file), so it competes
    in the fold's "latest signal wins" comparison at its true position instead
    of being appended after the transcript.
    """

    scanned = scan_raw_transcript(raw_lines)
    placed: list[tuple[int, ClaudeTaskEvent]] = []
    seen: set[tuple[str, str | None, int]] = set()
    for notice in scanned.notices:
        if notice.row_uuid is not None and notice.row_uuid in sdk_uuid_order:
            continue
        index = _raw_notice_index(raw_lines, notice, sdk_uuid_order)
        key = (notice.event.task_id, notice.event.status, index)
        if key in seen:
            # The CLI stages a notice twice (enqueue + delivery) with the same
            # task/status; the fold only needs one signal per position.
            continue
        seen.add(key)
        placed.append((index, notice.event))
    return tuple(placed)


def _raw_notice_index(
    raw_lines: Sequence[str],
    notice: RawTranscriptNotice,
    sdk_uuid_order: Mapping[str, int],
) -> int:
    if notice.anchor is not None and notice.anchor in sdk_uuid_order:
        return sdk_uuid_order[notice.anchor]
    for line in reversed(raw_lines[: notice.line_index]):
        if '"uuid"' not in line:
            continue
        try:
            row = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(row, Mapping):
            continue
        uuid = _string(row.get("uuid"))
        if uuid is not None and uuid in sdk_uuid_order:
            return sdk_uuid_order[uuid]
    return len(sdk_uuid_order)


def read_raw_transcript_lines(
    *,
    projects_dir: Path,
    cwd: str | None,
    external_session_id: str | None,
) -> tuple[str, ...]:
    """Read the raw transcript JSONL for a session, or ``()`` when unreadable.

    The file is ``<root>/<project-key>/<session-id>.jsonl``. Returns an empty
    tuple for any normal reason it cannot be read (unknown cwd, missing file,
    no permission) so the caller's fold simply proceeds without raw notices —
    absence of the raw file is never evidence and must not raise.
    """

    if not cwd or not external_session_id:
        return ()
    path = projects_dir / claude_project_key(cwd) / f"{external_session_id}.jsonl"
    try:
        with open(path, encoding="utf-8") as handle:
            return tuple(handle.read().splitlines())
    except OSError:
        return ()


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
