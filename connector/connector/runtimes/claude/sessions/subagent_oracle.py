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
import math
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
from connector.runtimes.claude.timeline.agent_calls import (
    DISPATCH_TOOL_NAME,
    SEND_MESSAGE_TOOL_NAME,
    agent_task_terminal_status,
    is_async_agent_receipt,
)

#: How a card was closed from engine evidence. Carried on the item's
#: ``content.metadata`` so a closure is auditable next to the status the client
#: renders. All values are free JSON keys (no contract enum); clients read
#: them beside ``kind`` and must tolerate new ones.
ClosedByEvidence = Literal[
    "terminalNotice", "agentFileStale", "neverStarted", "ageBounded"
]

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

#: The hard age ceiling (T2, ``.local-dev/stale-residue-selfheal-tasks.md``,
#: 2026-10-09): a task whose newest launch/survival evidence is older than
#: this — with no terminal notice and no live signal — closes as
#: ``interrupted`` even while its transcript file still *looks* fresh (the
#: mtime a restore or a copy re-stamped, a writer gone without ever emitting
#: a terminal event). No legitimate subagent runs anywhere near this long
#: (measured background work sits in the ~30-minute range), so the value is
#: far above every honest silence and a false close is impossible for any
#: task the transport still vouches for — ``attached``/live tasks are exempt
#: entirely. Overridable at construction; the environment variable below
#: supplies the default and a value ``<= 0`` disables the judgement.
SUBAGENT_AGE_BOUND_SECONDS: float = 24 * 60 * 60.0

#: Environment override for :data:`SUBAGENT_AGE_BOUND_SECONDS`, in seconds.
#: Unset keeps the default; an unparsable value or one under
#: :data:`SUBAGENT_AGE_BOUND_FLOOR_SECONDS` is REFUSED, which means 0 (the
#: judgement is off) — never the default, and never the value that was typed.
#: Values ``<= 0`` clamp to 0, the documented "disabled" value (the kill
#: switch). ``24h`` / ``90m`` / ``1.5h`` / ``30s`` are accepted.
SUBAGENT_AGE_BOUND_ENV: str = "AA_SUBAGENT_AGE_BOUND_SECONDS"

#: The smallest ceiling this judgement may be given. A ceiling this low stops
#: being a backstop and becomes a reaper: it fires on work that is demonstrably
#: still running. 60s was not low enough for that to be unreachable — a
#: background subagent dispatched 61s ago whose transcript was written 2s ago
#: is alive, and a 60s ceiling closed it as ``ageBounded`` with no transport
#: vouch required (R1b R2-4). The floor now sits an order of magnitude above
#: the longest legitimate background run (~30min measured, task sheet §3 T3),
#: so the only ceilings this judgement can be given are ones no live task can
#: reach. Refused rather than clamped, because silently raising an operator's
#: 60 back to 24h would hide the typo; the fix is the log line and a value
#: they meant.
#:
#: Note what this floor deliberately does NOT require: file silence. The
#: re-stamped-mtime residue T2 exists to close is precisely the case where the
#: session transcript is still being written while the task is dead, so
#: demanding a stale file here would disarm the rule against its own target.
SUBAGENT_AGE_BOUND_FLOOR_SECONDS: float = 60.0 * 60.0

#: Duration suffixes accepted after the number. Bare numbers are seconds,
#: which is what the variable name says; the suffixes are there so the natural
#: spelling of a day (``24h``) cannot land on "unparsable" — and, now that an
#: unparsable value means "off" rather than "the default", that distinction
#: matters.
_AGE_BOUND_SUFFIX_SECONDS: dict[str, float] = {
    "s": 1.0,
    "m": 60.0,
    "h": 60 * 60.0,
    "d": 24 * 60 * 60.0,
}


def _parse_age_bound_seconds(raw: str) -> float | None:
    """Seconds named by ``raw``, or ``None`` when the value is not usable."""

    text = raw.strip().lower()
    if not text:
        return None
    multiplier = 1.0
    if text[-1].isalpha():
        multiplier = _AGE_BOUND_SUFFIX_SECONDS.get(text[-1])
        if multiplier is None:
            return None
        text = text[:-1].strip()
    try:
        value = float(text)
    except ValueError:
        return None
    # `nan` compares false against everything, so it would sail through the
    # floor check below and reach the oracle as a ceiling that never fires.
    # `inf` parses fine and is just as useless. Both are rejected here.
    if not math.isfinite(value):
        return None
    return value * multiplier


