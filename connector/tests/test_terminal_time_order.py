"""Terminal time-order arbitration (F4) — connector half, 2026-10-09.

Why this file exists
--------------------
`.local-dev/subagent-alias-durability-tasks.md` rt2, red team CONFIRMED F4.
The G3 sweep lowered the live vouch to an ``attached`` exemption, which let a
*stale* terminal notice close a task the transport was actively driving: the
task was killed (a ``stopped`` notice on disk), resumed through SendMessage
(live/attached), its subagent file missing — and the sweep read the stale
notice as a death, closed the card ``interrupted``, and the terminal
stickiness then refused the engine's own honest ``completed``.

Two arbitrations close it, both keyed on time order:

* F4a (prevention, oracle rule 1): a terminal notice may close an attached
  task only when it post-dates the task's latest launch evidence by more than
  the mtime tolerance — anything at or before the receipt is a death the
  resume superseded and is treated as absent.
* F4b (correction, fold): a terminal fold may replace an already-terminal
  card only when the incoming engine verdict is strictly later than the time
  the card recorded; same-instant or older stays sticky (the stop race), and
  a closure with no engine time (``stoppedWithoutTask``) has nothing to order
  against and keeps its stickiness.

Fixtures are synthetic (fake clock, dict-backed file probe, planted synthetic
ids). The full kill-resume-sweep-completion sequence mirrors the red team's
``p6_d3_stale_notice.py`` probe.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from connector.runtime_protocol import AgentCallToolContent
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
    ClaudeSubagentOracle,
    RawTranscriptScan,
)
from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)

X = "a6805987502c5966c"
R = "call_00_TI9XPPSBD5s5i9F80v5h3870"
R2 = "call_00_T2SiblingRoot000000000"
SESSION_ID = "sess_rt2_time_order"
EXTERNAL_SESSION_ID = "e89abce5-f48c-463b-8d16-d3f78dd504c4"
CWD = "/home/ubuntu"
PROJECTS_DIR = Path("/tmp/fake-claude-projects")

# The probe's numbers: a kill notice at T_STALE, the sweep ten minutes later
# with the transport vouching for the resumed task.
T_STALE = 1_759_852_084_000
NOW = T_STALE + 600_000
TOLERANCE_MS = 2_000


class _Clock:
    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __call__(self) -> float:
        return self.seconds


def _planted_missing(*, projects_dir, project_key, external_session_id, task_id):
    _ = projects_dir, project_key, external_session_id, task_id
    return AgentFileInfo(exists=False, path_known=True)


def _oracle(*, now_ms: int) -> ClaudeSubagentOracle:
    return ClaudeSubagentOracle(
        projects_dir=PROJECTS_DIR,
        clock=_Clock(now_ms / 1000.0),
        file_probe=_planted_missing,
    )


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="rt2",
        cwd=CWD,
    )


def _notice_event(status: str, *, task_id: str = X) -> ClaudeTaskEvent:
    return ClaudeTaskEvent(kind="notification", task_id=task_id, status=status)


def _mint_card(
    projector: ClaudeMessageProjector,
    *,
    tool_use_id: str = R,
    status: str = "async_launched",
) -> str:
    session = _session()
    projector.fold_agent_task_event(
        session,
        tool_use_id=tool_use_id,
        overlay=ClaudeAgentTaskOverlay(agents={X: {"status": status}}),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    return stable_tool_item_id(session, tool_use_id)


# --------------------------------------------------------------------------
# F4a: the oracle attributes a notice to the current incarnation
# --------------------------------------------------------------------------


def _evidence(
    oracle: ClaudeSubagentOracle,
    *,
    terminal_events: tuple[tuple[int | None, ClaudeTaskEvent], ...],
    receipt_age_seconds: float | None,
    attached_live: bool = True,
) -> Any:
    return oracle.evidence(
        task_id=X,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=terminal_events,
        receipt_age_seconds=receipt_age_seconds,
        attached_live=attached_live,
        now_ms=NOW,
    )


def test_F4a_a_notice_at_the_receipt_time_is_superseded_for_an_attached_task() -> None:
    # The p6 shape: the newest launch evidence sits at the notice's own time —
    # the notice cannot be attributed to the incarnation the transport drives.
    oracle = _oracle(now_ms=NOW)
    verdict = _evidence(
        oracle,
        terminal_events=((T_STALE, _notice_event("stopped")),),
        receipt_age_seconds=(NOW - T_STALE) / 1000.0,
    )
    assert verdict is None


def test_F4a_a_notice_clearly_after_the_receipt_still_closes_an_attached_task() -> None:
    # A task launched ten minutes ago and killed a second ago: the notice
    # post-dates the receipt well beyond tolerance and rule 1 stands.
    oracle = _oracle(now_ms=NOW)
    verdict = _evidence(
        oracle,
        terminal_events=((NOW - 1_000, _notice_event("stopped")),),
        receipt_age_seconds=600.0,
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "terminalNotice"


def test_F4a_the_tolerance_band_is_the_boundary() -> None:
    oracle = _oracle(now_ms=NOW)
    receipt_time = NOW - 600_000
    in_band = receipt_time + TOLERANCE_MS - 1
    out_of_band = receipt_time + TOLERANCE_MS + 1
    assert (
        _evidence(
            oracle,
            terminal_events=((in_band, _notice_event("stopped")),),
            receipt_age_seconds=600.0,
        )
        is None
    )
    assert (
        _evidence(
            oracle,
            terminal_events=((out_of_band, _notice_event("stopped")),),
            receipt_age_seconds=600.0,
        )
        is not None
    )


def test_F4a_an_older_notice_is_superseded_too() -> None:
    oracle = _oracle(now_ms=NOW)
    verdict = _evidence(
        oracle,
        terminal_events=((NOW - 1_200_000, _notice_event("stopped")),),
        receipt_age_seconds=600.0,
    )
    assert verdict is None


def test_F4a_a_non_attached_task_keeps_rule_one() -> None:
    # The arbitration is scoped to attached tasks; a dead task's stale-looking
    # notice still closes exactly as before.
    oracle = _oracle(now_ms=NOW)
    verdict = _evidence(
        oracle,
        terminal_events=((T_STALE, _notice_event("stopped")),),
        receipt_age_seconds=(NOW - T_STALE) / 1000.0,
        attached_live=False,
    )
    assert verdict is not None
    assert verdict.closed_by == "terminalNotice"


def test_F4a_without_receipt_evidence_the_notice_stands() -> None:
    # Documented residual: with no launch evidence to order against, the
    # notice cannot be arbitrated and rule 1 stands (declining instead would
    # stop notices from ever closing attached tasks).
    oracle = _oracle(now_ms=NOW)
    verdict = _evidence(
        oracle,
        terminal_events=((T_STALE, _notice_event("stopped")),),
        receipt_age_seconds=None,
    )
    assert verdict is not None
    assert verdict.closed_by == "terminalNotice"


# --------------------------------------------------------------------------
# The full p6 sequence: kill -> resume -> sweep -> honest completion
# --------------------------------------------------------------------------


def test_F4_kill_resume_sweep_then_honest_completion_ends_done() -> None:
    projector = ClaudeMessageProjector()
    session = _session()

    # 1) the transport resumed the task: task_started folds the card open.
    resume = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "running", "subagentType": "general-purpose"}}
        ),
        status="running",
    )
    assert resume.status == "running"

    # 2) the periodic evidence sweep runs with the stale stopped notice and a
    #    missing subagent file: the notice is superseded, the task is spared.
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now_ms=NOW),
        terminal_events={X: ((T_STALE, _notice_event("stopped")),)},
        receipt_ages={X: (NOW - T_STALE) / 1000.0},
        attached_task_ids=frozenset({X}),
        live_task_ids=frozenset({X}),
        now_ms=NOW,
    )
    assert items == ()

    # 3) the task genuinely completes: the honest verdict lands.
    done = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(agents={X: {"status": "completed"}}),
        status="done",
    )
    assert done.status == "done"
    assert done.content["agents"][X]["status"] == "completed"


# --------------------------------------------------------------------------
# F4b: the stop race — same-instant or older engine verdicts stay sticky
# --------------------------------------------------------------------------


def test_F4b_an_older_completed_cannot_flip_a_stop_closed_card() -> None:
    # The stop path's subjective judgment carries no engine time; a late but
    # older completed notice must never walk it back.
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _mint_card(projector, status="async_launched")
    stopped = projector.close_open_agent_cards(session)
    assert [item.id for item in stopped] == [card_id]
    assert stopped[0].status == "interrupted"
    assert stopped[0].content["stoppedWithoutTask"] is True

    late = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=T_STALE
        ),
        status="done",
    )
    assert late.status == "interrupted"


def test_F4b_an_older_engine_terminal_cannot_reopen_a_recorded_closure() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    _mint_card(projector, status="running")
    killed = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "killed"}}, end_time=NOW
        ),
        status="interrupted",
    )
    assert killed.status == "interrupted"

    older = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=NOW - 60_000
        ),
        status="done",
    )
    assert older.status == "interrupted"
    # Provenance stays with the recorded closure: the superseded frame cannot
    # rewrite the end time either.
    assert older.content["endTime"] == NOW


def test_F4b_a_same_instant_engine_terminal_keeps_the_recorded_verdict() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    _mint_card(projector, status="running")
    projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "killed"}}, end_time=NOW
        ),
        status="interrupted",
    )

    same = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=NOW
        ),
        status="done",
    )
    assert same.status == "interrupted"
    assert same.content["endTime"] == NOW


def test_F4b_an_undated_engine_terminal_keeps_the_recorded_verdict() -> None:
    # The live wire's completion frame carries no end time; with nothing to
    # order against it, the recorded verdict stays (documented residual).
    projector = ClaudeMessageProjector()
    session = _session()
    _mint_card(projector, status="running")
    projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "killed"}}, end_time=NOW
        ),
        status="interrupted",
    )

    undated = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(agents={X: {"status": "completed"}}),
        status="done",
    )
    assert undated.status == "interrupted"


# --------------------------------------------------------------------------
# F4b: a strictly later engine terminal corrects an evidence closure
# --------------------------------------------------------------------------


def _close_by_notice(
    projector: ClaudeMessageProjector,
    session: ClaudeSession,
    *,
    notice_ms: int,
) -> Any:
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now_ms=NOW),
        terminal_events={X: ((notice_ms, _notice_event("stopped")),)},
        now_ms=NOW,
    )
    return items


def test_F4b_a_strictly_later_engine_terminal_overrides_a_notice_closure() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _mint_card(projector, status="running")
    closed = _close_by_notice(projector, session, notice_ms=NOW - 300_000)
    assert [item.id for item in closed] == [card_id]
    assert closed[0].status == "interrupted"
    assert closed[0].content["closedByEvidence"] == "terminalNotice"
    assert closed[0].content["endTime"] == NOW - 300_000

    # The engine's own completion, strictly later than the closure: the card
    # is corrected, and the evidence provenance does not ride the new state.
    corrected = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=NOW - 100_000
        ),
        status="done",
    )
    assert corrected.status == "done"
    assert corrected.content["endTime"] == NOW - 100_000
    assert "closedByEvidence" not in corrected.content
    assert corrected.content["agents"][X]["status"] == "completed"


def test_F4b_sibling_cards_follow_the_correction_and_stay_idempotent() -> None:
    # G2: both roots of the task were closed by the same sweep, and a strictly
    # later engine terminal must reach both — while a repeat at the same time
    # moves nothing (idempotent).
    scan = RawTranscriptScan(
        notices=(),
        receipt_times_ms={},
        send_aliases={},
        dispatch_roots={X: frozenset({R, R2})},
        # T1's provenance seal (red team F1/F3): a root the scan has not
        # verified as an assistant dispatch call is not evidence. The fixture
        # vouches for both roots, as a real scan would.
        verified_dispatch_ids=frozenset({R, R2}),
    )
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _session: scan)
    session = _session()
    canonical = _mint_card(projector, tool_use_id=R, status="running")
    sibling = _mint_card(projector, tool_use_id=R2, status="running")
    closed = _close_by_notice(projector, session, notice_ms=NOW - 300_000)
    assert sorted(item.id for item in closed) == sorted([canonical, sibling])

    items = projector.fold_agent_task_items(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=NOW - 100_000
        ),
        status="done",
    )
    by_id = {item.id: item for item in items}
    assert by_id[canonical].status == "done"
    assert by_id[sibling].status == "done"
    assert by_id[sibling].content["endTime"] == NOW - 100_000

    # Same instant again: no card moves, and nothing is republished.
    again = projector.fold_agent_task_items(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=NOW - 100_000
        ),
        status="done",
    )
    assert [item.id for item in again] == [canonical]
