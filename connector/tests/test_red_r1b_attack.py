"""R1 round-2 attack suite — the R1 fixes on `b2a7f9a9` (fix `f427cb29`).

Round 1 landed six findings; the fixer closed them and flipped my 18 attack
tests into 21 guards. This suite attacked the REPAIRS: the flag-carrying
`SessionListPage`, the unproven-empty rule, the idle backoff, the page-one
seam, the env suffix parser, and the now-shared `participation_times_ms`.

It found five more, and this file is their gate: every attack below is
FLIPPED — the same setup, asserting the repair instead of the hole — so a
regression reintroduces the finding rather than passing quietly. The three
controls and the reader-side P1-1/P1-2 assertions are kept as they were,
because they were already the passing side. Two guards are new, covering the
gaps this round could not reach from the outside: the production call shape
(the bound `RuntimeInstance`, not a fake runtime that hands back the real
page) and the real reader's own `except` branch, which until now was only
ever simulated by a hand-built `SessionListPage`.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

from test_claude_runtime import _HistorySdk, _RecordingHost, _runtime
from test_session_rotation import (
    ROTATION_STATE_KEY,
    MarkedPagedRuntime,
    StatefulRecordingHost,
    _all_session_ids,
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

from connector.runtime_protocol.instance_binding import RuntimeInstance
from connector.runtime_protocol.instance_models import RuntimeInstanceSpec
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.sessions.subagent_oracle import (
    SUBAGENT_AGE_BOUND_ENV,
    ClaudeSubagentOracle,
    participation_times_ms,
    scan_raw_transcript,
)
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
    SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT,
    _first_rotation_offset,
    _page_history_scanned,
    _page_read_failed,
)

NOW = 1_791_457_800.0


def _spec() -> RuntimeInstanceSpec:
    return RuntimeInstanceSpec(
        runtime_id="claude", runtime_type="claude", name="Claude"
    )


class _RaisingHistorySdk(_HistorySdk):
    """An SDK whose session list raises, like a real transient failure."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        # Every window the ladder asked for, including the ones that raised —
        # the base class only records what it actually served.
        self.attempted_offsets: list[int] = []

    def list_sessions(
        self, limit: int | None = None, offset: int = 0
    ) -> list[Any]:
        self.attempted_offsets.append(offset)
        if offset:
            raise OSError("sdk session list blew up")
        return super().list_sessions(limit=limit, offset=offset)


# ---------------------------------------------------------------------------
# ATTACK 1 — the SessionListPage flags are stripped by the production wrapper
# ---------------------------------------------------------------------------


def test_R1b_P0_the_native_reader_reports_read_failed() -> None:
    """CONTROL: the reader-side repair really does set the flag."""

    host = _RecordingHost()
    sdk = _RaisingHistorySdk(
        sessions=[
            SimpleNamespace(
                session_id="claude_a", summary="A", last_modified=1, file_size=1, cwd="/r"
            )
        ]
    )
    native = _runtime(host=host, sdk=sdk)

    page = asyncio.run(native.list_sessions(limit=100, cursor="100"))

    assert page.read_failed is True
    assert page.history_scanned == 0
    assert len(page) == 0


def test_R1b_P0_the_bound_page_keeps_both_flags() -> None:
    """P0, closed: `RuntimeInstance.list_sessions` used to rebuild the page
    with `tuple(...)`, so `read_failed` and `history_scanned` were both gone.

    The supervisor stores this wrapper as the entry's runtime
    (supervisor.py:330) and `resolve_runtime` hands it back, so the rotation
    sweep reads the WRAPPED page — which made the round-1 P1-2 repair inert in
    production while the unit tests, whose fake runtime returns a real
    `SessionListPage`, kept it green.
    """

    host = _RecordingHost()
    sdk = _RaisingHistorySdk(
        sessions=[
            SimpleNamespace(
                session_id="claude_a", summary="A", last_modified=1, file_size=1, cwd="/r"
            )
        ]
    )
    native = _runtime(host=host, sdk=sdk)
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    native_page = asyncio.run(native.list_sessions(limit=100, cursor="100"))
    bound_page = asyncio.run(bound.list_sessions(limit=100, cursor="100"))

    assert native_page.read_failed is True
    # The wrapper the sweep actually sees now carries the same verdict.
    assert type(bound_page) is not tuple
    assert _page_read_failed(bound_page) is True
    assert _page_history_scanned(bound_page) == 0


