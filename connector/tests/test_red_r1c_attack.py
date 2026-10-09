"""R1 round-3 attacks — the round-2 repairs on `cadf8176` (fix `e304af7a`).

Round 3 targets the NEW logic the repairs introduced: the `_repage_sessions`
duck type, the one-shot `circle_stalls` patience machine, the raised env
floor, and the scanner-anchor priority that replaced `verified_dispatch_ids`.

The attacks landed and were repaired; what landed is now flipped into guards
(R1c repairs, branch `fix/residue-redfix-c1c`), each keeping the attack's own
setup so it still reproduces the shape it was written for. The controls the
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
    MarkedPagedRuntime,
    PagedRuntime,
    StatefulRecordingHost,
    _all_session_ids,
    _meta,
    _runner,
)
from test_task_closure import (
    DISPATCH_TUID,
    T_AGE_BOUND,
    TASK_ID,
    _dispatch_message,
    _fresh_file,
    _oracle,
    _receipt_message,
    _session,
)

from connector.runtime_protocol.instance_binding import RuntimeInstance
from connector.runtime_protocol.instance_models import RuntimeInstanceSpec
from connector.runtimes.claude.sessions.reader import _history_items_from_messages
from connector.runtimes.claude.sessions.subagent_oracle import (
    SUBAGENT_AGE_BOUND_ENV,
    SUBAGENT_AGE_BOUND_FLOOR_SECONDS,
    _parse_age_bound_seconds,
    scan_raw_transcript,
)
from connector.server.runtime_sync import (
    SESSION_ROTATION_ENV,
    SESSION_ROTATION_FIRST_OFFSET,
    SESSION_ROTATION_PAGE_SIZE,
    SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT,
    _page_read_failed,
)

NOW = 1_791_457_800.0

#: ``SESSION_ROTATION_RESEEK_COOLDOWN_WINDOWS``, spelled out rather than
#: imported: these guards have to FAIL on the tree they were written against,
#: and a constant that does not exist there would fail them at import instead
#: of at the behaviour. Pinned on purpose — changing the cooldown is a decision,
#: and the bound it puts on a failure storm is what these guards exist to hold.
RESEEK_COOLDOWN_WINDOWS = 8


def _spec() -> RuntimeInstanceSpec:
    return RuntimeInstanceSpec(runtime_id="claude", runtime_type="claude", name="Claude")


def _iso(ms: int) -> str:
    return (
        datetime.fromtimestamp(ms / 1000, tz=UTC)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


# ---------------------------------------------------------------------------
# ATTACK A — the one-shot patience machine walks forward without bound
# ---------------------------------------------------------------------------


def test_R1c_P1_a_a_failure_storm_stays_bounded_and_re_seeks_again(
    monkeypatch,
) -> None:
    """ATTACK A, flipped: a reader that fails on every window must not be able
    to spend the sweep's whole life walking forward.

    The attack's setup is unchanged — every offset the ladder can reach fails,
    and the only residue sits beyond the failed region — so the shape it was
    written for is still the one under test. What changed is the ladder: the
    re-seek re-arms after a cooldown instead of being spent once per circle, so
    the storm now costs a bounded forward run and then looks back.

    `active` stays True on purpose. The activation signal is a page-1 edge that
    is still there, and disarming on a window that proved nothing is exactly the
    R1b R2-2 oscillation; the sweep keeps looking until page 1 consumes its
    signal."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    # Every offset the ladder can reach for the next 200 windows fails.
    runtime = MarkedPagedRuntime(
        failed=tuple(
            SESSION_ROTATION_FIRST_OFFSET + index * SESSION_ROTATION_PAGE_SIZE
            for index in range(200)
        )
    )
    runtime.page_one = (_meta(0, projection_outdated=True),)
    # The residue sits BEYOND the failed region, so only a ladder that came
    # back around could ever compare it.
    runtime.rotation_pages = {
        900 * SESSION_ROTATION_PAGE_SIZE: (_meta(9001, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    runner, _notifications = _runner(runtime, host)

    for _cycle in range(40):
        asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    offsets = [int(c) for c in runtime.cursors if c is not None]
    # It looks back: the re-seek fired again after its cooldown, not once.
    assert state["circleStalls"] >= 2, state
    wraps = [
        index
        for index, offset in enumerate(offsets)
        if offset == SESSION_ROTATION_FIRST_OFFSET
    ]
    assert len(wraps) >= 2, offsets[:20]
    # ...and the forward run between wraps is bounded, so a reader that recovers
    # is reached instead of the ladder climbing away from it for good.
    assert max(offsets) <= SESSION_ROTATION_FIRST_OFFSET + (
        RESEEK_COOLDOWN_WINDOWS
        + SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT
        + 1
    ) * SESSION_ROTATION_PAGE_SIZE, offsets[-8:]
    assert state["active"] is True


def test_R1c_P1_a_persisted_spent_re_seek_recovers_the_shrunken_library(
    monkeypatch,
) -> None:
    """ATTACK A, second shape, flipped: a ladder persisted past a library that
    shrank, with the re-seek already spent, must still come back.

    Every read here SUCCEEDS and returns nothing, because the library is
    shorter than the offset — precisely the case the re-seek was written for.
    With a one-shot budget the ladder walked forward from an unreachable
    position for the life of the process; now the cooldown re-arms it, so the
    window that exists is read again and its session rebuilt."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    # The library shrank: the only real window is at 100, and it still carries
    # the residue, so coming back to it is observable end to end.
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": 5000,
        "circleCandidates": 0,
        "circleRebuilt": 0,
        "circleStalls": 1,  # the re-seek, already spent before the restart
    }
    runner, notifications = _runner(runtime, host)

    for _cycle in range(30):
        asyncio.run(runner.sync_existing_once())

    offsets = [int(c) for c in runtime.cursors if c is not None]
    assert SESSION_ROTATION_FIRST_OFFSET in offsets, offsets[:8]
    assert offsets != sorted(offsets), "the ladder must be able to come back"
    # It came back within the cooldown, not by luck of a long run.
    assert offsets.index(SESSION_ROTATION_FIRST_OFFSET) <= (
        RESEEK_COOLDOWN_WINDOWS
        + SESSION_ROTATION_UNPROVEN_EMPTY_LIMIT
    ), offsets[:8]
    assert "sess_101" in _all_session_ids(notifications)
    assert host.state[ROTATION_STATE_KEY]["active"] is True


def test_R1c_P1_b_an_empty_window_past_the_known_extent_re_seeks_at_once(
    monkeypatch,
) -> None:
    """The position judgement, independent of the patience machine.

    The sweep has a high-water mark from the windows it really read, so a
    ladder that reads empty at or beyond it is not "unproven" — it is standing
    where the library does not have anything. This re-seeks on the coordinates
    alone, on the FIRST read, with a re-seek budget still spent and no patience
    spent either, which is what makes it independent rather than a second copy
    of the cooldown path."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": 5000,
        "circleCandidates": 0,
        "circleRebuilt": 0,
        "circleStalls": 1,
        "windowsSinceReseek": 0,
        "libraryExtent": 900,  # everything past 900 has never held a session
    }
    runner, notifications = _runner(runtime, host)

    asyncio.run(runner.sync_existing_once())

    state = host.state[ROTATION_STATE_KEY]
    assert runtime.cursors[-1] == "5000"
    # One read was enough: the ladder is back where the library is.
    assert state["offset"] == SESSION_ROTATION_FIRST_OFFSET
    assert state["pastLibraryExtent"] is True
    asyncio.run(runner.sync_existing_once())

    assert "sess_101" in _all_session_ids(notifications)


def test_R1c_P1_b_a_window_the_filters_emptied_is_not_a_dead_position(
    monkeypatch,
) -> None:
    """The other side of the position judgement, and a regression guard for it:
    a window whose sessions were all filtered out still HAS sessions, so the
    ladder's coordinates are fine and it must walk on rather than wrap back
    into the same hole."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = MarkedPagedRuntime(filtered=(SESSION_ROTATION_FIRST_OFFSET,))
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        2 * SESSION_ROTATION_PAGE_SIZE: (_meta(201, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": SESSION_ROTATION_FIRST_OFFSET,
        "circleCandidates": 0,
        "circleRebuilt": 0,
        "libraryExtent": SESSION_ROTATION_FIRST_OFFSET,  # window 100 had sessions
    }
    runner, notifications = _runner(runtime, host)

    for _cycle in range(3):
        asyncio.run(runner.sync_existing_once())

    offsets = [int(c) for c in runtime.cursors if c is not None]
    # It walked past the filtered window instead of wrapping back into it...
    assert offsets[:2] == [
        SESSION_ROTATION_FIRST_OFFSET,
        2 * SESSION_ROTATION_PAGE_SIZE,
    ], offsets
    assert offsets.count(SESSION_ROTATION_FIRST_OFFSET) == 1, offsets
    # ...and the window beyond it was compared as usual.
    assert "sess_201" in _all_session_ids(notifications)


def test_R1c_control_the_re_seek_recovers_an_unspent_ladder(monkeypatch) -> None:
    """CONTROL (does not land): with the budget unspent, the re-seek does
    recover a ladder pointing past a shrunken library."""

    monkeypatch.setenv(SESSION_ROTATION_ENV, "on")
    runtime = PagedRuntime()
    runtime.page_one = (_meta(0, projection_outdated=True),)
    runtime.rotation_pages = {
        SESSION_ROTATION_FIRST_OFFSET: (_meta(101, requires_sync=True),)
    }
    host = StatefulRecordingHost()
    host.state[ROTATION_STATE_KEY] = {
        "version": 1,
        "active": True,
        "offset": 5000,
        "circleCandidates": 0,
        "circleRebuilt": 0,
        "circleStalls": 0,
    }
    runner, _notifications = _runner(runtime, host)

    for _cycle in range(6):
        asyncio.run(runner.sync_existing_once())

    assert SESSION_ROTATION_FIRST_OFFSET in [
        int(c) for c in runtime.cursors if c is not None
    ]


# ---------------------------------------------------------------------------
# ATTACK B — the _repage_sessions duck type
# ---------------------------------------------------------------------------


class _PlainRuntime:
    """A runtime with no page type of its own (codex/dsh shape)."""

    identity = SimpleNamespace(runtime="codex", runtime_id="codex")

    def __init__(self) -> None:
        self.calls: list[str] = []

    async def list_sessions(
        self, limit: int = 100, cursor: str | None = None, force: bool = False
    ) -> tuple[Any, ...]:
        self.calls.append("list_sessions")
        return ()

    async def list_complete_session_inventory(
        self, page_size: int = 100, force: bool = False
    ) -> tuple[Any, ...]:
        self.calls.append("inventory")
        return ()


def test_R1c_control_a_runtime_without_a_page_type_is_left_alone() -> None:
    """CONTROL (does not land): the duck type does not re-wrap a runtime that
    has nothing to say — a plain tuple in, a plain tuple out, so the
    codex/dsh shape is untouched by the P0 repair."""

    native = _PlainRuntime()
    bound = RuntimeInstance(
        instance=RuntimeInstanceSpec(
            runtime_id="codex", runtime_type="codex", name="Codex"
        ),
        native_runtime=native,  # type: ignore[arg-type]
    )

    page = asyncio.run(bound.list_sessions(limit=100, cursor="100"))
    inventory = asyncio.run(bound.list_complete_session_inventory(page_size=100))

    assert type(page) is tuple
    assert type(inventory) is tuple
    assert _page_read_failed(page) is False
    assert native.calls == ["list_sessions", "inventory"]


def test_R1c_control_the_inventory_line_keeps_its_shape() -> None:
    """CONTROL (does not land): the repair also runs on the inventory path,
    and for a runtime with no page type that path is unchanged — so the
    complete-inventory branch (which never consults the flags) cannot be
    disturbed by the P0 fix."""

    native = _PlainRuntime()
    bound = RuntimeInstance(
        instance=RuntimeInstanceSpec(
            runtime_id="codex", runtime_type="codex", name="Codex"
        ),
        native_runtime=native,  # type: ignore[arg-type]
    )

    assert asyncio.run(bound.list_complete_session_inventory(page_size=100)) == ()


# ---------------------------------------------------------------------------
# ATTACK C — the raised floor still has no file-silence gate
# ---------------------------------------------------------------------------


def test_R1c_P2_a_silent_live_task_is_closed_by_the_other_rule_not_the_ceiling(
    monkeypatch,
) -> None:
    """ATTACK that does NOT land (recorded because the deviation was asked
    about): a live task whose transcript has been quiet for longer than
    `stale_seconds` is already closed by `agentFileStale`, which runs FIRST
    and keeps its own label.

    So the ceiling's missing file-silence gate does not add a new false close
    for the "alive but silent" shape — that card is closed either way, by the
    older and better-evidenced rule. The ceiling only ever reaches the
    fresh-file shape, which is the re-stamped-mtime residue it was written
    for."""

    monkeypatch.setenv(SUBAGENT_AGE_BOUND_ENV, "1h")
    oracle = _oracle(now=NOW, files={TASK_ID: _fresh_file(NOW - 1000.0)})
    assert oracle.age_bound_seconds == 3600.0

    silent = oracle.evidence(
        task_id=TASK_ID,
        external_session_id="e89abce5-f48c-463b-8d16-d3f78dd504c4",
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=7200.0,
        attached_live=False,
        now_ms=int(NOW * 1000),
    )
    assert silent is not None
    assert silent.closed_by == "agentFileStale", "the ceiling must not claim this"

    # And with a fresh file the ceiling is the one that fires, which is the
    # only shape it was ever meant to reach.
    fresh_oracle = _oracle(now=NOW, files={TASK_ID: _fresh_file(NOW)})
    fresh = fresh_oracle.evidence(
        task_id=TASK_ID,
        external_session_id="e89abce5-f48c-463b-8d16-d3f78dd504c4",
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=7200.0,
        attached_live=False,
        now_ms=int(NOW * 1000),
    )
    assert fresh is not None
    assert fresh.closed_by == "ageBounded"


def test_R1c_control_the_floor_is_an_hour_and_dangerous_forms_are_refused() -> None:
    """CONTROL: the floor is now 3600s and the parser refuses everything that
    could arm the judgement below it."""

    assert SUBAGENT_AGE_BOUND_FLOOR_SECONDS == 3600.0
    for refused in ("0", "59", "600", "1800", "3599", "0.5", "30s", "45m", "abc", ""):
        assert _parse_age_bound_seconds(refused) is None or float(
            _parse_age_bound_seconds(refused) or 0
        ) < SUBAGENT_AGE_BOUND_FLOOR_SECONDS, refused
    assert _parse_age_bound_seconds("1h") == 3600.0
    assert _parse_age_bound_seconds("24h") == 86400.0
    assert _parse_age_bound_seconds("2d") == 172800.0


# ---------------------------------------------------------------------------
# ATTACK D — scanner-anchor priority, and the retained raw-side pollution
# ---------------------------------------------------------------------------


def _echo_raw_line(at_ms: int) -> str:
    """A transcript line that merely CONTAINS `agentId:` — not a receipt.

    An assistant row quoting a run, which the raw scanner used to accept: it
    re-stamped a dead task's launch anchor and, with the priority rule on top,
    nothing could pull it back."""

    return json.dumps(
        {
            "type": "assistant",
            "uuid": f"echo-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": f"summary of run agentId: {TASK_ID}"}
                ],
            },
        }
    )


def _bare_receipt_raw_line(at_ms: int) -> str:
    """F5's receipt: the engine's answer to a dispatch call, with no call row.

    The transcript may no longer hold the `tool_use` this answers, and nothing
    here can be tied back to one — which is exactly why it must not be thrown
    away, and exactly why a free-text mention is allowed to overrule it."""

    return json.dumps(
        {
            "type": "user",
            "uuid": f"bare-receipt-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": DISPATCH_TUID,
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
                ],
            },
        }
    )


def _verified_receipt_raw_lines(at_ms: int) -> tuple[str, ...]:
    """The same receipt with its dispatch call — provenance the scan can verify."""

    call = json.dumps(
        {
            "type": "assistant",
            "uuid": f"dispatch-{at_ms}",
            "timestamp": _iso(at_ms),
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": DISPATCH_TUID,
                        "name": "Agent",
                        "input": {"description": "D0", "prompt": "Recon."},
                    }
                ],
            },
        }
    )
    return (call, _bare_receipt_raw_line(at_ms))


def _mention(timestamp_ms: int) -> Any:
    """F5's supplement in the SDK view: a timestamped message naming the id.

    The supplement is free text as far as the fold is concerned — it reads
    `agentId:` out of whatever text the message carries — so this is the shape
    a genuine launch looks like when only the message view has it, and the
    shape a stray quote looks like too. That ambiguity is exactly why the
    scanner's VERIFIED anchor outranks it (R1c R3-2)."""

    return SimpleNamespace(
        type="user",
        uuid=f"mention-{timestamp_ms}",
        timestamp=timestamp_ms,
        message={
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": (
                        "Async agent launched successfully.\n"
                        f"agentId: {TASK_ID} (internal ID)"
                    ),
                }
            ],
        },
    )


