"""Evidence-sweep truth coverage (G3) — connector half, 2026-10-09.

Why this file exists
--------------------
`.local-dev/subagent-alias-durability-tasks.md` T2. The R1/R2 evidence sweep
was built for the in-process case: it walked only the projector's
``_agent_cards`` and never read the engine's terminal notices (red team F7).
A connector restart exposed both holes at once (session
``sess_Nk19-gOK4L5Eaw``): the stranded cards lived in the restored timeline
and nowhere else, and the completions that could have closed them sat in the
raw transcript the sweep never opened.

What is pinned
--------------
* D1 — the traversal set is ``_agent_cards`` ∪ the session's non-terminal
  published agent_call items, deduped by id with the stronger status winning;
  the stop path keeps its original in-memory traversal;
* D2 — the sweep call site groups the raw scan's notices by task id
  (``RawTranscriptNotice.event`` + ``timestamp_ms``) and derives receipt ages
  from ``receipt_times_ms`` (same clamp as the history path), pinned to one
  "now";
* D3 — a task the transport vouches for is *attached* rather than skipped:
  file silence alone never closes it, a terminal notice still does
  (``attached`` semantics unchanged), F6 (every open task judged) holds.

Fixtures are synthetic: a fake clock, a dict-backed file probe, and a literal
transcript file under a relocated ``CLAUDE_CONFIG_DIR``. No real session's
content is read.
"""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from typing import Any

import pytest

from connector.runtime_protocol import (
    AgentCallToolContent,
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeTimelineItem,
    timeline_content_hash,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
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
from connector.runtimes.claude.turns.lifecycle import (
    _raw_transcript_scan,
    _receipt_ages_by_task,
    _terminal_events_by_task,
)

EXTERNAL_SESSION_ID = "e89abce5-f48c-463b-8d16-d3f78dd504c4"
SESSION_ID = "sess_alias_durability_t2"
CWD = "/home/ubuntu"
DISPATCH_TUID = "call_00_T2Dispatch000000000000"
TASK_ID = "a6805987502c5966c"
SECOND_TASK_ID = "a9c3fa4ea2000a79d"
PROJECTS_DIR = "/tmp/fake-claude-projects"

# The task sheet's defaults, restated so a drift in the module constants fails
# loudly here and the tests use the same numbers producers do.
T_START = 120.0
T_STALE = 900.0


# --------------------------------------------------------------------------
# Fixtures: fake clock, dict-backed file probe, synthetic card shapes
# --------------------------------------------------------------------------


class _Clock:
    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __call__(self) -> float:
        return self.seconds


def _file_table(*entries: tuple[str, AgentFileInfo]) -> Any:
    table = dict(entries)

    def probe(*, projects_dir, project_key, external_session_id, task_id):
        _ = projects_dir, project_key, external_session_id
        return table.get(task_id, AgentFileInfo(exists=False, path_known=True))

    return probe


def _oracle(
    *,
    now: float,
    files: dict[str, AgentFileInfo],
    stale: float = T_STALE,
) -> ClaudeSubagentOracle:
    from pathlib import Path

    return ClaudeSubagentOracle(
        projects_dir=Path(PROJECTS_DIR),
        clock=_Clock(now),
        file_probe=_file_table(*files.items()),
        start_grace_seconds=T_START,
        stale_seconds=stale,
    )


def _stale_file(now: float) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))


def _fresh_file(now: float) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int(now * 1000))


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Alias durability T2",
        cwd=CWD,
    )


def _notice_event(
    status: str,
    *,
    task_id: str = TASK_ID,
    end_ms: int | None = None,
) -> ClaudeTaskEvent:
    return ClaudeTaskEvent(
        kind="notification",
        task_id=task_id,
        status=status,
        end_time=end_ms,
    )


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


def _published_card(
    *,
    item_id: str = "claude_tool_t2published00000000000",
    status: str = "running",
    agents: dict[str, dict[str, Any]] | None = None,
    kind: str = "agent_call",
    tool_use_id: str = DISPATCH_TUID,
    order_seq: int = 7,
) -> RuntimeTimelineItem:
    """One published agent_call item, the shape a restored timeline holds."""

    content: dict[str, Any] = {
        "kind": kind,
        "title": "research",
        "agents": {k: dict(v) for k, v in (agents or {}).items()},
    }
    return RuntimeTimelineItem(
        id=item_id,
        session_id=SESSION_ID,
        type="tool",
        status=status,
        order_seq=order_seq,
        content_hash=timeline_content_hash(
            item_type="tool", status=status, role="tool", content=content
        ),
        role="tool",
        turn_id="turn_t2",
        content=content,
        source={
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemId": tool_use_id,
            "itemType": "tool_use",
            "event": "claude.agent.task",
        },
    )


