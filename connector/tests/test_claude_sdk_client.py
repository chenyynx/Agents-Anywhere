from __future__ import annotations

import asyncio
import inspect
from typing import Any

import claude_agent_sdk
import pytest

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sdk.client import (
    CLAUDE_INTERRUPT_TIMEOUT_SECONDS,
    build_sdk_options,
    interrupt_client,
)


def test_claude_sdk_buffer_handles_25_mib_image_read_result() -> None:
    options = build_sdk_options(
        claude_agent_sdk,
        {},
        ClaudeSession(session_id="sess_buffer"),
    )

    attachment_bytes = 25 * 1024 * 1024
    base64_bytes = 4 * ((attachment_bytes + 2) // 3)
    duplicated_read_result_bytes = 2 * base64_bytes
    json_overhead_bytes = 1024 * 1024

    assert options.max_buffer_size >= (
        duplicated_read_result_bytes + json_overhead_bytes
    )


def test_interrupt_client_answers_without_waiting_a_silent_cli() -> None:
    class _Client:
        def __init__(self) -> None:
            self.interrupted = False

        async def interrupt(self) -> None:
            self.interrupted = True

    class _SilentClient:
        async def interrupt(self) -> None:
            await asyncio.Event().wait()

    class _UnofficialClient:
        pass

    async def run() -> None:
        client = _Client()
        assert await interrupt_client(client) is True
        assert client.interrupted
        # A client without an interrupt method is still the "nothing to call"
        # answer, not an error.
        assert await interrupt_client(_UnofficialClient()) is False
        # The guard: a CLI that never answers must cost the stop path its
        # bound, never more. The caller treats the timeout like any other
        # interrupt error and proceeds to task.cancel().
        with pytest.raises(asyncio.TimeoutError):
            await interrupt_client(_SilentClient(), timeout=0.05)

    asyncio.run(run())


def test_interrupt_client_waits_for_a_sync_result_shape() -> None:
    class _SyncClient:
        def interrupt(self) -> Any:
            return {"ok": True}

    async def run() -> None:
        assert await interrupt_client(_SyncClient()) is True

    asyncio.run(run())


def test_interrupt_client_default_timeout_stays_a_stop_path_budget() -> None:
    """The bound belongs to the stop path, not to the SDK.

    A red-team note: the timeout test above passes its own value, so the
    default could drift to a minute and every test would stay green. The
    default is the real budget: bounded well below the server's 30 s RPC
    timeout (a stop that waits that long is the bug this guard exists for),
    and never zero (the CLI must get a chance to answer).
    """

    default = inspect.signature(interrupt_client).parameters["timeout"].default
    assert default == CLAUDE_INTERRUPT_TIMEOUT_SECONDS
    assert 0 < default <= 5