def test_R1b_P0_a_runtime_with_no_flags_still_returns_a_plain_tuple() -> None:
    """The other side of the same repair: the wrapper must not invent a page
    type for a runtime that has nothing to say about its read. Every non-Claude
    runtime returns a bare tuple and keeps its old, conservative meaning."""

    native = MarkedPagedRuntime()
    native.page_one = (_meta(0),)
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    page = asyncio.run(bound.list_sessions(limit=100))

    assert type(page) is tuple
    assert _page_read_failed(page) is False


def test_R1b_P0_the_seam_survives_the_wrapper() -> None:
    """The same wrapper used to drop page 1's seam, so the P2-6 fix was inert
    as well: `_page_reported_seam` could not see it and the ladder fell back
    to the fixed page boundary, stepping over the displaced sessions."""

    host = _RecordingHost()
    sdk = _HistorySdk(
        sessions=[
            SimpleNamespace(
                session_id=f"claude_rot_{index:03d}",
                summary=f"R{index}",
                last_modified=1_789_000_000_000 - index,
                file_size=123,
                cwd="/repo",
            )
            for index in range(130)
        ]
    )
    native = _runtime(host=host, sdk=sdk)
    for index in range(3):
        native._session_reader.session_store.ensure(
            f"local_only_{index}", cwd="/repo", title=f"Local {index}"
        )
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    native_page_one = asyncio.run(native.list_sessions(limit=100))
    bound_page_one = asyncio.run(bound.list_sessions(limit=100))

    assert native_page_one.history_scanned == 97
    # The ladder now starts where page 1 actually stopped, wrapper included.
    assert _first_rotation_offset(native_page_one) == 97
    assert _first_rotation_offset(bound_page_one) == 97


def test_R1b_P0_the_real_readers_except_branch_reports_through_the_binding() -> None:
    """R1 audit gap 1, closed: every `read_failed=True` in the suite used to be
    a hand-built `SessionListPage`, so restoring the bare `tuple(...)` in the
    binding left all 21 round-1 guards green — a silent regression.

    This one drives the reader's OWN `except` branch (an SDK whose session list
    raises, exactly as a transient failure does) and reads the verdict back
    through the bound `RuntimeInstance` the supervisor actually stores. If the
    binding ever stops re-wrapping, this goes red on its own."""

    host = _RecordingHost()
    sdk = _RaisingHistorySdk(
        sessions=[
            SimpleNamespace(
                session_id="claude_a", summary="A", last_modified=1, file_size=1, cwd="/r"
            )
        ]
    )
    native = _runtime(host=host, sdk=sdk)
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    # The real reader caught the raise itself; nothing here constructs the page.
    page = asyncio.run(bound.list_sessions(limit=100, cursor="100"))

    assert len(page) == 0
    assert page.read_failed is True
    assert _page_read_failed(page) is True
    # An empty window that is not the end of the library also needs a reason,
    # and "the read failed" is the one the ladder acts on.
    assert page.history_scanned == 0


