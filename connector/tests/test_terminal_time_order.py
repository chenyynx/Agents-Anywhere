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
  task only when it post-dates the task's latest *participation* evidence —
  the newer of the dispatch receipt and the task's most recent SendMessage
  resume row (P9, second red-team round: anchoring on the receipt alone let a
  legitimate stop notice close the resumed task, because the notice really
  does post-date the dispatch) — by more than the mtime tolerance.
* F4b (correction, fold): a terminal fold may replace an already-terminal
  card only when the incoming engine verdict is strictly later than the time
  the card recorded; same-instant or older stays sticky (the stop race), and
  a closure with no engine time (``stoppedWithoutTask``) has nothing to order
  against and keeps its stickiness.
* N1 (publication, P10): both publication loops share one gate — a terminal
  item that is not strictly newer than the already-published terminal of the
  same id is dropped, so a sweep's stale verdict cannot land after a fold's
  honest terminal and persist a card/published divergence.

Fixtures are synthetic (fake clock, dict-backed file probe, planted synthetic
ids and a synthetic incident timeline carrying the production offsets). The
full sequence mirrors the red team's ``p6_d3_stale_notice.py`` /
``p9_f4_real.py`` / ``p10_sweep_stale_publish.py`` probes.
"""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from connector.runtime_protocol import (
    AgentCallToolContent,
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeTimelineItem,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
    ClaudeSubagentOracle,
    RawTranscriptScan,
    participation_times_ms,
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
    terminal_publish_superseded,
)
from connector.runtimes.claude.turns.lifecycle import (
    _receipt_ages_by_task,
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

# The real incident timeline (sess_Nk19-gOK4L5Eaw, 2026-10-09), on a synthetic
# base with the production offsets: dispatch receipt 01:28:43, stop notice
# 01:48:04, SendMessage resume 01:52:17, honest completion 02:05:55. Anchored
# on the receipt alone the notice was "attributable" (it legitimately
# post-dates the dispatch) and closed the resumed task — the confirmed P9
# false closure; the resume row after the notice is what supersedes it.
INCIDENT_BASE_MS = 1_758_000_000_000
INCIDENT_RECEIPT_MS = INCIDENT_BASE_MS
INCIDENT_STOP_MS = INCIDENT_BASE_MS + 1_161_000
INCIDENT_RESUME_MS = INCIDENT_BASE_MS + 1_414_000
INCIDENT_COMP_MS = INCIDENT_BASE_MS + 2_232_000
INCIDENT_NOW_MS = INCIDENT_COMP_MS - 600_000


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


def _incident_scan() -> RawTranscriptScan:
    """The P9 fixture's scan: receipt at dispatch, resume row after the stop."""

    return RawTranscriptScan(
        notices=(),
        receipt_times_ms={X: INCIDENT_RECEIPT_MS},
        send_resume_times_ms={X: INCIDENT_RESUME_MS},
        send_aliases={R: X},
        dispatch_roots={X: frozenset({R})},
        verified_dispatch_ids=frozenset({R}),
    )


def test_P9_kill_resume_sweep_then_honest_completion_ends_done() -> None:
    # The real incident timeline. The caller hands the sweep the dispatch-only
    # receipt age (the pre-P9 premise, kept deliberately as the input), and the
    # projector's scan seam supplies the resume row: the merged participation
    # anchor supersedes the stop notice, so the resumed task is spared.
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: _incident_scan())
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

    # 2) the mid-run evidence sweep: stale stopped notice + missing subagent
    #    file + attached — the P9 shape that used to close the live task.
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now_ms=INCIDENT_NOW_MS),
        terminal_events={X: ((INCIDENT_STOP_MS, _notice_event("stopped")),)},
        receipt_ages={X: (INCIDENT_NOW_MS - INCIDENT_RECEIPT_MS) / 1000.0},
        attached_task_ids=frozenset({X}),
        live_task_ids=frozenset({X}),
        now_ms=INCIDENT_NOW_MS,
    )
    assert items == ()

    # 3) the honest completion lands — the live wire's undated notification
    #    first, then the import fold carrying the notice timestamp.
    live_done = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(agents={X: {"status": "completed"}}),
        status="done",
    )
    assert live_done.status == "done"
    imported = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "completed"}}, end_time=INCIDENT_COMP_MS
        ),
        status="done",
    )
    assert imported.status == "done"
    assert imported.content["agents"][X]["status"] == "completed"


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

# --------------------------------------------------------------------------
# P9: the scan records resume rows; the participation anchor merges the maps
# --------------------------------------------------------------------------


