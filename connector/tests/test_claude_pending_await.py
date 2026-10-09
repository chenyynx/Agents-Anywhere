"""B2 support layer: the pending-await signal the watchdog adjudicates on.

The watchdog's B2 exemption
(``.local-dev/claude-watchdog-liveness-tasks.md`` §3 D2) rests on two live
facts, both read at every poll tick and never cached:

* the projection's open tool calls for the turn under adjudication —
  ``ClaudeMessageProjector.open_tool_calls``;
* the interaction notices still awaiting an answer —
  ``ClaudeInteractionController.pending_for_session``.

This file pins the two accessors and the classifier that combines them
(``ClaudeTurnRunner._pending_await``) at their own boundary, so the watcher
integration cases in ``test_claude_watchdog_longrun.py`` can stay about the
watchdog. The projector and the notice registry are the real production
objects; only the controller's notification plumbing (host upserts) is
stubbed, because the subject here is which notices the accessor returns, not
how they travel to the server.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest

from connector.runtimes.claude.domain.session import ClaudeExecution, ClaudeSession
from connector.runtimes.claude.notifications.notices import ClaudeNoticeRegistry
from connector.runtimes.claude.timeline.messages import (
    ClaudeMessageProjector,
    ClaudeToolBlock,
    is_interactive_tool_name,
)
from connector.runtimes.claude.turns import lifecycle
from connector.runtimes.claude.turns.interactions import ClaudeInteractionController

SESSION_ID = "b2-pending"
TURN_OLD = "turn_claude_old"
TURN_NEW = "turn_claude_new"

QUESTIONS = [
    {
        "header": "Format",
        "question": "How should I format the output?",
        "multiSelect": False,
        "options": [
            {"label": "Summary", "description": "Brief overview"},
            {"label": "Detailed", "description": "Full explanation"},
        ],
    }
]


def _session() -> ClaudeSession:
    return ClaudeSession(session_id=SESSION_ID, external_session_id=SESSION_ID)


def _project_tool_use(
    projector: ClaudeMessageProjector,
    session: ClaudeSession,
    turn_id: str,
    tool_use_id: str,
    tool_name: str = "Bash",
) -> None:
    projector.tool_item(
        session=session,
        turn_id=turn_id,
        block=ClaudeToolBlock(
            block_type="tool_use",
            tool_use_id=tool_use_id,
            tool_name=tool_name,
            tool_input={"command": "true"},
        ),
    )


def _project_tool_result(
    projector: ClaudeMessageProjector,
    session: ClaudeSession,
    turn_id: str,
    tool_use_id: str,
) -> None:
    projector.tool_item(
        session=session,
        turn_id=turn_id,
        block=ClaudeToolBlock(
            block_type="tool_result",
            tool_use_id=tool_use_id,
            tool_result="done",
        ),
    )


# --------------------------------------------------------------------------
# The projector accessor
# --------------------------------------------------------------------------


def test_open_tool_calls_tracks_the_use_result_pair() -> None:
    projector = ClaudeMessageProjector()
    session = _session()

    _project_tool_use(projector, session, TURN_NEW, "toolu_one")
    calls = projector.open_tool_calls(TURN_NEW)
    assert [call.block.tool_use_id for call in calls] == ["toolu_one"], (
        "a projected tool_use with no result is an open call"
    )
    assert calls[0].block.tool_name == "Bash"

    _project_tool_result(projector, session, TURN_NEW, "toolu_one")
    assert projector.open_tool_calls(TURN_NEW) == (), (
        "the matching tool_result closes the call"
    )


def test_open_tool_calls_are_scoped_to_one_turn() -> None:
    """Pitfall #1 (B2 recon): a dead turn's leftover never excuses a later one.

    `_tool_calls` only drops an entry when its result arrives, so a killed
    turn's open call stays registered forever. Without the turn filter it
    would read as "still pending" and pause every later turn's stall clock —
    and exempt the hard cap outright if it happened to be an interactive
    name.
    """

    projector = ClaudeMessageProjector()
    session = _session()

    _project_tool_use(projector, session, TURN_OLD, "toolu_old")
    _project_tool_use(projector, session, TURN_NEW, "toolu_new")

    assert [c.block.tool_use_id for c in projector.open_tool_calls(TURN_NEW)] == [
        "toolu_new"
    ]
    assert projector.open_tool_calls("turn_claude_never_seen") == (), (
        "an unknown turn has no open calls, however many leftovers exist"
    )
    assert [
        c.block.tool_use_id for c in projector.open_tool_calls(TURN_OLD)
    ] == ["toolu_old"], "the leftover still belongs to its own turn"


@pytest.mark.parametrize(
    ("tool_name", "expected"),
    [
        ("AskUserQuestion", True),
        ("Bash", False),
        ("askuserquestion", False),
        (None, False),
    ],
)
def test_interactive_tool_name_is_the_question_tool(
    tool_name: str | None, expected: bool
) -> None:
    """The name is exact and single-sourced (recon: three scattered literals).

    Approvals are deliberately not name-classified — any tool can be held by
    `can_use_tool` — so only the question shape answers True here.
    """

    assert is_interactive_tool_name(tool_name) is expected


# --------------------------------------------------------------------------
# The interaction-notice accessor
# --------------------------------------------------------------------------


class _StubNotifications:
    """The controller's outbound surface: host traffic dropped, registry kept.

    `ClaudeNoticeHandler.notice_upsert` is `registry.upsert` plus the host
    send; only the send is stubbed here, because the registry write is the
    fact the accessor under test reads.
    """

    def __init__(self, registry: ClaudeNoticeRegistry) -> None:
        self.notice_upserts: list[Any] = []
        self.state_updates: list[Any] = []

        async def notice_upsert(notice: Any) -> None:
            self.notice_upserts.append(notice)
            registry.upsert(notice)

        async def session_state_update(*args: Any, **kwargs: Any) -> None:
            self.state_updates.append((args, kwargs))

        self.notice_handler = SimpleNamespace(notice_upsert=notice_upsert)
        self.session_state = SimpleNamespace(
            session_state_update=session_state_update
        )


def _controller() -> tuple[ClaudeInteractionController, _StubNotifications]:
    registry = ClaudeNoticeRegistry()
    notifications = _StubNotifications(registry)
    controller = ClaudeInteractionController(
        session_store=SimpleNamespace(get=lambda session_id: None),
        notices=registry,
        notifications=notifications,  # type: ignore[arg-type]
        has_active_turn=lambda session_id: False,
    )
    return controller, notifications


async def _wait_pending(
    controller: ClaudeInteractionController, session_id: str
) -> Any:
    for _ in range(200):
        pending = controller.pending_for_session(session_id)
        if pending:
            return pending[0]
        await asyncio.sleep(0.005)
    raise AssertionError("no interaction notice became pending")


def test_pending_for_session_returns_unanswered_notices_only() -> None:
    """An approval card is pending until it is answered; then it is gone.

    This accessor is what the watchdog reads for the hard-cap exemption —
    deliberately not `_interaction_futures`, whose `finally` runs while the
    notice is still mid-transition.
    """

    async def run() -> None:
        controller, _ = _controller()
        session = _session()

        task = asyncio.create_task(
            controller.request_tool_approval(
                session=session,
                turn_id=TURN_NEW,
                tool_name="Bash",
                tool_input={"command": "true"},
                context=None,
            )
        )
        notice = await _wait_pending(controller, SESSION_ID)
        assert notice.interaction_type == "approval"
        assert notice.response_required is True

        result = await controller.respond_interaction(
            SESSION_ID, notice.notice_id, "approve"
        )
        assert result.ok is True
        assert controller.pending_for_session(SESSION_ID) == (), (
            "an answered notice must not read as pending any more"
        )
        decision = await asyncio.wait_for(task, 1.0)
        assert decision.allowed is True

    asyncio.run(run())


def test_pending_for_session_covers_the_question_notice_too() -> None:
    async def run() -> None:
        controller, _ = _controller()
        session = _session()

        task = asyncio.create_task(
            controller.request_user_input(
                session=session,
                turn_id=TURN_NEW,
                tool_input={"questions": QUESTIONS},
                context=SimpleNamespace(tool_use_id="ask_tool_1"),
            )
        )
        notice = await _wait_pending(controller, SESSION_ID)
        assert notice.interaction_type == "input_request"

        result = await controller.respond_interaction(
            SESSION_ID, notice.notice_id, "cancel"
        )
        assert result.ok is True
        assert controller.pending_for_session(SESSION_ID) == ()
        decision = await asyncio.wait_for(task, 1.0)
        assert decision.allowed is False

    asyncio.run(run())


# --------------------------------------------------------------------------
# The classifier the watchdog calls per tick
# --------------------------------------------------------------------------


def _classify(
    projector: ClaudeMessageProjector,
    notices: list[Any],
    turn_id: str = TURN_NEW,
) -> lifecycle.PendingAwait:
    """Call the production classifier with its two live facts stubbed in.

    The method only touches `self.timeline` and `self.interactions`; the
    projector is the real one, and the notice source is a plain list so the
    notice path can be exercised without wiring a controller.
    """

    runner = SimpleNamespace(
        timeline=projector,
        interactions=SimpleNamespace(
            pending_for_session=lambda session_id: tuple(notices)
        ),
    )
    return lifecycle.ClaudeTurnRunner._pending_await(
        runner,  # type: ignore[arg-type]
        _session(),
        ClaudeExecution(turn_id=turn_id),
    )


def test_pending_await_classification_table() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    ask_notice = SimpleNamespace(interaction_type="input_request")

    assert _classify(projector, []) is lifecycle.PendingAwait.NONE

    _project_tool_use(projector, session, TURN_NEW, "toolu_bash")
    assert _classify(projector, []) is lifecycle.PendingAwait.EXECUTION, (
        "an execution call suspends the stall clock only"
    )
    assert lifecycle.PendingAwait.EXECUTION.stall_suspended is True
    assert lifecycle.PendingAwait.EXECUTION.cap_exempt is False

    _project_tool_use(projector, session, TURN_NEW, "toolu_ask", "AskUserQuestion")
    assert _classify(projector, [ask_notice]) is lifecycle.PendingAwait.INTERACTION, (
        "a live question notice exempts the hard cap as well"
    )
    assert lifecycle.PendingAwait.INTERACTION.cap_exempt is True
    assert _classify(projector, []) is lifecycle.PendingAwait.EXECUTION, (
        "B5/F1: the same question call without a live notice is a stale "
        "leftover — the stall clock pauses, the hard cap stays armed"
    )


def test_pending_await_ignores_other_turns_leftovers() -> None:
    projector = ClaudeMessageProjector()
    session = _session()
    _project_tool_use(projector, session, TURN_OLD, "toolu_old")

    assert _classify(projector, []) is lifecycle.PendingAwait.NONE, (
        "only the adjudicated turn's own open calls count"
    )


def test_pending_await_reads_the_notice_path_for_approvals() -> None:
    """Any tool can be approval-held, so the notice — not the name — decides."""

    projector = ClaudeMessageProjector()
    notice = SimpleNamespace(interaction_type="approval")

    assert _classify(projector, [notice]) is lifecycle.PendingAwait.INTERACTION, (
        "a pending approval exempts the cap even with no open call projected"
    )


def test_interaction_needs_a_live_notice_not_a_tool_name() -> None:
    """B5/F1: INTERACTION is gated on the notice registry alone.

    The red-team finding (`.local-dev/watchdog-liveness-b4-report.md` §1): a
    stale `AskUserQuestion` open entry — its result lost to a scope-drift
    pop-miss, its notice long closed — classified INTERACTION by name, which
    turned OFF the hard cap and PAUSED the stall clock, so the turn could sit
    on the execution lock at any age with no timer able to collect it. The
    real CLI routes AskUserQuestion through `can_use_tool` in every
    permission mode (B4 §2a), so a legitimate question always HAS a notice.
    The three states pinned here: stale entry without a notice -> EXECUTION
    (cap armed), live notice -> INTERACTION (cap exempt), and the name alone,
    with no notice, is never enough.
    """

    projector = ClaudeMessageProjector()
    session = _session()
    _project_tool_use(projector, session, TURN_NEW, "toolu_ask", "AskUserQuestion")

    stale = _classify(projector, [])
    assert stale is lifecycle.PendingAwait.EXECUTION
    assert stale.cap_exempt is False, "the hard cap must stay armed (F1)"
    assert stale.stall_suspended is True, "the call's silence is still legal"

    live = _classify(projector, [SimpleNamespace(interaction_type="input_request")])
    assert live is lifecycle.PendingAwait.INTERACTION
    assert live.cap_exempt is True

    # The name carries no signal of its own: an execution-class entry with
    # the same empty registry classifies identically.
    projector_b = ClaudeMessageProjector()
    _project_tool_use(projector_b, session, TURN_NEW, "toolu_bash_2", "Bash")
    assert _classify(projector_b, []) is lifecycle.PendingAwait.EXECUTION