def _age_bound_seconds_from_env() -> float:
    """The age-ceiling default, honouring ``SUBAGENT_AGE_BOUND_ENV``.

    Read once per oracle construction (not at import) so the deployed
    process environment and the tests drive the same code path.

    Unlike the connector's other float knobs this one fails SAFE, and the
    asymmetry is the point (R1 P2-4). A ceiling that comes out too small
    closes live work — ``0.5`` means half a second, which is below the
    dispatch-to-receipt gap of every task in the library, so the sweep and
    every rebuild would sweep the floor and close all of them. A ceiling that
    comes out too large merely does nothing until the next projection bump
    reaches the residue. So: unset keeps the documented default; anything
    unusable (unparsable, ``nan``, ``inf``, empty, below the floor) is refused
    and means 0, the kill switch, with a warning that names the rejected text.
    A too-large ceiling is not worth a second opinion — it is inert.
    """

    raw = os.environ.get(SUBAGENT_AGE_BOUND_ENV)
    if raw is None:
        return SUBAGENT_AGE_BOUND_SECONDS
    value = _parse_age_bound_seconds(raw)
    if value is None:
        logger.warning(
            "subagent age bound unusable; the judgement is disabled "
            "env={} value={} default_seconds={}",
            SUBAGENT_AGE_BOUND_ENV,
            raw,
            SUBAGENT_AGE_BOUND_SECONDS,
        )
        return 0.0
    if value <= 0:
        # The documented kill switch, and the same posture as a refused value:
        # no ceiling, no closures.
        return 0.0
    if value < SUBAGENT_AGE_BOUND_FLOOR_SECONDS:
        logger.warning(
            "subagent age bound below the floor; the judgement is disabled "
            "env={} value={} floor_seconds={}",
            SUBAGENT_AGE_BOUND_ENV,
            raw,
            SUBAGENT_AGE_BOUND_FLOOR_SECONDS,
        )
        return 0.0
    return value


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
    #: The age-bounded closure's hard ceiling (T2): see
    #: `SUBAGENT_AGE_BOUND_SECONDS`. Defaulted from the environment at
    #: construction (``SUBAGENT_AGE_BOUND_ENV``); ``<= 0`` disables the rule.
    age_bound_seconds: float = field(default_factory=_age_bound_seconds_from_env)
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
        ceiling_age_seconds: float | None = None,
        ceiling_anchored: bool = False,
        attached_live: bool = False,
        now_ms: int | None = None,
    ) -> AgentTaskEvidence | None:
        """The terminal state this task's evidence justifies, or ``None``.

        Decision order (``tasks.md`` §3.1):

        1. A terminal notice whose task had no writes after it (file silent, or
           no file) closes the card with that notice's status — for an
           ``attached`` task only when the notice post-dates the latest launch
           evidence beyond the mtime tolerance (F4 arbitration, below).
        2. Otherwise, an ``attached`` task (a live turn is driving the process)
           is never closed on file silence alone — a long tool call writes
           nothing for a while and must not be mistaken for dead. The
           exemption is hard for the age ceiling too: no clock judgement
           closes a task the transport still vouches for.
        3. No terminal notice: a missing transcript past the start grace closes
           as ``interrupted`` (never started); a transcript silent past the
           stale deadline closes as ``interrupted``; a fresh transcript stays
           running — except past the hard age ceiling (T2, ``ageBounded``):
           when the newest launch/survival evidence is older than
           ``age_bound_seconds`` and no live signal vouches for the task, the
           card closes as ``interrupted`` and the freshness of the file is
           precisely what that rule declines to trust.

        F4 arbitration (``.local-dev/subagent-alias-durability-tasks.md`` rt2,
        red team CONFIRMED): the D3 sweep lets a terminal notice close a task
        the transport still vouches for, and a *stale* notice — one written
        before the resume that re-launched the task — would then close a live
        task that later completes honestly, with the terminal stickiness
        refusing to undo it. For attached tasks the notice is therefore
        attributed to the current incarnation only when it strictly post-dates
        the task's latest launch evidence (``receipt_time = now -
        receipt_age``) by more than the tolerance; a notice at or before the
        receipt is a death the resume superseded and is treated as absent, so
        the attached branch simply declines. One clock rule, both directions of
        skew covered: the receipt may be a hair newer than the true launch
        without making a current notice stale (the band), and a notice a hair
        newer than the receipt is still read as superseded rather than trusted
        on sub-tolerance noise.

        The receipt age comes from the newest ``agentId:`` receipt, which later
        transcript text can *pollute* to be newer than the true launch; that
        bias shrinks the age, pushes ``receipt_time`` later, and so errs toward
        *superseding* notices — keeping attached tasks open. The bias is
        therefore conservative in the one direction that cannot lie about a
        live agent. With no receipt age, or a notice with no time, there is
        nothing to arbitrate and rule 1 stands exactly as before, as it does
        for non-attached tasks. This is also why the ceiling reads its own age
        instead: a newer anchor is harmless when it supersedes a notice, and
        unbounded when it defers a closure.

        Time order is the OUTER arbitration for one task's own notice
        sequence; ``closure_rank`` remains the INNER arbiter among verdicts of
        one adjudication (a card's several tasks) and is not consulted here —
        the two cannot disagree, because a superseded notice never becomes a
        verdict at all.
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
        if terminal is not None and attached_live:
            terminal = _attribute_notice_to_incarnation(
                terminal,
                receipt_time_ms=(
                    None
                    if receipt_age_seconds is None
                    else int(current_ms - receipt_age_seconds * 1000)
                ),
                tolerance_ms=tolerance_ms,
            )
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
        # T2 (stale-residue-selfheal): the age ceiling. The file still looks
        # fresh, but the task's newest launch/survival evidence is older than
        # any legitimate run — with no live signal, the file's freshness is
        # what this rule declines to trust, and the card closes. `attached`
        # has already returned above; the explicit guard is kept so the hard
        # exemption holds even if this branch is ever re-ordered.
        #
        # The ceiling is the one judgement that reads an age at all, so it is
        # also the one that must not read a *polluted* one (R1c): it judges on
        # `ceiling_age_seconds`, the anchor that came from the raw transcript
        # alone — no free-text supplement, no mention from either surface. A
        # newer bogus anchor can only ever DEFERR this closure, so a session
        # that keeps writing could hold a dead card open forever while every
        # other rule finds it fresh; the never-started grace and the F4
        # arbitration below keep the combined anchor, where a newer anchor is
        # the harmless direction. A caller with no separate ceiling anchor
        # falls back to the receipt age, so the ceiling is never unreachable.
        ceiling_age = (
            ceiling_age_seconds if ceiling_anchored else receipt_age_seconds
        )
        if (
            not attached_live
            and self.age_bound_seconds > 0
            and ceiling_age is not None
            and ceiling_age > self.age_bound_seconds
        ):
            return AgentTaskEvidence(
                closure_status="interrupted",
                closed_by="ageBounded",
                # The newest survival evidence is the anchor (the same one
                # the never-started rule ends on, F2b): the file's freshness
                # is exactly what this branch distrusts, so the mtime is not
                # the honest "ended at".
                end_time_ms=int(current_ms - ceiling_age * 1000),
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


def _attribute_notice_to_incarnation(
    terminal: tuple[int | None, ClaudeTaskEvent],
    *,
    receipt_time_ms: int | None,
    tolerance_ms: int,
) -> tuple[int | None, ClaudeTaskEvent] | None:
    """Attribute a terminal notice to the task's current incarnation (F4).

    Returns the notice when it may close an attached task, or ``None`` when it
    is superseded. A notice stands only when it strictly post-dates the latest
    launch evidence by more than the tolerance
    (``notice_time_ms >= receipt_time_ms + tolerance_ms``): anything at or
    before the receipt describes a death the later launch already superseded,
    and trusting it would strand a live task as ``interrupted`` (the red team's
    F4). A notice with no time, or a task with no receipt evidence, cannot be
    arbitrated and stands unchanged.
    """

    notice_time_ms, _ = terminal
    if notice_time_ms is None or receipt_time_ms is None:
        return terminal
    if notice_time_ms < receipt_time_ms + tolerance_ms:
        return None
    return terminal


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
    #: task_id -> epoch ms of the newest ``agentId: <id>`` receipt in the
    #: transcript. The CLI writes that receipt when an Agent call is
    #: dispatched, so it is the closest thing the transcript has to a launch
    #: time — the input the never-started grace needs (F5). The SDK message
    #: view exposes no timestamps at all, which is why this comes from the raw
    #: file. Rows are admitted by SHAPE (a ``user`` row carrying a
    #: ``tool_result`` block), not by the substring: a row that only quotes
    #: ``agentId:`` never gets in (R1c), because a mention is not a receipt.
    receipt_times_ms: Mapping[str, int] = field(default_factory=dict)
    #: SendMessage tool_use id -> the task id that call addresses. This is the
    #: persisted copy of the live projector's in-process alias map, so a
    #: restarted process can still route a resumed task's frames to its
    #: original dispatch card (alias-durability-tasks T1 A). Two raw shapes
    #: carry the join: the assistant row's own ``input.to``, and the user
    #: row's ``tool_result`` body / ``toolUseResult`` carrying
    #: ``resumedAgentId`` (keyed by that block's tool_use_id).
    send_aliases: Mapping[str, str] = field(default_factory=dict)
    #: task id -> epoch ms of the newest ``SendMessage`` call row that resumed
    #: it (red team P9, alias-durability rt2 round 2). A resume re-launches the
    #: task, so this is the task's newest *survival* evidence — the arbitration
    #: anchor F4 needs, because the dispatch receipt alone sits before the
    #: stop notice it must supersede (the incident's real timeline: receipt
    #: 01:28, stop 01:48, resume 01:52 — anchored on the receipt, the stale
    #: notice still closed the resumed task). Recorded from the assistant
    #: row's own timestamp when its ``tool_use`` is a verified ``SendMessage``
    #: call; a row without a timestamp contributes nothing (only add, never
    #: guess). Default empty so hand-built and older scans behave as before.
    send_resume_times_ms: Mapping[str, int] = field(default_factory=dict)
    #: task id -> the tool_use ids of the dispatch receipts that named it.
    #: Read from the ``tool_result`` rows that launch an Agent call — the
    #: line-style ``agentId: <id>`` body wording, or a structured
    #: ``toolUseResult.agentId`` — and keyed by that block's tool_use_id. The
    #: engine's own receipt rows therefore pin a task's dispatch roots without
    #: any in-process memory, which is what survives a connector restart.
    #:
    #: Membership is gated on provenance (red team F1): a block contributes a
    #: root only when its tool_use id is one the scan verified as a dispatch
    #: call, so a tool result *quoting* ``agentId: <task>`` in its output
    #: (grep/cat/cat-like echoes of a receipt) is never a root.
    dispatch_roots: Mapping[str, frozenset[str]] = field(default_factory=dict)
    #: The tool_use ids the scan verified as **dispatch calls**: assistant
    #: rows (sidechain included) whose tool_use name is ``DISPATCH_TOOL_NAME``,
    #: the same name the in-process lineage gate uses. Every id in
    #: ``dispatch_roots`` is guaranteed to be in here, and carrying the set
    #: lets a consumer re-check that provenance instead of trusting the
    #: mapping alone (red team F2/F3: a hand-built or polluted mapping must not
    #: be able to mint phantom cards or steer a fold onto a quoting tool id).
    verified_dispatch_ids: frozenset[str] = frozenset()


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
    receipt (its dispatch receipt time), each task's newest ``SendMessage``
    resume-call row time (its newest survival evidence, P9), and the lineage
    the resume fold needs (alias-durability-tasks T1 A): the SendMessage alias
    map, the dispatch roots, and the provenance set that gates both, so
    callers get every fact for one read of the file.

    Receipt times are read by the row's SHAPE, not by the substring (R1c): a
    ``user`` row — carrying a ``tool_result`` block, the row-level
    ``toolUseResult`` variant, or the bare body F5 pinned — is the engine's
    answer to a dispatch call, while an ``assistant`` row that merely contains
    ``agentId:`` is quoting one. Both are found by the same substring, and only
    one of them is evidence of a launch: the quoting shape is what let an
    assistant's sentence re-stamp a dead task's launch anchor and defer the age
    ceiling indefinitely. The gate here is deliberately weaker than the lineage
    gate below, which also demands the acknowledged call's *name* because it
    mints a root — F5's bare result, whose call row was trimmed away, must
    still date its task.

    Both lineage maps are **provenance-gated** (red team F1): a ``tool_result``
    row only counts as a dispatch receipt when the call it acknowledges is an
    assistant ``tool_use`` named ``DISPATCH_TOOL_NAME``, and only counts as a
    SendMessage receipt when that call is named ``SEND_MESSAGE_TOOL_NAME``.
    The name map is built in the same pass — the transcript writes a call's
    ``tool_use`` row before its ``tool_result`` row, so the name is always
    registered by the time its result is read — and a result whose call was
    never seen (or was seen with another name) contributes nothing at all
    (fail-closed direction). Without this gate any tool output that merely
    *quotes* ``agentId: <task>`` — a grep/cat of a receipt, a report about
    another agent — read as a dispatch root, which is how a Bash tool id
    became a task's only root and minted phantom cards (F1/F2/F3).
    """

    notices: list[RawTranscriptNotice] = []
    receipt_times: dict[str, int] = {}
    send_aliases: dict[str, str] = {}
    send_resume_times: dict[str, int] = {}
    dispatch_roots: dict[str, set[str]] = {}
    tool_use_names: dict[str, str] = {}
    last_anchor: str | None = None
    for line_index, line in enumerate(raw_lines):
        wants_notice = "<task-notification>" in line
        wants_receipt = "agentId:" in line
        wants_uuid = '"uuid"' in line
        wants_send = "SendMessage" in line
        wants_resume = "resumedAgentId" in line
        wants_agent_key = '"agentId"' in line
        wants_tool_use = '"tool_use"' in line
        if not (
            wants_notice
            or wants_receipt
            or wants_uuid
            or wants_send
            or wants_resume
            or wants_agent_key
            or wants_tool_use
        ):
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
        if wants_tool_use:
            _register_tool_use_names(row, tool_use_names)
        if wants_receipt or wants_send or wants_resume or wants_agent_key:
            try:
                _extract_transcript_lineage(
                    row,
                    tool_use_names=tool_use_names,
                    send_aliases=send_aliases,
                    send_resume_times=send_resume_times,
                    dispatch_roots=dispatch_roots,
                )
            except Exception:  # noqa: BLE001
                # Lineage is best-effort: a row whose shape surprises the
                # extractor is skipped, never allowed to sink the scan.
                logger.debug(
                    "Claude transcript lineage row skipped",
                    exc_info=True,
                )
        if not wants_notice and not wants_receipt:
            continue
        timestamp_ms = _parse_iso_ms(row.get("timestamp"))
        # R1c: a receipt is admitted by the SHAPE of the row, not by the
        # substring. The CLI writes the launch receipt as the ``tool_result``
        # that answers the dispatch call, so a row of that shape is a receipt
        # whatever it says (F5's bare result, whose call row may be trimmed, is
        # still a receipt and must survive); a row that merely *contains*
        # ``agentId:`` — an assistant quoting a run, a report about another
        # agent, a grep/cat of a transcript — is not, and letting it in let any
        # sentence re-stamp a dead task's launch anchor. Same shape test the
        # notice branch below applies to its own rows, and strictly weaker than
        # the lineage gate: that one also demands the acknowledged call's name,
        # because it mints a root, while this only dates a mention.
        if wants_receipt and timestamp_ms is not None and _is_receipt_row(row):
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
    verified_dispatch_ids = frozenset(
        tool_use_id
        for tool_use_id, name in tool_use_names.items()
        if name == DISPATCH_TOOL_NAME
    )
    # Invariant seal: the extraction gate above already refuses any receipt
    # whose call was not a verified dispatch, so this intersection changes
    # nothing today — it exists so "dispatch_roots ⊆ verified_dispatch_ids"
    # is true of the returned data by construction, whatever future edits do
    # inside the loop.
    sealed_roots = {
        task_id: roots & verified_dispatch_ids
        for task_id, roots in dispatch_roots.items()
    }
    return RawTranscriptScan(
        notices=tuple(notices),
        receipt_times_ms=receipt_times,
        send_aliases=send_aliases,
        send_resume_times_ms=send_resume_times,
        dispatch_roots={
            task_id: frozenset(roots)
            for task_id, roots in sealed_roots.items()
            if roots
        },
        verified_dispatch_ids=verified_dispatch_ids,
    )


