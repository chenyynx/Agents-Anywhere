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
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any

from connector.runtime_protocol import AgentCallToolContent
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    SUBAGENT_AGE_BOUND_ENV,
    SUBAGENT_AGE_BOUND_SECONDS,
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
T_AGE_BOUND = 86_400.0  # 24h — the T2 hard age ceiling


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
    age_bound: float | None = None,
) -> ClaudeSubagentOracle:
    # `age_bound=None` leaves the field on its construction-time default
    # (the environment-aware one); the T2 env tests exercise that seam.
    extras: dict[str, Any] = (
        {"age_bound_seconds": age_bound} if age_bound is not None else {}
    )
    return ClaudeSubagentOracle(
        projects_dir=__import__("pathlib").Path(PROJECTS_DIR),
        clock=_Clock(now),
        file_probe=_file_table(*files.items()),
        start_grace_seconds=start_grace,
        stale_seconds=stale,
        **extras,
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
    # exists, and it carries no uuid of its own.
    lines = (
        _raw_user_row("u1", "hello", "2026-10-08T08:00:00.000Z"),
        _raw_enqueue_row(_notice_text(TASK_ID, "completed", DISPATCH_TUID),
                         "2026-10-08T08:02:15.015Z"),
    )
    scan = scan_raw_transcript(lines)
    assert len(scan.notices) == 1
    assert scan.notices[0].event.status == "completed"
    assert scan.notices[0].row_uuid is None


def test_scan_collects_receipt_times_with_and_without_timestamps() -> None:
    # F5: the launch time comes from the raw receipt rows. A row with a
    # timestamp contributes; one without contributes nothing (never guessed).
    lines = (
        _raw_user_row(
            "r1",
            f"Async agent launched successfully.\nagentId: {TASK_ID} (internal ID)",
            "2026-10-08T09:00:01.000Z",
        ),
        json.dumps(
            {
                "type": "user",
                "uuid": "r2",
                "message": {
                    "role": "user",
                    "content": f"quoted later: agentId: {SECOND_TASK_ID} (internal ID)",
                },
            }
        ),
    )
    scan = scan_raw_transcript(lines)
    assert scan.receipt_times_ms == {TASK_ID: 1_791_450_001_000}


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


# --------------------------------------------------------------------------
# F4: a raw notice older than the window must never beat in-window activity
# --------------------------------------------------------------------------

_WINDOW_DISPATCH = "call_dispatch_1"
_WINDOW_SEND = "call_send_1"


def _window_dispatch_message() -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid="d1",
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": _WINDOW_DISPATCH,
                    "name": "Agent",
                    "input": {"description": "bytegate", "prompt": "p",
                              "run_in_background": True},
                }
            ],
        },
    )


def _window_receipt_message() -> Any:
    return SimpleNamespace(
        type="user",
        uuid="d2",
        message={
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": _WINDOW_DISPATCH,
                    "content": [
                        {"type": "text",
                         "text": f"Async agent launched successfully.\nagentId: {TASK_ID} (internal ID)"}
                    ],
                }
            ],
        },
    )


def _window_send_message() -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid="w2",
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": _WINDOW_SEND,
                    "name": "SendMessage",
                    "input": {"to": TASK_ID, "message": "continue"},
                }
            ],
        },
    )


def _window_user_message() -> Any:
    return SimpleNamespace(
        type="user", uuid="w1",
        message={"role": "user", "content": "把子代理继续跑起来"},
    )


def _incremental_window_card(
    raw_lines: tuple[str, ...],
    window: tuple[Any, ...] | None = None,
) -> Any:
    """Project one settle window with optional raw transcript rows.

    The dispatch and its receipt are outside the window but present in the
    full-chain lookup, exactly like a real settle sync. The default window is
    the resume turn; a caller can pass a resume-free window to model a settle
    that carries no new activity at all.
    """

    from connector.runtimes.claude.sessions.reader import _history_tool_call_context

    session = _session()
    full_chain = (
        _window_dispatch_message(),
        _window_receipt_message(),
        _window_user_message(),
        _window_send_message(),
    )
    lookup, _ = _history_tool_call_context(session, full_chain)
    resolved_window = (
        window if window is not None else (_window_user_message(), _window_send_message())
    )
    items = _history_items_from_messages(
        session, resolved_window, tool_call_lookup=lookup, raw_lines=raw_lines
    )
    return next(i for i in items if i.content.get("kind") == "agent_call")


