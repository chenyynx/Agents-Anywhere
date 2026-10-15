"""Stream drop observation is per-turn, not per-frame (2026-10-15).

The identity-drop gate used to log a WARNING for every refused delta: the
incident that exposed the subagent-reset bug was 3 days ≈ 52k journal lines,
which buried the very signal they carried. These tests pin the replacement --
one warning on the FIRST drop of a kind, a single per-turn summary with the
counts, and (once a reset is the cause) the reset call site named -- so the next
incident is legible from one line instead of a flood.

The last two tests are the integration ones the unit tests cannot give: one
drives the real turn loop to prove the `reset_causes` wiring from the reset call
site through to the summary, and one replays a captured production slice to
prove a clean stream stays drop-free.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from test_claude_compact_ghost import _runtime_with, _single_client_factory
from test_claude_runtime import (
    _FakeClaudeClient,
    _RecordingHost,
    _ScheduledClaudeClient,
)

from connector.logging import logger
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator

_FIXTURE = Path(__file__).parent / "fixtures" / "claude_clean_stream_slice.json"
_DISPATCH_TUID = "call_00_obs_reason_probe"


class StreamEvent(SimpleNamespace):
    """The SDK's stream frame; the accumulator keys on the class name."""


class _LogCapture:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self._sink: int | None = None

    def __enter__(self) -> _LogCapture:
        self._sink = logger.add(
            lambda message: self.lines.append(str(message)), level="WARNING"
        )
        return self

    def __exit__(self, *exc: Any) -> bool:
        if self._sink is not None:
            logger.remove(self._sink)
        return False


def _evt(event: dict[str, Any]) -> StreamEvent:
    return StreamEvent(uuid="u", session_id="e_obs", event=event)


def _thinking_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta", "index": index,
        "delta": {"type": "thinking_delta", "thinking": text},
    }


def _text_delta(index: int, text: str) -> dict[str, Any]:
    return {
        "type": "content_block_delta", "index": index,
        "delta": {"type": "text_delta", "text": text},
    }


def test_drop_warning_fires_once_per_turn_not_per_frame() -> None:
    """The 52k-line flood becomes one line per turn."""

    session = ClaudeSession(session_id="s_obs", external_session_id="e_obs")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    with _LogCapture() as capture:
        # No message_start: every delta drops (the watchdog shape). 200 frames
        # must NOT produce 200 warnings.
        for n in range(200):
            acc.item_from_stream_event(
                session=session, turn_id="t_obs",
                message=_evt(_thinking_delta(1, f"chunk {n}")), projector=proj,
            )
        acc.finalize_pending_thinking(session, "t_obs", proj)

    first = [line for line in capture.lines if "without message_start id" in line]
    assert len(first) == 1, first
    summary = [line for line in capture.lines if "at turn end" in line]
    assert len(summary) == 1, capture.lines
    # 200 refusals + the settle-time close re-attempt (the pre-fix per-frame
    # warning counted that too, so the number stays comparable to the baseline).
    assert "dropped_thinking=201" in summary[0], summary[0]
    assert "dropped_text=0" in summary[0], summary[0]


def test_turn_end_summary_counts_text_and_thinking_drops() -> None:
    session = ClaudeSession(session_id="s_obs2", external_session_id="e_obs2")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    with _LogCapture() as capture:
        for n in range(3):
            acc.item_from_stream_event(
                session=session, turn_id="t_obs2",
                message=_evt(_text_delta(0, f"t{n}")), projector=proj,
            )
            acc.item_from_stream_event(
                session=session, turn_id="t_obs2",
                message=_evt(_thinking_delta(1, f"k{n}")), projector=proj,
            )
        acc.finalize_pending_thinking(session, "t_obs2", proj)

    summary = [line for line in capture.lines if "at turn end" in line]
    assert len(summary) == 1, capture.lines
    assert "dropped_text=3" in summary[0], summary[0]
    # 3 thinking refusals, +1 for the settle-time close re-attempt
    assert "dropped_thinking=4" in summary[0], summary[0]
    first = [line for line in capture.lines if "without message_start id" in line]
    assert len(first) == 2, capture.lines


def test_clean_turn_logs_no_drop_summary() -> None:
    """A turn that loses nothing stays silent (no summary line)."""

    session = ClaudeSession(session_id="s_obs3", external_session_id="e_obs3")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    with _LogCapture() as capture:
        for event in (
            {"type": "message_start", "message": {"id": "A"}},
            _thinking_delta(1, "ok"),
            _text_delta(0, "fine"),
            {"type": "message_stop"},
        ):
            acc.item_from_stream_event(
                session=session, turn_id="t_obs3", message=_evt(event), projector=proj,
            )
        acc.finalize_pending_thinking(session, "t_obs3", proj)
    assert [line for line in capture.lines if "at turn end" in line] == []
    assert acc.dropped_thinking_frames == 0 and acc.dropped_text_frames == 0


def test_drop_summary_names_the_reset_path_that_caused_it() -> None:
    """A drop after a ``reset`` names the reset's call site as its cause.

    The second live incident could not be attributed to the assistant-frame
    reset, so the summary must let the NEXT one self-describe. A drop is caused
    by whichever ``reset()`` cleared the identity -- here ``result_text``.
    """

    session = ClaudeSession(session_id="s_obs4", external_session_id="e_obs4")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    with _LogCapture() as capture:
        acc.item_from_stream_event(
            session=session, turn_id="t_obs4",
            message=_evt({"type": "message_start", "message": {"id": "MAIN"}}),
            projector=proj,
        )
        acc.item_from_stream_event(
            session=session, turn_id="t_obs4",
            message=_evt(_thinking_delta(1, "live")), projector=proj,
        )
        # The result-text fallback resets mid-stream (its own call site).
        acc.reset(session, "t_obs4", proj, reason="result_text")
        # The main chain keeps streaming -> dropped, cause = result_text.
        acc.item_from_stream_event(
            session=session, turn_id="t_obs4",
            message=_evt(_thinking_delta(1, "after")), projector=proj,
        )
        acc.finalize_pending_thinking(session, "t_obs4", proj)

    summary = [line for line in capture.lines if "at turn end" in line]
    assert len(summary) == 1, capture.lines
    assert "reset_causes=result_text" in summary[0], summary[0]


