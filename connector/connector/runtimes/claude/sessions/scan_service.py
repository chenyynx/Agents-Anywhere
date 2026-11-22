"""Bounded, single-flight execution for Claude transcript scans.

The scanner itself is synchronous (it reads a whole JSONL file and parses it),
so calling it directly on the connector's event loop blocks every other RPC,
push and sweep for the duration — measured at ~3s for a 97MB active transcript
on 2026-11-23. This service keeps the scanning contract unchanged (full
``RawTranscriptScan``) and only moves the work onto two small thread pools:

* ``foreground`` — settle/snapshot reads, one worker;
* ``background`` — the periodic evidence sweep, one worker.

Two pools, not one, so a slow sweep can never starve a settle read. Identical
file versions are single-flighted per lane: concurrent requests in the same
lane share one scan future instead of reading the same 97MB file several times.
A foreground request never queues behind a background sweep of the same file;
it starts its own scan in the foreground lane.

Async callers use ``scan`` and await the result. Synchronous folds are wrapped
by ``messages.override_raw_scan`` after the caller has awaited one scan; the
service deliberately has no synchronous scheduling seam, so a missed override
fails visible in tests rather than silently blocking the loop.
"""

from __future__ import annotations

import asyncio
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Literal

from connector.logging import logger
from connector.runtimes.claude.sessions.subagent_oracle import (
    RawTranscriptScan,
    ScanCacheKey,
    cached_transcript_scan,
    scan_transcript_file,
    transcript_scan_key,
)

Priority = Literal["foreground", "background"]
InflightKey = tuple[ScanCacheKey, Priority]

#: One worker per lane is deliberate: each scan can hold a >3x-file-size parse
#: in memory, so more parallelism buys head-of-line blocking, not throughput.
_FOREGROUND_WORKERS = 1
_BACKGROUND_WORKERS = 1
#: A scan or queue wait above these is worth a log line; normal scans are
#: sub-second for ordinary transcripts and the thresholds only surface the
#: large-file cases this service exists to keep off the event loop.
_SLOW_SCAN_MS = 2000.0
_SLOW_QUEUE_MS = 1000.0