def _raw_assistant_tool_row(uuid: str, tool_use_id: str, name: str, tool_input: Any, ts: str) -> str:
    return json.dumps({
        "type": "assistant", "uuid": uuid, "timestamp": ts,
        "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": tool_use_id, "name": name, "input": tool_input},
        ]},
    })


_F4_RAW_HEAD = (
    _raw_assistant_tool_row("d1", _WINDOW_DISPATCH, "Agent",
                            {"description": "bytegate", "prompt": "p",
                             "run_in_background": True},
                            "2026-10-08T09:00:00.000Z"),
    _raw_user_row("d2", f"Async agent launched successfully.\nagentId: {TASK_ID} (internal ID)",
                  "2026-10-08T09:00:01.000Z"),
)

#: The old stopped notice as a user row (uuid "n1") and as an enqueue row — the
#: two raw shapes seen in production.
_F4_RAW_NOTICE_USER = _raw_user_row(
    "n1", _notice_text(TASK_ID, "stopped"), "2026-10-08T09:21:23.290Z"
)
_F4_RAW_NOTICE_ENQUEUE = _raw_enqueue_row(
    _notice_text(TASK_ID, "stopped"), "2026-10-08T09:21:23.290Z"
)

_F4_RAW_TAIL = (
    _raw_user_row("w1", "把子代理继续跑起来", "2026-10-08T09:30:00.000Z"),
    _raw_assistant_tool_row("w2", _WINDOW_SEND, "SendMessage",
                            {"to": TASK_ID, "message": "continue"},
                            "2026-10-08T09:30:30.000Z"),
)

_F4_LATER_WINDOW_RAW = (
    _raw_user_row("w3", "later message", "2026-10-08T10:00:00.000Z"),
    _raw_assistant_tool_row("w4", "call_later", "Bash", {"command": "ls"},
                            "2026-10-08T10:00:05.000Z"),
)


def _f4_notice_message(status: str = "stopped") -> Any:
    """The notice as an in-window driver message (uuid "n1")."""

    return SimpleNamespace(
        type="user", uuid="n1",
        message={"role": "user", "content": _notice_text(TASK_ID, status)},
    )


def _f4_later_user_message() -> Any:
    return SimpleNamespace(
        type="user", uuid="w3",
        message={"role": "user", "content": "later message"},
    )


def test_F4_matrix_1_resume_window_with_the_notice_outside_is_running() -> None:
    # ① The window carries the resume; the old notice's row is outside it, so
    # it does not participate at all.
    card = _incremental_window_card(_F4_RAW_HEAD + (_F4_RAW_NOTICE_ENQUEUE,) + _F4_RAW_TAIL)
    assert card.status == "running"


def test_F4_matrix_1b_user_row_notice_outside_the_window_is_dropped() -> None:
    card = _incremental_window_card(_F4_RAW_HEAD + (_F4_RAW_NOTICE_USER,) + _F4_RAW_TAIL)
    assert card.status == "running"


def test_F4_matrix_2_the_window_after_the_resume_does_not_reclose() -> None:
    # ② The N1 regression: every settle after the resume used to re-fold the
    # old notice and republish the card as interrupted. A window that owns no
    # signal for this task must publish no terminal card for it.
    raw = _F4_RAW_HEAD + (_F4_RAW_NOTICE_USER,) + _F4_RAW_TAIL + _F4_LATER_WINDOW_RAW
    items = _history_items_from_messages(
        _session(), (_f4_later_user_message(),), tool_call_lookup=_f4_lookup(), raw_lines=raw
    )
    cards = [i for i in items if i.content.get("kind") == "agent_call"]
    assert all(card.status not in {"interrupted", "done", "failed"} for card in cards)


def test_F4_matrix_3_resume_as_the_first_window_row_is_running() -> None:
    # ③ No index-0 tie any more: the notice is dropped (its row is outside),
    # and the resume re-opens the task.
    raw = _F4_RAW_HEAD + (_F4_RAW_NOTICE_USER,) + _F4_RAW_TAIL
    card = _incremental_window_card(raw, window=(_window_send_message(),))
    assert card.status == "running"


def test_F4_matrix_4_a_notice_inside_the_window_still_closes() -> None:
    # ④ The notice's own row is in the window and nothing newer follows.
    raw = _F4_RAW_HEAD + (_F4_RAW_NOTICE_USER,)
    card = _incremental_window_card(raw, window=(_f4_notice_message(),))
    assert card.status == "interrupted"


