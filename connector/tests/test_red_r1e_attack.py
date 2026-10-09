"""R1 round-5 attacks — the c1e repairs on `d5db6422` (fix `c1f`).

Round 5 verifies the two R4 repairs and attacks what they introduced: the
page-1 seam seeding `library_extent` (which makes `beyond_extent` reachable a
cycle earlier) and the wording gate on bare-string user rows.

The round's outcome lands in this file and two product files:

* R1e-1 — the seed's early exit turns a two-cycle transient hole into a
  permanent sleep with residue past page 1. Kept as a RECORDED TRADE (bounded
  load ⇄ the R4-1 forever-walk), not fixed; the two shapes stay pinned below
  and the trade is annotated at the seed in `runtime_sync.py`.
* R1e-2 — the `toolUseResult` branch admitted any row carrying the metadata,
  while the message view decides on its `status` first: a sync Agent call's
  result frame was a launch receipt to the raw scan. Repaired (c1f): the
  branch now runs the same judgment (`is_async_agent_receipt`) over the
  metadata and the row's own text. The attack is flipped into its guard
  below, keeping the attack's own setup.
* R1e-3 — the `_is_receipt_row` docstring's "one rule / same boundary" claim
  about the message view; corrected to "same wording criterion, wider
  channel" in `subagent_oracle.py`.
* R1e-4 — the extent's "kept across a sleep ... wakes up past the end then
  re-seeks" comment promised a wake-up re-seek the activation path cannot
  deliver; corrected in `runtime_sync.py` and pinned by the fresh-state
  control below.

Everything else — the seed's guards (`..._control_a_failed_page_one_read_*`,
`..._control_a_complete_page_*`, `..._control_report_mode_*`), the
lower-bound argument (`..._control_the_seam_seed_is_a_lower_bound_*`), and
the two hollow-green proofs (the in-test neutralization of the seed and the
inline pre-c1e predicate) — is kept verbatim.
"""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import _HistorySdk, _RecordingHost, _runtime
from test_session_rotation import (
    ROTATION_STATE_KEY,
    MarkedPagedRuntime,
    PagedRuntime,
    StatefulRecordingHost,
    _meta,
    _runner,
)
from test_task_closure import (
    T_AGE_BOUND,
    TASK_ID,
    _dispatch_message,
    _fresh_file,
    _old_receipt_raw_lines,
    _oracle,
    _receipt_message,
    _session,
)

from connector.runtimes.claude.sessions.reader import (
    SessionListPage,
    _history_items_from_messages,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    _is_receipt_row,
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline.agent_calls import is_async_agent_receipt
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
)

NOW = 1_791_457_800.0


