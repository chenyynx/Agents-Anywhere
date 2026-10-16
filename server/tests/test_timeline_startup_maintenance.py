"""Startup maintenance failure isolation and task lifecycle (P0-1, app.py).

The startup sweep is three independent best-effort passes. Before the fix a
single wrapping ``try`` aborted the whole sweep on the first failure (so an
ownership-guard error in dedup also skipped the very order repair the pass was
for) and the boot logged nothing distinguishing "repaired" from "skipped". And
the background task was created without being retained, so a shutdown could
dispose the store/Redis while a pass was still running.

These tests pin the fixed contract: each pass is isolated and reported
honestly, and the lifespan cancels the maintenance task before it closes the
store and Redis.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from loguru import logger as loguru_logger

import agent_server.app as app_module


class _FakeStore:
    def __init__(self, *, fail: str | None = None) -> None:
        self.calls: list[str] = []
        self._fail = fail

    async def backfill_native_item_ids(self) -> int:
        self.calls.append("backfill")
        if self._fail == "backfill":
            raise RuntimeError("backfill boom")
        return 4

    async def deduplicate_message_identities(self) -> int:
        self.calls.append("dedup")
        if self._fail == "dedup":
            raise RuntimeError("dedup boom")
        return 2

    async def repair_intra_message_order(self) -> int:
        self.calls.append("repair")
        if self._fail == "repair":
            raise RuntimeError("repair boom")
        return 1


def _capture() -> tuple[list[str], int]:
    messages: list[str] = []
    sink_id = loguru_logger.add(messages.append, level="INFO")
    return messages, sink_id


@pytest.mark.anyio
async def test_a_failing_pass_does_not_skip_the_later_passes() -> None:
    store = _FakeStore(fail="dedup")
    app = SimpleNamespace(state=SimpleNamespace(store=store))
    messages, sink_id = _capture()
    try:
        await app_module._timeline_startup_maintenance(app)
    finally:
        loguru_logger.remove(sink_id)

    # The failed dedup must not have aborted the order repair.
    assert store.calls == ["backfill", "dedup", "repair"]
    text = "".join(messages)
    assert "incomplete" in text
    # The honest report never claims the repair completed.
    assert "maintenance applied" not in text


@pytest.mark.anyio
async def test_all_passes_succeed_reports_applied_and_not_incomplete() -> None:
    store = _FakeStore()
    app = SimpleNamespace(state=SimpleNamespace(store=store))
    messages, sink_id = _capture()
    try:
        await app_module._timeline_startup_maintenance(app)
    finally:
        loguru_logger.remove(sink_id)

    assert store.calls == ["backfill", "dedup", "repair"]
    text = "".join(messages)
    assert "maintenance applied" in text
    assert "incomplete" not in text


@pytest.mark.anyio
async def test_cancellation_propagates_so_shutdown_is_not_swallowed() -> None:
    """A cancel during a pass must not be caught as a generic failure: the
    lifespan needs it to unwind promptly instead of logging a fake "failed"."""

    class _CancellingStore(_FakeStore):
        async def deduplicate_message_identities(self) -> int:
            self.calls.append("dedup")
            raise asyncio.CancelledError

    store = _CancellingStore()
    app = SimpleNamespace(state=SimpleNamespace(store=store))
    with pytest.raises(asyncio.CancelledError):
        await app_module._timeline_startup_maintenance(app)
    assert store.calls == ["backfill", "dedup"]


@pytest.mark.anyio
async def test_lifespan_cancels_maintenance_task_before_closing_store(
    tmp_path, monkeypatch
) -> None:
    """The background maintenance must be cancelled and awaited when the app
    shuts down, before the store/Redis are closed underneath it."""

    started = asyncio.Event()
    seen: dict[str, Any] = {}

    async def slow_maintenance(app: Any) -> None:
        seen["task"] = asyncio.current_task()
        started.set()
        await asyncio.sleep(30)

    monkeypatch.setattr(
        app_module, "_timeline_startup_maintenance", slow_maintenance
    )
    app = app_module.create_app()
    async with app.router.lifespan_context(app):
        await asyncio.wait_for(started.wait(), timeout=10)
        assert not seen["task"].done()

    # The lifespan's finally cancelled and awaited the task, so it is finished
    # rather than left running against a disposed engine.
    assert seen["task"].done()