def _card(items: tuple[Any, ...]) -> Any:
    return next(item for item in items if item.content.get("kind") == "agent_call")


# ---------------------------------------------------------------------------
# ATTACK D — scanner-anchor priority, and the retained raw-side pollution
# ---------------------------------------------------------------------------


def test_R1c_P2_a_raw_echo_no_longer_moves_the_dead_tasks_anchor() -> None:
    """RESIDUAL, flipped: a line that only quotes `agentId:` is not a receipt.

    The echo the attacker wrote is an assistant row quoting a run, and the raw
    scanner used to take its timestamp as the task's launch. That is now gated
    on the row's shape, so the quote contributes nothing at all — and the card
    below closes on the real 26-hour-old receipt with the same echo sitting in
    the transcript, which is the half that matters: the echo is inert, not the
    closure path."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)
    echo_ms = int((NOW - 600.0) * 1000)

    # Inert at the source...
    assert scan_raw_transcript(
        (_bare_receipt_raw_line(old_ms), _echo_raw_line(echo_ms))
    ).receipt_times_ms == {TASK_ID: old_ms}
    assert scan_raw_transcript((_echo_raw_line(echo_ms),)).receipt_times_ms == {}

    # ...and inert at the card: a genuine receipt 26h old, a fresh file, and an
    # echo 10 minutes old in the same transcript.
    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=(_bare_receipt_raw_line(old_ms), _echo_raw_line(echo_ms)),
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = _card(items)
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"
    assert card.content["endTime"] == old_ms

    # Control: strip the receipt and the echo cannot stand in for it — no
    # anchor, so no ceiling. The closure above was the receipt's doing.
    echo_only = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=(_echo_raw_line(old_ms),),
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    echo_only_card = _card(echo_only)
    assert echo_only_card.status == "running"
    assert "closedByEvidence" not in echo_only_card.content


def test_R1c_P2_the_ceiling_reads_the_raw_anchor_only() -> None:
    """The ceiling's own anchor (R1c): neither pollution surface can defer it.

    The age ceiling is the one judgement where a newer anchor is not a harmless
    tie — it defers a HARD closure, and while the session keeps being written
    the file stays fresh so `agentFileStale` never fires either. So the ceiling
    is given an age of its own, taken from the raw transcript with no
    message-view supplement at all. Both surfaces are polluted here at once: an
    assistant echo in the transcript and a timestamped mention in the message
    view, both 10 minutes old, against a real receipt 26h old."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)
    fresh_ms = int((NOW - 600.0) * 1000)

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message(), _mention(fresh_ms)),
        raw_lines=(_bare_receipt_raw_line(old_ms), _echo_raw_line(fresh_ms)),
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = _card(items)
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "ageBounded"
    assert card.content["endTime"] == old_ms