def test_R1b_P0_a_failed_window_through_the_wrapper_does_not_end_the_sweep(
    monkeypatch,
) -> None:
    """P0, closed, end to end on the production call shape: one failed window
    used to complete the circle and disarm the sweep, leaving the residue
    window unread. The wrapper now reports the failed read, so the ladder
    steps over the window and keeps climbing.
    """

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = StatefulRecordingHost()
    sdk = _RaisingHistorySdk(
        sessions=[
            SimpleNamespace(
                session_id=f"claude_{index:03d}",
                summary=f"S{index}",
                last_modified=1_789_000_000_000 - index,
                file_size=123,
                cwd="/repo",
            )
            for index in range(4)
        ]
    )
    native = _runtime(host=host, sdk=sdk)
    bound = RuntimeInstance(instance=_spec(), native_runtime=native)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(bound, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    # Page 1 reports an outdated projection, so the sweep activates...
    page_one = asyncio.run(bound.list_sessions(limit=100))
    assert len(page_one) >= 1
    # ...and the next window read raises inside the reader, which reports it.
    failing = asyncio.run(bound.list_sessions(limit=100, cursor="100"))
    assert len(failing) == 0

    # The wrapper can now tell the sweep, so the empty is not read as the end.
    assert _page_read_failed(failing) is True
    assert _page_history_scanned(failing) == 0

    # ...and running the real sweep on the bound runtime walks past the failed
    # window instead of concluding the library on it. Page 1 reports a seam of
    # 4 (it exposed all four library sessions), so the ladder starts there.
    first_offset = _first_rotation_offset(page_one)
    assert first_offset == 4
    for _cycle in range(6):
        asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    # Still armed, still climbing, and it has read no real window — so it can
    # never have claimed the library ended.
    assert state["active"] is True, state
    assert state["circleWindows"] == 0, state
    window_offsets = [
        offset for offset in sdk.attempted_offsets if offset >= first_offset
    ]
    assert window_offsets, sdk.attempted_offsets
    assert max(window_offsets) >= first_offset + 2 * SESSION_ROTATION_PAGE_SIZE


# ---------------------------------------------------------------------------
# ATTACK 2 — the unproven-empty rule still concludes after three
# ---------------------------------------------------------------------------


def test_R1b_P1_three_consecutive_failures_no_longer_lose_the_tail(monkeypatch) -> None:
    """P1, closed: `unproven >= SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT` used to
    conclude the library even with `circle_windows == 0`, and with no candidates
    the sweep disarmed. The activation signal is a page-1 edge that nothing
    here consumes, so the very next cycle re-armed and burned the same three
    failures — the round-1 hole bounded and then repeated, and the ladder never
    climbed past the third window.

    A spent patience now re-seeks instead of disarming, and only ONE re-seek is
    allowed per circle: a second one would wrap the ladder straight back into
    the windows that just failed. So the ladder climbs past them and the
    residue at offset 400 is reached, compared and rebuilt."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime(
        failed=tuple(
            SESSION_ROTATION_FIRST_OFFSET + index * SESSION_ROTATION_PAGE_SIZE
            for index in range(SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT)
        )
    )
    runtime.page_one = (_meta(0, requires_sync=True, projection_outdated=True),)
    runtime.rotation_pages = {
        4 * SESSION_ROTATION_FIRST_OFFSET: (_meta(401, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    runner, notifications = _runner(runtime, host)

    for _cycle in range(30):
        asyncio.run(runner.sync_existing_once())

    # The tail is compared and rebuilt.
    assert "sess_401" in _all_session_ids(notifications)
    assert str(4 * SESSION_ROTATION_FIRST_OFFSET) in runtime.cursors
    # ...and the ladder got there by climbing, not by restarting at the top on
    # every cycle: the failing windows are behind it, not in front of it.
    window_reads = [c for c in runtime.cursors if c is not None]
    first_seen = window_reads.index(str(4 * SESSION_ROTATION_FIRST_OFFSET))
    before = window_reads[:first_seen]
    # One re-seek per circle is the whole bound: each failing window is re-read
    # exactly once (initial climb + the re-seek) before the ladder commits
    # forward past it. The old behaviour re-read them on every single cycle and
    # never reached the tail at all.
    for offset in range(1, SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT + 1):
        cursor = str(offset * SESSION_ROTATION_FIRST_OFFSET)
        assert before.count(cursor) == 2, (cursor, window_reads)


# ---------------------------------------------------------------------------
# ATTACK 3 — history_scanned is measured after the id skip
# ---------------------------------------------------------------------------


def test_R1b_P2_a_mid_library_window_of_unreadable_rows_is_not_the_library_end(
    monkeypatch,
) -> None:
    """P2, closed: `history_scanned` used to be counted as `len(metas)`, AFTER
    the rows whose `session_id` cannot be extracted are skipped, so a window the
    SDK really filled reported `history_scanned == 0` and looked exactly like a
    proven empty.

    Once the circle has read one real window, `circle_windows > 0` plus
    `unverified == False` then made the ladder conclude the library — with a
    whole hundred sessions sitting unread past it. The count is now the rows
    the SDK actually returned."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sessions: list[Any] = []
    for index in range(400):
        if 200 <= index < 300:
            # The SDK returned a row, but no extractable id.
            sessions.append(
                SimpleNamespace(
                    summary=f"drift {index}",
                    last_modified=1_789_000_000_000 - index,
                    file_size=1,
                    cwd="/repo",
                )
            )
        else:
            sessions.append(
                SimpleNamespace(
                    session_id=f"claude_{index:03d}",
                    summary=f"S{index}",
                    last_modified=1_789_000_000_000 - index,
                    file_size=123,
                    cwd="/repo",
                )
            )
    sdk = _HistorySdk(sessions=sessions)
    runtime = _runtime(host=host, sdk=sdk)

    page = asyncio.run(runtime.list_sessions(limit=100, cursor="200"))
    # The SDK returned 100 rows and not one of them carried a usable id; the
    # page is empty, but it now says the window was not empty in the library.
    assert len(page) == 0
    assert page.read_failed is False
    assert page.history_scanned == 100
    # Which is what keeps the ladder off the "proven end of the library" branch.
    assert _page_read_failed(page) is False
    assert _page_history_scanned(page) == 100
    assert _page_history_scanned(page) > 0


# ---------------------------------------------------------------------------
# ATTACK 4 — the env floor still admits a ceiling that closes live work
# ---------------------------------------------------------------------------


def test_R1b_P2_the_floor_no_longer_admits_a_ceiling_that_closes_live_work(
    monkeypatch,
) -> None:
    """P2, closed: the floor was 60s, which is inside the window where a
    background subagent is alive and writing. Dispatched 61s ago, transcript
    written 2s ago, no transport vouch — closed as `ageBounded`.

    The floor existed to stop `0.5`, and it did; but 60s was not a backstop
    ceiling, it was a reaper with a slightly larger trigger. The floor now sits
    above the longest legitimate background run, so no ceiling this judgement
    can be given reaches live work."""

    # The same scenario, at the smallest ceiling the rule now accepts.
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "3600")
    oracle = _oracle(now=NOW, files={TASK_ID: _fresh_file(NOW)})
    assert oracle.age_bound_seconds == 3600.0

    verdict = oracle.evidence(
        task_id=TASK_ID,
        external_session_id="e89abce5-f48c-463b-8d16-d3f78dd504c4",
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=61.0,
        attached_live=False,
        now_ms=int(NOW * 1000),
    )

    assert verdict is None, verdict

    # ...and the old reaper ceiling is refused outright rather than honoured.
    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "60")
    assert _oracle(now=NOW, files={TASK_ID: _fresh_file(NOW)}).age_bound_seconds == 0.0


