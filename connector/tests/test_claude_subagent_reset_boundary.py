"""A SUBAGENT assistant frame must not gate the MAIN chain's stream (2026-10-15).

Corrected root cause (task handoff, superseding the earlier "id-less
``message_start``" theory, which the live dump refuted: 1,023,595 frames, 1146
``message_start``, ZERO without an id).

``drive_turn`` publishes an assistant frame and then, to close the streamed
message, calls ``stream_accumulator.reset()`` (turns/lifecycle.py). That reset
had NO main-chain guard: EVERY assistant frame with text ran it, a background
subagent's aggregated frame included. ``reset()`` nulls ``partial_message_id``,
so the MAIN message still streaming loses its identity; every subsequent main
thinking/text delta then hits the ``partial_message_id is None`` drop gate and
is thrown away, frame by frame, until the main chain's next ``message_start``.
The same missing guard set ``emitted_final_assistant_content`` from a subagent
frame, which suppresses the main turn's result-text fallback and loses the reply
outright.

The neighbouring ``assistant_usage`` block (lifecycle.py, a few lines above the
reset) DOES guard on ``frame_parent_tool_use_id is None`` -- the reset and the
flag simply never got the same treatment. This file pins the gap:

  * red on the pre-fix tree: the main delta after the subagent frame is lost,
    and the result-only reply is suppressed;
  * green once the guard is main-chain only.

A companion case pins the ADJACENT path SETTLED (it is NOT a second fix): a
parented (sidechain) ``message_start`` DOES set ``partial_message_id`` by
design -- that write is what mints a subagent's streamed rows under its own id
so they fold into the capsule. It must not be "fixed" away.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_compact_ghost import _runtime_with, _single_client_factory
from test_claude_runtime import (
    StreamEvent,
    _FakeClaudeClient,
    _RecordingHost,
    _ScheduledClaudeClient,
)

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.runtimes.claude.timeline.stream import ClaudeStreamAccumulator

DISPATCH_TUID = "call_00_subagent_reset_probe"


class _MainStreamInterruptedBySubagentFrameClient(_ScheduledClaudeClient):
    """Main thinking streams; a parented assistant frame arrives mid-stream.

    The subagent frame is an aggregated ``AssistantMessage`` carrying text and
    ``parent_tool_use_id`` -- the shape the live incident showed landing 0.42s
    before the drop began (a sidechain reply routed through the main turn loop's
    ``claude.turn.assistant`` path).
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        frames = [
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={"type": "message_start", "message": {"id": "msg_main"}},
            ),
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={
                    "type": "content_block_delta", "index": 0,
                    "delta": {"type": "thinking_delta", "thinking": "MAIN-1 "},
                },
            ),
            # A background subagent's aggregated assistant frame, parented.
            SimpleNamespace(
                type="assistant", uuid="a_sub", session_id=self.native_id,
                parent_tool_use_id=DISPATCH_TUID,
                message={"id": "msg_sub", "role": "assistant",
                         "content": [{"type": "text", "text": "sub reply"}]},
            ),
            # The MAIN chain keeps streaming the SAME message.
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={
                    "type": "content_block_delta", "index": 0,
                    "delta": {"type": "thinking_delta", "thinking": "MAIN-2"},
                },
            ),
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={
                    "type": "content_block_delta", "index": 1,
                    "delta": {"type": "text_delta", "text": "MAIN-TEXT"},
                },
            ),
            SimpleNamespace(
                type="assistant", uuid="a_main", session_id=self.native_id,
                parent_tool_use_id=None,
                message={"id": "msg_main", "role": "assistant",
                         "content": [{"type": "text", "text": "main reply"}]},
            ),
            SimpleNamespace(type="result", session_id=self.native_id),
        ]
        for frame in frames:
            await self.incoming.put(frame)


def _main_thinking(host: _RecordingHost, item_id: str) -> list[Any]:
    return [
        item
        for item in host.timeline_item_upserts
        if (item.content or {}).get("blockType") == "thinking"
        and dict(getattr(item, "source", {}) or {}).get("itemId") == item_id
    ]


def test_subagent_assistant_frame_does_not_reset_the_main_stream() -> None:
    """RED before the fix: the main delta after the subagent frame is dropped.

    Without the main-chain guard on ``reset()``, the parented assistant frame
    nulls ``partial_message_id``; the MAIN-2 thinking delta that follows is
    dropped ("dropping Claude stream thinking without message_start id"). With
    the guard, the main message survives and its final row carries both halves.
    """

    async def run() -> None:
        client = _MainStreamInterruptedBySubagentFrameClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("mixreset", None, "go")
            await asyncio.wait_for(runtime._sessions["mixreset"].active_task, 5)

            rows = _main_thinking(host, "msg_main")
            assert rows, "the main thinking row was never published"
            final = rows[-1]
            assert final.status == "done"
            # The reset must not have split MAIN-1 off and dropped MAIN-2.
            assert final.content.get("text") == "MAIN-1 MAIN-2", (
                "the main message was reset mid-stream by a subagent frame: "
                f"{[(r.status, r.content.get('text')) for r in rows]}"
            )
        finally:
            await runtime.stop()

    asyncio.run(run())


