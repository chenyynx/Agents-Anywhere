"""Agent cards stranded by a compaction reach their evidence (2026-10-21).

Why this file exists
--------------------
A reviewer card in ``sess_FsxRdfmQ4nNHlQ`` stayed ``running`` for twelve hours
after the connector restarted under it. The CLI re-delivered a
``<status>stopped</status>`` notice, but the history fold resolves a notice's
task id through the dispatch rows the SDK message view still returns, and a
``/compact`` had restarted that view at a summary: the dispatch lived only in
the raw transcript. The notice resolved against no root and was dropped.

What is pinned
--------------
* the raw scan retains verified dispatch rows and their receipts
  (``RawTranscriptScan.dispatch_records``);
* a fold whose window only holds the terminal notice rebuilds the task -> card
  join from those rows and closes the card;
* the closure keeps the card's evidence — dispatch prompt, launch receipt, and
  the summary/usage an earlier completion notice carried — instead of
  publishing a thin row (the live fold accumulates those; a rebuild must reach
  the same content shape);
* a transcript without the dispatch row changes nothing (fail-closed).

Fixtures are synthetic: this file's rows are written from the production
shapes measured on 2026-10-21, with no real session content.
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Mapping

from connector.runtime_protocol import RuntimeConfig, RuntimeTimelineItem
from connector.runtime_protocol.host import RuntimeHostClient
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sessions.open_cards import KEY, ClaudeOpenAgentCards
from connector.runtimes.claude.sessions.reader import (
    _history_items_from_messages,
    scan_agent_call_cards,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
    ClaudeSubagentOracle,
    scan_raw_transcript,
    subagent_token_usage,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)
from connector.runtimes.claude.turns.lifecycle import (
    _receipt_ages_by_task,
    _terminal_events_by_task,
)

EXTERNAL_SESSION_ID = "claude_evidence_reach"
SESSION_ID = "sess_evidence_reach"
CWD = "/repo"

DISPATCH_TUID = "call_02_4wfRk7k4lNCCmuXjWDdP3222"
TASK_ID = "a65c7ea68d9bee0de"
PROMPT = "REVIEW-PROMPT"
RESULT = "FINAL-REPORT"

DISPATCH_TS = "2026-10-20T17:16:40.526Z"
RECEIPT_TS = "2026-10-20T17:16:41.000Z"
COMPLETED_TS = "2026-10-20T17:33:11.398Z"
STOPPED_TS = "2026-10-20T18:05:44.118Z"


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Evidence reach",
        cwd=CWD,
    )


def _line(payload: Mapping[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def _dispatch_line() -> str:
    return _line(
        {
            "type": "assistant",
            "uuid": "dispatch-row",
            "isSidechain": False,
            "timestamp": DISPATCH_TS,
            "message": {
                "id": "msg_dispatch",
                "type": "message",
                "role": "assistant",
                "model": "claude-x",
                "content": [
                    {
                        "type": "tool_use",
                        "id": DISPATCH_TUID,
                        "name": "Agent",
                        "input": {
                            "description": "审查流式渲染正确性",
                            "prompt": PROMPT,
                            "subagent_type": "reviewer",
                            "run_in_background": True,
                        },
                    }
                ],
            },
        }
    )


def _receipt_line() -> str:
    return _line(
        {
            "type": "user",
            "uuid": "receipt-row",
            "isSidechain": False,
            "timestamp": RECEIPT_TS,
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
                                    "Async agent launched successfully. "
                                    f"agentId: {TASK_ID} (internal ID)"
                                ),
                            }
                        ],
                    }
                ],
            },
            "toolUseResult": {"status": "async_launched", "agentId": TASK_ID},
        }
    )


def _completed_line() -> str:
    return _line(
        {
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": COMPLETED_TS,
            "sessionId": EXTERNAL_SESSION_ID,
            "content": (
                "<task-notification>\n"
                f"<task-id>{TASK_ID}</task-id>\n"
                f"<tool-use-id>{DISPATCH_TUID}</tool-use-id>\n"
                "<status>completed</status>\n"
                '<summary>Agent "审查流式渲染正确性" finished</summary>\n'
                f"<result>{RESULT}</result>\n"
                "<usage><subagent_tokens>282378</subagent_tokens>"
                "<tool_uses>88</tool_uses><duration_ms>990967</duration_ms></usage>\n"
                "</task-notification>"
            ),
        }
    )


def _stopped_text() -> str:
    return (
        "<task-notification>\n"
        f"<task-id>{TASK_ID}</task-id>\n"
        "<status>stopped</status>\n"
        "<summary>Background agent \"审查流式渲染正确性\" didn't finish before "
        "the previous session ended</summary>\n"
        "</task-notification>"
    )


def _stopped_line() -> str:
    return _line(
        {
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": STOPPED_TS,
            "sessionId": EXTERNAL_SESSION_ID,
            "content": _stopped_text(),
        }
    )


def _stop_message() -> Any:
    """The only row the compacted window still returns: the stopped notice."""

    return SimpleNamespace(
        type="user",
        uuid="stop-native",
        timestamp=STOPPED_TS,
        message={"role": "user", "content": _stopped_text()},
    )


def _card_items(items: tuple[Any, ...]) -> list[Any]:
    card_id = stable_tool_item_id(_session(), DISPATCH_TUID)
    return [item for item in items if item.id == card_id]


# --------------------------------------------------------------------------
# 1. The scan retains exactly the rows a dispatch rebuild needs
# --------------------------------------------------------------------------


def test_scan_retains_the_verified_dispatch_row_and_its_receipt() -> None:
    scan = scan_raw_transcript((_dispatch_line(), _receipt_line(), _completed_line()))

    assert set(scan.dispatch_records) == {DISPATCH_TUID}
    dispatch_row, result_row = scan.dispatch_records[DISPATCH_TUID]
    assert dispatch_row["uuid"] == "dispatch-row"
    assert result_row is not None
    assert result_row["uuid"] == "receipt-row"


def test_scan_does_not_retain_a_non_dispatch_tool_call() -> None:
    bash_line = _line(
        {
            "type": "assistant",
            "uuid": "bash-row",
            "timestamp": DISPATCH_TS,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "call_bash_1",
                        "name": "Bash",
                        "input": {"command": "ls"},
                    }
                ],
            },
        }
    )
    result_line = _line(
        {
            "type": "user",
            "uuid": "bash-result",
            "timestamp": RECEIPT_TS,
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "call_bash_1",
                        "content": "file.txt",
                    }
                ],
            },
        }
    )
    scan = scan_raw_transcript((bash_line, result_line))

    assert scan.dispatch_records == {}


# --------------------------------------------------------------------------
# 2. The compacted window closes the card from the raw rows
# --------------------------------------------------------------------------


def test_compacted_window_closes_the_card_from_raw_dispatch_rows() -> None:
    raw_lines = (
        _dispatch_line(),
        _receipt_line(),
        _completed_line(),
        _stopped_line(),
    )

    items = _history_items_from_messages(
        _session(),
        (_stop_message(),),
        raw_lines=raw_lines,
    )

    cards = _card_items(items)
    assert len(cards) == 1
    card = cards[0]
    assert card.status == "interrupted"
    content = card.content
    assert content["input"]["prompt"] == PROMPT
    assert content["input"]["description"] == "审查流式渲染正确性"
    assert "Async agent launched successfully" in content["output"]
    # The stopped notice's own summary is the latest state (the live fold
    # writes the same), but the completion's usage is not repeated by it and
    # must survive from the pre-window notice instead of being dropped.
    assert content["summary"] == (
        'Background agent "审查流式渲染正确性" didn\'t finish before the '
        "previous session ended"
    )
    assert content["usage"] == {
        "tokens": 282378,
        "toolCalls": 88,
        "durationMs": 990967,
    }
    assert content["agents"][TASK_ID]["status"] == "stopped"


def test_a_notice_without_a_dispatch_row_still_folds_nothing() -> None:
    """Fail-closed: no dispatch evidence, no card — never a guessed one."""

    items = _history_items_from_messages(
        _session(),
        (_stop_message(),),
        raw_lines=(_stopped_line(),),
    )

    assert _card_items(items) == []


# --------------------------------------------------------------------------
# 3. The evidence sweep reaches a card that never re-entered the timeline
# --------------------------------------------------------------------------


def _ms(iso: str) -> int:
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


NOW = 1_792_550_000.0  # 2026-10-20T18:33:20Z, after every fixture event


class _Clock:
    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __call__(self) -> float:
        return self.seconds


def _oracle(
    *,
    mtime_ms: int | None,
    exists: bool = True,
) -> ClaudeSubagentOracle:
    def probe(*, projects_dir, project_key, external_session_id, task_id):
        _ = projects_dir, project_key, external_session_id, task_id
        return AgentFileInfo(exists=exists, path_known=True, mtime_ms=mtime_ms)

    return ClaudeSubagentOracle(
        projects_dir=Path("/tmp/nonexistent-projects"),
        clock=_Clock(NOW),
        file_probe=probe,
    )


def _sweep(
    raw_lines: tuple[str, ...],
    *,
    mtime_ms: int | None,
    exists: bool = True,
) -> tuple[Any, ...]:
    scan = scan_raw_transcript(raw_lines)
    return ClaudeMessageProjector().close_open_agent_cards(
        _session(),
        oracle=_oracle(mtime_ms=mtime_ms, exists=exists),
        terminal_events=_terminal_events_by_task(scan),
        receipt_ages=_receipt_ages_by_task(scan, now_ms=int(NOW * 1000)),
        scan_cards=scan_agent_call_cards(_session(), scan),
        now_ms=int(NOW * 1000),
    )


def test_sweep_closes_a_card_that_never_re_entered_the_timeline() -> None:
    # The restart shape: no in-memory card, no restored timeline row, and the
    # subagent transcript has been silent for far longer than the deadline.
    items = _sweep(
        (_dispatch_line(), _receipt_line()),
        mtime_ms=int((NOW - 1000) * 1000),
    )

    assert len(items) == 1
    item = items[0]
    assert item.id == stable_tool_item_id(_session(), DISPATCH_TUID)
    assert item.status == "interrupted"
    assert item.content["closedByEvidence"] == "agentFileStale"
    assert item.content["input"]["prompt"] == PROMPT
    assert "Async agent launched successfully" in item.content["output"]
    assert item.content["agents"][TASK_ID]["status"] == "interrupted"


def test_sweep_leaves_a_card_whose_transcript_is_still_growing() -> None:
    items = _sweep(
        (_dispatch_line(), _receipt_line()),
        mtime_ms=int(NOW * 1000),
    )

    assert items == ()


def test_sweep_closes_on_a_terminal_notice_that_never_reached_the_fold() -> None:
    # The notice is in the raw transcript (the fold's window never saw it), and
    # the subagent transcript stopped before it was written.
    items = _sweep(
        (_dispatch_line(), _receipt_line(), _stopped_line()),
        mtime_ms=_ms(STOPPED_TS) - 5_000,
    )

    assert len(items) == 1
    item = items[0]
    assert item.status == "interrupted"
    assert item.content["closedByEvidence"] == "terminalNotice"
    assert item.content["agents"][TASK_ID]["status"] == "stopped"


# --------------------------------------------------------------------------
# 4. The startup reconciliation reaches a session the store never adopted
# --------------------------------------------------------------------------


class _FakeHost(RuntimeHostClient):
    def __init__(self, state: dict[str, Any] | None = None) -> None:
        self.state = dict(state or {})
        self.upserts: list[RuntimeTimelineItem] = []

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.state.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.state[key] = value

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.upserts.append(item)


def _agent_item(item_id: str, *, status: str) -> RuntimeTimelineItem:
    return RuntimeTimelineItem(
        id=item_id,
        session_id=SESSION_ID,
        type="tool",
        status=status,
        order_seq=7,
        content_hash="sha256:test",
        role="tool",
        content={"kind": "agent_call", "agents": {TASK_ID: {"status": "running"}}},
    )


def test_open_card_index_tracks_open_and_terminal_publishes() -> None:
    host = _FakeHost()
    index = ClaudeOpenAgentCards(host)

    asyncio.run(index.record(_session(), _agent_item("card-1", status="running")))
    assert host.state[KEY]["sessions"][SESSION_ID]["itemIds"] == ["card-1"]
    assert (
        host.state[KEY]["sessions"][SESSION_ID]["externalSessionId"]
        == EXTERNAL_SESSION_ID
    )

    # A terminal publish retires the entry; the session leaves the work list.
    asyncio.run(index.record(_session(), _agent_item("card-1", status="done")))
    assert host.state[KEY]["sessions"] == {}


def test_startup_reconciliation_judges_an_indexed_session(
    tmp_path: Any,
    monkeypatch: Any,
) -> None:
    # The session was never adopted by the in-memory store (it is not touched
    # after the restart); only the durable index knows it exists.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    project = tmp_path / "projects" / "-repo"
    project.mkdir(parents=True)
    (project / f"{EXTERNAL_SESSION_ID}.jsonl").write_text(
        "\n".join((_dispatch_line(), _receipt_line())),
        encoding="utf-8",
    )
    host = _FakeHost(
        {
            KEY: {
                "sessions": {
                    SESSION_ID: {
                        "externalSessionId": EXTERNAL_SESSION_ID,
                        "cwd": CWD,
                        "itemIds": [stable_tool_item_id(_session(), DISPATCH_TUID)],
                    }
                }
            }
        }
    )
    runtime = ClaudeRuntime(
        config=RuntimeConfig(
            runtime="claude", revision=1, values={"environment": {}}
        ),
        host=host,
        subagent_oracle=_oracle(mtime_ms=int((NOW - 1000) * 1000)),
    )

    reconciled = asyncio.run(
        runtime._turns.runner.reconcile_agent_cards_from_evidence()
    )

    assert reconciled == 1
    assert [item.status for item in host.upserts] == ["interrupted"]
    assert host.upserts[0].id == stable_tool_item_id(_session(), DISPATCH_TUID)
    # The closure was recorded, so the work list retires itself.
    assert host.state[KEY]["sessions"] == {}


# --------------------------------------------------------------------------
# 5. Real input/output usage from the subagent transcript
# --------------------------------------------------------------------------


def _usage_row(
    input_tokens: int,
    output_tokens: int,
    *,
    cache_read: int = 0,
    cache_creation: int = 0,
) -> str:
    return _line(
        {
            "type": "assistant",
            "uuid": f"usage-{input_tokens}-{output_tokens}",
            "timestamp": DISPATCH_TS,
            "message": {
                "id": f"msg-{input_tokens}-{output_tokens}",
                "role": "assistant",
                "usage": {
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                    "cache_creation_input_tokens": cache_creation,
                    "cache_read_input_tokens": cache_read,
                },
                "content": [{"type": "text", "text": "working"}],
            },
        }
    )


def _write_subagent_transcript(root: Path) -> None:
    path = (
        root
        / "projects"
        / "-repo"
        / EXTERNAL_SESSION_ID
        / "subagents"
        / f"agent-{TASK_ID}.jsonl"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            (
                _usage_row(1_000, 200),
                _usage_row(500, 300, cache_read=9_000),
            )
        ),
        encoding="utf-8",
    )


def test_subagent_usage_sums_the_transcripts_per_call_rows(
    tmp_path: Any,
    monkeypatch: Any,
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _write_subagent_transcript(tmp_path)

    usage = subagent_token_usage(
        cwd=CWD,
        external_session_id=EXTERNAL_SESSION_ID,
        task_id=TASK_ID,
    )

    assert usage == {
        "inputTokens": 1_500,
        "outputTokens": 500,
        "cacheCreationTokens": 0,
        "cacheReadTokens": 9_000,
    }


def test_compacted_window_publishes_the_real_input_output_split(
    tmp_path: Any,
    monkeypatch: Any,
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _write_subagent_transcript(tmp_path)

    items = _history_items_from_messages(
        _session(),
        (_stop_message(),),
        raw_lines=(
            _dispatch_line(),
            _receipt_line(),
            _completed_line(),
            _stopped_line(),
        ),
    )

    content = _card_items(items)[0].content
    assert content["usage"]["inputTokens"] == 1_500
    assert content["usage"]["outputTokens"] == 500
    assert content["usage"]["cacheReadTokens"] == 9_000


def test_sweep_publishes_the_real_input_output_split(
    tmp_path: Any,
    monkeypatch: Any,
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _write_subagent_transcript(tmp_path)

    items = _sweep(
        (_dispatch_line(), _receipt_line()),
        mtime_ms=int((NOW - 1000) * 1000),
    )

    usage = items[0].content["usage"]
    assert usage["inputTokens"] == 1_500
    assert usage["outputTokens"] == 500
    assert usage["cacheReadTokens"] == 9_000