# --------------------------------------------------------------------------
# D1: the traversal set reaches the published cards
# --------------------------------------------------------------------------


def test_D1_a_published_card_is_judged_by_evidence_and_closes() -> None:
    # The restart shape: the card lives only in the restored timeline, and a
    # stale subagent transcript proves the task died under the old process.
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "running"}})
    session.timeline_items[item.id] = item
    now = 1_791_457_800.0

    items = projector.close_open_agent_cards(
        session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
    )

    assert [closed.id for closed in items] == [item.id]
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "agentFileStale"
    assert items[0].content["agents"][TASK_ID]["status"] == "interrupted"
    # The published item's own identity rides through untouched.
    assert items[0].order_seq == item.order_seq
    assert items[0].turn_id == item.turn_id
    assert items[0].source["itemId"] == DISPATCH_TUID
    assert items[0].content_hash != item.content_hash
    # Convergent: an unrecorded re-run produces the same verdict, never drift
    # (the caller records the closure, which is what retires the candidate).
    again = projector.close_open_agent_cards(
        session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
    )
    assert again == items


def test_D1_a_published_card_with_a_fresh_file_stays_open() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "running"}})
    session.timeline_items[item.id] = item
    now = 1_791_457_800.0

    assert (
        projector.close_open_agent_cards(
            session, oracle=_oracle(now=now, files={TASK_ID: _fresh_file(now)})
        )
        == ()
    )


def test_D1_published_items_have_no_launch_stamp_so_files_are_the_only_decider() -> None:
    # A published-only candidate cannot date a never-started launch by itself:
    # no receipt age, no launch stamp — the oracle declines and the card stays
    # open (defensive: evidence is never guessed).
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "async_launched"}})
    session.timeline_items[item.id] = item
    now = 1_791_457_800.0

    assert (
        projector.close_open_agent_cards(session, oracle=_oracle(now=now, files={}))
        == ()
    )


def test_D1_dedup_a_terminal_published_item_wins_over_an_open_card() -> None:
    # Same id on both surfaces, closed on one: the stronger status is not
    # open, and the sweep neither re-judges nor republishes it.
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _card_with_tasks(projector, {TASK_ID: "running"})
    session.timeline_items[card_id] = _published_card(
        item_id=card_id, status="done", agents={TASK_ID: {"status": "completed"}}
    )
    now = 1_791_457_800.0

    assert (
        projector.close_open_agent_cards(
            session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
        )
        == ()
    )


def test_D1_dedup_both_surfaces_open_judge_the_card_once() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _card_with_tasks(projector, {TASK_ID: "running"})
    session.timeline_items[card_id] = _published_card(
        item_id=card_id, status="running", agents={TASK_ID: {"status": "running"}}
    )
    now = 1_791_457_800.0

    items = projector.close_open_agent_cards(
        session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
    )

    assert [closed.id for closed in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "agentFileStale"


def test_D1_published_only_cards_are_invisible_to_the_stop_path() -> None:
    # D3: stop path (oracle=None) untouched — its traversal set stays the
    # process's own cards, and a restored timeline item is not one.
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "async_launched"}})
    session.timeline_items[item.id] = item

    assert projector.close_open_agent_cards(session) == ()


def test_D1_items_of_other_kinds_are_not_candidates() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(
        agents={TASK_ID: {"status": "running"}}, kind="command"
    )
    session.timeline_items[item.id] = item
    now = 1_791_457_800.0

    assert (
        projector.close_open_agent_cards(
            session, oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)})
        )
        == ()
    )


def test_D2_receipt_ages_close_a_published_never_started_card() -> None:
    # D2 at the projector seam: the caller supplies the receipt age (there is
    # no launch stamp on a published item), and the never-started grace turns
    # it into a closure with the receipt time as the end time (F2b).
    projector = ClaudeMessageProjector()
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "async_launched"}})
    session.timeline_items[item.id] = item
    now = 1_791_457_800.0
    receipt_age = T_START + 30

    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now=now, files={}),
        receipt_ages={TASK_ID: receipt_age},
        now_ms=int(now * 1000),
    )

    assert [closed.id for closed in items] == [item.id]
    assert items[0].status == "interrupted"
    assert items[0].content["closedByEvidence"] == "neverStarted"
    assert items[0].content["endTime"] == int((now - receipt_age) * 1000)


