from __future__ import annotations

from connector.runtimes.claude.timeline.messages import (
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


def test_partial_line_range_is_truncated_even_without_the_token_cap() -> None:
    mapping = _read_result(
        {
            "filePath": "/tmp/large.txt",
            "numLines": 200,
            "startLine": 201,
            "totalLines": 5000,
        }
    )

    assert mapping["truncated"] is True