_AGENT_ID_RE = re.compile(r"agentId:\s*([0-9a-zA-Z]+)")


def _is_receipt_row(row: Mapping[str, Any]) -> bool:
    """Whether this raw row has the shape a dispatch receipt is written in.

    Receipts arrive on a ``user`` row, in either of the two shapes the CLI has
    written them in: a ``tool_result`` block (with the row-level
    ``toolUseResult`` variant), or the bare body of the user row itself — the
    form F5 pinned, whose dispatch call row the transcript may no longer hold
    and which is the reason the message-view supplement exists at all. Both are
    the engine's own channel.

    An ``assistant`` row is not one of those shapes and never was: that is where
    free text lives, so a line that merely *mentions* ``agentId:`` there is a
    sentence about a run, not the engine's answer to a dispatch call. Dropping
    that shape is what R1c needed; the two receipt shapes above are kept whole.

    The bare body is the shape the HUMAN writes on a ``user`` row too — a typed
    message, hook output, a pasted command result — so the row type alone
    cannot admit it without re-opening the pollution this gate exists to close
    one row-type over (R4-2: a human message quoting the id re-stamped a dead
    task's launch anchor through exactly this branch). What separates the two
    is the engine's own wording: every launch receipt opens with
    ``ASYNC_AGENT_RECEIPT_PREFIX``. What the raw scan and the message view
    share is that wording criterion, NOT the same boundary (R1e-3): every
    message-view call site hands :func:`is_async_agent_receipt` a
    *tool_result* channel and the fold additionally demands a known ``Agent``
    call, while this scan reads the user row's own text with no call
    requirement at all — so a human pasting the receipt wording verbatim is
    admitted here where the message view has no channel that would. That
    looseness is declared and accepted: no reliable marker separates the two
    rows.
    The ``tool_result`` block shape without metadata is deliberately NOT
    gated on wording: the block type is the engine's channel there, and F5's
    bare result — the form whose dispatch call row the transcript may no
    longer hold — keeps its prefix clause instead of a lineage check, which
    would kill it.

    Where the row carries ``toolUseResult`` metadata, the metadata's mere
    presence is not the test (R1e-2): the frame is judged by
    :func:`is_async_agent_receipt` on that metadata with the row's own text
    as the body — an explicit ``async_launched`` status is a launch receipt;
    any other explicit status is the call's OUTCOME (a sync Agent call's
    result frame is its card's done/failed, and the message view refuses the
    very same metadata); a status-less frame falls back to the wording. A
    row whose text cannot be read is refused when no explicit status speaks
    for it (R1f-2): a status-less frame is not trusted on the metadata alone,
    while an explicit ``async_launched`` admits without a body — the message
    view judges that frame the same way.
    """

    if row.get("type") != "user":
        return False
    if isinstance(row.get("toolUseResult"), Mapping):
        return is_async_agent_receipt(
            row.get("toolUseResult"),
            output=_receipt_row_body_text(row),
        )
    message = row.get("message")
    content = message.get("content") if isinstance(message, Mapping) else None
    if isinstance(content, str):
        # The bare F5 body: the receipt IS the user row's content — admitted
        # only when the body carries the engine's launch wording (R4-2). The
        # metadata channel is absent by construction here (that is the other
        # branch above), so the body has to speak, exactly as
        # `is_async_agent_receipt` reads it in the message view.
        return is_async_agent_receipt(None, output=content)
    return isinstance(content, list) and any(
        isinstance(block, Mapping) and block.get("type") == "tool_result"
        for block in content
    )


