"""Subagent task-truth closure (R1/R2) — connector half, 2026-10-08.

Why this file exists
--------------------
Two ways an Agent card could be stranded ``running`` forever, both measured on
the 2026-10-08 sessions (``.local-dev/subagent-status-truth-tasks.md``):

* **R1** — the CLI persists a background completion as a ``<task-notification>``
  transcript row, but a notice whose wrapper the SDK's message view drops never
  reaches the fold. Both research cards in session ``e89abce5`` completed with
  their notice present in the raw ``queue-operation`` rows and absent from
  ``read_sdk_session_messages``.
* **R2** — when the host process is killed, the CLI emits no terminal event at
  all, so nothing can close the card.

The fix reads the completion back from the engine's own files: the raw
transcript (R1) and the per-task ``subagents/agent-<id>.jsonl`` mtime (R2). Both
decisions are driven here with a fake clock and fake files — no real disk, no
wall time — through the injectable oracle.

What is pinned
--------------
* the raw-transcript scanner: only user rows and enqueue rows, of both wrapper
  layouts, deduped, with an anchor for placement;
* the oracle decision order: terminal notice (silent file) first, then the
  never-started grace, then the stale deadline, with ``attached`` exempt from
  file silence;
* the live sweep's evidence mode (closes only justified cards) versus the stop
  ghost mode (closes every open card);
* the history post-pass: a dropped notice closes the card with ``terminalNotice``
  and a killed task closes it with ``agentFileStale`` / ``neverStarted``.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any

from connector.runtime_protocol import AgentCallToolContent
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
    ClaudeSubagentOracle,
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)

EXTERNAL_SESSION_ID = "e89abce5-f48c-463b-8d16-d3f78dd504c4"
SESSION_ID = "sess_claude_truth_closure"
CWD = "/home/ubuntu"
PROJECT_KEY = "-home-ubuntu"
DISPATCH_TUID = "call_00_VfDHxRgrlK9Rcz5Aj42Y0476"
TASK_ID = "a90d5e84970e81d34"
SECOND_TASK_ID = "a187622e7200028c3"
PROJECTS_DIR = "/tmp/fake-claude-projects"

# The task sheet's defaults, restated so a drift in the module constants fails
# loudly here and the tests use the same numbers producers do.
T_START = 120.0
T_STALE = 900.0


# --------------------------------------------------------------------------
# Fixtures: a fake clock and a dict-backed file probe
# --------------------------------------------------------------------------


class _Clock:
    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __call__(self) -> float:
        return self.seconds


def _file_table(
    *entries: tuple[str, AgentFileInfo],
) -> Any:
    table = dict(entries)

    def probe(*, projects_dir, project_key, external_session_id, task_id):
        _ = projects_dir, project_key, external_session_id
        return table.get(task_id, AgentFileInfo(exists=False, path_known=True))

    return probe


def _oracle(
    *,
    now: float,
    files: dict[str, AgentFileInfo],
    start_grace: float = T_START,
    stale: float = T_STALE,
) -> ClaudeSubagentOracle:
    return ClaudeSubagentOracle(
        projects_dir=__import__("pathlib").Path(PROJECTS_DIR),
        clock=_Clock(now),
        file_probe=_file_table(*files.items()),
        start_grace_seconds=start_grace,
        stale_seconds=stale,
    )


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Truth closure",
        cwd=CWD,
    )


def _notice_event(status: str, *, task_id: str = TASK_ID, end_ms: int | None = None):
    return ClaudeTaskEvent(
        kind="notification",
        task_id=task_id,
        status=status,
        end_time=end_ms,
    )


# --------------------------------------------------------------------------
# 1. The raw-transcript scanner (R1)
# --------------------------------------------------------------------------


def _raw_user_row(uuid: str, text: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "timestamp": timestamp,
            "message": {"role": "user", "content": text},
        }
    )


def _raw_enqueue_row(text: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": timestamp,
            "content": text,
        }
    )


def _notice_text(task_id: str, status: str, tool_use_id: str | None = None) -> str:
    tool = f"<tool-use-id>{tool_use_id}</tool-use-id>\n" if tool_use_id else ""
    return (
        "<task-notification>\n"
        f"<task-id>{task_id}</task-id>\n"
        f"{tool}"
        f"<status>{status}</status>\n"
        "<summary>Agent \"research\" finished</summary>\n"
        "</task-notification>"
    )


def test_scan_reads_a_user_row_notice() -> None:
    lines = (
        _raw_user_row("u1", _notice_text(TASK_ID, "completed", DISPATCH_TUID),
                      "2026-10-08T08:02:15.015Z"),
    )
    scan = scan_raw_transcript(lines)
    assert len(scan.notices) == 1
    notice = scan.notices[0]
    assert notice.event.task_id == TASK_ID
    assert notice.event.status == "completed"
    assert notice.event.tool_use_id == DISPATCH_TUID
    assert notice.row_uuid == "u1"
    assert notice.timestamp_ms == 1_791_446_535_015


def test_scan_reads_an_enqueue_row_notice_without_a_user_row() -> None:
    # The real shape for both research cards: only the queue-operation row
    # exists, and it carries no uuid, so the anchor is the preceding row's.
    lines = (
        _raw_user_row("u1", "hello", "2026-10-08T08:00:00.000Z"),
        _raw_enqueue_row(_notice_text(TASK_ID, "completed", DISPATCH_TUID),
                         "2026-10-08T08:02:15.015Z"),
    )
    scan = scan_raw_transcript(lines)
    assert len(scan.notices) == 1
    assert scan.notices[0].event.status == "completed"
    assert scan.notices[0].row_uuid is None
    assert scan.notices[0].anchor == "u1"


def test_scan_ignores_attachment_rendering_rows() -> None:
    lines = (
        json.dumps(
            {
                "type": "attachment",
                "uuid": "a1",
                "attachment": {"type": "queued_command", "prompt": _notice_text(TASK_ID, "completed")},
            }
        ),
    )
    assert scan_raw_transcript(lines).notices == ()


def test_scan_ignores_non_enqueue_queue_operations() -> None:
    lines = (
        json.dumps(
            {
                "type": "queue-operation",
                "operation": "dequeue",
                "content": _notice_text(TASK_ID, "completed"),
            }
        ),
    )
    assert scan_raw_transcript(lines).notices == ()


# --------------------------------------------------------------------------
# 2/3/5/6. The oracle decision order
# --------------------------------------------------------------------------


def test_terminal_notice_with_silent_file_closes_as_the_notice_status() -> None:
    # Scenario 4 (R1): a completed notice names the task; the file stopped at
    # the notice time, so the notice's status is the truth.
    notice_ms = 1_791_446_535_015
    oracle = _oracle(
        now=notice_ms / 1000.0 + 3600,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=notice_ms)},
    )
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=((notice_ms, _notice_event("completed", end_ms=notice_ms)),),
    )
    assert verdict is not None
    assert verdict.closure_status == "done"
    assert verdict.closed_by == "terminalNotice"
    assert verdict.end_time_ms == notice_ms


def test_terminal_notice_with_missing_file_still_closes() -> None:
    notice_ms = 1_791_446_535_015
    oracle = _oracle(now=notice_ms / 1000.0, files={})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=((notice_ms, _notice_event("killed", end_ms=notice_ms)),),
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "terminalNotice"


def test_notice_does_not_close_when_the_file_kept_writing_after_it() -> None:
    # The task was resumed and is writing again — the stale notice must not win.
    notice_ms = 1_791_446_535_015
    oracle = _oracle(
        now=(notice_ms + 600_000) / 1000.0,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=notice_ms + 600_000)},
    )
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=((notice_ms, _notice_event("completed", end_ms=notice_ms)),),
    )
    assert verdict is None


def test_scenario_3_never_started_closes_within_T_start() -> None:
    # Scenario 3: an async_launched dispatch whose file never appeared, past the
    # start grace, is judged interrupted rather than "starting" forever.
    now = 1_791_446_600.0
    oracle = _oracle(now=now, files={})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=T_START + 1,
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "neverStarted"


def test_never_started_does_not_close_before_the_grace() -> None:
    oracle = _oracle(now=1_791_446_600.0, files={})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=T_START - 1,
    )
    assert verdict is None


def test_scenario_1_stale_file_closes_as_interrupted() -> None:
    # Scenario 1: stop → resume → silent kill. Past T_stale with no notice, the
    # file's stillness is the evidence.
    now = 1_791_446_535.0
    file_mtime = int((now - T_STALE - 1) * 1000)
    oracle = _oracle(now=now, files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=file_mtime)})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "agentFileStale"
    assert verdict.end_time_ms == file_mtime


def test_scenario_5_fresh_file_does_not_close() -> None:
    now = 1_791_446_535.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int(now * 1000) - 5_000)},
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
        )
        is None
    )


def test_scenario_6_attached_is_not_killed_by_file_silence() -> None:
    # A long tool call inside a live turn writes nothing for a while; attached
    # tasks are exempt from the stale-file closure.
    now = 1_791_446_535.0
    file_mtime = int((now - T_STALE - 1) * 1000)
    oracle = _oracle(now=now, files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=file_mtime)})
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            attached_live=True,
        )
        is None
    )


def test_attached_still_closes_on_a_terminal_notice() -> None:
    notice_ms = 1_791_446_535_015
    oracle = _oracle(now=(notice_ms + 600_000) / 1000.0, files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=notice_ms)})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=((notice_ms, _notice_event("completed", end_ms=notice_ms)),),
        attached_live=True,
    )
    assert verdict is not None
    assert verdict.closure_status == "done"


def test_unknown_project_directory_declines_to_judge() -> None:
    # No cwd -> the oracle cannot locate the file, so absence proves nothing.
    oracle = _oracle(now=1_791_446_600.0, files={})
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=None,
        )
        is None
    )


def test_project_key_matches_the_cli_rule() -> None:
    from connector.runtimes.claude.sessions.subagent_oracle import claude_project_key

    assert claude_project_key("/home/ubuntu") == "-home-ubuntu"
    assert claude_project_key("/home/ubuntu/repos/Agents-Anywhere") == (
        "-home-ubuntu-repos-Agents-Anywhere"
    )


# --------------------------------------------------------------------------
# The live sweep: evidence mode vs stop ghost mode
# --------------------------------------------------------------------------


def _async_card(projector: ClaudeMessageProjector) -> str:
    """Mint one open card in the async_launched shape (the stranded card)."""

    session = _session()
    projector.fold_agent_task_event(
        session,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(agents={TASK_ID: {"status": "async_launched"}}),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    return stable_tool_item_id(session, DISPATCH_TUID)


def test_sweep_evidence_mode_closes_a_stale_card() -> None:
    projector = ClaudeMessageProjector()
    card_id = _async_card(projector)
    session = _session()
    now = 1_791_446_535.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))},
    )
    items = projector.close_open_agent_cards(session, oracle=oracle)
    assert [item.id for item in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "agentFileStale"
    assert items[0].content["agents"][TASK_ID]["status"] == "interrupted"


def test_sweep_evidence_mode_leaves_a_fresh_card_open() -> None:
    projector = ClaudeMessageProjector()
    _async_card(projector)
    session = _session()
    now = 1_791_446_535.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int(now * 1000))},
    )
    assert projector.close_open_agent_cards(session, oracle=oracle) == ()


def test_sweep_evidence_mode_leaves_live_task_open() -> None:
    projector = ClaudeMessageProjector()
    _async_card(projector)
    session = _session()
    now = 1_791_446_535.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))},
    )
    # The transport still lists the task as active: no file judgement may win.
    assert (
        projector.close_open_agent_cards(
            session, oracle=oracle, live_task_ids=frozenset({TASK_ID})
        )
        == ()
    )


def test_sweep_stop_mode_still_closes_every_open_card() -> None:
    # Regression: the stop-path ghost sweep is unchanged when no oracle is given.
    projector = ClaudeMessageProjector()
    card_id = _async_card(projector)
    session = _session()
    items = projector.close_open_agent_cards(session)
    assert [item.id for item in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["stoppedWithoutTask"] is True


# --------------------------------------------------------------------------
# The history post-pass: R1 / R2 closures from evidence
# --------------------------------------------------------------------------


def _dispatch_message() -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid="dispatch-native",
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": DISPATCH_TUID,
                    "name": "Agent",
                    "input": {
                        "description": "D0 侦察：切模型/灰键修复",
                        "prompt": "Recon.",
                        "run_in_background": True,
                    },
                }
            ],
        },
    )


def _receipt_message(task_id: str = TASK_ID) -> Any:
    return SimpleNamespace(
        type="user",
        uuid="receipt-native",
        message={
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": DISPATCH_TUID,
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                "Async agent launched successfully.\n"
                                f"agentId: {task_id} (internal ID)"
                            ),
                        }
                    ],
                }
            ],
        },
    )


def test_scenario_4_raw_notice_closes_a_card_the_sdk_view_dropped() -> None:
    # The SDK view here holds dispatch + receipt and NO notification message;
    # the completion survives only in the raw transcript.
    messages = (_dispatch_message(), _receipt_message())
    raw_lines = (
        _raw_user_row("dispatch-native", "go", "2026-10-08T09:00:00.000Z"),
        _raw_enqueue_row(
            _notice_text(TASK_ID, "completed", DISPATCH_TUID),
            "2026-10-08T09:10:00.000Z",
        ),
    )
    notice_ms = 1_791_457_800_000  # 2026-10-08T09:10:00Z in ms
    oracle = _oracle(
        now=notice_ms / 1000.0 + 3600,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=notice_ms)},
    )
    items = _history_items_from_messages(
        _session(), messages, raw_lines=raw_lines, oracle=oracle
    )
    card = [i for i in items if i.content.get("kind") == "agent_call"]
    assert len(card) == 1
    assert card[0].status == "done"
    assert card[0].content["agents"][TASK_ID]["status"] == "completed"


def test_scenario_1_history_closes_a_stale_card_by_file() -> None:
    # No notice anywhere; only the file's stillness. Without the oracle this
    # card stays running forever.
    messages = (_dispatch_message(), _receipt_message())
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))},
    )
    items = _history_items_from_messages(_session(), messages, oracle=oracle)
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "agentFileStale"
    # The per-task detail must stop claiming running/async_launched.
    assert card.content["agents"][TASK_ID]["status"] == "interrupted"


def test_history_without_an_oracle_is_unchanged() -> None:
    messages = (_dispatch_message(), _receipt_message())
    items = _history_items_from_messages(_session(), messages)
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "running"
    assert "closedByEvidence" not in card.content


def test_scenario_2_restart_reconcile_closes_a_card() -> None:
    # Scenario 2 (kill -9 the host): the startup reconciliation judges the open
    # card once, from the files, and closes it. Exercised at the sweep the
    # reconciliation iterates (building a whole runner is out of scope here).
    projector = ClaudeMessageProjector()
    card_id = _async_card(projector)
    session = _session()
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))},
    )
    items = projector.close_open_agent_cards(session, oracle=oracle)
    assert [item.id for item in items] == [card_id]
    assert items[0].status == "interrupted"