def _iso_ms(epoch_ms: int) -> str:
    return (
        datetime.fromtimestamp(epoch_ms / 1000, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _raw_assistant_send_row(tool_use_id: str, to: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "assistant",
            "uuid": f"row-{tool_use_id}",
            "timestamp": timestamp,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": tool_use_id,
                        "name": "SendMessage",
                        "input": {"to": to, "message": "resume"},
                    }
                ],
            },
        }
    )


def _raw_assistant_agent_row(tool_use_id: str, to: str, timestamp: str) -> str:
    # The control shape: a non-SendMessage tool_use that happens to carry an
    # ``input.to`` — it must not record a resume time.
    return json.dumps(
        {
            "type": "assistant",
            "uuid": f"row-{tool_use_id}",
            "timestamp": timestamp,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": tool_use_id,
                        "name": "Agent",
                        "input": {"to": to, "prompt": "x"},
                    }
                ],
            },
        }
    )


def test_scan_records_the_newest_resume_row_time_per_task() -> None:
    first = INCIDENT_BASE_MS + 1_000
    newest = INCIDENT_BASE_MS + 5_000
    scan = scan_raw_transcript(
        (
            _raw_assistant_send_row("call_send_1", X, _iso_ms(first)),
            _raw_assistant_send_row("call_send_2", X, _iso_ms(newest)),
            _raw_assistant_agent_row("call_agent_to", X, _iso_ms(newest + 1_000)),
            # No timestamp on this row: it must contribute nothing (only add,
            # never guess).
            json.dumps(
                {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "call_send_3",
                                "name": "SendMessage",
                                "input": {"to": X},
                            }
                        ],
                    },
                }
            ),
        )
    )
    assert scan.send_resume_times_ms == {X: newest}
    # The alias map is unchanged by the new field: the newest row still
    # registers its alias (setdefault keeps the first id seen per call).
    assert scan.send_aliases == {
        "call_send_1": X,
        "call_send_2": X,
        "call_send_3": X,
    }


def test_participation_times_take_the_newer_of_receipt_and_resume() -> None:
    receipt_only = RawTranscriptScan(
        notices=(), receipt_times_ms={X: 1_000, "other": 500}
    )
    assert participation_times_ms(receipt_only) == {X: 1_000, "other": 500}

    resume_newer = RawTranscriptScan(
        notices=(),
        receipt_times_ms={X: 1_000},
        send_resume_times_ms={X: 2_000, "resume_only": 3_000},
    )
    assert participation_times_ms(resume_newer) == {X: 2_000, "resume_only": 3_000}

    receipt_newer = RawTranscriptScan(
        notices=(),
        receipt_times_ms={X: 5_000},
        send_resume_times_ms={X: 2_000},
    )
    assert participation_times_ms(receipt_newer) == {X: 5_000}


def test_receipt_ages_use_the_participation_anchor() -> None:
    # The lifecycle consumer: a resumed task's age must come from the resume
    # row, not the dispatch receipt the stop notice post-dates.
    scan = _incident_scan()
    ages = _receipt_ages_by_task(scan, now_ms=INCIDENT_NOW_MS)
    assert ages[X] == (INCIDENT_NOW_MS - INCIDENT_RESUME_MS) / 1000.0
    assert _receipt_ages_by_task(None, now_ms=INCIDENT_NOW_MS) == {}


# --------------------------------------------------------------------------
# N1: the shared publication gate (fold loop and sweep loop)
# --------------------------------------------------------------------------


def _platform_card(
    *,
    status: str,
    end_time_ms: int | None,
    agents: dict[str, dict[str, Any]] | None = None,
) -> RuntimeTimelineItem:
    content: dict[str, Any] = {
        "kind": "agent_call",
        "title": "research",
        "agents": {k: dict(v) for k, v in (agents or {X: {"status": status}}).items()},
    }
    if end_time_ms is not None:
        content["endTime"] = end_time_ms
    return RuntimeTimelineItem(
        id="claude_tool_n1",
        session_id=SESSION_ID,
        type="tool",
        status=status,
        order_seq=1,
        content_hash="sha256:n1",
        role="tool",
        content=content,
    )