def _receipt_row_body_text(row: Mapping[str, Any]) -> str | None:
    """The text of the row's own content, for the wording judgment.

    The raw scan's counterpart of the text the message view hands to
    :func:`is_async_agent_receipt` as the tool_result's body: a bare string
    content reads as itself, a ``tool_result`` block as its text parts. Only
    ``tool_result`` blocks are read, which is narrower than the message
    view's own extraction (that one reads any block's ``text``): a
    text-typed frame is refused here where the view could read it (R1f-1,
    recorded — the refusal only ever delays a closure, and the CLI writes
    receipts as bare strings or ``tool_result`` blocks, not text-typed
    frames). ``None`` when no text can be read this way — a status-less row
    is then refused rather than trusted on the metadata alone.
    """

    message = row.get("message")
    content = message.get("content") if isinstance(message, Mapping) else None
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    texts: list[str] = []
    for block in content:
        if not isinstance(block, Mapping) or block.get("type") != "tool_result":
            continue
        texts.extend(_tool_result_texts(block.get("content")))
    return "\n".join(texts) if texts else None


def _register_tool_use_names(
    row: Mapping[str, Any],
    tool_use_names: dict[str, str],
) -> None:
    """Record one row's ``tool_use`` id -> name pairs, in place.

    The transcript writes a call's ``tool_use`` block on an assistant row
    (sidechain rows included) *before* the tool_result row that answers it, so
    a single forward pass over the file always has a call's name registered by
    the time its result is read. This map is what turns "this tool_result
    mentioned ``agentId``" into "this tool_use **dispatched** the task": the
    judgement cannot be made from the result row alone, only from the call it
    acknowledges. An id whose name never appears gets no entry, and every
    consumer treats a missing entry as "not a dispatch" — fail-closed, so a
    trimmed call row loses lineage rather than inventing it.
    """

    if row.get("type") != "assistant":
        return
    message = row.get("message")
    content = message.get("content") if isinstance(message, Mapping) else None
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, Mapping):
            continue
        if block.get("type") != "tool_use":
            continue
        tool_use_id = _string(block.get("id"))
        name = _string(block.get("name"))
        if tool_use_id is not None and name is not None:
            tool_use_names.setdefault(tool_use_id, name)