def test_R1b_P2_a_ceiling_below_the_floor_is_refused(monkeypatch) -> None:
    """CONTROL: sub-floor and unusable values are refused to 0 (off), and the
    suffixes still parse above the floor."""

    for refused in (
        "59",
        "60",
        "0.5",
        "30s",
        "30m",
        "abc",
        "",
        "nan",
        "inf",
        "-1",
        "1.5.5h",
    ):
        monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, refused)
        assert (
            ClaudeSubagentOracle(projects_dir="/nonexistent").age_bound_seconds == 0.0
        ), refused
    for accepted, expected in (
        ("3600", 3600.0),
        ("1h", 3600.0),
        ("24h", 86400.0),
        ("90m", 5400.0),
        ("1.5h", 5400.0),
        ("2d", 172800.0),
    ):
        monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, accepted)
        assert (
            ClaudeSubagentOracle(projects_dir="/nonexistent").age_bound_seconds
            == expected
        ), accepted


# ---------------------------------------------------------------------------
# ATTACK 5 — the shared participation anchor can be pushed newer by a dead task
# ---------------------------------------------------------------------------


def _mention_message(at_ms: int) -> Any:
    """A later SDK message that merely QUOTES the task's agentId."""

    return SimpleNamespace(
        type="assistant",
        uuid=f"mention-{at_ms}",
        timestamp=at_ms,
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "text",
                    "text": f"wrapping up the run for agentId: {TASK_ID} (internal ID)",
                }
            ],
        },
    )