def _iso(ms: int) -> str:
    return (
        datetime.fromtimestamp(ms / 1000, tz=UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _sdk_session(index: int) -> Any:
    return SimpleNamespace(
        session_id=f"claude_{index:03d}",
        summary=f"S{index}",
        last_modified=1_789_000_000_000 - index,
        file_size=123,
        cwd="/repo",
    )


# ---------------------------------------------------------------------------
# ATTACK A — the seeded extent makes a transient hole a permanent sleep
# ---------------------------------------------------------------------------


def test_R1e_P2_a_two_cycle_hole_sleeps_the_sweep_with_residue_beyond(
    monkeypatch,
) -> None:
    """RECORDED TRADE (R1e-1, not a defect): the extent seed turns one
    verified empty window at the seam into `past_library_extent`, and the
    next empty window into a disarm.

    Before c1e that same shape kept walking (R4-1), so the sweep eventually
    reached whatever was beyond. Now, if the library is transiently short for
    exactly the two cycles the ladder reads it — page 1 full at the seam, the
    seam window empty, then content back — the sweep sleeps and never looks
    again: the page-1 signal has been consumed, so nothing re-arms it. The
    residue past page 1 is then unreached until the next projection bump.

    This is the deliberate trade the tree makes (bounded load for a new
    early-exit route; the exchange is annotated at the seed in
    `runtime_sync.py`); the shape needs an exactly-full page plus a transient
    spanning exactly two cycles, which is why it is filed P2 rather than P1.
    The test pins the trade's shape for the record — it is not a defect
    report."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime()
    # Page 1 is exactly full: complete=False, seam=100 (the R4-1 shape), with
    # one outdated session to open the sweep.
    runtime.page_one = SessionListPage(
        tuple(
            _meta(i, projection_outdated=(i == 0))
            for i in range(SESSION_ROTATION_PAGE_SIZE)
        ),
        history_scanned=SESSION_ROTATION_PAGE_SIZE,
    )
    # The hole: the window at the seam answers empty for the first cycles.
    runtime.rotation_pages = {SESSION_ROTATION_FIRST_OFFSET: ()}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(4):
        asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    assert state["active"] is False, "sweep did not sleep; finding does not reproduce"
    # The page-1 signal is consumed from here on: nothing can re-arm the sweep.
    runtime.page_one = SessionListPage(
        tuple(_meta(0) for _ in range(SESSION_ROTATION_PAGE_SIZE)),
        history_scanned=SESSION_ROTATION_PAGE_SIZE,
    )

    # The library comes back with residue — and the sweep never looks again.
    # Only ROTATION reads count here: page 1 is fetched every cycle by design,
    # sweep or no sweep.
    before = [cursor for cursor in runtime.cursors if cursor is not None]
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(1001, requires_sync=True),)
    }
    for _cycle in range(10):
        asyncio.run(runner.sync_existing_once())

    after = [cursor for cursor in runtime.cursors if cursor is not None]
    assert after == before, "the sweep read a window while asleep"
    assert "sess_1001" not in {
        notice["params"].get("sessionId")
        for notice in notifications
        if isinstance(notice.get("params"), dict)
    }


def test_R1e_control_the_hole_shape_really_is_new(monkeypatch) -> None:
    """CONTROL for the claim that c1e introduced this route: with the extent
    seed absent (a page that reports no seam), the same transient shape keeps
    the sweep walking instead of sleeping — which is the R4-1 behavior c1e
    replaced."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    # A plain page: no seam marker, so nothing seeds the extent.
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {SESSION_ROTATION_FIRST_OFFSET: ()}
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    for _cycle in range(6):
        asyncio.run(runner.sync_existing_once())

    assert host.state[ROTATION_STATE_KEY]["active"] is True


# ---------------------------------------------------------------------------
# ATTACK B — the seed's guards
# ---------------------------------------------------------------------------


def test_R1e_control_a_failed_page_one_read_seeds_nothing(monkeypatch) -> None:
    """CONTROL: a page-1 read that raised must not seed the extent, exactly as
    it must not start the ladder at a seam it did not prove."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime()
    runtime.page_one = SessionListPage(
        (_meta(0, projection_outdated=True),),
        history_scanned=SESSION_ROTATION_PAGE_SIZE,
        read_failed=True,
    )
    runtime.rotation_pages = {SESSION_ROTATION_FIRST_OFFSET: ()}
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    assert state["libraryExtent"] == 0, state
    assert state["active"] is True


def test_R1e_control_the_seam_seed_is_a_lower_bound_of_the_library() -> None:
    """CONTROL, proving the seed cannot manufacture a false end: page 1's seam
    is the number of rows the SDK actually returned, so for any library longer
    than a page it is strictly below the library's true length. The seed can
    therefore only make `beyond_extent` fire LATER than the truth, never
    earlier."""

    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(250)])
    runtime = _runtime(host=host, sdk=sdk)

    page_one = asyncio.run(runtime.list_sessions(limit=SESSION_ROTATION_PAGE_SIZE))

    # 250 sessions on disk, but page 1 exposes at most the page size.
    assert len(sdk.sessions) == 250
    assert page_one.history_scanned == SESSION_ROTATION_PAGE_SIZE
    # The window at the seam is non-empty, so the walk continues normally; the
    # seed alone can never conclude a library that has content past the seam.
    window = asyncio.run(
        runtime.list_sessions(
            limit=SESSION_ROTATION_PAGE_SIZE,
            cursor=str(SESSION_ROTATION_FIRST_OFFSET),
        )
    )
    assert len(window) == SESSION_ROTATION_PAGE_SIZE
    assert window.history_scanned > 0


def test_R1e_control_a_stale_high_extent_still_converges(monkeypatch) -> None:
    """CONTROL: a persisted extent above the real library is harmless — the
    ladder concludes on the ordinary proof (`circle_windows`) long before
    `beyond_extent` could matter, so a stale high-water mark cannot make the
    sweep walk further."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101),),
        SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE: (_meta(201),),
    }
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": SESSION_ROTATION_FIRST_OFFSET,
        "libraryExtent": 5000,  # stale, far above the real end
    }
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())  # 100
    asyncio.run(runner.sync_existing_once())  # 200
    asyncio.run(runner.sync_existing_once())  # 300 -> empty, proven by circle_windows

    assert host.state[ROTATION_STATE_KEY]["active"] is False
    # It stopped at the real end, not at the stale extent.
    assert max(int(c) for c in runtime.cursors if c is not None) == (
        SESSION_ROTATION_FIRST_OFFSET + 2 * SESSION_ROTATION_PAGE_SIZE
    )


