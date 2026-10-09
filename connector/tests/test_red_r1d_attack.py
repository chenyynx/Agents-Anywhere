"""R1 round-4 attacks — the c1c/c1d repairs on `ebcf73cf` (fix `c1e`).

Round 4 is the final verification round. It attacks the two new repair sets:
c1c (re-seek cooldown, `library_extent`/`past_library_extent`, verified-anchor
priority, `_is_receipt_row`, the ceiling's own anchor) and c1d (`page_one_complete`,
the seam-0 start, `cursor="0"` semantics).

Two of its findings landed and were repaired:

* R4-1 — a library of exactly `limit` sessions let the sweep walk forever
  (fixed by seeding `library_extent` from page 1's seam, `runtime_sync.py`);
* R4-2 — `_is_receipt_row` admitted any bare-string ``user`` row, moving the
  mention pollution one row type over (fixed by gating that branch on the
  engine's launch wording, `subagent_oracle.py`).

Both attacks are flipped into guards here, each keeping the attack's own
setup so it still reproduces the shape it was written for; R4-1's
precondition test (the reader's refusal to call a full page complete — still
true, still what hands the shape to the ladder) and every control the
reviewer pinned as "does not land" are kept verbatim.
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
    _meta,
    _runner,
)
from test_task_closure import (
    T_AGE_BOUND,
    TASK_ID,
    _dispatch_message,
    _fresh_file,
    _oracle,
    _receipt_message,
    _session,
)

from connector.runtimes.claude.sessions.reader import (
    SessionListPage,
    _history_items_from_messages,
    _history_receipt_ages,
    _page_one_covers_library,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    _is_receipt_row,
    participation_times_ms,
    scan_raw_transcript,
)
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
    SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS,
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
# ATTACK A — a library whose history is exactly one page never lets the sweep
# sleep (the c1d boundary)
# ---------------------------------------------------------------------------


def test_R1d_P1_the_real_reader_calls_an_exactly_full_page_incomplete() -> None:
    """PRECONDITION: for a library of exactly `limit` sessions the real reader
    reports a full page — `history_scanned == limit` — which is exactly the
    condition c1d's `page_one_complete` refuses to trust.

    The refusal is deliberate ("the library may be exactly one page, or longer
    — the residual the ladder still has to walk"), so this shape is handed to
    the ladder. What the ladder then does with it is the attack below."""

    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(100)])
    runtime = _runtime(host=host, sdk=sdk)

    page_one = asyncio.run(runtime.list_sessions(limit=100))

    assert len(page_one) == 100
    assert page_one.history_scanned == SESSION_ROTATION_PAGE_SIZE
    assert page_one.page_one_complete is False
    assert page_one.read_failed is False


def test_R1d_P1_an_exactly_one_page_library_lets_the_sweep_sleep(
    monkeypatch,
) -> None:
    """GUARD (was the R4-1 attack): the sweep opened by the shape above now
    sleeps — on the library's own evidence, in two reads.

    The repair (c1e): page 1's seam seeds `library_extent`, so the first
    empty window at the seam is `beyond_extent` rather than "unproven" — it
    wraps and records `past_library_extent` — and the next verified empty
    window concludes the circle. Where the attack measured one window read
    per cycle for the life of the process (a whole-library SDK scan each),
    the walk is now two reads and a disarm.

    The attack's last observation is kept and re-read the other way: the
    page-1 signal IS fully consumed here, and the sweep slept anyway — an
    armed sweep never consults that signal, which is exactly why the fixer's
    "or the page-1 signal is consumed" exit never existed."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(100)])
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    cycles = 24
    for _cycle in range(cycles):
        asyncio.run(runner.sync_existing_once())

    state = host.sync_states.get(ROTATION_STATE_KEY) or {}
    assert state.get("active") is False, "sweep still walking after the fix"
    # The end proven in exactly two reads: the wrap beyond the seeded extent,
    # then the read that concludes on the way back. Nothing scans after that.
    window_reads = [c for c in sdk.list_calls if c["offset"] > 0]
    assert len(window_reads) == 2, window_reads

    # The page-1 signal is consumed — and the sleep did not need it.
    from connector.server.runtime_sync import session_projection_outdated

    page_one_now = asyncio.run(runtime.list_sessions(limit=100))
    assert not any(
        session_projection_outdated(session) for session in page_one_now
    ), "the page-1 signal is still lit; the test would not prove the clause"
    assert state.get("active") is False


def test_R1d_P1_the_oscillation_is_gone(monkeypatch) -> None:
    """GUARD (was the R4-1 attack, traced): the ladder wraps exactly once and
    sleeps — the endless oscillation is gone, not merely bounded.

    The attack traced two cooldowns of the shape: an offset repeats (the
    re-seek wraps) and the sweep is still armed, because neither proof of the
    library's end (`circle_windows > 0`, `past_library_extent`) was reachable
    for it. With the extent seeded from page 1's seam, the first empty window
    at the seam IS `beyond_extent`, the wrap records the proof, and the next
    read concludes — the same position, twice, then sleep. The cooldown
    machinery is never reached in this shape at all."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(100)])
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    for _cycle in range(2 * SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS + 4):
        asyncio.run(runner.sync_existing_once())

    offsets = [c["offset"] for c in sdk.list_calls if c["offset"] > 0]
    # Exactly the two seam reads — the wrap beyond the seeded extent and the
    # concluding read — and nothing else across two full cooldowns' worth of
    # cycles.
    assert offsets == [SESSION_ROTATION_FIRST_OFFSET] * 2, offsets
    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active") is False


def test_R1d_control_a_101_session_library_does_sleep(monkeypatch) -> None:
    """CONTROL (does not land): one session more than a page gives the ladder a
    non-empty window, and the same sweep concludes and sleeps normally. The
    boundary is exactly the page size."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(101)])
    runtime = _runtime(host=host, sdk=sdk)

    async def no_catalogs(_runtime_: Any) -> None:
        return None

    runner, _notifications = _runner(runtime, host)
    monkeypatch.setattr(runner, "push_runtime_catalogs", no_catalogs)

    for _cycle in range(8):
        asyncio.run(runner.sync_existing_once())

    assert (host.sync_states.get(ROTATION_STATE_KEY) or {}).get("active") is False


# ---------------------------------------------------------------------------
# ATTACK B — _is_receipt_row admits a USER row that only mentions the id
# ---------------------------------------------------------------------------


def _user_mention_line(at_ms: int) -> str:
    """A human-typed user row whose body is free text quoting an agentId.

    This is the shape R1c's own docstring is about ("a grep/cat of a
    transcript", "a report about another agent") — but written by the human,
    so it lands on a `user` row and the shape gate admits it."""

    return json.dumps(
        {
            "type": "user",
            "uuid": f"user-mention-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "user",
                "content": f"what happened to agentId: {TASK_ID} yesterday?",
            },
        }
    )