def test_R1b_P2_a_mention_no_longer_refreshes_the_anchor_of_a_dead_task(
    monkeypatch,
) -> None:
    """P2, closed: the shared anchor is "the newest survival evidence", but
    `_history_receipt_ages` used to fold in any later MESSAGE whose text merely
    quoted `agentId:`. A dead task whose id was mentioned again had its clock
    reset, so the ceiling never fired — the re-stamped-mtime residue T2 exists
    to close stayed `running` indefinitely.

    This was the documented F4 pollution bias ("later transcript text can
    pollute to be newer than the true launch"). It was harmless while the
    anchor only fed notice arbitration and the never-started grace, where a
    newer anchor defers a judgement that another rule would catch anyway. T2
    makes the anchor load-bearing for a HARD ceiling, so the bias deferred
    closures without bound, and no other rule could catch this card: the file
    mtime is fresh, so `agentFileStale` never fired either.

    The message view may now only PLACE an anchor the scanner did not; a task
    the scanner already placed keeps the scanner's answer."""

    old_receipt_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)
    mention_ms = int((NOW - 600.0) * 1000)
    raw_lines = _old_receipt_raw_lines(old_receipt_ms)
    scan = scan_raw_transcript(raw_lines)
    # The scan's own participation anchor is still the old dispatch...
    assert participation_times_ms(scan)[TASK_ID] == old_receipt_ms

    # ...and a later message that merely names the task no longer outranks it,
    # so the ceiling is reached and the dead card closes.
    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message(), _mention_message(mention_ms)),
        raw_lines=raw_lines,
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"

    # Same verdict with no mention at all: the mention changed nothing.
    closed = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=raw_lines,
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    closed_card = next(i for i in closed if i.content.get("kind") == "agent_call")
    assert closed_card.status == "interrupted"
    assert closed_card.content["closedByEvidence"] == "ageBounded"


def test_R1b_P2_the_message_view_still_supplies_an_unanchored_task(monkeypatch) -> None:
    """The other side: the message fold is the F5 supplement and it must keep
    working. A task the raw transcript never placed — nothing readable for it
    at all — still gets its anchor from the message view, which is what makes
    the never-started closure reachable on real data in the first place."""

    from connector.runtimes.claude.sessions.reader import _history_receipt_ages

    mention_ms = 1_791_457_000_000
    ages = _history_receipt_ages(
        (_dispatch_message(), _mention_message(mention_ms)),
        now_ms=mention_ms + 180_000,
        raw_receipt_times={},
    )
    assert ages[TASK_ID] == 180.0

    # ...and the scanner's own answer still wins whenever it has one — but
    # "the scanner's own" now means VERIFIED (R1c R3-2): a scan that tied the
    # anchor to a real dispatch call has the engine's word and keeps it, which
    # is the rule this half of the test was written for.
    scanned_ms = mention_ms - 600_000
    anchored = _history_receipt_ages(
        (_dispatch_message(), _mention_message(mention_ms)),
        now_ms=mention_ms + 180_000,
        raw_receipt_times={TASK_ID: scanned_ms},
        verified_dispatch_roots=frozenset({TASK_ID}),
    )
    assert anchored[TASK_ID] == 780.0

    # An UNVERIFIED scanner anchor is the other case, and R1b's absolute rule
    # could not tell them apart: nothing ties that anchor to a call (F5's bare
    # `tool_result`, whose dispatch row was trimmed away), so a strictly newer
    # receipt in the message view overrules it. Only newer mentions displace
    # one, so the direction of travel stays "later", never "older".
    overruled = _history_receipt_ages(
        (_dispatch_message(), _mention_message(mention_ms)),
        now_ms=mention_ms + 180_000,
        raw_receipt_times={TASK_ID: scanned_ms},
    )
    assert overruled[TASK_ID] == 180.0
    # ...and an older mention still does not.
    assert _history_receipt_ages(
        (_dispatch_message(), _mention_message(scanned_ms - 1)),
        now_ms=mention_ms + 180_000,
        raw_receipt_times={TASK_ID: scanned_ms},
    )[TASK_ID] == 780.0


# ---------------------------------------------------------------------------
# CONTROLS — repairs that hold
# ---------------------------------------------------------------------------


def test_R1b_control_the_round_one_findings_are_closed_on_the_native_reader() -> None:
    """CONTROL: on the reader the rotation actually calls, P1-1 and P1-2 hold."""

    # P1-1: a task resumed five minutes ago is no longer closed.
    from test_red_r1_attack import (
        FRESH_RESUME_MS,
        OLD_RECEIPT_MS,
        _resume_raw_line,
    )

    raw_lines = (*_old_receipt_raw_lines(OLD_RECEIPT_MS), _resume_raw_line(FRESH_RESUME_MS))
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


def test_R1b_control_the_idle_backoff_still_reaches_the_library_end(
    monkeypatch,
) -> None:
    """CONTROL (does not land): the backoff is bounded at 8 rest cycles, so an
    idle sweep still concludes and never becomes "never look again"."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101),),
        SESSION_ROTATION_FIRST_OFFSET + SESSION_ROTATION_PAGE_SIZE: (_meta(201),),
    }
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    for _cycle in range(60):
        asyncio.run(runner.sync_existing_once())

    assert host.state[ROTATION_STATE_KEY]["active"] is False