def test_R1e_control_the_extent_does_not_survive_an_activation() -> None:
    """RECORDED MISMATCH (not a defect): the state docstring says the extent is
    kept across a sleep so "a ladder that wakes up past the end then re-seeks
    at once instead of spending a cooldown learning the same thing again", but
    activation builds a FRESH `SessionRotationState`, which resets the extent
    to 0 — and the ladder starts at `first_offset`, not at a persisted
    position. The kept value is therefore never read in that scenario.

    Pinned as documentation drift: if a future change makes the ladder resume
    from a persisted offset, this is the assertion that will notice."""

    from connector.server.runtime_sync import SessionRotationState

    fresh = SessionRotationState(active=True, offset=SESSION_ROTATION_FIRST_OFFSET)
    assert fresh.library_extent == 0


# ---------------------------------------------------------------------------
# ATTACK C — the new wording gate
# ---------------------------------------------------------------------------


def _receipt_prefixed_line(at_ms: int, *, body_prefix: str = "") -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": f"r-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "user",
                "content": (
                    f"{body_prefix}Async agent launched successfully.\n"
                    f"agentId: {TASK_ID} (internal ID)"
                ),
            },
        }
    )


def test_R1e_control_the_prefix_must_open_the_body() -> None:
    """CONTROL: the gate is a prefix test on the lstripped body, so a quote
    marker or any other leading character keeps the row out."""

    ms = int(NOW * 1000)
    assert _is_receipt_row(json.loads(_receipt_prefixed_line(ms))) is True
    # Leading whitespace is stripped before the test.
    assert (
        _is_receipt_row(json.loads(_receipt_prefixed_line(ms, body_prefix="  \n ")))
        is True
    )
    # A quote marker is not whitespace: the row is refused.
    assert (
        _is_receipt_row(json.loads(_receipt_prefixed_line(ms, body_prefix="> ")))
        is False
    )
    # A prefix in the middle of the body is refused too.
    quoted = json.loads(_receipt_prefixed_line(ms))
    quoted["message"]["content"] = (
        "here is what it said: Async agent launched successfully.\n"
        f"agentId: {TASK_ID}"
    )
    assert _is_receipt_row(quoted) is False


def test_R1e_P2_a_sync_agents_result_row_is_refused_as_a_receipt() -> None:
    """GUARD (was the R1e-2 attack): the `toolUseResult` branch no longer
    admits the row on the mere PRESENCE of the metadata — it now runs the
    message view's own judgment (`is_async_agent_receipt`) over the metadata
    and the row's text, so the two surfaces agree on the same frame.

    The attack: a SYNCHRONOUS Agent call's result — the frame the message
    view treats as the call's outcome, hence a card that is `done`/`failed` —
    was a launch receipt to the raw scan whenever its body carried the id,
    because that branch returned True unconditionally. The repair (c1f): an
    explicit non-`async_launched` status is the call's OUTCOME and refuses
    the row; `async_launched` still admits (the true launch receipt); a
    status-less frame falls back to the body's wording, exactly as the
    message view reads it. The F5 shapes are untouched — their control below
    still lands."""

    ms = int(NOW * 1000)
    row = json.loads(_receipt_prefixed_line(ms))
    row["toolUseResult"] = {"status": "completed"}
    row["message"]["content"] = [
        {
            "type": "tool_result",
            "tool_use_id": "call_1",
            "content": [{"type": "text", "text": f"done, agentId: {TASK_ID}"}],
        }
    ]

    # The raw gate refuses it now (R1e-2)...
    assert _is_receipt_row(row) is False
    # ...and the scan records no anchor from it.
    assert scan_raw_transcript((json.dumps(row),)).receipt_times_ms == {}
    # ...while the message view refuses the very same metadata — the two
    # surfaces agree on the frame again.
    assert is_async_agent_receipt({"status": "completed"}, "done") is False
    # The only metadata the message view calls a receipt:
    assert is_async_agent_receipt({"status": "async_launched"}, None) is True
    # ...and the true launch receipt — the same row with the launch status —
    # is still admitted, anchor and all.
    launch = json.loads(_receipt_prefixed_line(ms))
    launch["toolUseResult"] = {"status": "async_launched"}
    launch["message"]["content"] = [
        {
            "type": "tool_result",
            "tool_use_id": "call_1",
            "content": [
                {
                    "type": "text",
                    "text": (
                        "Async agent launched successfully.\n"
                        f"agentId: {TASK_ID} (internal ID)"
                    ),
                }
            ],
        }
    ]
    assert _is_receipt_row(launch) is True
    assert (
        scan_raw_transcript((json.dumps(launch),)).receipt_times_ms[TASK_ID] == ms
    )


