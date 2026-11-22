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


def test_many_waiters_share_one_scan(
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

    async def run() -> list[object]:
        tasks = [asyncio.create_task(service.scan(path)) for _ in range(32)]
        await asyncio.to_thread(started.wait, 2)
        release.set()
        return await asyncio.gather(*tasks)  # type: ignore[return-value]

    try:
        results = asyncio.run(run())
    finally:
        service.shutdown()
    assert calls == 1
    assert all(result is results[0] for result in results)
    assert service.stats()["singleflight_hits"] == 31
    assert service.stats()["inflight"] == 0


def test_scan_failure_fans_out_and_clears_inflight(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()

    def fake_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        raise RuntimeError("boom")

    monkeypatch.setattr(scan_service, "scan_transcript_file", fake_scan)  # type: ignore[attr-defined]

    async def run() -> tuple[object, object]:
        return await asyncio.gather(service.scan(path), service.scan(path))  # type: ignore[return-value]

    try:
        first, second = asyncio.run(run())
    finally:
        service.shutdown()
    assert first is None and second is None
    assert service.stats()["scan_errors"] == 1
    assert service.stats()["inflight"] == 0


def test_second_scan_hits_the_cache(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()
    calls = 0
    original = scan_service.scan_transcript_file

    def counting_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        nonlocal calls
        calls += 1
        return original(path, cancel=cancel, chunk_size=chunk_size)

    monkeypatch.setattr(scan_service, "scan_transcript_file", counting_scan)  # type: ignore[attr-defined]

    async def run() -> tuple[object, object]:
        return await service.scan(path), await service.scan(path)

    try:
        first, second = asyncio.run(run())
    finally:
        service.shutdown()
    assert calls == 1
    assert first is second


def test_foreground_does_not_join_a_background_scan(
    tmp_path: Path, monkeypatch: object
) -> None:
    path = _write(tmp_path / "transcript.jsonl")
    service = TranscriptScanService()
    background_started = threading.Event()
    release_background = threading.Event()
    calls = 0

    def fake_scan(path: Path, *, cancel=None, chunk_size: int = 0) -> object:
        nonlocal calls
        calls += 1
        if threading.current_thread().name.startswith("aa-scan-bg"):
            background_started.set()
            release_background.wait(timeout=2)
        return object()

    monkeypatch.setattr(scan_service, "scan_transcript_file", fake_scan)  # type: ignore[attr-defined]

    async def run() -> tuple[object, object]:
        background = asyncio.create_task(
            service.scan(path, priority="background")
        )
        await asyncio.to_thread(background_started.wait, 2)
        foreground = await asyncio.wait_for(
            service.scan(path, priority="foreground"), timeout=1
        )
        release_background.set()
        return foreground, await background

    try:
        foreground, background = asyncio.run(run())
    finally:
        service.shutdown()
    assert calls == 2
    assert foreground is not None and background is not None