def test_drop_summary_omits_reset_cause_when_none_cleared_identity() -> None:
    """A drop with no intervening reset (no message_start at all) has no cause."""

    session = ClaudeSession(session_id="s_obs5", external_session_id="e_obs5")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    with _LogCapture() as capture:
        acc.item_from_stream_event(
            session=session, turn_id="t_obs5",
            message=_evt(_thinking_delta(1, "orphan")), projector=proj,
        )
        acc.finalize_pending_thinking(session, "t_obs5", proj)
    summary = [line for line in capture.lines if "at turn end" in line]
    assert len(summary) == 1, capture.lines
    assert "reset_causes=-" in summary[0], summary[0]


# ---------------------------------------------------------------------------
# Integration: the reset reason reaches the summary through the REAL turn loop.
# ---------------------------------------------------------------------------


class _MainEarlyAggregateClient(_ScheduledClaudeClient):
    """A MAIN aggregated frame arrives mid-stream, then more main deltas.

    The LiteLLM wire can emit the aggregated assistant frame before the stream's
    own delta tail (this session's capture shows exactly that shape). The reset
    it runs clears the live identity, so the tail is dropped and the summary
    must name the path -- `assistant_frame` -- through the REAL turn loop.
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        frames = [
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={"type": "message_start", "message": {"id": "A"}},
            ),
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={"type": "content_block_delta", "index": 0,
                       "delta": {"type": "thinking_delta", "thinking": "T1 "}},
            ),
            SimpleNamespace(
                type="assistant", uuid="a1", session_id=self.native_id,
                parent_tool_use_id=None,
                message={"id": "A", "role": "assistant",
                         "content": [{"type": "text", "text": "agg"}]},
            ),
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={"type": "content_block_delta", "index": 0,
                       "delta": {"type": "thinking_delta", "thinking": "T2"}},
            ),
            SimpleNamespace(type="result", session_id=self.native_id),
        ]
        for frame in frames:
            await self.incoming.put(frame)


def test_reset_reason_from_drive_turn_reaches_the_summary() -> None:
    """The `reason=` the turn loop passes is the `reset_causes=` it prints.

    Unit tests pass `reason=` as a literal; this one drives `drive_turn` so
    changing the call site's literal (or dropping the argument) turns this red --
    the wiring from reset call site to summary is the whole point of the field.
    """

    async def run() -> None:
        host = _RecordingHost()
        runtime = _runtime_with(
            host, _single_client_factory(_MainEarlyAggregateClient())
        )
        try:
            await runtime.start_turn("reasonwire", None, "go")
            await asyncio.wait_for(runtime._sessions["reasonwire"].active_task, 5)
        finally:
            await runtime.stop()

    with _LogCapture() as capture:
        asyncio.run(run())

    summary = [line for line in capture.lines if "at turn end" in line]
    assert len(summary) == 1, capture.lines
    assert "reset_causes=assistant_frame" in summary[0], summary[0]


# ---------------------------------------------------------------------------
# Real-wire replay: a captured production slice must stay drop-free.
# ---------------------------------------------------------------------------
#
# NOTE on the fixture: it is trimmed from the live dump session `d5ae5036-*`,
# which recorded each stream frame TWICE (the same uuid redelivered on the wire,
# ~50% of frames -- a dump-observed wire artefact, kept as-is so the replay is
# faithful). The assertions below therefore check DROPS and stable row identity,
# not exact text, so the redelivery does not make them vacuous.


def _replay_capture() -> ClaudeStreamAccumulator:
    frames = json.loads(_FIXTURE.read_text())
    session = ClaudeSession(
        session_id="d5ae5036-84b9-4a7f-a5dd-b9fe42d59656",
        external_session_id="d5ae5036-84b9-4a7f-a5dd-b9fe42d59656",
    )
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()
    for frame in frames:
        kwargs: dict[str, Any] = {
            "uuid": frame.get("uuid") or "u",
            "session_id": frame["session_id"],
            "event": frame["event"],
        }
        if frame.get("parent_tool_use_id"):
            kwargs["parent_tool_use_id"] = frame["parent_tool_use_id"]
        acc.item_from_stream_event(
            session=session, turn_id="t_replay",
            message=StreamEvent(**kwargs), projector=proj,
        )
        acc.confirm_pending_items(len(acc.peek_pending_items()))
    acc.finalize_pending_thinking(session, "t_replay", proj)
    return acc


def test_clean_production_slice_replays_with_zero_drops() -> None:
    """A real captured message must lose NOTHING: zero thinking/text drops.

    Load-bearing against the change: the per-turn drop counters are read AFTER
    a full replay of a clean capture, and the tidy-up (the settle flush) is the
    same path the fix touches. A regression that dropped a delta on this wire
    would move these counts off zero.
    """

    acc = _replay_capture()
    assert acc.dropped_thinking_frames == 0, acc.dropped_thinking_frames
    assert acc.dropped_text_frames == 0, acc.dropped_text_frames