def test_R1e_P2_a_pasted_receipt_body_is_admitted_where_the_view_would_not() -> None:
    """ATTACK (P2) on the fixer's DECLARED boundary, and the asymmetry inside
    the claim "same boundary as the message view".

    A human pasting the engine's receipt text verbatim into their own message
    sails through the raw gate — which the fixer declared and accepted. What
    the declaration does not say is that the message view would NOT admit it:
    every message-view call site passes a *tool_result* channel and (for the
    fold) additionally requires a known `Agent` call, whereas the raw gate
    reads the user row's own text with no call requirement. The raw surface is
    therefore strictly looser for this shape, not "the same boundary"."""

    ms = int(NOW * 1000)
    pasted = json.loads(_receipt_prefixed_line(ms))

    assert _is_receipt_row(pasted) is True
    # The message view has no channel that would read a plain user text as a
    # receipt: its body argument is always a tool_result's text.
    assert is_async_agent_receipt(None, pasted["message"]["content"]) is True
    # ...but it is only ever called with a call in hand:
    import inspect

    from connector.runtimes.claude.timeline import messages as messages_module

    source = inspect.getsource(messages_module)
    assert "call.tool_name == \"Agent\"" in source


def test_R1e_control_a_human_receipt_paste_still_defers_the_ceiling(
    monkeypatch,
) -> None:
    """The consequence of the declared boundary, pinned end to end: a dead
    task's ceiling is deferred by a human message that opens with the engine's
    receipt wording. Filed as 记档 — the fixer declared it, and no reliable
    marker distinguishes the two rows."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)
    paste_ms = int((NOW - 600.0) * 1000)
    raw_lines = (_old_receipt_raw_lines(old_ms)[0], _receipt_prefixed_line(paste_ms))

    scan = scan_raw_transcript(raw_lines)
    assert scan.receipt_times_ms[TASK_ID] == paste_ms

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=raw_lines,
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "running"


def test_R1e_control_the_f5_bare_receipt_still_lands() -> None:
    """CONTROL: the shape the gate exists to keep — the engine's bare
    `tool_result` receipt, and the prefix-opening bare body — still arrives."""

    ms = int(NOW * 1000)
    assert _is_receipt_row(json.loads(_receipt_prefixed_line(ms))) is True
    tool_result_row = json.loads(_receipt_prefixed_line(ms))
    tool_result_row["message"]["content"] = [
        {
            "type": "tool_result",
            "tool_use_id": "call_1",
            "content": [{"type": "text", "text": f"Async agent launched\nagentId: {TASK_ID}"}],
        }
    ]
    assert _is_receipt_row(tool_result_row) is True

# ---------------------------------------------------------------------------
# HOLLOW-GREEN CHECK — do the flipped guards actually depend on the fixes?
# ---------------------------------------------------------------------------


def test_R1e_the_R4_1_guard_is_not_hollow_green(monkeypatch) -> None:
    """With the c1e extent seed neutralized, the R4-1 shape reproduces: the
    exactly-one-page library walks windows forever instead of sleeping. That
    is what makes the flipped guard (`..._lets_the_sweep_sleep`) evidence for
    the fix rather than a test that would pass either way."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    # Neutralize the seed in the runner's own namespace — an in-test patch, no
    # product code touched.
    monkeypatch.setattr(
        "connector.server.runtime_sync._page_reported_seam", lambda page: None
    )

    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(100)])
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    for _cycle in range(12):
        asyncio.run(runner.sync_existing_once())

    state = host.sync_states.get(ROTATION_STATE_KEY) or {}
    # The pre-c1e behavior: never sleeps, and keeps paying a window read.
    assert state.get("active") is True
    assert len([c for c in sdk.list_calls if c["offset"] > 0]) >= 9