def test_N1_the_publish_gate_drops_terminal_items_not_strictly_newer() -> None:
    done_t2 = _platform_card(status="done", end_time_ms=NOW)
    interrupted_t1 = _platform_card(status="interrupted", end_time_ms=NOW - 60_000)
    undated = _platform_card(status="interrupted", end_time_ms=None)
    undated_published = _platform_card(status="done", end_time_ms=None)
    running = _platform_card(status="running", end_time_ms=None)

    # A rival verdict (different status) that is not strictly newer is
    # dropped — including the same instant and an undated incoming.
    assert terminal_publish_superseded(interrupted_t1, done_t2) is True
    assert terminal_publish_superseded(undated, done_t2) is True
    assert terminal_publish_superseded(
        _platform_card(status="interrupted", end_time_ms=NOW), done_t2
    ) is True  # same instant
    # Strictly later — F4b's legitimate correction passes.
    assert terminal_publish_superseded(done_t2, interrupted_t1) is False
    # A published state with no time cannot order a timed incoming claim: the
    # stop closure's undated interruption must stay correctable.
    assert terminal_publish_superseded(done_t2, undated_published) is False
    # A republish of the SAME verdict is enrichment (the terminal burst:
    # task_updated closes with the end time, task_notification adds the
    # verbatim summary) — it passes at equal time and only a strictly older
    # one is refused, so the recorded time is never walked backwards.
    enriched_done = _platform_card(
        status="done", end_time_ms=NOW, agents={X: {"status": "completed"}}
    )
    assert terminal_publish_superseded(enriched_done, done_t2) is False
    assert terminal_publish_superseded(
        _platform_card(status="done", end_time_ms=None), done_t2
    ) is False
    assert terminal_publish_superseded(
        _platform_card(status="interrupted", end_time_ms=NOW - 120_000),
        _platform_card(status="interrupted", end_time_ms=NOW - 60_000),
    ) is True
    # Non-terminal incoming always publishes (the reopen path).
    assert terminal_publish_superseded(running, done_t2) is False
    # No published state: nothing to arbitrate.
    assert terminal_publish_superseded(interrupted_t1, None) is False


class _RecordingHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)


def test_N1_the_fold_loop_refuses_a_superseded_terminal_publish() -> None:
    # The P10 interleave, driven through the real fold publication loop: the
    # published row already carries the honest stale-corrected terminal at t2,
    # the in-memory card still records its own closure at t1 < t2, and the
    # fold's republish (content differs, time not strictly newer) must not
    # land. Without the gate this loop traded a card/published divergence.
    import asyncio

    host = _RecordingHost()
    runtime = ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=host,
        subagent_oracle=_oracle(now_ms=NOW),
    )
    # Hermetic: no ambient transcript read for the sibling walk.
    runtime._timeline._raw_scan_provider = lambda _s: None
    session = _session()
    runtime._sessions[session.session_id] = session
    runner = runtime._turns.runner
    runner.agent_task_calls[(session.session_id, X)] = R

    projector = runtime._timeline
    projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(agents={X: {"status": "running"}}),
        status="running",
    )
    card_id = stable_tool_item_id(session, R)
    closed = projector.fold_agent_task_event(
        session,
        tool_use_id=R,
        overlay=ClaudeAgentTaskOverlay(
            agents={X: {"status": "killed"}}, end_time=NOW - 60_000
        ),
        status="interrupted",
    )
    assert closed.status == "interrupted"
    # The honest completion already landed and published (t2 > t1).
    session.timeline_items[card_id] = replace(
        closed,
        status="done",
        content={
            **dict(closed.content),
            "agents": {X: {"status": "completed"}},
            "endTime": NOW,
        },
    )

    # A superseded engine frame (an older stopped notice) folds: the card
    # stays interrupted at t1, and the republish is refused by the gate.
    asyncio.run(
        runner.fold_agent_task_event(
            session,
            ClaudeTaskEvent(
                kind="updated",
                task_id=X,
                status="stopped",
                tool_use_id=R,
                end_time=NOW - 120_000,
            ),
        )
    )
    assert host.timeline_item_upserts == []
    assert session.timeline_items[card_id].status == "done"


def test_N1_a_stale_sweep_item_is_refused_by_the_shared_gate() -> None:
    # The sweep loop's half: the item the sweep computed synchronously is
    # checked against the state at publish time, and a stale terminal that is
    # not strictly newer is dropped (the same rule the fold loop applies).
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _mint_card(projector, status="running")
    stale = _close_by_notice(projector, session, notice_ms=NOW - 300_000)
    assert [item.id for item in stale] == [card_id]
    stale_item = stale[0]
    session.timeline_items[card_id] = replace(
        stale_item,
        status="done",
        content={
            **dict(stale_item.content),
            "agents": {X: {"status": "completed"}},
            "endTime": NOW,
        },
    )
    assert terminal_publish_superseded(stale_item, session.timeline_items[card_id])