def test_F4_matrix_5_a_resume_before_an_in_window_notice_is_closed() -> None:
    # ⑤ Both signals in one window, in transcript order: the notice is later,
    # so it is the latest signal and wins.
    raw = (
        _F4_RAW_HEAD
        + _F4_RAW_TAIL
        + (_raw_user_row("n1", _notice_text(TASK_ID, "stopped"),
                         "2026-10-08T09:41:00.000Z"),)
    )
    card = _incremental_window_card(
        raw, window=(_window_send_message(), _f4_notice_message())
    )
    assert card.status == "interrupted"


def test_F4_matrix_6_two_raw_notices_for_one_task_keep_the_newest() -> None:
    # ⑥ Both enqueue rows anchor to the same in-window row; the newest by
    # timestamp decides ("completed" here, at 10:13 vs 09:21).
    raw = _F4_RAW_HEAD + _F4_LATER_WINDOW_RAW[:1] + (
        _raw_enqueue_row(_notice_text(TASK_ID, "stopped"),
                         "2026-10-08T09:21:00.000Z"),
        _raw_enqueue_row(_notice_text(TASK_ID, "completed"),
                         "2026-10-08T10:13:00.000Z"),
    )
    card = _incremental_window_card(raw, window=(_f4_later_user_message(),))
    assert card.status == "done"


def test_F4_matrix_7_a_full_rebuild_closes_the_research_shape() -> None:
    # ⑦ The research cards' shape: one in-window notice, no later activity.
    raw = _F4_RAW_HEAD + (
        _raw_user_row("n1", _notice_text(TASK_ID, "completed"),
                      "2026-10-08T10:13:00.000Z"),
    )
    card = _incremental_window_card(
        raw,
        window=(
            _window_dispatch_message(),
            _window_receipt_message(),
            _f4_notice_message("completed"),
        ),
    )
    assert card.status == "done"


def _f4_lookup() -> Any:
    from connector.runtimes.claude.sessions.reader import _history_tool_call_context

    full_chain = (
        _window_dispatch_message(),
        _window_receipt_message(),
        _window_user_message(),
        _window_send_message(),
    )
    lookup, _ = _history_tool_call_context(_session(), full_chain)
    return lookup


def test_F4_variant_control_no_raw_lines_is_running() -> None:
    card = _incremental_window_card(())
    assert card.status == "running"


def test_F4_repeated_projection_is_idempotent() -> None:
    raw = _F4_RAW_HEAD + (_F4_RAW_NOTICE_USER,) + _F4_RAW_TAIL
    first = _incremental_window_card(raw)
    second = _incremental_window_card(raw)
    assert first.status == second.status == "running"
    assert dict(first.content) == dict(second.content)


# --------------------------------------------------------------------------
# F1/F6: the evidence sweep judges every open task, and only judged ones
# --------------------------------------------------------------------------


def _stale_file(now: float) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))


def _fresh_file(now: float) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int(now * 1000))


def _card_with_tasks(
    projector: ClaudeMessageProjector,
    statuses: dict[str, str],
) -> str:
    session = _session()
    projector.fold_agent_task_event(
        session,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(
            agents={task_id: {"status": status} for task_id, status in statuses.items()}
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    return stable_tool_item_id(session, DISPATCH_TUID)


def test_F1_a_running_entry_with_a_stale_file_is_closed() -> None:
    # The new coverage F1 asks for: a *started* task whose transcript went
    # silent is dead, and the evidence sweep closes it.
    projector = ClaudeMessageProjector()
    card_id = _card_with_tasks(projector, {TASK_ID: "running"})
    session = _session()
    now = 1_791_457_800.0
    items = projector.close_open_agent_cards(
        session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
    )
    assert [item.id for item in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["agents"][TASK_ID]["status"] == "interrupted"


def test_F1_a_running_entry_with_a_fresh_file_stays_open() -> None:
    projector = ClaudeMessageProjector()
    _card_with_tasks(projector, {TASK_ID: "running"})
    session = _session()
    now = 1_791_457_800.0
    assert (
        projector.close_open_agent_cards(
            session, oracle=_oracle(now=now, files={TASK_ID: _fresh_file(now)})
        )
        == ()
    )


def test_F6_partial_verdicts_leave_the_whole_card_open() -> None:
    # One stale task (a verdict) and one fresh sibling (none): the card must
    # stay open AND neither agents entry may be rewritten.
    projector = ClaudeMessageProjector()
    _card_with_tasks(projector, {TASK_ID: "running", SECOND_TASK_ID: "running"})
    session = _session()
    now = 1_791_457_800.0
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(
            now=now,
            files={TASK_ID: _stale_file(now), SECOND_TASK_ID: _fresh_file(now)},
        ),
    )
    assert items == ()


def test_F6_only_the_judged_task_entry_is_rewritten() -> None:
    # Two stale tasks: both are judged, so the card may close — and both
    # entries carry the closure status (no stale `running` left behind).
    projector = ClaudeMessageProjector()
    card_id = _card_with_tasks(
        projector, {TASK_ID: "running", SECOND_TASK_ID: "async_launched"}
    )
    session = _session()
    now = 1_791_457_800.0
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(
            now=now,
            files={TASK_ID: _stale_file(now), SECOND_TASK_ID: _stale_file(now)},
        ),
    )
    assert [item.id for item in items] == [card_id]
    agents = items[0].content["agents"]
    assert agents[TASK_ID]["status"] == "interrupted"
    assert agents[SECOND_TASK_ID]["status"] == "interrupted"


def test_F6_a_live_task_keeps_the_card_open() -> None:
    projector = ClaudeMessageProjector()
    _card_with_tasks(projector, {TASK_ID: "running", SECOND_TASK_ID: "running"})
    session = _session()
    now = 1_791_457_800.0
    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(
                now=now,
                files={TASK_ID: _stale_file(now), SECOND_TASK_ID: _stale_file(now)},
            ),
            live_task_ids=frozenset({SECOND_TASK_ID}),
        )
        == ()
    )


