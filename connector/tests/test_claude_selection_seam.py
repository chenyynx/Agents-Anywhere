"""In-process selection changes: the SDK seam wrappers (2026-10-15 §3.1).

The connector used to treat a model/permission change as a CLI relaunch, which
is what held user messages for up to 600 s behind running background work. The
SDK exposes the change as an in-place control request (``set_model`` /
``set_permission_mode``); these wrappers are the single seam the turn path
calls, so their contract is pinned here:

* the capability probe is the attribute (the seam), never a version number;
* a call reaches the live client with the exact value the caller chose;
* anything else — a missing seam, a refusal, a silent CLI — is a ``False`` and
  a WARN, never an exception into the user's turn.

Behaviour is asserted through what the fake client received, the return value,
and the captured WARNING line — not through private state.
"""

from __future__ import annotations

import asyncio
from typing import Any, Self

import pytest

from connector.logging import logger
from connector.runtimes.claude.sdk import client as client_module
from connector.runtimes.claude.sdk.client import (
    CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS,
    client_supports_set_model,
    client_supports_set_permission_mode,
    set_model_client,
    set_permission_mode_client,
)


class _Warnings:
    """Collect connector WARNING lines emitted around a block."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self._sink: int | None = None

    def __enter__(self) -> Self:
        self._sink = logger.add(
            lambda message: self.lines.append(str(message)), level="WARNING"
        )
        return self

    def __exit__(self, *_exc: object) -> None:
        assert self._sink is not None
        logger.remove(self._sink)

    def joined(self) -> str:
        return "\n".join(self.lines)


class _RecordingClient:
    """A live client whose two controls land in separate channels.

    Keeping model and permission in distinct lists is what lets a test prove
    the two paths are not crossed (a ``set_permission_mode`` that reached
    ``set_model`` would be a silent wrong-model switch).
    """

    def __init__(self) -> None:
        self.model_calls: list[str | None] = []
        self.permission_calls: list[str] = []

    async def set_model(self, model: str | None = None) -> None:
        self.model_calls.append(model)

    async def set_permission_mode(self, mode: str) -> None:
        self.permission_calls.append(mode)


# --- the capability probe (by seam, not by version) --------------------------


def test_capability_probe_reflects_the_seam() -> None:
    assert client_supports_set_model(_RecordingClient()) is True
    assert client_supports_set_permission_mode(_RecordingClient()) is True
    # A client without the control has no in-place path, whatever it is: the
    # probe is the missing attribute, not a version guess.
    assert client_supports_set_model(object()) is False
    assert client_supports_set_permission_mode(object()) is False


# --- acceptance reaches the client with the exact value ----------------------


def test_set_model_reaches_the_live_client_and_reports_acceptance() -> None:
    async def run() -> None:
        client = _RecordingClient()
        assert await set_model_client(client, "oc/deepseek-v4.1-flash") is True
        assert client.model_calls == ["oc/deepseek-v4.1-flash"]
        # The other control was not touched by this path.
        assert client.permission_calls == []

    asyncio.run(run())


def test_set_permission_mode_reaches_the_live_client_and_reports_acceptance() -> None:
    async def run() -> None:
        client = _RecordingClient()
        assert await set_permission_mode_client(client, "acceptEdits") is True
        assert client.permission_calls == ["acceptEdits"]
        assert client.model_calls == []

    asyncio.run(run())


def test_set_model_forwards_none_verbatim() -> None:
    """`None` means "the CLI default" and must survive, not be dropped."""

    async def run() -> None:
        client = _RecordingClient()
        assert await set_model_client(client, None) is True
        assert client.model_calls == [None]

    asyncio.run(run())


def test_a_sync_result_shape_is_accepted() -> None:
    """The seam may return a plain value; it is not required to be awaitable."""

    class _SyncClient:
        def __init__(self) -> None:
            self.models: list[str | None] = []

        def set_model(self, model: str | None = None) -> Any:
            self.models.append(model)
            return {"ok": True}

    async def run() -> None:
        client = _SyncClient()
        assert await set_model_client(client, "wb/deepseek-v4.1-flash") is True
        assert client.models == ["wb/deepseek-v4.1-flash"]

    asyncio.run(run())


# --- refusal is a False and a WARN, never an exception -----------------------


def test_missing_seam_reports_false_with_a_warning() -> None:
    async def run() -> None:
        with _Warnings() as warnings:
            assert await set_model_client(object(), "wb/x") is False
            assert await set_permission_mode_client(object(), "acceptEdits") is False
        joined = warnings.joined()
        assert "set_model" in joined
        assert "set_permission_mode" in joined

    asyncio.run(run())


def test_refusal_reports_false_without_raising() -> None:
    class _RefusingClient:
        async def set_model(self, model: str | None = None) -> None:
            raise RuntimeError("Cannot set model: catalog_unknown")

    async def run() -> None:
        with _Warnings() as warnings:
            assert await set_model_client(_RefusingClient(), "bogus/model") is False
        # The failure is observable and names the target — no silent drop.
        joined = warnings.joined()
        assert "set_model" in joined
        assert "bogus/model" in joined
        assert "catalog_unknown" in joined

    asyncio.run(run())


def test_a_silent_cli_fails_the_bounded_wait(monkeypatch: pytest.MonkeyPatch) -> None:
    """A CLI that never answers must cost the bound, not the turn.

    The wait is bounded by the module constant, which is monkeypatched to a
    tiny value here — the test does not drag real time to prove the bound.
    """

    class _SilentClient:
        async def set_model(self, model: str | None = None) -> None:
            await asyncio.Event().wait()

    monkeypatch.setattr(
        client_module, "CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS", 0.05
    )

    async def run() -> None:
        with _Warnings() as warnings:
            assert await set_model_client(_SilentClient(), "wb/x") is False
        # The bound fired — not a refusal path; both are False but only this
        # one says why.
        assert "timed out" in warnings.joined()

    asyncio.run(run())


def test_selection_control_default_timeout_stays_below_the_rpc_budget() -> None:
    """The default is the real budget, not the SDK's 60 s wait.

    A red-team note mirroring the interrupt guard: the timeout tests pass
    their own value, so the default could drift to a minute and every test
    would stay green. It must stay a finite bound well under the server's
    30 s RPC timeout, and never zero (the CLI must get a chance to answer).
    """

    assert 0 < CLAUDE_SELECTION_CONTROL_TIMEOUT_SECONDS < 30