# --------------------------------------------------------------------------
# D3: vouch semantics — attached exempts file silence, never a notice
# --------------------------------------------------------------------------


def test_D3_a_live_task_with_a_terminal_notice_closes_with_the_notice_status() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _card_with_tasks(projector, {TASK_ID: "running"})
    now = 1_791_457_800.0
    notice_ms = int(now * 1000) - 1000

    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)}),
        live_task_ids=frozenset({TASK_ID}),
        terminal_events={TASK_ID: ((notice_ms, _notice_event("completed")),)},
    )

    assert [closed.id for closed in items] == [card_id]
    assert items[0].status == "done"
    assert items[0].content["closedByEvidence"] == "terminalNotice"
    assert items[0].content["agents"][TASK_ID]["status"] == "completed"
    assert items[0].content["endTime"] == notice_ms


def test_D3_a_live_task_without_a_notice_is_never_closed_by_file_silence() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    _card_with_tasks(projector, {TASK_ID: "running"})
    now = 1_791_457_800.0

    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(now=now, files={TASK_ID: _stale_file(now)}),
            live_task_ids=frozenset({TASK_ID}),
        )
        == ()
    )


def test_D3_a_live_task_with_a_notice_but_an_active_file_stays_open() -> None:
    # The notice only stands while the subagent file wrote nothing after it —
    # a resumed task that is writing again is running, vouch or no vouch.
    projector = ClaudeMessageProjector()
    session = _session()
    _card_with_tasks(projector, {TASK_ID: "running"})
    now = 1_791_457_800.0
    stale_notice_ms = int(now * 1000) - 600_000

    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(now=now, files={TASK_ID: _fresh_file(now)}),
            live_task_ids=frozenset({TASK_ID}),
            terminal_events={TASK_ID: ((stale_notice_ms, _notice_event("completed")),)},
        )
        == ()
    )


def test_D3_F6_a_live_sibling_without_a_notice_keeps_the_whole_card_open() -> None:
    # F6 still holds under the new vouch semantics: one dead task alone may
    # not hide a live sibling that no notice has adjudicated.
    projector = ClaudeMessageProjector()
    session = _session()
    _card_with_tasks(projector, {TASK_ID: "running", SECOND_TASK_ID: "running"})
    now = 1_791_457_800.0
    notice_ms = int(now * 1000) - 1000

    assert (
        projector.close_open_agent_cards(
            session,
            oracle=_oracle(
                now=now,
                files={TASK_ID: _stale_file(now), SECOND_TASK_ID: _stale_file(now)},
            ),
            live_task_ids=frozenset({SECOND_TASK_ID}),
            terminal_events={TASK_ID: ((notice_ms, _notice_event("stopped")),)},
        )
        == ()
    )


def test_D3_F6_every_task_adjudicated_then_the_card_closes() -> None:
    # Both tasks adjudicated — one by file staleness, one (live) by its own
    # notice — so the card may close; the strongest verdict wins the card
    # status while each task keeps its own.
    projector = ClaudeMessageProjector()
    session = _session()
    card_id = _card_with_tasks(
        projector, {TASK_ID: "running", SECOND_TASK_ID: "running"}
    )
    now = 1_791_457_800.0
    notice_ms = int(now * 1000) - 1000

    items = projector.close_open_agent_cards(
        session,
        oracle=_oracle(
            now=now,
            files={TASK_ID: _stale_file(now), SECOND_TASK_ID: _stale_file(now)},
        ),
        live_task_ids=frozenset({SECOND_TASK_ID}),
        terminal_events={
            SECOND_TASK_ID: ((notice_ms, _notice_event("completed", task_id=SECOND_TASK_ID)),)
        },
    )

    assert [closed.id for closed in items] == [card_id]
    assert items[0].status == "interrupted"
    assert items[0].content["agents"][TASK_ID]["status"] == "interrupted"
    assert items[0].content["agents"][SECOND_TASK_ID]["status"] == "completed"


# --------------------------------------------------------------------------
# D2 at the sweep call site: raw scan grouping helpers and the scan seam
# --------------------------------------------------------------------------


def _raw_enqueue_row(text: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": timestamp,
            "content": text,
        }
    )


def _raw_receipt_row(task_id: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": "receipt-row",
            "timestamp": timestamp,
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
                                    f"agentId: {task_id} (internal ID)"
                                ),
                            }
                        ],
                    }
                ],
            },
        }
    )


def _notice_text(task_id: str, status: str) -> str:
    return (
        "<task-notification>\n"
        f"<task-id>{task_id}</task-id>\n"
        f"<status>{status}</status>\n"
        "<summary>Agent \"research\" finished</summary>\n"
        "</task-notification>"
    )


