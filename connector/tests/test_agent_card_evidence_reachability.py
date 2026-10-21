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

import json
from types import SimpleNamespace
from typing import Any, Mapping

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.sessions.subagent_oracle import scan_raw_transcript
from connector.runtimes.claude.timeline.messages import stable_tool_item_id

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