def _extract_transcript_lineage(
    row: Mapping[str, Any],
    *,
    tool_use_names: Mapping[str, str],
    send_aliases: dict[str, str],
    send_resume_times: dict[str, int],
    dispatch_roots: dict[str, set[str]],
) -> None:
    """Learn one raw row's resume aliases and dispatch roots, in place.

    Two row shapes carry lineage and both are read here (T1 A-1):

    * an ``assistant`` row's ``SendMessage`` tool_use block — its
      ``input.to`` names the task the call addresses, keyed by the block's
      tool_use id (the id the resumed task's later frames are keyed on). The
      same block's row timestamp is recorded as that task's newest resume
      time (P9): a resume is a relaunch, and the F4 arbitration anchors on
      the newest launch/survival evidence, not on the dispatch receipt the
      stop notice legitimately post-dates. A row with no timestamp records
      no time — the map only ever grows on evidence;
    * a ``user`` row's ``tool_result`` blocks — a body whose JSON carries
      ``resumedAgentId`` (or the row's own ``toolUseResult``) names the task a
      SendMessage resumed, and a body carrying the launch receipt's
      ``agentId`` (line-style, or structured in ``toolUseResult``) names the
      task its tool_use id dispatched.

    Both ``tool_result`` sources are gated on the **acknowledged call's name**
    (red team F1): ``agentId`` is only a dispatch receipt when
    ``tool_use_names`` says the call is ``DISPATCH_TOOL_NAME``, and
    ``resumedAgentId`` is only a resume receipt when it says
    ``SEND_MESSAGE_TOOL_NAME``. This is the same judgement the in-process path
    makes (``messages._tool_call_content``'s ``if tool_name == "Agent"``,
    ``send_message_target``'s ``tool_name != "SendMessage"``), applied to the
    persisted surface — without it, any tool output that merely *quotes* a
    receipt (a grep/cat, a report about another agent) becomes lineage. A
    result whose call name was never seen contributes nothing (fail-closed).

    Every field is read defensively; a row that does not match any shape
    contributes nothing. The row-level ``toolUseResult`` is only attributed
    when its row holds a single ``tool_result`` block — with several blocks in
    one row the correspondence is ambiguous, and guessing it could splice an
    alias onto the wrong call.
    """

    row_type = row.get("type")
    message = row.get("message")
    content = message.get("content") if isinstance(message, Mapping) else None
    if row_type == "assistant":
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, Mapping):
                continue
            if (
                block.get("type") != "tool_use"
                or block.get("name") != SEND_MESSAGE_TOOL_NAME
            ):
                continue
            tool_use_id = _string(block.get("id"))
            tool_input = block.get("input")
            target = (
                tool_input.get("to") if isinstance(tool_input, Mapping) else None
            )
            if tool_use_id is not None and isinstance(target, str) and target:
                send_aliases.setdefault(tool_use_id, target)
                row_time_ms = _parse_iso_ms(row.get("timestamp"))
                if row_time_ms is not None:
                    current = send_resume_times.get(target)
                    if current is None or row_time_ms > current:
                        send_resume_times[target] = row_time_ms
        return
    if row_type != "user" or not isinstance(content, list):
        return
    blocks = [
        block
        for block in content
        if isinstance(block, Mapping) and block.get("type") == "tool_result"
    ]
    if not blocks:
        return
    row_details = row.get("toolUseResult")
    row_details = row_details if isinstance(row_details, Mapping) else None
    for block in blocks:
        tool_use_id = _string(block.get("tool_use_id"))
        if tool_use_id is None:
            continue
        call_name = tool_use_names.get(tool_use_id)
        if call_name not in (DISPATCH_TOOL_NAME, SEND_MESSAGE_TOOL_NAME):
            # A result the transcript never paired with a call — or paired
            # with anything but a dispatch/resume call — proves nothing about
            # this task. Fail closed, whatever its body says.
            continue
        texts = _tool_result_texts(block.get("content"))
        parsed = _json_mapping_from_texts(texts)
        if call_name == SEND_MESSAGE_TOOL_NAME:
            resumed: Any = (
                parsed.get("resumedAgentId") if parsed is not None else None
            )
            if not isinstance(resumed, str) or not resumed:
                resumed = None
            if resumed is None and row_details is not None and len(blocks) == 1:
                candidate = row_details.get("resumedAgentId")
                resumed = (
                    candidate if isinstance(candidate, str) and candidate else None
                )
            if resumed is not None:
                send_aliases.setdefault(tool_use_id, resumed)
        if call_name != DISPATCH_TOOL_NAME:
            continue
        roots: set[str] = set()
        if parsed is not None:
            dispatched = parsed.get("agentId")
            if isinstance(dispatched, str) and dispatched:
                roots.add(dispatched)
        if row_details is not None and len(blocks) == 1:
            dispatched = row_details.get("agentId")
            if isinstance(dispatched, str) and dispatched:
                roots.add(dispatched)
        for text in texts:
            for match in _AGENT_ID_RE.finditer(text):
                roots.add(match.group(1))
        for agent_id in roots:
            dispatch_roots.setdefault(agent_id, set()).add(tool_use_id)