def test_R1c_control_no_raw_anchor_means_no_ceiling_closure() -> None:
    """CONTROL for the ceiling's anchor: absent evidence is not borrowed.

    The ceiling judges on its own anchor, and this pins the other half of that:
    a task the raw transcript has nothing for is not handed the free-text
    supplement as a stand-in. The mention below is 26 hours old and would
    satisfy the ceiling on its own — that is the whole reason the two ages are
    kept apart — so a card that closes here means the ceiling quietly fell back
    to the polluted age, and a card that closes on this shape is the deferral
    the repair exists to stop."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message(), _mention(old_ms)),
        raw_lines=(_echo_raw_line(old_ms),),  # quoting only: no launch evidence
        oracle=_oracle(
            now=NOW, files={TASK_ID: _fresh_file(NOW)}, age_bound=T_AGE_BOUND
        ),
    )
    card = _card(items)
    assert card.status == "running", card.content.get("closedByEvidence")
    assert "closedByEvidence" not in card.content


def test_R1c_P2_a_genuine_newer_receipt_beats_an_unverified_anchor() -> None:
    """ATTACK (P2), flipped: the priority rule is no longer one-way.

    The scanner put a 26-hour-old anchor on this task and nothing ties it to a
    call (F5's bare result), while the real launch is in the message view five
    minutes ago. Before the fix the older anchor won unconditionally and the
    card closed on it. Now an unverified scanner anchor yields to a strictly
    newer receipt, so a task that launched five minutes ago is not mistaken for
    one that launched a day ago.

    Driven at the never-started rule, which reads this anchor: with a ten-minute
    start grace the two anchors give opposite verdicts, so the closure can only
    be the scanner's or the message view's, never neither."""

    stale_ms = int((NOW - (T_AGE_BOUND + 7200.0)) * 1000)  # scanner: 26h ago
    real_ms = int((NOW - 300.0) * 1000)  # the real launch: 5 minutes ago

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message(), _mention(real_ms)),
        raw_lines=(_bare_receipt_raw_line(stale_ms),),
        oracle=_oracle(
            now=NOW,
            files={},  # no transcript at all: the never-started rule decides
            start_grace=600.0,
            age_bound=T_AGE_BOUND,
        ),
    )
    card = _card(items)
    assert card.status == "running", card.content
    assert "closedByEvidence" not in card.content


def test_R1c_control_a_verified_scanner_anchor_is_not_overruled() -> None:
    """CONTROL for the rule above: a receipt the scan can verify keeps it.

    This is the part of R1b's rule that must not move: the scanner's own
    receipt IS the evidence the closure is supposed to rest on, so a free-text
    mention ten minutes old cannot re-stamp a task the engine dispatched a day
    ago — which would defer the never-started closure for as long as anyone
    kept mentioning it."""

    stale_ms = int((NOW - (T_AGE_BOUND + 7200.0)) * 1000)
    fresh_ms = int((NOW - 300.0) * 1000)

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message(), _mention(fresh_ms)),
        raw_lines=_verified_receipt_raw_lines(stale_ms),
        oracle=_oracle(
            now=NOW,
            files={},
            start_grace=600.0,
            age_bound=T_AGE_BOUND,
        ),
    )
    card = _card(items)
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "neverStarted"
    assert card.content["endTime"] == stale_ms


def test_R1c_control_a_bare_receipt_still_dates_its_task() -> None:
    """CONTROL for the shape gate: F5's bare receipt must survive it.

    The gate that stops the assistant echo stops on the row's shape, and the
    shape F5 depends on is a user row carrying the receipt body — here with no
    transcript file to read, so the never-started closure is reachable only
    because the receipt was admitted. Drop it and this closure disappears."""

    old_ms = int((NOW - (T_AGE_BOUND + 3600.0)) * 1000)

    assert scan_raw_transcript(
        (_bare_receipt_raw_line(old_ms),)
    ).receipt_times_ms == {TASK_ID: old_ms}

    items = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=(_bare_receipt_raw_line(old_ms),),
        oracle=_oracle(
            now=NOW,
            files={},
            start_grace=600.0,
            age_bound=T_AGE_BOUND,
        ),
    )
    card = _card(items)
    assert card.status == "interrupted"
    assert card.content["closedByEvidence"] == "neverStarted"

    # ...and with no receipt row anywhere the same card stays open, which is
    # what proves the closure above came from the bare row.
    without = _history_items_from_messages(
        _session(),
        (_dispatch_message(), _receipt_message()),
        raw_lines=(),
        oracle=_oracle(
            now=NOW,
            files={},
            start_grace=600.0,
            age_bound=T_AGE_BOUND,
        ),
    )
    assert _card(without).status == "running"


# ---------------------------------------------------------------------------
# CONTROLS
# ---------------------------------------------------------------------------


def test_R1c_control_the_bound_page_still_carries_both_flags() -> None:
    """CONTROL: the P0 repair holds on the production call path."""

    from test_red_r1b_attack import _RaisingHistorySdk

    host = _RecordingHost()
    sdk = _RaisingHistorySdk(
        sessions=[
            SimpleNamespace(
                session_id="claude_a", summary="A", last_modified=1, file_size=1, cwd="/r"
            )
        ]
    )
    bound = RuntimeInstance(instance=_spec(), native_runtime=_runtime(host=host, sdk=sdk))

    page = asyncio.run(bound.list_sessions(limit=100, cursor="100"))

    assert _page_read_failed(page) is True
    assert page.history_scanned == 0


def test_R1c_control_a_mid_library_window_of_unreadable_rows_is_visible() -> None:
    """CONTROL: `history_scanned` now counts the rows the SDK really returned."""

    host = _RecordingHost()
    sessions: list[Any] = []
    for index in range(400):
        row = SimpleNamespace(
            summary=f"drift {index}",
            last_modified=1_789_000_000_000 - index,
            file_size=1,
            cwd="/repo",
        )
        if not 200 <= index < 300:
            row.session_id = f"claude_{index:03d}"
        sessions.append(row)
    runtime = _runtime(host=host, sdk=_HistorySdk(sessions=sessions))

    page = asyncio.run(runtime.list_sessions(limit=100, cursor="200"))

    assert len(page) == 0
    assert page.history_scanned == 100