def _iso(epoch_seconds: float) -> str:
    return (
        datetime.fromtimestamp(epoch_seconds, tz=UTC)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _transcript_path(root: Any) -> Any:
    return root / "projects" / "-home-ubuntu" / f"{EXTERNAL_SESSION_ID}.jsonl"


def _write_transcript(root: Any, lines: tuple[str, ...]) -> None:
    path = _transcript_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_D2_helpers_group_notices_by_task_and_clamp_receipt_ages() -> None:
    receipt_ms = 1_791_457_000_000
    scan = scan_raw_transcript(
        (
            _raw_enqueue_row(_notice_text(TASK_ID, "completed"), _iso(receipt_ms / 1000)),
            _raw_receipt_row(TASK_ID, _iso(receipt_ms / 1000)),
            _raw_receipt_row(SECOND_TASK_ID, _iso(receipt_ms / 1000 + 5)),
        )
    )

    events = _terminal_events_by_task(scan)
    assert set(events) == {TASK_ID}
    assert events[TASK_ID][0][0] == receipt_ms
    assert events[TASK_ID][0][1].status == "completed"

    ages = _receipt_ages_by_task(scan, now_ms=receipt_ms + 60_000)
    assert ages[TASK_ID] == pytest.approx(60.0)
    # A receipt stamped after "now" clamps to zero, never negative.
    assert _receipt_ages_by_task(scan, now_ms=receipt_ms - 60_000)[TASK_ID] == 0.0

    assert _terminal_events_by_task(None) == {}
    assert _receipt_ages_by_task(None, now_ms=0) == {}


def test_D2_scan_seam_returns_none_without_a_transcript(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    assert _raw_transcript_scan(_session()) is None
    assert (
        _raw_transcript_scan(
            ClaudeSession(session_id="s", external_session_id=None, cwd=None)
        )
        is None
    )


# --------------------------------------------------------------------------
# The full sweep call site: a runner pass closes a restored card from the
# raw transcript's own notice, and republishing is a no-op
# --------------------------------------------------------------------------


class _RecordingHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)


def _runtime(host: RuntimeHostClient, oracle: ClaudeSubagentOracle) -> ClaudeRuntime:
    return ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=host,
        subagent_oracle=oracle,
    )


def test_D2_the_sweep_runner_closes_a_restored_card_from_the_raw_notice(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    notice_ms = 1_791_457_795_000
    _write_transcript(
        tmp_path,
        (_raw_enqueue_row(_notice_text(TASK_ID, "completed"), _iso(notice_ms / 1000)),),
    )
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "running"}})
    session.timeline_items[item.id] = item
    host = _RecordingHost()
    runtime = _runtime(host=host, oracle=_oracle(now=1_791_457_800.0, files={}))
    runtime._sessions[session.session_id] = session
    runner = runtime._turns.runner

    published = asyncio.run(runner.sweep_agent_cards_by_evidence(session))

    assert published == 1
    upsert = host.timeline_item_upserts[0]
    assert upsert.id == item.id
    assert upsert.status == "done"
    assert upsert.content["closedByEvidence"] == "terminalNotice"
    assert upsert.content["agents"][TASK_ID]["status"] == "completed"
    assert upsert.content["endTime"] == notice_ms
    # The closed item is recorded on the session, so the next pass sees a
    # terminal card and publishes nothing (idempotent).
    assert session.timeline_items[item.id].status == "done"
    assert asyncio.run(runner.sweep_agent_cards_by_evidence(session)) == 0
    assert len(host.timeline_item_upserts) == 1


def test_D2_the_sweep_runner_dates_a_never_started_task_from_the_raw_receipt(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    now = 1_791_457_800.0
    receipt_ms = int((now - (T_START + 30)) * 1000)
    _write_transcript(
        tmp_path, (_raw_receipt_row(TASK_ID, _iso(receipt_ms / 1000)),)
    )
    session = _session()
    item = _published_card(agents={TASK_ID: {"status": "async_launched"}})
    session.timeline_items[item.id] = item
    host = _RecordingHost()
    runtime = _runtime(host=host, oracle=_oracle(now=now, files={}))
    runtime._sessions[session.session_id] = session
    runner = runtime._turns.runner

    published = asyncio.run(runner.sweep_agent_cards_by_evidence(session))

    assert published == 1
    upsert = host.timeline_item_upserts[0]
    assert upsert.status == "interrupted"
    assert upsert.content["closedByEvidence"] == "neverStarted"
    assert upsert.content["endTime"] == receipt_ms