def _tool_result_texts(content: Any) -> tuple[str, ...]:
    """The text bodies of one ``tool_result`` block's content, whatever shape."""

    if isinstance(content, str):
        return (content,)
    if not isinstance(content, list):
        return ()
    texts: list[str] = []
    for entry in content:
        if isinstance(entry, str):
            texts.append(entry)
        elif isinstance(entry, Mapping):
            text = entry.get("text")
            if isinstance(text, str):
                texts.append(text)
    return tuple(texts)


def _json_mapping_from_texts(texts: Sequence[str]) -> Mapping[str, Any] | None:
    """The first text body that parses as a JSON object, else ``None``."""

    for text in texts:
        stripped = text.strip()
        if not stripped.startswith("{"):
            continue
        try:
            parsed = json.loads(stripped)
        except (ValueError, TypeError):
            continue
        if isinstance(parsed, Mapping):
            return parsed
    return None


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


def participation_times_ms(scan: RawTranscriptScan) -> dict[str, int]:
    """Each task's newest survival evidence: dispatch receipt vs resume (P9).

    The F4 arbitration must anchor on when the task was last *known alive*,
    and a dispatch receipt alone is not that: after a SendMessage resume the
    receipt still sits at the original dispatch, so the stop notice that
    killed the previous incarnation post-dates it and would be attributed to
    the incarnation the transport is now driving — the P9 false closure on
    the real incident timeline (receipt 01:28, stop 01:48, resume 01:52). The
    newest of (dispatch receipt, resume call row) is the honest anchor;
    either source alone is merely the best the transcript had.
    """

    merged: dict[str, int] = dict(scan.receipt_times_ms)
    for task_id, time_ms in scan.send_resume_times_ms.items():
        current = merged.get(task_id)
        if current is None or time_ms > current:
            merged[task_id] = time_ms
    return merged