def test_F1_an_attached_task_is_not_killed_by_file_silence() -> None:
    projector = ClaudeMessageProjector()
    _card_with_tasks(projector, {TASK_ID: "running"})
    session = _session()
    now = 1_791_457_800.0
    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)}),
            attached_task_ids=frozenset({TASK_ID}),
        )
        == ()
    )


# --------------------------------------------------------------------------
# F5: the never-started grace reaches production (receipt ages)
# --------------------------------------------------------------------------


def test_F5_sweep_uses_the_cards_launch_stamp_for_never_started() -> None:
    # No explicit ages: the card's own launch stamp supplies the receipt age,
    # so a task with no subagent transcript at all is judged after T_start.
    now = 1_791_457_800.0
    projector = ClaudeMessageProjector(clock=lambda: now - (T_START + 30))
    _card_with_tasks(projector, {TASK_ID: "async_launched"})
    session = _session()
    expected_receipt_ms = int((now - (T_START + 30)) * 1000)
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now=now, files={}),
        now_ms=int(now * 1000),
    )
    assert len(items) == 1
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "neverStarted"
    # F2b: the end time is the receipt time, not "now".
    assert items[0].content["endTime"] == expected_receipt_ms


def test_F5_never_started_stays_open_inside_the_grace() -> None:
    now = 1_791_457_800.0
    projector = ClaudeMessageProjector(clock=lambda: now - (T_START - 30))
    _card_with_tasks(projector, {TASK_ID: "async_launched"})
    session = _session()
    assert (
        projector.close_open_agent_cards(
            session, oracle=_oracle(now=now, files={}), now_ms=int(now * 1000)
        )
        == ()
    )


def test_F5_history_receipt_age_comes_from_the_raw_transcript() -> None:
    # The SDK view carries no timestamps, so without the raw receipt the age
    # is unknown; the raw scan supplies it and the never-started closure fires.
    from connector.runtimes.claude.sessions.reader import _history_receipt_ages

    messages = (_dispatch_message(), _receipt_message())
    raw_lines = (
        json.dumps(
            {
                "type": "user",
                "uuid": "receipt-native",
                "timestamp": "2026-10-08T09:00:01.000Z",
                "message": {
                    "role": "user",
                    "content": [
                        {"type": "tool_result", "tool_use_id": DISPATCH_TUID,
                         "content": [{"type": "text",
                                      "text": f"Async agent launched successfully.\nagentId: {TASK_ID} (internal ID)"}]},
                    ],
                },
            }
        ),
    )
    receipt_ms = scan_raw_transcript(raw_lines).receipt_times_ms[TASK_ID]
    now_ms = float(receipt_ms + int((T_START + 60) * 1000))
    ages = _history_receipt_ages(
        messages, now_ms=now_ms, raw_receipt_times={TASK_ID: receipt_ms}
    )
    assert ages[TASK_ID] == T_START + 60
    oracle = _oracle(now=now_ms / 1000.0, files={})
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=ages[TASK_ID],
        now_ms=int(now_ms),
    )
    assert verdict is not None
    assert verdict.closed_by == "neverStarted"
    # F2b: the end time is the receipt time, not "now".
    assert verdict.end_time_ms == receipt_ms


