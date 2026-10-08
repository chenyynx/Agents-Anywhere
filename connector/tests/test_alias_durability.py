"""Alias-lineage durability: persisted resolution + same-task terminal truth.

Why this file exists
--------------------
``.local-dev/subagent-alias-durability-tasks.md`` (T1). Session
``sess_Nk19-gOK4L5Eaw`` lost its resume lineage when the connector restarted
at 01:40: the resumed tasks' frames arrived keyed on the *SendMessage*
tool_use id, but the new process had never seen the dispatch frames — so the
in-process join maps were empty, the fold failed closed, and it minted a
second card under the SendMessage id. The original dispatch cards froze
``running`` forever while their twins closed correctly (two cards per task).

The fix has two halves and this file pins both with synthetic fixtures shaped
exactly like the incident (the real transcript bodies never enter the repo):

* **A — persisted resolution** (``scan_raw_transcript``'s ``send_aliases`` /
  ``dispatch_roots`` + the projector's fallback chain): the resume join is
  read back from the engine's own transcript, so a restarted process still
  folds the resumed task's frames onto the original dispatch card. The
  in-process maps stay the hot path and are backfilled from a persisted hit.
* **B — same-task terminal truth** (``fold_agent_task_items``): a terminal
  verdict (or a running re-open) reaches every other card id the task can
  live under — existing twins are synchronised, engine-evidenced dispatch
  roots with no local card are published, and nothing stronger is ever walked
  backwards. Nothing is minted from an alias id whose card was never seen.

The scan is injected through the projector's ``raw_scan_provider`` seam (and
monkeypatched at the module default for the reader-path test), so no test
touches the real disk or the wall clock.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any

from connector.runtime_protocol import RuntimeTimelineItem
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.sessions.subagent_oracle import (
    scan_raw_transcript,
)
from connector.runtimes.claude.timeline import messages as messages_module
from connector.runtimes.claude.timeline.agent_calls import (
    ClaudeAgentTaskOverlay,
    resolve_resume_alias_from_scan,
    resolve_task_card_from_timeline,
)
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    stable_tool_item_id,
)

SESSION_ID = "sess_alias_durability"
EXTERNAL_SESSION_ID = "alias-durability-session"
DISPATCH = "call_dispatch_root_a"
SEND = "call_sendmsg_alias_a"
SEND2 = "call_sendmsg_alias_b"
ROOT_A = "call_dispatch_root_b"
ROOT_B = "call_dispatch_root_c"
# Real task ids are pure alphanumeric (the CLI's own shape): the scanner's
# ``agentId:`` wording stops at a non-alnum byte, so a fixture with an
# underscore would not reproduce what the engine writes.
TASK = "task9a1b2c3d4e5f607"


def _session() -> ClaudeSession:
    # No cwd: even a stray call to the default scan seam stays off the real
    # disk (the reader scanner declines a session without cwd).
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
    )


# --------------------------------------------------------------------------
# Synthetic raw-row fixtures (shapes trimmed from the incident, ids invented)
# --------------------------------------------------------------------------


def _raw_send_row(uuid: str, tool_use_id: str, task_id: str) -> str:
    """An assistant row carrying the SendMessage call that resumes a task."""

    return json.dumps(
        {
            "type": "assistant",
            "uuid": uuid,
            "timestamp": "2026-10-09T01:52:17.000Z",
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": tool_use_id,
                        "name": "SendMessage",
                        "input": {"to": task_id, "message": "keep going"},
                    }
                ],
            },
        }
    )


def _raw_resume_row(uuid: str, tool_use_id: str, task_id: str) -> str:
    """The user row acknowledging the resume (body JSON + structured details)."""

    body = json.dumps(
        {
            "success": True,
            "message": "Resuming agent",
            "resumedAgentId": task_id,
            "pin": {"id": task_id, "ref": "713524"},
        }
    )
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "timestamp": "2026-10-09T01:52:23.907Z",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": tool_use_id,
                        "content": [{"type": "text", "text": body}],
                    }
                ],
            },
            "toolUseResult": {
                "success": True,
                "message": "Resuming agent",
                "resumedAgentId": task_id,
                "pin": {"id": task_id, "ref": "713524"},
            },
        }
    )


def _raw_receipt_row(
    uuid: str,
    tool_use_id: str,
    task_id: str,
    *,
    body: bool = True,
    structured: bool = True,
) -> str:
    """The dispatch receipt row (line-style body and/or structured details)."""

    text = (
        f"Async agent launched successfully. (internal metadata)\n"
        f"agentId: {task_id} (internal ID - do not mention to user.)\n"
        f"The agent is working in the background."
    )
    row: dict[str, Any] = {
        "type": "user",
        "uuid": uuid,
        "timestamp": "2026-10-09T01:28:43.000Z",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": (
                        [{"type": "text", "text": text if body else "(elided)"}]
                    ),
                }
            ],
        },
    }
    if structured:
        row["toolUseResult"] = {
            "isAsync": True,
            "status": "async_launched",
            "agentId": task_id,
        }
    return json.dumps(row)


def _incident_scan():
    """The full transcript of the incident shape: dispatch + resume + receipt."""

    return scan_raw_transcript(
        (
            _raw_receipt_row("r1", DISPATCH, TASK),
            _raw_send_row("s1", SEND, TASK),
            _raw_resume_row("s2", SEND, TASK),
        )
    )


def _empty_scan():
    return scan_raw_transcript(())


def _parsed_send_frame() -> SimpleNamespace:
    """A wire SendMessage frame, the shape the live projector consumes."""

    return SimpleNamespace(
        type="assistant",
        uuid="wire-send",
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": SEND,
                    "name": "SendMessage",
                    "input": {"to": TASK, "message": "keep going"},
                }
            ],
        },
    )


def _overlay(*, status: str, **entry: Any) -> ClaudeAgentTaskOverlay:
    agent = {"status": status}
    agent.update(entry)
    return ClaudeAgentTaskOverlay(agents={TASK: agent})


def _fold(
    projector: ClaudeMessageProjector,
    session: ClaudeSession,
    *,
    tool_use_id: str,
    overlay: ClaudeAgentTaskOverlay,
    status: str | None,
):
    return projector.fold_agent_task_event(
        session,
        tool_use_id=tool_use_id,
        overlay=overlay,
        status=status,
    )


# --------------------------------------------------------------------------
# A-1: the scanner's persisted lineage
# --------------------------------------------------------------------------


def test_scan_learns_the_sendmessage_alias_from_input_to() -> None:
    scan = scan_raw_transcript((_raw_send_row("s1", SEND, TASK),))
    assert scan.send_aliases == {SEND: TASK}
    # A SendMessage row alone teaches nothing about dispatch roots.
    assert scan.dispatch_roots == {}


def test_scan_learns_the_resume_alias_from_body_and_structured_details() -> None:
    # Both surfaces carry it; either alone must be enough.
    row_with_body = _raw_resume_row("s2", SEND, TASK)
    assert scan_raw_transcript((row_with_body,)).send_aliases == {SEND: TASK}
    structured_only = json.loads(row_with_body)
    structured_only["message"]["content"][0]["content"] = [
        {"type": "text", "text": "(elided)"}
    ]
    scan = scan_raw_transcript((json.dumps(structured_only),))
    assert scan.send_aliases == {SEND: TASK}


def test_scan_does_not_treat_a_resume_row_as_a_dispatch_root() -> None:
    # The resume body carries ``resumedAgentId`` — camelCase — and its task id
    # must never leak into dispatch_roots through the ``agentId:`` wording.
    scan = scan_raw_transcript(
        (_raw_send_row("s1", SEND, TASK), _raw_resume_row("s2", SEND, TASK))
    )
    assert scan.dispatch_roots == {}
    assert scan.send_aliases == {SEND: TASK}


def test_scan_learns_dispatch_roots_from_body_and_structured_shapes() -> None:
    full = scan_raw_transcript((_raw_receipt_row("r1", DISPATCH, TASK),))
    assert full.dispatch_roots == {TASK: frozenset({DISPATCH})}
    body_only = scan_raw_transcript(
        (_raw_receipt_row("r2", DISPATCH, TASK, structured=False),)
    )
    assert body_only.dispatch_roots == {TASK: frozenset({DISPATCH})}
    structured_only = scan_raw_transcript(
        (_raw_receipt_row("r3", DISPATCH, TASK, body=False),)
    )
    assert structured_only.dispatch_roots == {TASK: frozenset({DISPATCH})}


def test_scan_keeps_every_root_of_an_ambiguous_task() -> None:
    scan = scan_raw_transcript(
        (
            _raw_receipt_row("r1", DISPATCH, TASK),
            _raw_receipt_row("r2", ROOT_A, TASK),
        )
    )
    assert scan.dispatch_roots == {TASK: frozenset({DISPATCH, ROOT_A})}


def test_scan_never_attributes_row_details_when_the_row_has_two_results() -> None:
    row = json.loads(_raw_receipt_row("r4", DISPATCH, TASK, body=False))
    row["message"]["content"].append(
        {
            "type": "tool_result",
            "tool_use_id": ROOT_A,
            "content": [{"type": "text", "text": "ok"}],
        }
    )
    scan = scan_raw_transcript((json.dumps(row),))
    # The structured agentId belongs to one of two blocks; guessing would
    # splice the root onto the wrong call, so it is declined entirely.
    assert scan.dispatch_roots == {}


def test_scan_ignores_non_tool_rows_and_hostile_shapes() -> None:
    hostile = (
        json.dumps({"type": "attachment", "uuid": "a1", "content": "resumedAgentId"}),
        json.dumps(
            {
                "type": "queue-operation",
                "operation": "enqueue",
                "content": '{"resumedAgentId": "task_x"}',
            }
        ),
        json.dumps(
            {
                "type": "user",
                "uuid": "u9",
                "message": {"role": "user", "content": "not a list"},
                "toolUseResult": {"agentId": 7},
            }
        ),
        json.dumps(
            {
                "type": "user",
                "uuid": "u10",
                "message": {
                    "role": "user",
                    "content": [
                        {"type": "tool_result", "tool_use_id": None, "content": 12},
                        {"type": "tool_result", "tool_use_id": "call_x", "content": [5]},
                    ],
                },
                "toolUseResult": "no",
            }
        ),
        "{ not json",
    )
    scan = scan_raw_transcript(hostile)
    assert scan.send_aliases == {}
    assert scan.dispatch_roots == {}
    assert scan.notices == ()


# --------------------------------------------------------------------------
# A-2: the fallback chain's own rules (pure functions)
# --------------------------------------------------------------------------


def test_resolve_from_scan_keeps_the_single_root_contract() -> None:
    sends = {SEND: TASK}
    assert resolve_resume_alias_from_scan(
        SEND, send_aliases=sends, dispatch_roots={TASK: frozenset({DISPATCH})}
    ) == (TASK, DISPATCH)
    # Not an alias at all.
    assert (
        resolve_resume_alias_from_scan(
            DISPATCH, send_aliases=sends, dispatch_roots={TASK: frozenset({DISPATCH})}
        )
        is None
    )
    # Alias whose receipt never landed.
    assert (
        resolve_resume_alias_from_scan(
            SEND, send_aliases=sends, dispatch_roots={}
        )
        is None
    )
    # Ambiguity stays ambiguous.
    assert (
        resolve_resume_alias_from_scan(
            SEND,
            send_aliases=sends,
            dispatch_roots={TASK: frozenset({DISPATCH, ROOT_A})},
        )
        is None
    )
    # A self-referential mapping never loops back on itself.
    assert (
        resolve_resume_alias_from_scan(
            SEND, send_aliases=sends, dispatch_roots={TASK: frozenset({SEND})}
        )
        is None
    )
    # No scan content at all.
    assert (
        resolve_resume_alias_from_scan(
            SEND, send_aliases=None, dispatch_roots=None
        )
        is None
    )


def _timeline_item(native: str, task_id: str) -> RuntimeTimelineItem:
    return RuntimeTimelineItem(
        id=f"claude_tool_{native}",
        session_id=SESSION_ID,
        type="tool",
        status="running",
        order_seq=1,
        content_hash="hash",
        role="tool",
        content={"kind": "agent_call", "agents": {task_id: {"status": "running"}}},
        source={"runtime": "claude", "itemId": native},
    )


def test_resolve_from_timeline_needs_a_unique_non_alias_card() -> None:
    items = {
        "a": _timeline_item(DISPATCH, TASK),
        "b": _timeline_item(SEND, TASK),  # an alias-keyed twin: not a root
    }
    assert (
        resolve_task_card_from_timeline(
            task_id=TASK,
            timeline_items=items,
            alias_keys={SEND},
            exclude=SEND2,
        )
        == DISPATCH
    )
    # Two genuine roots are ambiguity.
    two_roots = {"a": _timeline_item(DISPATCH, TASK), "b": _timeline_item(ROOT_A, TASK)}
    assert (
        resolve_task_card_from_timeline(
            task_id=TASK, timeline_items=two_roots, alias_keys=set(), exclude=SEND
        )
        is None
    )
    # No card names the task.
    other = {"a": _timeline_item(DISPATCH, "task_other")}
    assert (
        resolve_task_card_from_timeline(
            task_id=TASK, timeline_items=other, alias_keys=set(), exclude=SEND
        )
        is None
    )
    # The alias being folded never resolves to itself.
    assert (
        resolve_task_card_from_timeline(
            task_id=TASK,
            timeline_items={"b": _timeline_item(SEND, TASK)},
            alias_keys=set(),
            exclude=SEND,
        )
        is None
    )


# --------------------------------------------------------------------------
# A-2: the fold's chain — order, uniqueness, backfill, fail-closed
# --------------------------------------------------------------------------


def test_fold_lands_the_original_card_from_a_post_restart_window() -> None:
    """The incident shape: dispatch outside the window, resume inside it."""

    session = _session()
    canonical = stable_tool_item_id(session, DISPATCH)
    scan = _incident_scan()

    # A fresh process: it has seen the SendMessage frame (the alias map has
    # the join) but no dispatch frame, so the root map is empty.
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _session: scan)
    projector._send_to_task[SEND] = TASK
    assert projector._task_roots.get(TASK) is None

    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert item.id == canonical
    # No twin under the SendMessage id — the persistence gap is what minted it.
    assert stable_tool_item_id(session, SEND) not in projector._agent_cards
    # The persisted hit backfilled both maps: later frames take the hot path.
    assert projector._send_to_task[SEND] == TASK
    assert projector._task_roots[TASK] == {DISPATCH}

    final = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed", summary="done"),
        status="done",
    )
    assert final.id == canonical
    assert final.status == "done"
    assert final.content["agents"][TASK]["status"] == "completed"


def test_fold_resolves_even_when_the_frame_window_missed_the_send_message() -> None:
    # A restart so late that neither the dispatch nor the SendMessage frame is
    # in-process: the persisted alias map alone must carry the join.
    session = _session()
    scan = _incident_scan()
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert item.id == stable_tool_item_id(session, DISPATCH)


def test_fold_prefers_in_process_lineage_and_backfills_without_rescanning() -> None:
    session = _session()
    calls = {"n": 0}

    def provider(_session: ClaudeSession):
        calls["n"] += 1
        return _incident_scan()

    projector = ClaudeMessageProjector(raw_scan_provider=provider)
    first = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert first.id == stable_tool_item_id(session, DISPATCH)
    assert calls["n"] == 1
    # Second frame: the backfilled maps answer, the scan is not consulted.
    second = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert second.id == first.id
    assert calls["n"] == 1


def test_in_process_lineage_outranks_a_conflicting_scan() -> None:
    """The chain only takes over where the in-process resolution returned None."""

    session = _session()
    conflicting = {"scan": _incident_scan(), "calls": 0}

    def provider(_session: ClaudeSession):
        conflicting["calls"] += 1
        return conflicting["scan"]

    projector = ClaudeMessageProjector(raw_scan_provider=provider)
    first = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert first.id == stable_tool_item_id(session, DISPATCH)
    calls_after_first = conflicting["calls"]

    # A plain running frame resolves entirely in-process: the fallback (and
    # its scan read) must not run at all.
    running_again = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert running_again.id == first.id
    assert conflicting["calls"] == calls_after_first

    # A richer scan claims a different root for the same task; even a terminal
    # frame (whose sibling walk does read the scan) must keep the root the hot
    # path already resolved.
    conflicting["scan"] = scan_raw_transcript(
        (
            _raw_send_row("s1", SEND, TASK),
            _raw_receipt_row("r9", ROOT_A, TASK),
        )
    )
    second = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert second.id == stable_tool_item_id(session, DISPATCH)


def test_post_restart_window_fold_never_mints_the_alias_id() -> None:
    """The sheet's incident unit shape: only post-restart frames are projected.

    The SendMessage frame is in the window (so the alias map learns the join),
    the dispatch and its receipt are not — the exact state the restarted
    process was in. The fold must land the canonical dispatch id and mint no
    card under the alias.
    """

    session = _session()
    scan = _incident_scan()
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    # Only the SendMessage frame arrives (its own tool_result too, as on the
    # wire); nothing else of the dispatch exists in-process.
    projector.tool_items_for_message(
        session=session,
        turn_id="t2",
        message=_parsed_send_frame(),
    )
    assert projector._send_to_task == {SEND: TASK}
    assert projector._task_roots.get(TASK) is None

    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert item.id == stable_tool_item_id(session, DISPATCH)
    assert stable_tool_item_id(session, SEND) not in projector._agent_cards
    assert projector._task_roots[TASK] == {DISPATCH}


def test_fold_falls_back_to_the_projected_timeline_when_receipts_are_gone() -> None:
    session = _session()
    # The scan knows the alias but has no receipt row to pin a root.
    scan = scan_raw_transcript((_raw_send_row("s1", SEND, TASK),))
    session.timeline_items["a"] = _timeline_item(DISPATCH, TASK)
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert item.id == stable_tool_item_id(session, DISPATCH)
    assert projector._task_roots[TASK] == {DISPATCH}


def test_fold_stays_fail_closed_without_any_evidence() -> None:
    session = _session()
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: None)
    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    # Today's behaviour, byte for byte: the id stays as it came.
    assert item.id == stable_tool_item_id(session, SEND)
    assert projector._task_roots == {}


def test_fold_survives_a_failing_scan_provider() -> None:
    session = _session()

    def broken(_session: ClaudeSession):
        raise RuntimeError("transcript unreadable")

    projector = ClaudeMessageProjector(raw_scan_provider=broken)
    item = _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert item.id == stable_tool_item_id(session, SEND)


# --------------------------------------------------------------------------
# B: the terminal verdict reaches every derived card id
# --------------------------------------------------------------------------


def test_terminal_fold_closes_an_alias_twin_card() -> None:
    """The incident's twin: a card minted under the alias before the fix."""

    session = _session()
    canonical = stable_tool_item_id(session, DISPATCH)
    twin = stable_tool_item_id(session, SEND)
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: _empty_scan())
    # A pre-fix fold (no lineage anywhere) minted the twin.
    _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert twin in projector._agent_cards

    # The lineage becomes readable (restart, redeploy): the same task's
    # terminal frame now lands canonical, and the twin must close with it.
    projector._raw_scan_provider = lambda _s: _incident_scan()
    items = projector.fold_agent_task_items(
        session,
        tool_use_id=SEND,
        overlay=ClaudeAgentTaskOverlay(
            agents={TASK: {"status": "completed"}},
            summary="all done",
            end_time=1_791_000_000_000,
        ),
        status="done",
    )
    assert items[0].id == canonical
    assert [item.id for item in items] == [canonical, twin]
    twin_item = items[1]
    assert twin_item.status == "done"
    assert twin_item.content["agents"][TASK]["status"] == "completed"
    assert twin_item.content["summary"] == "all done"
    assert twin_item.content["endTime"] == 1_791_000_000_000

    # Idempotent: a repeated fold republishes the canonical card only.
    again = projector.fold_agent_task_items(
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert [item.id for item in again] == [canonical]
    assert projector._agent_cards[twin].status == "done"


def test_terminal_fold_mints_engine_evidenced_roots_without_local_cards() -> None:
    session = _session()
    # Two receipt rows claim the same task: the resolution stays fail-closed
    # (ambiguity), but both roots are engine facts and get the verdict.
    scan = scan_raw_transcript(
        (
            _raw_send_row("s1", SEND, TASK),
            _raw_receipt_row("r1", ROOT_A, TASK),
            _raw_receipt_row("r2", ROOT_B, TASK),
        )
    )
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    items = projector.fold_agent_task_items(
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert items[0].id == stable_tool_item_id(session, SEND)
    assert sorted(item.id for item in items) == sorted(
        stable_tool_item_id(session, tool_use_id)
        for tool_use_id in (SEND, ROOT_A, ROOT_B)
    )
    assert {item.status for item in items} == {"done"}
    # Ambiguity resolved nothing in-process; both maps stay honest.
    assert projector._task_roots == {}


def test_terminal_fold_never_mints_a_card_for_an_alias_without_one() -> None:
    session = _session()
    # Two aliases map to the task; neither ever had a card. The canonical root
    # is folded, and no alias id may be fabricated into a visible card.
    scan = scan_raw_transcript(
        (
            _raw_send_row("s1", SEND, TASK),
            _raw_send_row("s2", SEND2, TASK),
            _raw_receipt_row("r1", DISPATCH, TASK),
        )
    )
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    items = projector.fold_agent_task_items(
        session,
        tool_use_id=DISPATCH,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert [item.id for item in items] == [stable_tool_item_id(session, DISPATCH)]
    assert stable_tool_item_id(session, SEND) not in projector._agent_cards
    assert stable_tool_item_id(session, SEND2) not in projector._agent_cards


def test_a_terminal_sibling_is_never_walked_backwards() -> None:
    session = _session()
    twin = stable_tool_item_id(session, SEND)
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: _empty_scan())
    _fold(
        projector,
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert projector._agent_cards[twin].status == "done"
    # A later interrupted verdict for the same task must leave it untouched.
    projector._raw_scan_provider = lambda _s: _incident_scan()
    items = projector.fold_agent_task_items(
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="killed"),
        status="interrupted",
    )
    assert twin not in [item.id for item in items]
    assert projector._agent_cards[twin].status == "done"


def test_reopen_spreads_running_to_root_backed_ids_only() -> None:
    session = _session()
    holder = {"scan": scan_raw_transcript((_raw_receipt_row("r1", ROOT_A, TASK),))}
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: holder["scan"])
    closed = projector.fold_agent_task_items(
        session,
        tool_use_id=ROOT_A,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert [item.id for item in closed] == [stable_tool_item_id(session, ROOT_A)]

    # A second root appears (the task was dispatched twice); the started event
    # re-opens the canonical card, and the root with no card is published in
    # the re-opened state too — it is engine evidence, an alias would not be.
    holder["scan"] = scan_raw_transcript(
        (
            _raw_receipt_row("r1", ROOT_A, TASK),
            _raw_receipt_row("r2", ROOT_B, TASK),
        )
    )
    reopened = projector.fold_agent_task_items(
        session,
        tool_use_id=ROOT_A,
        overlay=_overlay(status="running"),
        status="running",
    )
    assert [item.id for item in reopened] == [
        stable_tool_item_id(session, ROOT_A),
        stable_tool_item_id(session, ROOT_B),
    ]
    assert {item.status for item in reopened} == {"running"}


def test_reopen_does_not_revive_a_terminal_sibling() -> None:
    session = _session()
    scan = scan_raw_transcript(
        (
            _raw_receipt_row("r1", ROOT_A, TASK),
            _raw_receipt_row("r2", ROOT_B, TASK),
        )
    )
    projector = ClaudeMessageProjector(raw_scan_provider=lambda _s: scan)
    projector.fold_agent_task_items(
        session,
        tool_use_id=ROOT_A,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert projector._agent_cards[stable_tool_item_id(session, ROOT_B)].status == "done"
    reopened = projector.fold_agent_task_items(
        session,
        tool_use_id=ROOT_A,
        overlay=_overlay(status="running"),
        status="running",
    )
    # The canonical card re-opens; the terminal sibling keeps its verdict.
    assert [item.id for item in reopened] == [stable_tool_item_id(session, ROOT_A)]
    assert reopened[0].status == "running"


# --------------------------------------------------------------------------
# The reader path sees the same resolution through the default seam
# --------------------------------------------------------------------------


def test_default_seam_resolves_without_an_injected_provider(monkeypatch) -> None:
    """The reader-path projector (no provider injected) still gets the scan.

    ``_history_items_from_messages`` constructs its projector without the
    injectable provider, so its folds take the module-level default. Patching
    that default to the synthetic scan proves the wiring — and that the
    fallback reads through it — without touching the real disk.
    """

    session = _session()
    canonical = stable_tool_item_id(session, DISPATCH)
    scan = _incident_scan()
    monkeypatch.setattr(
        messages_module, "_read_session_raw_scan", lambda _session: scan
    )
    projector = ClaudeMessageProjector()
    item = projector.fold_agent_task_event(
        session,
        tool_use_id=SEND,
        overlay=_overlay(status="completed"),
        status="done",
    )
    assert item.id == canonical
    assert projector._agent_cards[canonical].status == "done"
