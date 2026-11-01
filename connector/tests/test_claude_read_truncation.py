from __future__ import annotations

import json

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.subagent_oracle import scan_raw_transcript
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    ClaudeToolBlock,
    _tool_result_content,
)


def _read_result(file_metadata: dict[str, object]) -> dict[str, object]:
    call = ClaudeToolBlock(
        block_type="tool_use",
        tool_use_id="tool-1",
        tool_name="Read",
        tool_input={"file_path": "/tmp/trunc-lines-3000.txt"},
    )
    result = ClaudeToolBlock(
        block_type="tool_result",
        tool_use_id="tool-1",
        tool_result="LINE-0000 " + ("x" * 40),
        tool_result_metadata={"file": file_metadata},
    )
    return dict(_tool_result_content(result, call).to_mapping())


def test_read_result_carries_the_official_truncation_metadata() -> None:
    mapping = _read_result(
        {
            "filePath": "/tmp/trunc-lines-3000.txt",
            "numLines": 1769,
            "startLine": 1,
            "totalLines": 3000,
            "truncatedByTokenCap": True,
        }
    )

    assert mapping["readMetadata"] == {
        "filePath": "/tmp/trunc-lines-3000.txt",
        "numLines": 1769,
        "startLine": 1,
        "totalLines": 3000,
        "truncatedByTokenCap": True,
    }
    assert mapping["truncated"] is True


def test_read_result_with_complete_file_is_not_marked_truncated() -> None:
    mapping = _read_result(
        {
            "filePath": "/tmp/small.txt",
            "numLines": 12,
            "startLine": 1,
            "totalLines": 12,
            "truncatedByTokenCap": False,
        }
    )

    assert mapping["readMetadata"]["numLines"] == 12
    assert mapping["readMetadata"]["totalLines"] == 12
    assert "truncated" not in mapping


def test_partial_line_range_is_not_truncated_without_the_token_cap() -> None:
    """An intentional ``offset``/``limit`` slice is not a cut output."""

    mapping = _read_result(
        {
            "filePath": "/tmp/large.txt",
            "numLines": 200,
            "startLine": 201,
            "totalLines": 5000,
        }
    )

    assert mapping["readMetadata"]["numLines"] == 200
    assert "truncated" not in mapping


def test_raw_scan_keeps_read_file_metadata_without_the_body() -> None:
    row = {
        "type": "user",
        "uuid": "result-row",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": "tool-1",
                    "content": "LINE-0000",
                }
            ],
        },
        "toolUseResult": {
            "type": "text",
            "file": {
                "filePath": "/tmp/trunc-lines-3000.txt",
                "numLines": 1769,
                "startLine": 1,
                "totalLines": 3000,
                "truncatedByTokenCap": True,
                "content": "the whole file body",
            },
        },
    }

    scan = scan_raw_transcript((json.dumps(row),))

    assert scan.tool_result_metadata["tool-1"] == {
        "file": {
            "filePath": "/tmp/trunc-lines-3000.txt",
            "numLines": 1769,
            "startLine": 1,
            "totalLines": 3000,
            "truncatedByTokenCap": True,
        }
    }


def test_history_rebuild_restores_metadata_dropped_by_the_sdk_view() -> None:
    """The SDK message view has no toolUseResult; the raw scan supplies it."""

    session = ClaudeSession(session_id="s", external_session_id="ext")
    projector = ClaudeMessageProjector(
        tool_result_metadata={
            "tool-1": {
                "file": {
                    "filePath": "/tmp/trunc-lines-3000.txt",
                    "numLines": 1769,
                    "startLine": 1,
                    "totalLines": 3000,
                    "truncatedByTokenCap": True,
                }
            }
        }
    )
    call = {
        "type": "assistant",
        "uuid": "call-row",
        "message": {
            "id": "msg-1",
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": "tool-1",
                    "name": "Read",
                    "input": {"file_path": "/tmp/trunc-lines-3000.txt"},
                }
            ],
        },
    }
    result = {
        "type": "user",
        "uuid": "result-row",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": "tool-1",
                    "content": "LINE-0000",
                }
            ],
        },
    }

    projector.tool_items_for_message(session, "turn-1", call)
    items = projector.tool_items_for_message(session, "turn-1", result)

    assert len(items) == 1
    content = items[0].content
    assert content["readMetadata"]["totalLines"] == 3000
    assert content["truncated"] is True