# --------------------------------------------------------------------------
# F2: the history rebuild respects the live transport's task set
# --------------------------------------------------------------------------


def test_F2_live_task_keeps_a_history_card_open() -> None:
    messages = (_dispatch_message(), _receipt_message())
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _stale_file(now)})
    items = _history_items_from_messages(
        _session(), messages, oracle=oracle, live_task_ids=frozenset({TASK_ID})
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "running"
    assert "closedByEvidence" not in card.content


def test_F2_a_live_id_that_is_not_on_the_card_does_not_block() -> None:
    # The exemption is per named task: a live id the card does not carry must
    # not hold an unrelated card open.
    messages = (_dispatch_message(), _receipt_message(TASK_ID))
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _stale_file(now)})
    items = _history_items_from_messages(
        _session(), messages, oracle=oracle, live_task_ids=frozenset({SECOND_TASK_ID})
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "interrupted"


# --------------------------------------------------------------------------
# N3: a status-less card is still judged (both evidence paths)
# --------------------------------------------------------------------------


def test_N3_a_status_less_card_is_closed_by_the_sweep() -> None:
    # No entry claims a status, yet the card is not terminal: the sweep falls
    # back to judging every named task instead of stranding the card.
    projector = ClaudeMessageProjector()
    session = _session()
    projector.fold_agent_task_event(
        session,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(agents={TASK_ID: {}}),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    now = 1_791_457_800.0
    items = projector.close_open_agent_cards(
        session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
    )
    assert len(items) == 1
    assert items[0].status == "interrupted"


def test_N3_a_status_less_card_is_closed_by_the_history_pass() -> None:
    from connector.runtime_protocol import RuntimeTimelineItem, timeline_content_hash
    from connector.runtimes.claude.sessions.reader import _apply_oracle_closures

    content = {"kind": "agent_call", "agents": {TASK_ID: {}}}
    item = RuntimeTimelineItem(
        id="card",
        session_id=SESSION_ID,
        type="tool",
        status="running",
        order_seq=1,
        content=content,
        content_hash=timeline_content_hash(
            item_type="tool", status="running", role="tool", content=content
        ),
        role="tool",
    )
    now = 1_791_457_800.0
    items = _apply_oracle_closures(
        _session(),
        (item,),
        messages=(),
        raw_notices=(),
        oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)}),
    )
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "agentFileStale"


# --------------------------------------------------------------------------
# N5b: a missing subagents directory is "unknown", not "missing file"
# --------------------------------------------------------------------------


def test_N5b_a_missing_projects_tree_declines_to_judge(tmp_path: Any) -> None:
    from connector.runtimes.claude.sessions.subagent_oracle import probe_agent_file

    info = probe_agent_file(
        projects_dir=tmp_path / "nonexistent-projects",
        project_key="-home-ubuntu",
        external_session_id=EXTERNAL_SESSION_ID,
        task_id=TASK_ID,
    )
    assert info.exists is False
    assert info.path_known is False
    # And the oracle therefore never manufactures a closure from a path miss.
    oracle = ClaudeSubagentOracle(
        projects_dir=tmp_path / "nonexistent-projects", clock=_Clock(1_791_457_800.0)
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_START + 600,
        )
        is None
    )


def test_N5b_an_existing_tree_without_the_task_file_still_judges(tmp_path: Any) -> None:
    from connector.runtimes.claude.sessions.subagent_oracle import probe_agent_file

    base = tmp_path / "projects" / "-home-ubuntu" / EXTERNAL_SESSION_ID / "subagents"
    base.mkdir(parents=True)
    info = probe_agent_file(
        projects_dir=tmp_path / "projects",
        project_key="-home-ubuntu",
        external_session_id=EXTERNAL_SESSION_ID,
        task_id=TASK_ID,
    )
    assert info.exists is False
    assert info.path_known is True


# --------------------------------------------------------------------------
# N6: the runtime wires the live-task provider into reader + syncer
# --------------------------------------------------------------------------


def test_N6_the_runtime_wires_the_live_task_provider() -> None:
    from test_claude_compact_ghost import _runtime_with
    from test_claude_runtime import _RecordingHost

    runtime = _runtime_with(_RecordingHost(), lambda *args, **kwargs: None)
    runner = runtime._turns.runner
    assert runtime._session_reader.live_task_ids == runner.live_agent_task_ids
    assert runtime._history_syncer.live_task_ids == runner.live_agent_task_ids
    # A session with no live connection answers "nothing is live", which is the
    # conservative side the history rebuild relies on.
    assert runner.live_agent_task_ids(_session()) == frozenset()


