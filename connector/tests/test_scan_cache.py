"""The raw-transcript scan cache (2026-11-09 event-loop stall).

The 60s evidence sweep re-reads every store session's transcript. The cache
was capped at 16 entries and keyed by (path, size, mtime), so an active
session's every append inserted a new key: the cache filled with stale
versions of one file and evicted the rest of the library. These tests pin
one entry per transcript and the survival of the other sessions.
"""

from __future__ import annotations

from pathlib import Path

from connector.runtimes.claude.sessions import subagent_oracle
from connector.runtimes.claude.sessions.subagent_oracle import scan_transcript_file

ROW = '{"type":"user"}\n'


def _entries(path: Path) -> list[tuple[str, int, int]]:
    return [key for key in subagent_oracle._SCAN_CACHE if key[0] == str(path)]


def test_a_changed_transcript_replaces_its_own_cache_entry(
    tmp_path: Path, monkeypatch: object
) -> None:
    monkeypatch.setattr(subagent_oracle, "_SCAN_CACHE", {})  # type: ignore[attr-defined]
    path = tmp_path / "transcript.jsonl"
    path.write_text(ROW, encoding="utf-8")
    first = scan_transcript_file(path)
    assert len(_entries(path)) == 1

    path.write_text(ROW * 2, encoding="utf-8")
    second = scan_transcript_file(path)
    assert second is not None and first is not None
    assert second is not first
    assert len(_entries(path)) == 1


def test_one_growing_transcript_does_not_evict_other_sessions(
    tmp_path: Path, monkeypatch: object
) -> None:
    monkeypatch.setattr(subagent_oracle, "_SCAN_CACHE", {})  # type: ignore[attr-defined]
    other = tmp_path / "other-session.jsonl"
    other.write_text(ROW, encoding="utf-8")
    scan_transcript_file(other)

    growing = tmp_path / "growing-session.jsonl"
    for line_count in range(1, 21):
        growing.write_text(ROW * line_count, encoding="utf-8")
        scan_transcript_file(growing)

    assert len(_entries(growing)) == 1
    assert len(_entries(other)) == 1


def test_budget_evicts_the_oldest_scan(
    tmp_path: Path, monkeypatch: object
) -> None:
    monkeypatch.setattr(subagent_oracle, "_SCAN_CACHE", {})  # type: ignore[attr-defined]
    monkeypatch.setattr(  # type: ignore[attr-defined]
        subagent_oracle, "_SCAN_RETAINED_BYTES_PER_SOURCE_BYTE", 1.0
    )
    monkeypatch.setattr(subagent_oracle, "_SCAN_MIN_CHARGE_BYTES", 0)  # type: ignore[attr-defined]
    row_bytes = len(ROW.encode())
    monkeypatch.setattr(  # type: ignore[attr-defined]
        subagent_oracle, "_SCAN_CACHE_BUDGET_BYTES", row_bytes * 2 + row_bytes // 2
    )
    first = tmp_path / "first.jsonl"
    second = tmp_path / "second.jsonl"
    third = tmp_path / "third.jsonl"
    for path in (first, second, third):
        path.write_text(ROW, encoding="utf-8")

    scan_transcript_file(first)
    scan_transcript_file(second)
    scan_transcript_file(third)

    assert _entries(first) == []
    assert len(_entries(second)) == 1
    assert len(_entries(third)) == 1


def test_budget_never_caches_a_scan_larger_than_itself(
    tmp_path: Path, monkeypatch: object
) -> None:
    monkeypatch.setattr(subagent_oracle, "_SCAN_CACHE", {})  # type: ignore[attr-defined]
    monkeypatch.setattr(  # type: ignore[attr-defined]
        subagent_oracle, "_SCAN_RETAINED_BYTES_PER_SOURCE_BYTE", 1.0
    )
    monkeypatch.setattr(subagent_oracle, "_SCAN_MIN_CHARGE_BYTES", 0)  # type: ignore[attr-defined]
    row_bytes = len(ROW.encode())
    monkeypatch.setattr(  # type: ignore[attr-defined]
        subagent_oracle, "_SCAN_CACHE_BUDGET_BYTES", row_bytes - 1
    )
    path = tmp_path / "oversize.jsonl"
    path.write_text(ROW, encoding="utf-8")

    assert scan_transcript_file(path) is not None
    assert _entries(path) == []
