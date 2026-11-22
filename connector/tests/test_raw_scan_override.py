"""The sync fold seam must use an awaited scan, never touch the file itself."""

from __future__ import annotations

import asyncio

import pytest

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions import reader
from connector.runtimes.claude.timeline import messages


def _session(session_id: str) -> ClaudeSession:
    return ClaudeSession(
        session_id=session_id,
        external_session_id=f"ext-{session_id}",
        cwd="/tmp/project",
    )


def test_override_is_used_for_the_matching_session_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session = _session("s1")
    other = _session("s2")
    injected = object()

    def fail(session: ClaudeSession) -> object:
        raise AssertionError("fallback scan must not run under an override")

    monkeypatch.setattr(reader, "_read_raw_transcript_scan", fail)

    with messages.override_raw_scan(session, injected):  # type: ignore[arg-type]
        assert messages._read_session_raw_scan(session) is injected
        with pytest.raises(AssertionError):
            messages._read_session_raw_scan(other)

    with messages.override_raw_scan(session, None):
        assert messages._read_session_raw_scan(session) is None


def test_async_seam_uses_the_scan_service_not_the_sync_reader(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    session = _session("s1")
    injected = object()

    def fail(path: object) -> object:
        raise AssertionError("the async seam must not scan inline")

    class _Service:
        async def scan(self, path: object, *, priority: str = "foreground") -> object:
            assert priority == "foreground"
            return injected

    monkeypatch.setattr(reader, "scan_transcript_file", fail)
    monkeypatch.setattr(reader, "get_scan_service", lambda: _Service())

    assert asyncio.run(reader._read_raw_transcript_scan_async(session)) is injected