def test_raw_notice_anchor_resolves_in_the_real_sdk_id_space() -> None:
    """Red-team P0 regression: an anchor must hit the SDK view on either id.

    Real SDK messages carry the Anthropic ``message.id`` nested under
    ``.message`` while the raw row's uuid lives on ``.uuid`` — different
    strings on assistant rows. A notice anchored on an assistant row must
    still resolve (keying ``message_id`` alone placed 0 of 41 real notices).
    """

    from connector.runtimes.claude.sessions.reader import _raw_history_notices
    from connector.runtimes.claude.sessions.subagent_oracle import scan_raw_transcript

    raw = (
        json.dumps(
            {
                "type": "assistant",
                "uuid": "row-uuid-1",
                "timestamp": "2026-10-08T09:30:00.000Z",
                "message": {"id": "chatcmpl-abc", "role": "assistant", "content": []},
            }
        ),
        json.dumps(
            {
                "type": "queue-operation",
                "operation": "enqueue",
                "timestamp": "2026-10-08T09:30:05.000Z",
                "content": (
                    "<task-notification>\n<task-id>atask1</task-id>\n"
                    "<status>completed</status>\n</task-notification>"
                ),
            }
        ),
    )
    scan = scan_raw_transcript(raw)
    messages = (
        SimpleNamespace(
            type="assistant",
            uuid="row-uuid-1",
            message={"id": "chatcmpl-abc", "role": "assistant", "content": []},
        ),
    )
    placed = _raw_history_notices(messages, scan)
    assert len(placed) == 1, "anchor on the raw row uuid failed to resolve"
    assert placed[0][0] == 0
    assert placed[0][1].task_id == "atask1"


def test_probe_distinguishes_missing_session_dir_from_missing_subagents(tmp_path: Any) -> None:
    """N5b refinement: only a wrong/unknown session declines to judge."""

    from connector.runtimes.claude.sessions.subagent_oracle import probe_agent_file

    # Session directory exists, no subagents tree yet (lazy creation): a
    # missing file is genuine never-started evidence.
    (tmp_path / "proj" / "sess").mkdir(parents=True)
    info = probe_agent_file(
        projects_dir=tmp_path, project_key="proj", external_session_id="sess", task_id="a1"
    )
    assert info.exists is False and info.path_known is True

    # Neither exists: a wrong project key or unknown session must decline.
    info2 = probe_agent_file(
        projects_dir=tmp_path, project_key="missing", external_session_id="sess", task_id="a1"
    )
    assert info2.exists is False and info2.path_known is False


# --------------------------------------------------------------------------
# T2: the hard age ceiling (stale-residue-selfheal, 2026-10-09)
# --------------------------------------------------------------------------
#
# The corner the ceiling exists for: a card whose transcript file still looks
# fresh — an mtime a restore or copy re-stamped, a writer gone without ever
# emitting a terminal event — long after its last launch/survival evidence.
# The file cannot judge it and no notice ever will; the clock alone cannot
# lie. The live/attached exemption stays hard in the same breath: a task the
# transport still vouches for is never closed by a clock, and the older
# closures (a notice, file silence, a never-started launch) keep their own
# labels and end times.


def test_T2_the_default_age_ceiling_is_24h() -> None:
    assert SUBAGENT_AGE_BOUND_SECONDS == T_AGE_BOUND


def test_T2_a_fresh_file_past_the_ceiling_closes_as_age_bounded() -> None:
    now = 1_791_457_800.0
    receipt_age = T_AGE_BOUND + 1
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=receipt_age,
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "ageBounded"
    assert verdict.agent_status == "interrupted"
    # The end time is the newest survival evidence (the receipt), not the
    # distrusted mtime and not "now" (the never-started rule's own anchor).
    assert verdict.end_time_ms == int((now - receipt_age) * 1000)


def test_T2_a_fresh_file_inside_the_ceiling_stays_open() -> None:
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND - 1,
        )
        is None
    )


def test_T2_the_ceiling_is_exclusive() -> None:
    # The rule is "older than the ceiling", strictly: exactly at the bound is
    # still inside it.
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND,
        )
        is None
    )


def test_T2_attached_is_never_closed_by_the_ceiling() -> None:
    # The hard exemption: a live turn is driving the process — no clock
    # judgement may close the task, however old its evidence looks.
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND * 10,
            attached_live=True,
        )
        is None
    )