def verified_dispatch_tasks(scan: RawTranscriptScan) -> frozenset[str]:
    """The tasks whose dispatch receipt the scan can attribute to a real call.

    ``dispatch_roots`` is already sealed to ``verified_dispatch_ids`` by the
    scan, so a non-empty root set *is* the intersection; it is recomputed here
    explicitly because the consumer's decision is "may this anchor be
    overruled?", and a decision that turns on an invariant living three files
    away should say which invariant it means.

    A task outside this set still has a receipt time — a bare ``tool_result``
    whose dispatch row the transcript no longer holds is F5's whole reason the
    supplement exists — but nothing ties it to a call, so a free-text mention
    newer than it may overrule it (R1c R3-2).
    """

    verified = scan.verified_dispatch_ids
    return frozenset(
        task_id
        for task_id, roots in scan.dispatch_roots.items()
        if roots & verified
    )


def participation_ages_seconds(
    scan: RawTranscriptScan | None,
    *,
    now_ms: int,
) -> dict[str, float]:
    """Every task's age from the raw transcript ALONE (R1c).

    This is the age ceiling's anchor, kept apart from the age the other rules
    judge on for exactly one reason: the others consume a free-text supplement
    (F5's bare ``tool_result``, which the raw file may not have), and that
    supplement is also the shape a quote takes. A mention that only *says*
    ``agentId:`` can move this anchor in both directions — and for a ceiling,
    moving it later defers the closure without bound, while every other rule
    that would otherwise reach the card finds a fresh file.

    So the ceiling reads this, and only this. A task the raw transcript has
    nothing for gets no age and therefore no ceiling closure; the server-side
    age janitor is the floor under that shape, not this rule's job to guess.
    """

    if scan is None:
        return {}
    return {
        task_id: max((now_ms - time_ms) / 1000.0, 0.0)
        for task_id, time_ms in participation_times_ms(scan).items()
    }


def participation_age_seconds(
    scan: RawTranscriptScan,
    task_id: str,
    *,
    now_ms: int,
) -> float | None:
    """The age of a task's newest survival evidence, or ``None`` (P9).

    Same clamp as every other receipt age. A newer age is the conservative
    direction everywhere this feeds: the F4 notice arbitration supersedes more
    readily (sparing live tasks), and the never-started grace judges later, so
    a resumed task is never mistaken for one that never launched.
    """

    time_ms = participation_times_ms(scan).get(task_id)
    if time_ms is None:
        return None
    return max((now_ms - time_ms) / 1000.0, 0.0)


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