def test_R1d_P2_the_shape_gate_refuses_a_user_row_that_only_mentions() -> None:
    """GUARD (was the R4-2 attack): `_is_receipt_row` no longer admits a bare
    ``user`` row whose string body merely quotes an agentId.

    The attack: the R1c repair excluded `assistant` rows, but the free text a
    human writes lives on `user` rows — and the string branch admitted those
    unconditionally (the bare-F5 shape), so the pollution moved one row type
    over. The repair (c1e) gates that branch on the engine's own wording
    (`ASYNC_AGENT_RECEIPT_PREFIX`, the same criterion the message view applies
    through `is_async_agent_receipt`): the launch receipt's text is the
    engine's channel, the human sentence is not. F5's real body — which does
    open with the prefix — still lands (that test is the F5 guard in
    `test_task_closure.py`)."""

    mention_ms = int((NOW - 600.0) * 1000)
    row = json.loads(_user_mention_line(mention_ms))

    assert _is_receipt_row(row) is False
    scan = scan_raw_transcript((_user_mention_line(mention_ms),))
    assert scan.receipt_times_ms == {}, scan.receipt_times_ms


def _raw_receipt_line(at_ms: int) -> str:
    """The engine's own launch receipt on a bare-string user row (F5 shape).

    The body opens with ``ASYNC_AGENT_RECEIPT_PREFIX``, which is what
    separates it from `_user_mention_line` now that both ride the same row
    type — the distinction the c1e repair draws.
    """

    return json.dumps(
        {
            "type": "user",
            "uuid": f"receipt-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "user",
                "content": (
                    "Async agent launched successfully.\n"
                    f"agentId: {TASK_ID} (internal ID)"
                ),
            },
        }
    )