def test_T2_no_receipt_age_cannot_be_judged() -> None:
    # No anchor, no judgement: the ceiling never fires on a guessed age.
    now = 1_791_457_800.0
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
        )
        is None
    )


def test_T2_a_terminal_notice_still_wins_past_the_ceiling() -> None:
    # Terminal states are untouched: the notice branch returns first, with
    # the notice's own status and provenance.
    notice_ms = 1_791_446_535_015
    oracle = _oracle(
        now=notice_ms / 1000.0 + 3600,
        files={TASK_ID: AgentFileInfo(exists=True, mtime_ms=notice_ms)},
        age_bound=T_AGE_BOUND,
    )
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        terminal_events=((notice_ms, _notice_event("completed", end_ms=notice_ms)),),
        receipt_age_seconds=T_AGE_BOUND * 10,
    )
    assert verdict is not None
    assert verdict.closure_status == "done"
    assert verdict.closed_by == "terminalNotice"


def test_T2_the_stale_file_closure_keeps_precedence() -> None:
    # File silence is the more precise evidence and keeps its own label and
    # end time; the ceiling only owns the fresh-file corner.
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _stale_file(now)}, age_bound=T_AGE_BOUND)
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=T_AGE_BOUND * 10,
    )
    assert verdict is not None
    assert verdict.closed_by == "agentFileStale"
    assert verdict.end_time_ms == int((now - T_STALE - 1) * 1000)


def test_T2_the_never_started_closure_keeps_precedence() -> None:
    now = 1_791_457_800.0
    receipt_age = T_AGE_BOUND * 10
    oracle = _oracle(now=now, files={}, age_bound=T_AGE_BOUND)
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=receipt_age,
    )
    assert verdict is not None
    assert verdict.closed_by == "neverStarted"
    assert verdict.end_time_ms == int((now - receipt_age) * 1000)


def test_T2_env_zero_disables_the_ceiling(monkeypatch: Any) -> None:
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "0")
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
    assert oracle.age_bound_seconds == 0.0
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND * 10,
        )
        is None
    )


def test_T2_env_negative_disables_the_ceiling(monkeypatch: Any) -> None:
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "-5")
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
    assert oracle.age_bound_seconds == 0.0
    assert (
        oracle.evidence(
            task_id=TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND * 10,
        )
        is None
    )


def test_T2_env_overrides_the_ceiling(monkeypatch: Any) -> None:
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "3600")
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
    assert oracle.age_bound_seconds == 3600.0
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=3601.0,
    )
    assert verdict is not None
    assert verdict.closed_by == "ageBounded"


def test_T2_env_unset_keeps_the_default(monkeypatch: Any) -> None:
    monkeypatch.delenv(SUBAGENT_AGE_BOUND_ENV, raising=False)
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
    assert oracle.age_bound_seconds == T_AGE_BOUND


def test_T2_env_garbage_refuses_rather_than_defaulting(monkeypatch: Any) -> None:
    """R1 P2-4: an unusable value must not silently become the default.

    The old reading ("unparsable keeps the default") looks harmless and is
    the wrong direction for this knob: the operator's intent is discarded
    either way, but "default" reads as a working ceiling in the logs while an
    off-by-a-decade typo must not quietly arm a reaper. Unusable now means
    unusable — the judgement is off, and the warning says which value was
    refused.
    """

    for raw in ("not-a-number", "", "   ", "nan", "inf", "-inf", "24 hours"):
        monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, raw)
        now = 1_791_457_800.0
        oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
        assert oracle.age_bound_seconds == 0.0, raw
        # Off means off: nothing is closed, however old it claims to be.
        assert (
            oracle.evidence(
                task_id=TASK_ID,
                external_session_id=EXTERNAL_SESSION_ID,
                cwd=CWD,
                receipt_age_seconds=T_AGE_BOUND * 10,
            )
            is None
        ), raw


def test_T2_env_below_the_floor_is_refused(monkeypatch: Any) -> None:
    """The reaper case. `0.5` means half a second, which is below the
    dispatch-to-receipt gap of every task in the library: a ceiling that small
    closes live work in a sweep. It is refused (judgement off), not clamped up
    to the default — clamping would hide the typo behind a number the operator
    never wrote."""

    for raw in ("0.5", "30", "59"):
        monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, raw)
        now = 1_791_457_800.0
        oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
        assert oracle.age_bound_seconds == 0.0, raw
        assert (
            oracle.evidence(
                task_id=TASK_ID,
                external_session_id=EXTERNAL_SESSION_ID,
                cwd=CWD,
                receipt_age_seconds=T_AGE_BOUND * 10,
            )
            is None
        ), raw


