"""Bounded, single-flight transcript scan service (plan A)."""

from __future__ import annotations

import asyncio
import threading
from pathlib import Path

from connector.runtimes.claude.sessions import scan_service
from connector.runtimes.claude.sessions.scan_service import TranscriptScanService


def _write(path: Path) -> Path:
    path.write_text('{"type":"user"}\n', encoding="utf-8")
    return path


def test_scan_runs_on_the_foreground_worker(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()
    seen: list[str] = []

    def fake_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        seen.append(threading.current_thread().name)
        return object()

    monkeypatch.setattr(scan_service, "scan_transcript_file", fake_scan)  # type: ignore[attr-defined]

    async def run() -> object:
        return await service.scan(path)

    try:
        result = asyncio.run(run())
    finally:
        service.shutdown()
    assert result is not None
    assert seen and seen[0].startswith("aa-scan-fg")


def test_concurrent_scans_of_one_version_are_single_flighted(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()
    started = threading.Event()
    release = threading.Event()
    calls = 0

    def fake_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        nonlocal calls
        calls += 1
        started.set()
        release.wait(timeout=2)
        return object()

    monkeypatch.setattr(scan_service, "scan_transcript_file", fake_scan)  # type: ignore[attr-defined]

    async def run() -> tuple[object, object]:
        first = asyncio.create_task(service.scan(path))
        second = asyncio.create_task(service.scan(path))
        await asyncio.to_thread(started.wait, 2)
        release.set()
        return await asyncio.gather(first, second)  # type: ignore[return-value]

    try:
        one, two = asyncio.run(run())
    finally:
        service.shutdown()
    assert calls == 1
    assert one is two


def test_cached_or_schedule_outside_a_loop_keeps_the_inline_scan(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()
    expected = object()

    def fake_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        return expected

    monkeypatch.setattr(scan_service, "scan_transcript_file", fake_scan)  # type: ignore[attr-defined]

    try:
        assert service.cached_or_schedule(path) is expected
    finally:
        service.shutdown()