class TranscriptScanService:
    """Two bounded scan lanes with per-version single-flight."""

    def __init__(
        self,
        *,
        foreground_workers: int = _FOREGROUND_WORKERS,
        background_workers: int = _BACKGROUND_WORKERS,
    ) -> None:
        self._pools: dict[Priority, ThreadPoolExecutor] = {
            "foreground": ThreadPoolExecutor(
                max_workers=foreground_workers,
                thread_name_prefix="aa-scan-fg",
            ),
            "background": ThreadPoolExecutor(
                max_workers=background_workers,
                thread_name_prefix="aa-scan-bg",
            ),
        }
        self._lock = threading.Lock()
        #: Per-lane single-flight: a foreground settle must not queue behind a
        #: background sweep scan of the same file. The same version may be
        #: scanned once per lane (bounded by two workers); within a lane it is
        #: shared.
        self._inflight: dict[
            InflightKey,
            asyncio.Future[RawTranscriptScan | None],
        ] = {}
        self._stats: dict[str, int] = {
            "cache_hits": 0,
            "singleflight_hits": 0,
            "scans": 0,
            "scan_errors": 0,
            "submit_errors": 0,
            "cancelled": 0,
        }
        self._last_scan_ms: dict[Priority, float] = {
            "foreground": 0.0,
            "background": 0.0,
        }
        self._last_queue_ms: dict[Priority, float] = {
            "foreground": 0.0,
            "background": 0.0,
        }

    def stats(self) -> dict[str, object]:
        with self._lock:
            return {
                **self._stats,
                "last_scan_ms": dict(self._last_scan_ms),
                "last_queue_ms": dict(self._last_queue_ms),
                "inflight": len(self._inflight),
            }

    async def scan(
        self,
        path: Path,
        *,
        priority: Priority = "foreground",
    ) -> RawTranscriptScan | None:
        """Return the file's current scan, running it off the event loop."""

        cached = cached_transcript_scan(path)
        if cached is not None:
            self._bump("cache_hits")
            return cached
        future = self._request(path, priority)
        if future is None:
            return None
        try:
            return await asyncio.shield(future)
        except asyncio.CancelledError:
            if future.cancelled():
                self._bump("cancelled")
                return None
            raise

    def _request(
        self,
        path: Path,
        priority: Priority,
    ) -> asyncio.Future[RawTranscriptScan | None] | None:
        scan_key = transcript_scan_key(path)
        if scan_key is None:
            return None
        key: InflightKey = (scan_key, priority)
        loop = asyncio.get_running_loop()
        with self._lock:
            existing = self._inflight.get(key)
            if existing is not None:
                # A future bound to a closed/other loop is poison: every later
                # request for this version would await a result that can never
                # arrive. Drop it and scan again in this loop.
                if not existing.done() and existing.get_loop() is loop:
                    self._stats["singleflight_hits"] += 1
                    return existing
                self._inflight.pop(key, None)
            future: asyncio.Future[RawTranscriptScan | None] = loop.create_future()
            self._inflight[key] = future
        cancelled = threading.Event()
        future.add_done_callback(
            lambda done: cancelled.set() if done.cancelled() else None
        )
        submitted_at = time.monotonic()
        try:
            self._pools[priority].submit(
                self._run,
                path,
                key,
                future,
                loop,
                cancelled,
                priority,
                submitted_at,
            )
        except Exception as exc:  # noqa: BLE001 - the pool may be shutting down
            with self._lock:
                self._inflight.pop(key, None)
                self._stats["submit_errors"] += 1
            logger.opt(exception=(type(exc), exc, exc.__traceback__)).error(
                "Claude transcript scan submit failed path={} priority={}",
                path,
                priority,
            )
            if not future.done():
                future.set_result(None)
            return None
        return future

    def _run(
        self,
        path: Path,
        key: InflightKey,
        future: asyncio.Future[RawTranscriptScan | None],
        loop: asyncio.AbstractEventLoop,
        cancelled: threading.Event,
        priority: Priority,
        submitted_at: float,
    ) -> None:
        started_at = time.monotonic()
        scan: RawTranscriptScan | None
        error: BaseException | None = None
        try:
            scan = scan_transcript_file(path, cancel=cancelled.is_set)
        except Exception as exc:  # noqa: BLE001 - reported, never raised into the loop
            scan = None
            error = exc
        finished_at = time.monotonic()
        try:
            loop.call_soon_threadsafe(
                self._finish,
                key,
                future,
                scan,
                error,
                priority,
                (started_at - submitted_at) * 1000.0,
                (finished_at - started_at) * 1000.0,
            )
        except RuntimeError:
            # The loop closed while the scan was running (shutdown/tests).
            # Drop the in-flight entry so a later loop can scan this version
            # instead of joining a future that can never be resolved.
            with self._lock:
                self._inflight.pop(key, None)
            return

    def _finish(
        self,
        key: InflightKey,
        future: asyncio.Future[RawTranscriptScan | None],
        scan: RawTranscriptScan | None,
        error: BaseException | None,
        priority: Priority,
        queue_ms: float,
        scan_ms: float,
    ) -> None:
        scan_key = key[0]
        with self._lock:
            self._inflight.pop(key, None)
            self._stats["scans"] += 1
            if error is not None:
                self._stats["scan_errors"] += 1
            self._last_queue_ms[priority] = queue_ms
            self._last_scan_ms[priority] = scan_ms
        if error is not None:
            logger.opt(
                exception=(type(error), error, error.__traceback__)
            ).error(
                "Claude transcript scan failed path={} error={!r}",
                scan_key[0],
                error,
            )
        elif scan_ms >= _SLOW_SCAN_MS or queue_ms >= _SLOW_QUEUE_MS:
            logger.info(
                "Claude transcript scan slow path={} priority={} bytes={} queue_ms={:.1f} scan_ms={:.1f}",
                scan_key[0],
                priority,
                scan_key[1],
                queue_ms,
                scan_ms,
            )
        if not future.done():
            try:
                future.set_result(scan)
            except asyncio.InvalidStateError:
                # The waiter was cancelled between the check and the set.
                pass

    def _bump(self, name: str) -> None:
        with self._lock:
            self._stats[name] = self._stats.get(name, 0) + 1

    def shutdown(self) -> None:
        with self._lock:
            futures = list(self._inflight.values())
            self._inflight.clear()
        for future in futures:
            if future.done():
                continue
            try:
                if not future.get_loop().is_closed():
                    future.cancel()
            except RuntimeError:
                # A future whose loop was closed by the owning test/process.
                pass
        for pool in self._pools.values():
            pool.shutdown(wait=False, cancel_futures=True)


_SERVICE: TranscriptScanService | None = None
_SERVICE_LOCK = threading.Lock()


def get_scan_service() -> TranscriptScanService:
    global _SERVICE
    with _SERVICE_LOCK:
        if _SERVICE is None:
            _SERVICE = TranscriptScanService()
        return _SERVICE