def test_R1d_P2_a_user_mention_no_longer_defers_the_ceiling_of_a_dead_task(
    monkeypatch,
) -> None:
    """GUARD (was the R4-2 attack), end to end: a human mention no longer
    holds a dead task's card open.

    The attack: the ceiling reads the RAW anchor alone (`ceiling_age_seconds`,
    no message-view supplement), so a user-row mention of the id re-stamped
    the one anchor the hard closure depends on — a task dispatched 25h ago
    whose id a human quoted 10 minutes ago stayed `running`, with the file's
    freshness keeping `agentFileStale` away. The repair (c1e) admits only the
    engine's launch wording as a receipt, so the mention no longer moves the
    anchor and the card closes `ageBounded` on the real 25h-old receipt —
    identically to the control below, which drops the fresh mention: the
    human sentence changed nothing."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)
    mention_ms = int((NOW - 600.0) * 1000)
    raw_lines = (_raw_receipt_line(old_ms), _user_mention_line(mention_ms))

    scan = scan_raw_transcript(raw_lines)
    # The mention did not re-stamp the launch anchor (and the engine's own
    # bare-body receipt — the F5 shape — is what anchors it).
    assert scan.receipt_times_ms[TASK_ID] == old_ms
    assert participation_times_ms(scan)[TASK_ID] == old_ms

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=raw_lines,
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = next(i for i in items if i.content.get("kind") == "agent_call")
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"

    # Control: without the fresh mention the same card closes the same way.
    without = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=(_raw_receipt_line(old_ms),),
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    without_card = next(i for i in without if i.content.get("kind") == "agent_call")
    assert without_card.status == "interrupted"
    assert without_card.content["closedByEvidence"] == "ageBounded"


def test_R1d_control_the_assistant_row_is_still_refused() -> None:
    """CONTROL: the shape the R1c repair was written for really is refused."""

    mention_ms = int((NOW - 600.0) * 1000)
    row = {
        "type": "assistant",
        "uuid": "a1",
        "timestamp": _iso(mention_ms),
        "message": {
            "role": "assistant",
            "content": [
                {"type": "text", "text": f"wrapping up agentId: {TASK_ID}"}
            ],
        },
    }
    assert _is_receipt_row(row) is False
    assert scan_raw_transcript((json.dumps(row),)).receipt_times_ms == {}


# ---------------------------------------------------------------------------
# ATTACK C — verified-anchor over-lock
# ---------------------------------------------------------------------------


def _mention_message(at_ms: int) -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid=f"m-{at_ms}",
        timestamp=at_ms,
        message={
            "role": "assistant",
            "content": [{"type": "text", "text": f"about agentId: {TASK_ID}"}],
        },
    )


def test_R1d_control_a_verified_anchor_resists_free_text_mentions() -> None:
    """CONTROL, NOT a finding: an over-lock I tried to build and could not.

    The lock is per TASK, so once the scan ties a task to a real dispatch call
    its anchor is frozen against the message view. The question is whether a
    GENUINELY newer anchor can be locked out. It cannot be reached with the
    message view's free text — which is the lock working as designed (this
    assertion) — and the other channel that could carry newer evidence for the
    same task, a SendMessage resume, is folded into the raw anchor itself by
    `participation_times_ms`, so the frozen anchor is already the newer one.
    Filed as 打不穿 with that argument; the assertion below pins the intended
    scope of the lock (mentions do not move it)."""

    stale_ms = int((NOW - (T_AGE_BOUND + 7200.0)) * 1000)
    real_ms = int((NOW - 300.0) * 1000)

    ages = _history_receipt_ages(
        (_dispatch_message(), _mention_message(real_ms)),
        now_ms=NOW * 1000,
        raw_receipt_times={TASK_ID: stale_ms},
        verified_dispatch_roots=frozenset({TASK_ID}),
    )
    # The verified anchor stands: a free-text mention is not evidence.
    assert ages[TASK_ID] == (NOW - stale_ms / 1000.0)


def test_R1d_control_an_unverified_anchor_yields_to_newer_evidence() -> None:
    """CONTROL: the unverified half of the R3-2 repair does work, and an older
    message never moves an anchor backwards."""

    stale_ms = int((NOW - 7200.0) * 1000)
    real_ms = int((NOW - 300.0) * 1000)

    assert _history_receipt_ages(
        (_mention_message(real_ms),),
        now_ms=NOW * 1000,
        raw_receipt_times={TASK_ID: stale_ms},
    )[TASK_ID] == 300.0
    assert _history_receipt_ages(
        (_mention_message(stale_ms - 1000),),
        now_ms=NOW * 1000,
        raw_receipt_times={TASK_ID: stale_ms},
    )[TASK_ID] == 7200.0


# ---------------------------------------------------------------------------
# ATTACK D — page_one_complete false positives
# ---------------------------------------------------------------------------


def _hist(index: int, *, local: bool = False) -> Any:
    session_id = f"claude_{index:03d}" if not local else f"local_{index:03d}"
    return SimpleNamespace(
        session_id=session_id,
        external_session_id=f"ext_{index:03d}",
        runtime="claude",
        title=f"S{index}",
        cwd="/repo",
        ordering_time=f"2026-08-01T00:{index:02d}:00Z",
        metadata={"source": "claude.session/list", "sync": {}},
    )


def _page(rows: tuple[Any, ...], *, scanned: int) -> SessionListPage:
    return SessionListPage(rows, history_scanned=scanned)


def test_R1d_P2_a_displaced_session_is_caught_only_if_it_is_in_the_filtered_list(
) -> None:
    """ATTACK (P2), the semantic the docstring claims is safe: sessions the
    live/active filters dropped are excluded from the completeness check, so a
    page whose filtered tail was dropped can still report complete.

    The claim is that a paged window applies the SAME filters, so the sweep
    could never reach them either — which is true in the reader, and is the
    reason this is not a hole in the sweep's coverage. Recorded here as the
    boundary of the verdict, pinned so a future filter change that makes the
    two paths differ will show up: the check is against `history_sessions`
    (filtered), NOT against what the SDK returned."""

    history_rows = tuple(_hist(i) for i in range(3))
    merged = history_rows  # all three made it onto the page
    # ...but the filtered list the reader passes in still holds only two of
    # them, because the third was dropped by a filter. The verdict is then
    # computed over two sessions and reports complete.
    assert (
        _page_one_covers_library(
            merged_page=merged,
            history_page=_page(history_rows, scanned=3),
            history_sessions=history_rows[:2],
            limit=100,
        )
        is True
    )
    # The displacement case IS caught, which is the hole P2-6 was about.
    assert (
        _page_one_covers_library(
            merged_page=history_rows[:2],
            history_page=_page(history_rows, scanned=3),
            history_sessions=history_rows,
            limit=100,
        )
        is False
    )


def test_R1d_P2_an_id_can_be_claimed_by_a_different_session() -> None:
    """ATTACK (P2), identity claim: `covered` is one flat set of every session
    and external id on the page, and a history session counts as covered if
    EITHER of its ids appears in it — so a session can be vouched for by an
    entry that is not itself.

    Real ids live in separate spaces (`stable_session_id` derives the session
    id from the external one), so this needs a crafted collision; it is filed
    as a boundary of the verdict rather than a live defect. It matters because
    a false `complete` does not merely skip a window — it makes the sweep
    refuse to open at all."""

    history = (_hist(0),)
    # The page holds a DIFFERENT session whose session_id equals the history
    # session's external id.
    impostor = _hist(9)
    impostor.session_id = history[0].external_session_id
    assert (
        _page_one_covers_library(
            merged_page=(impostor,),
            history_page=_page(history, scanned=1),
            history_sessions=history,
            limit=100,
        )
        is True
    )


def test_R1d_P2_a_full_page_is_never_complete(monkeypatch) -> None:
    """CONTROL: a full window is always unprovable, which is what keeps the
    ladder walking when the library may be longer than one page."""

    rows = tuple(_hist(i) for i in range(100))
    assert (
        _page_one_covers_library(
            merged_page=rows,
            history_page=_page(rows, scanned=100),
            history_sessions=rows,
            limit=100,
        )
        is False
    )


def test_R1d_P2_an_unkeyed_row_blocks_the_verdict() -> None:
    """CONTROL: a row the reader could not key on keeps the page from claiming
    the library."""

    rows = tuple(_hist(i) for i in range(3))
    assert (
        _page_one_covers_library(
            merged_page=rows,
            history_page=_page(rows, scanned=4),  # 4 read, 3 keyed
            history_sessions=rows,
            limit=100,
        )
        is False
    )


# ---------------------------------------------------------------------------
# ATTACK E — cursor="0" semantics
# ---------------------------------------------------------------------------


def test_R1d_P2_cursor_zero_now_returns_the_raw_window() -> None:
    """The c1d semantics change, pinned: `cursor=None` is the merged page,
    `cursor="0"` is a paged window. The two used to be the same read."""

    host = _RecordingHost()
    sdk = _HistorySdk(sessions=[_sdk_session(i) for i in range(5)])
    runtime = _runtime(host=host, sdk=sdk)
    runtime._session_reader.session_store.ensure("local_only_0", cwd="/repo", title="L")

    merged = asyncio.run(runtime.list_sessions(limit=100))
    paged = asyncio.run(runtime.list_sessions(limit=100, cursor="0"))

    assert any(s.session_id == "local_only_0" for s in merged)
    assert not any(s.session_id == "local_only_0" for s in paged)
    assert len(paged) == 5


def test_R1d_control_no_product_caller_passes_cursor_zero() -> None:
    """CONTROL for the claim "only the rotation sends 0": the product tree has
    no `cursor="0"` caller, and every other `list_sessions` call site passes
    `cursor=None`. The RPC path forwards a client-supplied cursor, so the claim
    holds for the repo and rests on clients not paging `session.discover`
    (noted in the report as the remaining surface)."""

    import pathlib

    hits = []
    for path in pathlib.Path("connector").rglob("*.py"):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if 'cursor="0"' in line or "cursor='0'" in line:
                hits.append(f"{path}:{number}")
    assert hits == [], hits


def test_R1d_control_the_rotation_is_the_only_explicit_cursor_sender() -> None:
    """The rotation fetch is the only call site that builds a cursor from
    state; every other one forwards a caller's parameter or passes None."""

    import pathlib

    senders = []
    for path in pathlib.Path("connector").rglob("*.py"):
        text = path.read_text()
        if "cursor=str(state.offset)" in text:
            senders.append(str(path))
    assert senders == ["connector/server/runtime_sync.py"], senders