def test_subagent_assistant_frame_does_not_drop_main_text() -> None:
    """The mirror on the body text: the main text delta must survive too."""

    async def run() -> None:
        client = _MainStreamInterruptedBySubagentFrameClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("mixreset2", None, "go")
            await asyncio.wait_for(runtime._sessions["mixreset2"].active_task, 5)
            text_rows = [
                item
                for item in host.timeline_item_upserts
                if (item.source or {}).get("event") == "claude.turn.assistant.partial"
                and dict(getattr(item, "source", {}) or {}).get("itemId") == "msg_main"
            ]
            assert text_rows, "no main text partial was published"
            assert any(
                (r.content or {}).get("text") == "MAIN-TEXT" for r in text_rows
            ), f"the main text delta was dropped: {[r.content for r in text_rows]}"
        finally:
            await runtime.stop()

    asyncio.run(run())


class _SubagentFrameThenResultReplyClient(_ScheduledClaudeClient):
    """A subagent assistant frame lands, then the turn's reply is a result only.

    Same root as the reset gap, one flag over: the pre-fix code set
    ``emitted_final_assistant_content = True`` for ANY assistant frame with
    text, the subagent's included. That flag suppresses the result-text
    fallback, so when this turn's own reply never arrives as a separate
    assistant frame (`_publish_result_text` is the whole point of the flag) the
    SUBAGENT's frame silently swallows the main reply -- the answer never
    reaches the timeline at all.
    """

    async def _complete_query(self, prompt: str) -> None:
        await _FakeClaudeClient.query(self, prompt)
        frames = [
            StreamEvent(
                uuid="u1", session_id=self.native_id,
                event={"type": "message_start", "message": {"id": "MAIN"}},
            ),
            SimpleNamespace(
                type="assistant", uuid="s1", session_id=self.native_id,
                parent_tool_use_id=DISPATCH_TUID,
                message={"id": "SUB", "role": "assistant",
                         "content": [{"type": "text", "text": "sub reply"}]},
            ),
            # The turn's own reply arrives ONLY as the result envelope.
            SimpleNamespace(
                type="result", session_id=self.native_id,
                result="THE MAIN REPLY", result_type="success",
            ),
        ]
        for frame in frames:
            await self.incoming.put(frame)


def test_subagent_frame_does_not_suppress_the_main_result_reply() -> None:
    """RED before the fix: the main reply is lost to a subagent frame."""

    async def run() -> None:
        client = _SubagentFrameThenResultReplyClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            await runtime.start_turn("flagturn", None, "go")
            await asyncio.wait_for(runtime._sessions["flagturn"].active_task, 5)
            result_rows = [
                item
                for item in host.timeline_item_upserts
                if (item.source or {}).get("event") == "claude.turn.result"
            ]
            assert result_rows, (
                "the subagent frame suppressed the main turn's result reply"
            )
            assert (result_rows[-1].content or {}).get("text") == "THE MAIN REPLY"
        finally:
            await runtime.stop()

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Adjacent path, SETTLED (not a second fix): a parented (sidechain)
# StreamEvent message_start DOES set ``partial_message_id`` -- by design. That
# write is what mints a subagent's streamed rows under its own message id so
# they fold into the dispatch capsule (see
# ``test_claude_subagent_progress.py::test_subagent_text_partial_keeps_its_card``,
# which asserts a subagent text partial's ``itemId``). So it is NOT the same
# root cause as the reset gap and must NOT be "fixed" by ignoring sidechain
# message_starts -- that would break capsule minting. This test pins the
# designed behaviour so a future reader does not mistake it for the bug.
# ---------------------------------------------------------------------------


def test_parented_stream_message_start_sets_identity_by_design() -> None:
    """A parented ``message_start`` opens a subagent message -- deliberately.

    The accumulator is SHARED between the main chain and subagent streams (its
    ``_note_thinking_origin`` comments say so: "a subagent's stream leaking into
    the parent message's stream"). A subagent frame's ``message_start`` setting
    ``partial_message_id`` to the subagent's id is the mechanism that publishes
    the subagent's streamed thinking/text rows under that id (folded into the
    capsule via the per-index parent mark). The drop incident is the RESET gap,
    not this -- the live dump carried zero sidechain StreamEvents, and removing
    this write would strand the subagent's rows.

    NOTE (open hazard, not a defect): if a parented ``message_start`` ever
    arrives mid-stream while the main chain has a live identity, it WOULD
    retarget that identity (the same shared-accumulator hazard the ``reset()``
    guard closes on its side). No red test exists because no such frame appears
    in the captured wire; the turn-end ``reset_causes`` observation is the
    safety net if one ever does.
    """

    session = ClaudeSession(session_id="s_probe", external_session_id="e_probe")
    acc = ClaudeStreamAccumulator()
    proj = ClaudeMessageProjector()

    def ev(event: dict[str, Any], parent: str | None = None) -> StreamEvent:
        kwargs: dict[str, Any] = {"uuid": "u", "session_id": "e_probe", "event": event}
        if parent is not None:
            kwargs["parent_tool_use_id"] = parent
        return StreamEvent(**kwargs)

    acc.item_from_stream_event(
        session=session, turn_id="t",
        message=ev({"type": "message_start", "message": {"id": "MAIN"}}),
        projector=proj,
    )
    acc.item_from_stream_event(
        session=session, turn_id="t",
        message=ev(
            {"type": "message_start", "message": {"id": "SUB"}}, parent=DISPATCH_TUID
        ),
        projector=proj,
    )
    # The subagent's message_start opens ITS message: identity follows it, so
    # its own (parented) deltas mint SUB rows. This is intended.
    assert acc.partial_message_id == "SUB"
