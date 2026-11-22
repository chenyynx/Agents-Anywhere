"""Chunked transcript reading must match the old full-file scan exactly."""

from __future__ import annotations

import json
import os
from pathlib import Path

from connector.runtimes.claude.sessions import subagent_oracle
from connector.runtimes.claude.sessions.subagent_oracle import (
    scan_raw_transcript,
    scan_transcript_file,
)


def _row(uuid: str, text: str = "hello") -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "message": {"role": "user", "content": text},
        },
        ensure_ascii=False,
    )


def _fields(scan: object) -> tuple[int, tuple[str, ...], int, int]:
    return (
        len(scan.notices),  # type: ignore[attr-defined]
        tuple(sorted(scan.uuid_line_index)),  # type: ignore[attr-defined]
        len(scan.dispatch_records),  # type: ignore[attr-defined]
        len(scan.block_order_ledgers),  # type: ignore[attr-defined]
    )


def _clear_cache() -> None:
    subagent_oracle._SCAN_CACHE.clear()


def test_chunked_scan_matches_full_scan_across_separators(tmp_path: Path) -> None:
    rows = [_row("a" * 36), _row("b" * 36, "world"), _row("c" * 36)]
    for name, content in {
        "lf": "\n".join(rows) + "\n",
        "crlf": "\r\n".join(rows) + "\r\n",
        "cr_only": "\r".join(rows) + "\r",
        "u2028": "\u2028".join(rows) + "\u2028",
        "no_trailing": "\n".join(rows),
    }.items():
        path = tmp_path / f"{name}.jsonl"
        path.write_text(content, encoding="utf-8")
        _clear_cache()
        expected = scan_raw_transcript(tuple(content.splitlines()))
        got = scan_transcript_file(path, chunk_size=7)
        assert got is not None
        assert _fields(got) == _fields(expected), name


def test_chunked_scan_keeps_first_and_last_rows_of_a_large_file(
    tmp_path: Path,
) -> None:
    first = _row("f" * 36, "first")
    last = _row("l" * 36, "last")
    middle = [_row(f"{i:036d}", "x" * 200) for i in range(2000)]
    content = "\n".join([first, *middle, last]) + "\n"
    path = tmp_path / "large.jsonl"
    path.write_text(content, encoding="utf-8")
    _clear_cache()
    scan = scan_transcript_file(path)
    assert scan is not None
    assert "f" * 36 in scan.uuid_line_index
    assert "l" * 36 in scan.uuid_line_index


def test_same_size_middle_rewrite_misses_the_cache(tmp_path: Path) -> None:
    first = _row("a" * 36, "x" * 20000)
    second = _row("b" * 36, "y" * 20000)
    content = first + "\n" + second + "\n"
    path = tmp_path / "rewrite.jsonl"
    path.write_text(content, encoding="utf-8")
    stat = path.stat()
    _clear_cache()
    before = scan_transcript_file(path)
    assert before is not None
    replaced = content.replace("b" * 36, "c" * 36, 1)
    assert len(replaced.encode()) == len(content.encode())
    path.write_text(replaced, encoding="utf-8")
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    after = scan_transcript_file(path)
    assert after is not None
    assert after is not before
    assert "c" * 36 in after.uuid_line_index
    assert "b" * 36 not in after.uuid_line_index


def test_cancelled_scan_returns_none_and_does_not_cache(tmp_path: Path) -> None:
    path = tmp_path / "cancel.jsonl"
    path.write_text(
        "\n".join(_row(f"{i:036d}") for i in range(100)) + "\n",
        encoding="utf-8",
    )
    _clear_cache()
    calls = 0

    def cancel() -> bool:
        nonlocal calls
        calls += 1
        return calls >= 2

    assert scan_transcript_file(path, cancel=cancel, chunk_size=8) is None
    assert not any(key[0] == str(path) for key in subagent_oracle._SCAN_CACHE)
