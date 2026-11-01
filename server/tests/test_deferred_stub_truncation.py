from __future__ import annotations

import json

from agent_server.infra.timeline_store import (
    STUB_MAX_BYTES,
    STUB_VERSION,
    build_stub_content,
)


def _stub_bytes(stub: dict[str, object]) -> int:
    return len(
        json.dumps(stub, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
    )


def test_stub_keeps_the_tool_result_truncation_fields() -> None:
    content = {
        "kind": "tool_call",
        "toolName": "Read",
        "toolUseId": "tool-1",
        "output": "x" * 200_000,
        "outputText": "x" * 200_000,
        "outputPreview": "tail",
        "readMetadata": {
            "filePath": "/tmp/trunc-lines-3000.txt",
            "numLines": 1769,
            "startLine": 1,
            "totalLines": 3000,
            "truncatedByTokenCap": True,
        },
        "truncated": True,
        "optionalLarge": "y" * 10_000,
    }

    stub = build_stub_content(content, 200_000)

    assert stub is not None
    assert stub["readMetadata"]["numLines"] == 1769
    assert stub["readMetadata"]["totalLines"] == 3000
    assert stub["truncated"] is True
    assert stub["deferred"] is True
    assert "output" not in stub
    assert "outputText" not in stub
    assert "optionalLarge" not in stub
    assert _stub_bytes(stub) <= STUB_MAX_BYTES


def test_stub_version_tracks_the_new_fields() -> None:
    assert STUB_VERSION == 2