def test_T2_env_at_or_above_the_floor_is_honoured(monkeypatch: Any) -> None:
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "60")
    now = 1_791_457_800.0
    oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
    assert oracle.age_bound_seconds == 60.0
    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=61.0,
    )
    assert verdict is not None
    assert verdict.closed_by == "ageBounded"


def test_T2_env_duration_suffixes_are_accepted(monkeypatch: Any) -> None:
    """`24h` is the natural spelling of a day, and after the fail-safe change
    an unparsable value means OFF rather than the default — so the suffix has
    to parse, or the fix would turn a harmless typo into a dead safety net."""

    for raw, seconds in (
        ("24h", 86400.0),
        ("30m", 1800.0),
        ("90s", 90.0),
        ("1.5h", 5400.0),
        ("2d", 172800.0),
        (" 12H ", 43200.0),
    ):
        monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, raw)
        now = 1_791_457_800.0
        oracle = _oracle(now=now, files={TASK_ID: _fresh_file(now)})
        assert oracle.age_bound_seconds == seconds, raw


def test_T2_sweep_closes_a_fresh_file_card_past_the_ceiling() -> None:
    # The periodic sweep inherits the rule through the shared oracle — no
    # sweep-side change needed.
    projector = ClaudeMessageProjector()
    # The fixture's session id and cwd are the real incident's, so the
    # default raw-scan provider finds this machine's own transcript and its
    # participation would re-anchor the age; neutralize the seam so the
    # caller's receipt age is the only survival evidence (the same idiom as
    # test_terminal_time_order's projector fixture).
    projector._raw_scan_provider = lambda _s: None
    card_id = _async_card(projector)
    session = _session()
    now = 1_791_457_800.0
    receipt_age = T_AGE_BOUND + 60
    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(
            now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
        ),
        receipt_ages={TASK_ID: receipt_age},
        now_ms=int(now * 1000),
    )
    assert [item.id for item in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "ageBounded"
    assert items[0].content["agents"][TASK_ID]["status"] == "interrupted"
    assert items[0].content["endTime"] == int((now - receipt_age) * 1000)


def test_T2_sweep_a_live_task_is_never_closed_by_the_ceiling() -> None:
    projector = ClaudeMessageProjector()
    projector._raw_scan_provider = lambda _s: None
    _async_card(projector)
    session = _session()
    now = 1_791_457_800.0
    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(
                now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
            ),
            receipt_ages={TASK_ID: T_AGE_BOUND * 10},
            live_task_ids=frozenset({TASK_ID}),
            now_ms=int(now * 1000),
        )
        == ()
    )


def _iso_ms(value: int) -> str:
    return (
        datetime.fromtimestamp(value / 1000, tz=UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _old_receipt_raw_lines(receipt_ms: int) -> tuple[str, ...]:
    """One raw receipt row whose timestamp is the task's launch evidence."""

    return (
        json.dumps(
            {
                "type": "user",
                "uuid": "receipt-native",
                "timestamp": _iso_ms(receipt_ms),
                "message": {
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
                                        f"agentId: {TASK_ID} (internal ID)"
                                    ),
                                }
                            ],
                        }
                    ],
                },
            }
        ),
    )


def test_T2_history_closes_a_fresh_file_card_past_the_ceiling() -> None:
    # The history rebuild inherits the rule too: the raw receipt row dates
    # the launch, the file still looks fresh, and the rebuild publishes the
    # age-bounded closure.
    messages = (_dispatch_message(), _receipt_message())
    now = 1_791_457_800.0
    receipt_ms = int((now - (T_AGE_BOUND + 60)) * 1000)
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=_old_receipt_raw_lines(receipt_ms),
        oracle=oracle,
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"
    assert card.content["agents"][TASK_ID]["status"] == "interrupted"
    assert card.content["endTime"] == receipt_ms


def test_T2_history_a_live_task_is_never_closed_by_the_ceiling() -> None:
    messages = (_dispatch_message(), _receipt_message())
    now = 1_791_457_800.0
    receipt_ms = int((now - (T_AGE_BOUND + 60)) * 1000)
    oracle = _oracle(
        now=now, files={TASK_ID: _fresh_file(now)}, age_bound=T_AGE_BOUND
    )
    items = _history_items_from_messages(
        _session(),
        messages,
        raw_lines=_old_receipt_raw_lines(receipt_ms),
        oracle=oracle,
        live_task_ids=frozenset({TASK_ID}),
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "running"
    assert "closedByEvidence" not in card.content