def test_R1e_the_R4_2_guard_is_not_hollow_green() -> None:
    """With the pre-c1e predicate, the same user row the flipped guard refuses
    is admitted — so that guard is evidence for the wording gate, not a test
    that passes because the row was never a receipt."""

    ms = int((NOW - 600.0) * 1000)
    row = json.loads(_user_mention_line_for_r1e(ms))

    def _pre_c1e_is_receipt_row(candidate: Any) -> bool:
        # The c1e parent's logic, inline: any user row with a string body.
        if candidate.get("type") != "user":
            return False
        if isinstance(candidate.get("toolUseResult"), dict):
            return True
        content = candidate.get("message", {}).get("content")
        if isinstance(content, str):
            return True
        return isinstance(content, list) and any(
            isinstance(block, dict) and block.get("type") == "tool_result"
            for block in content
        )

    assert _is_receipt_row(row) is False
    assert _pre_c1e_is_receipt_row(row) is True
    assert scan_raw_transcript((json.dumps(row),)).receipt_times_ms == {}


def _user_mention_line_for_r1e(at_ms: int) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": f"m-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "user",
                "content": f"what happened to agentId: {TASK_ID} yesterday?",
            },
        }
    )


# ---------------------------------------------------------------------------
# REACHABILITY — the transient hole through the REAL reader
# ---------------------------------------------------------------------------


class _TransientlyTruncatedSdk(_HistorySdk):
    """An SDK whose session list is temporarily short, like a project
    directory that is unreadable for a while (a mount hiccup, a CLI
    migration): `visible` is how many of its sessions it reports right now."""

    def __init__(self, sessions: list[Any], *, visible: int) -> None:
        super().__init__(sessions=sessions)
        self.visible = visible

    def list_sessions(
        self, limit: int | None = None, offset: int = 0
    ) -> list[Any]:
        self.list_calls.append({"limit": limit, "offset": offset})
        sessions = self.sessions[: self.visible][offset:]
        return sessions[:limit] if limit is not None else sessions


def test_R1e_P2_the_transient_hole_is_reachable_through_the_real_reader(
    monkeypatch,
) -> None:
    """RECORDED TRADE (R1e-1), reachability: the shape the previous test
    injects through fake flags is producible end to end by the REAL reader.

    A 300-session library whose listing is temporarily truncated to exactly
    one page: page 1 reads full (so `page_one_complete` refuses it), the
    window at the seam reads empty, the extent is seeded from the seam and
    `beyond_extent` fires — the sweep wraps, records the end, and sleeps on
    the next read. When the library comes back, the sweep is asleep and page
    1's signal has been consumed, so nothing looks at the restored sessions.

    Pinned as the reachability half of the recorded trade — the same shape
    the first test pins through injected flags, here through the real reader
    — not as a defect report.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _TransientlyTruncatedSdk(
        [_sdk_session(i) for i in range(300)],
        visible=SESSION_ROTATION_PAGE_SIZE,
    )
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    # Two cycles of the transient is all it takes.
    asyncio.run(runner.sync_existing_once())
    asyncio.run(runner.sync_existing_once())
    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active") is False

    # The library is back — and the sweep never reads a window again.
    sdk.visible = 300
    reads_before = len([c for c in sdk.list_calls if c["offset"] > 0])
    for _cycle in range(8):
        asyncio.run(runner.sync_existing_once())

    assert len([c for c in sdk.list_calls if c["offset"] > 0]) == reads_before
    # ...while 200 sessions sit past the page the sweep stopped believing in.
    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active") is False


def test_R1e_control_a_complete_page_seeds_nothing(monkeypatch) -> None:
    """CONTROL: the `page_one_complete` rejection path returns before the
    seed, so a library page 1 covers never writes an extent."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime()
    page = SessionListPage(
        (_meta(0, projection_outdated=True),),
        history_scanned=1,
        page_one_complete=True,
    )
    runtime.page_one = page
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    assert ROTATION_STATE_KEY not in host.state
    assert host.state.get(ROTATION_STATE_KEY) is None


def test_R1e_control_report_mode_seeds_but_publishes_nothing(monkeypatch) -> None:
    """CONTROL: report mode walks the same path, so it carries the seed in the
    state it writes — and still publishes nothing to the platform."""

    monkeypatch.setenv("AGENT_CONNECTOR_SESSION_ROTATION", "report")
    runtime = MarkedPagedRuntime()
    runtime.page_one = SessionListPage(
        tuple(_meta(i, projection_outdated=(i == 0)) for i in range(100)),
        history_scanned=SESSION_ROTATION_PAGE_SIZE,
    )
    # An empty window, so the extent in the written state can only be the
    # seed (a non-empty one would raise it to offset + page size).
    runtime.rotation_pages = {SESSION_ROTATION_FIRST_OFFSET: ()}
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    assert state["libraryExtent"] == SESSION_ROTATION_PAGE_SIZE
    assert notifications == []