def test_R1d_control_offset_zero_survives_the_persisted_round_trip() -> None:
    """CONTROL: the T1b floor change — 0 is a legitimate persisted position and
    comes back as 0, so a seam-0 ladder resumes where it was."""

    from connector.server.runtime_sync import (
        SessionRotationState,
        session_rotation_state_from_mapping,
        session_rotation_state_payload,
    )

    payload = session_rotation_state_payload(
        SessionRotationState(active=True, offset=0)
    )
    restored = session_rotation_state_from_mapping(payload)

    assert restored.offset == 0
    assert restored.active is True
    # ...and a negative offset is still corruption.
    assert (
        session_rotation_state_from_mapping(
            {**payload, "offset": -100}
        ).offset
        == SESSION_ROTATION_FIRST_OFFSET
    )


def test_R1d_control_a_failed_window_is_never_the_end_of_the_library() -> None:
    """CONTROL for the named guard change: with the new complete-page
    semantics, the substantive intent — a failed window read must never be
    read as the library's end — still holds on a multi-page library, at every
    position including the last window."""

    from test_session_rotation import MarkedPagedRuntime, StatefulRecordingHost

    from connector.server.runtime_sync import _page_read_failed

    runtime = MarkedPagedRuntime(failed=(SESSION_ROTATION_FIRST_OFFSET,))
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {SESSION_ROTATION_FIRST_OFFSET + 100: ()}
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    import os

    os.environ[SESSION_ROTATION_ENV] = "on"
    try:
        for _cycle in range(10):
            asyncio.run(runner.sync_existing_once())
    finally:
        os.environ.pop(SESSION_ROTATION_ENV, None)

    # The failed window is still recognised as a failed read...
    failed = asyncio.run(runtime.list_sessions(limit=100, cursor=str(
        SESSION_ROTATION_FIRST_OFFSET
    )))
    assert _page_read_failed(failed) is True
    # ...and the sweep were never allowed to conclude the library on it.
    assert (host.state.get(ROTATION_STATE_KEY) or {}).get("active") is True
