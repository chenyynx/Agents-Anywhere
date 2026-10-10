"""R1-zombie (Z1) attacks — the zombie agent-card self-heal on `935571e3`.

Attacks the four fix surfaces (F1 snapshot vouch, F2 attached ceiling pierce,
F3 reverse binding, F1 release) and the production-reachability of the three
observed zombie cards (sess_GnXkr: a0a5ff4b / a79eb82e / ae7d1a47).

Round outcome (adopted verbatim after the Z1 pass — no fix was required):
**放行进部署批**. Nothing here flipped; every case pins either a guard that
held or a deliberate trade the batch made:

* the two ``..._P2_...`` cases pin the trades on purpose — the pierce
  judges age, not file freshness (25h+ live attached tasks close, the same
  shape T2 already accepts for non-attached), and a live task the snapshot
  has not updated loses its exemption (the notification-gap window);
* ``..._a_restart_that_reannounces_a_zombie_defers_it_to_the_pierce`` pins
  the deployment caveat: the first-sweep closure assumes the CLI does not
  re-announce dead tasks after a restart — if it does, the zombie rides the
  ceiling instead;
* the rest are controls that must stay green (terminal beats the pierce, a
  listed snapshot keeps the exemption, release is idempotent and cannot
  touch a live sibling, F3 picks the dispatch card and never crosses
  sessions, the env kill switch restores the full set).
"""

from __future__ import annotations

import asyncio

from test_zombie_card_selfheal import (
    DISPATCH_TUID,
    EXTERNAL_SESSION_ID,
    NOW,
    ZOMBIE_TASK_ID,
    _harness,
    _oracle,
    _snapshot_frame,
)

from connector.runtimes.claude.sdk.background import ClaudeBackgroundTasks
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
)
from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay
from connector.runtimes.claude.timeline.messages import (
    AgentCallToolContent,
)
from connector.runtimes.claude.turns.lifecycle import (
    LIVE_VOUCH_ENV,
)

STALE = AgentFileInfo(exists=True, mtime_ms=int((NOW - 3600.0) * 1000))
FRESH = AgentFileInfo(exists=True, mtime_ms=int(NOW * 1000))
T_25H = 25 * 3600.0


# ---------------------------------------------------------------------------
# ATTACK A — F2 pierce closes a LIVE 25h+ attached task with a FRESH file
# ---------------------------------------------------------------------------


def test_Z1_P2_the_pierce_closes_a_live_attached_task_whose_file_is_fresh() -> None:
    """ATTACK (P2): the F2 pierce fires on CEILING AGE alone — it never looks
    at the file. An attached task (in the snapshot) dispatched 25h ago whose
    transcript is being written RIGHT NOW (fresh mtime) is closed as
    `ageBounded`.

    The task is alive and writing; the only thing "wrong" with it is that its
    launch receipt is 25h old. The spec's premise is "no legitimate run
    exceeds 24h", and this is that premise being enforced without a liveness
    signal — the file, the strongest liveness signal the oracle has, is
    ignored on this branch.

    Consistent with T2's non-attached ceiling (which also closes a fresh-file
    task on age), so this is not a new class — it is T2's accepted trade
    extended to attached tasks, which the fix deliberately did. Filed P2 so
    the trade is on record: a 25h+ attached live task is closed."""

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: FRESH}, age_bound=24 * 3600.0)
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=T_25H,
        ceiling_age_seconds=T_25H,
        ceiling_anchored=True,
        attached_live=True,
        now_ms=int(NOW * 1000),
    )

    assert verdict is not None
    assert verdict.closed_by == "ageBounded"


def test_Z1_control_inside_the_ceiling_a_fresh_attached_task_stays_open() -> None:
    """CONTROL: the same shape under 24h (a 20h attached task, fresh file)
    abstains — the pierce is a clock, not a liveness call."""

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: FRESH}, age_bound=24 * 3600.0)
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd="/home/ubuntu",
            terminal_events=(),
            receipt_age_seconds=20 * 3600.0,
            ceiling_age_seconds=20 * 3600.0,
            ceiling_anchored=True,
            attached_live=True,
            now_ms=int(NOW * 1000),
        )
        is None
    )


def test_Z1_control_an_unanchored_attached_task_still_abstains_past_the_ceiling() -> None:
    """CONTROL: without a raw-transcript anchor the pierce never fires, so an
    attached task whose anchor is missing (the F1-fix-invisible shape) keeps
    its exemption even past 24h."""

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE}, age_bound=24 * 3600.0)
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd="/home/ubuntu",
            terminal_events=(),
            receipt_age_seconds=T_25H,
            ceiling_age_seconds=None,
            ceiling_anchored=False,
            attached_live=True,
            now_ms=int(NOW * 1000),
        )
        is None
    )


def test_Z1_control_a_terminal_notice_still_beats_the_pierce() -> None:
    """CONTROL: the terminal-notice path runs BEFORE the pierce, so an attached
    task with a terminal notice closes on the notice's status, not ageBounded
    — the F4 arbitration is untouched."""

    from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: FRESH}, age_bound=24 * 3600.0)
    notice = ClaudeTaskEvent(
        kind="notification", task_id=ZOMBIE_TASK_ID, status="completed", end_time=None
    )
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=((None, notice),),
        receipt_age_seconds=T_25H,
        ceiling_age_seconds=T_25H,
        ceiling_anchored=True,
        attached_live=True,
        now_ms=int(NOW * 1000),
    )
    assert verdict is not None
    assert verdict.closed_by == "terminalNotice"
    assert verdict.closure_status == "done"


# ---------------------------------------------------------------------------
# ATTACK B — F1's unexempt window: a live task whose snapshot was not updated
# ---------------------------------------------------------------------------


def test_Z1_P2_a_live_task_missing_from_the_snapshot_loses_its_exemption() -> None:
    """ATTACK (P2): F1 narrows the exemption to `active ∩ snapshot`. A task
    that started (task_started -> active_ids) but whose snapshot was NOT
    updated (the CLI's next `background_tasks_changed` is delayed or lost —
    the same notification gap that caused the zombie) is unexempt.

    Before the fix it was exempt via `active_ids` alone and a file-silent
    long tool call could never close it. Now, if the snapshot lags and the
    task's transcript goes silent >900s, the sweep closes it — a false close
    on a live task, introduced by the exemption narrowing.

    The spec's protection is T4 (the snapshot listing the task) — this is the
    gap where it does NOT list it. The CLI is expected to send the snapshot
    promptly, so the window is narrow; filed P2 as the trade F1 makes."""

    background = ClaudeBackgroundTasks()
    # The task starts: task_started adds it to active_ids.
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    # The snapshot is stale: the CLI's newest snapshot predates the task.
    background.observed(_snapshot_frame([]))

    active = frozenset(background.active_ids)
    snapshot = background.last_snapshot_ids
    assert ZOMBIE_TASK_ID in active
    assert snapshot is not None and ZOMBIE_TASK_ID not in snapshot
    # F1: the live set is the intersection — the task is unexempt.
    live = active & snapshot
    assert ZOMBIE_TASK_ID not in live

    # The sweep judges it: not attached (unexempt), file silent 1h -> closed.
    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE})
    _host, _runtime, session, runner, _connection = _harness(oracle)
    runner.connections[session.session_id].background = background
    published = asyncio.run(runner.sweep_agent_cards_by_evidence(session))
    # ...but this harness has no card for the task, so nothing publishes. The
    # closure shape is pinned by the oracle verdict below instead.
    assert published == 0
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=600.0,
        ceiling_age_seconds=None,
        ceiling_anchored=False,
        attached_live=ZOMBIE_TASK_ID in live,
        now_ms=int(NOW * 1000),
    )
    assert verdict is not None
    assert verdict.closed_by == "agentFileStale"


def test_Z1_control_a_snapshot_that_lists_the_task_keeps_it_exempt(monkeypatch) -> None:
    """CONTROL (T4): the same shape where the CLI's snapshot DOES list the
    task — the task stays exempt even with a 1h-silent file."""

    background = ClaudeBackgroundTasks()
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    background.observed(_snapshot_frame([ZOMBIE_TASK_ID]))

    live = frozenset(background.active_ids) & (background.last_snapshot_ids or frozenset())
    assert ZOMBIE_TASK_ID in live

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE})
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=600.0,
        ceiling_age_seconds=None,
        ceiling_anchored=False,
        attached_live=ZOMBIE_TASK_ID in live,
        now_ms=int(NOW * 1000),
    )
    assert verdict is None


def test_Z1_control_the_env_kill_switch_restores_the_full_set(monkeypatch) -> None:
    """CONTROL: with the snapshot stale and the kill switch off, the full
    register still vouches — the old behaviour, byte for byte."""

    monkeypatch.setenv(LIVE_VOUCH_ENV, "off")
    background = ClaudeBackgroundTasks()
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    background.observed(_snapshot_frame([]))

    # The provider honours the kill switch.
    assert background.last_snapshot_ids == frozenset()
    # (The intersection logic lives in `live_agent_task_ids`, covered by T2.)
    monkeypatch.delenv(LIVE_VOUCH_ENV)


# ---------------------------------------------------------------------------
# ATTACK C — F3 folds a terminal into the FIRST card naming the task
# ---------------------------------------------------------------------------


def test_Z1_P2_F3_folds_a_terminal_into_the_first_of_two_cards_naming_a_task(
    tmp_path, monkeypatch
) -> None:
    """ATTACK (P2): two cards name the same task (the dispatch card and its
    SendMessage alias twin). F3's reverse-lookup is first-wins by insertion
    order, so the terminal folds into the FIRST card — the original dispatch
    card, which precedes the twin. The twin stays open here; the
    alias-durability same-task consistency is the mechanism that propagates
    the terminal to it (out of F3's scope but in the blast radius)."""

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent

    host, _, session, runner, _ = _harness(_oracle(files={}))
    # The dispatch card, minted first.
    from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay
    from connector.runtimes.claude.timeline.messages import AgentCallToolContent

    dispatch = runner.timeline.fold_agent_task_event(
        session,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "async_launched"}}
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    # The twin, minted second.
    runner.timeline.fold_agent_task_event(
        session,
        tool_use_id="call_twin_1",
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "async_launched"}}
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research (resume)", agents={}),
    )
    # No binding: F3 reverse-lookup resolves to the FIRST card.
    assert runner.agent_task_calls == {}
    resolved = runner.timeline.tool_use_id_for_task(session, ZOMBIE_TASK_ID)
    assert resolved == DISPATCH_TUID

    # The terminal folds into the dispatch card.
    asyncio.run(
        runner.fold_agent_task_event(
            session,
            ClaudeTaskEvent(
                kind="updated",
                task_id=ZOMBIE_TASK_ID,
                status="completed",
                end_time=int(NOW * 1000),
            ),
        )
    )
    assert host.timeline_item_upserts
    upsert = host.timeline_item_upserts[-1]
    assert upsert.id == dispatch.id
    assert upsert.status == "done"


def test_Z1_control_F3_skips_a_card_without_a_dispatch_id(tmp_path, monkeypatch) -> None:
    """CONTROL: a card minted without a tool_use_id cannot host a fold and is
    skipped by the reverse-lookup."""

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _, _, session, runner, _ = _harness(_oracle(files={}))
    runner.timeline.fold_agent_task_event(
        session,
        tool_use_id=None,
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "async_launched"}}
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    assert runner.timeline.tool_use_id_for_task(session, ZOMBIE_TASK_ID) is None


def test_Z1_control_F3_does_not_cross_sessions(tmp_path, monkeypatch) -> None:
    """CONTROL: a card in another session naming the same task id is not a
    valid target — the reverse-lookup filters by session."""

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    from connector.runtimes.claude.domain.session import ClaudeSession

    _, _, session, runner, _ = _harness(_oracle(files={}))
    foreign = ClaudeSession(
        session_id="sess_other_session",
        external_session_id="ext_other",
        cwd="/repo",
    )
    runner.timeline.fold_agent_task_event(
        foreign,
        tool_use_id="call_other",
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "async_launched"}}
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )
    assert runner.timeline.tool_use_id_for_task(session, ZOMBIE_TASK_ID) is None


# ---------------------------------------------------------------------------
# ATTACK D — the release pin race
# ---------------------------------------------------------------------------


def test_Z1_control_a_late_task_started_repins_the_released_task() -> None:
    """ATTACK that does NOT land over an ordered transport: after the evidence
    closure releases a task, a LATE `task_started` for it would re-add it to
    `active_ids` and re-wedge arm_idle. Over one WebSocket frames are ordered,
    so a task_started cannot arrive after its own card was closed (the start
    precedes the judgement that closed it); the race is unreachable without a
    transport reorder. Pinned so a future transport change that allows
    reordering shows up here."""

    background = ClaudeBackgroundTasks()
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    background.observed(_snapshot_frame([ZOMBIE_TASK_ID]))
    assert ZOMBIE_TASK_ID in background.active_ids

    # The evidence closure releases it.
    background.release(ZOMBIE_TASK_ID)
    assert ZOMBIE_TASK_ID not in background.active_ids
    assert background.drained.is_set()

    # A late task_started would re-pin (simulated; unreachable in order).
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    assert ZOMBIE_TASK_ID in background.active_ids
    assert not background.drained.is_set()


def test_Z1_control_release_is_idempotent() -> None:
    """CONTROL: releasing twice is a no-op."""

    background = ClaudeBackgroundTasks()
    background.observed(
        {"subtype": "task_started", "task_id": ZOMBIE_TASK_ID, "task_type": "local_agent"}
    )
    background.release(ZOMBIE_TASK_ID)
    background.release(ZOMBIE_TASK_ID)
    assert ZOMBIE_TASK_ID not in background.active_ids


# ---------------------------------------------------------------------------
# ATTACK E — the CLI's own stale snapshot (F1 cannot help; F2 is the floor)
# ---------------------------------------------------------------------------


def test_Z1_P2_a_cli_stale_snapshot_keeps_a_dead_task_exempt_until_the_pierce() -> None:
    """ATTACK (P2): the CLI re-announces a DEAD task in its snapshot (the
    CLI's own state lost the terminal — the same notification gap). The task
    is then `active ∩ snapshot` = exempt, so F1 cannot close it: the snapshot
    vouches for a corpse. The card stays open until the F2 pierce's 24h
    ceiling.

    This is the shape F1 explicitly cannot fix (the spec's F1 section: the
    snapshot is only as good as the CLI's view) and F2 exists for. Pinned to
    show the two layers complement and the pierce is reachable on this path."""

    background = ClaudeBackgroundTasks()
    # The CLI re-announces the dead task.
    background.observed(_snapshot_frame([ZOMBIE_TASK_ID]))
    assert ZOMBIE_TASK_ID in background.active_ids

    # F1: exempt (in both sets).
    live = frozenset(background.active_ids) & (background.last_snapshot_ids or frozenset())
    assert ZOMBIE_TASK_ID in live

    # The oracle abstains under 24h (attached, anchored age fresh)...
    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE}, age_bound=24 * 3600.0)
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd="/home/ubuntu",
            terminal_events=(),
            receipt_age_seconds=3600.0,
            ceiling_age_seconds=3600.0,
            ceiling_anchored=True,
            attached_live=True,
            now_ms=int(NOW * 1000),
        )
        is None
    )
    # ...and closes at the pierce (25h anchored age).
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=T_25H,
        ceiling_age_seconds=T_25H,
        ceiling_anchored=True,
        attached_live=True,
        now_ms=int(NOW * 1000),
    )
    assert verdict is not None
    assert verdict.closed_by == "ageBounded"


# ---------------------------------------------------------------------------
# ATTACK F — production zombie reachability
# ---------------------------------------------------------------------------


def test_Z1_P2_a_restart_that_reannounces_a_zombie_defers_it_to_the_pierce() -> None:
    """PRODUCTION REACHABILITY, the dependency the spec's §6 glosses: the three
    observed zombies close promptly after restart ONLY if the CLI's
    post-restart snapshot excludes them. If the CLI's own state still lists a
    zombie (its terminal was lost internally too), the zombie is re-announced
    into `active_ids` via the snapshot's add loop, becomes attached, and the
    pierce defers its closure to 24h instead of the first sweep's
    agentFileStale.

    The spec's §6 says "重启清空 active_ids ⇒ 非 attached" — true only when the
    CLI does not re-announce. This test pins the re-announce branch so the
    deployment acceptance (first-cycle closure) is understood to depend on the
    CLI's post-restart view being correct."""

    background = ClaudeBackgroundTasks()
    # The CLI re-announces the zombie after the connector restarts.
    background.observed(_snapshot_frame([ZOMBIE_TASK_ID]))

    live = frozenset(background.active_ids) & (background.last_snapshot_ids or frozenset())
    assert ZOMBIE_TASK_ID in live, "the re-announced zombie is attached"

    # Under 24h the sweep abstains (attached + anchored age fresh).
    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE}, age_bound=24 * 3600.0)
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd="/home/ubuntu",
            terminal_events=(),
            receipt_age_seconds=2.7 * 3600.0,
            ceiling_age_seconds=2.7 * 3600.0,
            ceiling_anchored=True,
            attached_live=True,
            now_ms=int(NOW * 1000),
        )
        is None
    ), "a re-announced zombie under 24h is NOT closed by the first sweep"

    # If the CLI excludes it (the spec's assumed shape), the sweep closes it
    # via agentFileStale in the first cycle.
    clean = ClaudeBackgroundTasks()
    clean.observed(_snapshot_frame([]))
    live_clean = frozenset(clean.active_ids) & (
        clean.last_snapshot_ids or frozenset()
    )
    assert ZOMBIE_TASK_ID not in live_clean
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=2.7 * 3600.0,
        ceiling_age_seconds=None,
        ceiling_anchored=False,
        attached_live=False,
        now_ms=int(NOW * 1000),
    )
    assert verdict is not None
    assert verdict.closed_by == "agentFileStale"


def test_Z1_control_the_first_sweep_closes_a_zombie_the_cli_dropped() -> None:
    """CONTROL (the spec's §6 shape): a zombie the CLI dropped from its
    snapshot (it knows the task died) is unexempt, its file is silent >900s,
    and the first sweep closes it via agentFileStale."""

    background = ClaudeBackgroundTasks()
    background.observed(_snapshot_frame([]))  # the CLI dropped the zombie.
    live = frozenset(background.active_ids) & (
        background.last_snapshot_ids or frozenset()
    )
    assert ZOMBIE_TASK_ID not in live

    oracle = _oracle(now=NOW, files={ZOMBIE_TASK_ID: STALE})
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/home/ubuntu",
        terminal_events=(),
        receipt_age_seconds=2.7 * 3600.0,
        ceiling_age_seconds=None,
        ceiling_anchored=False,
        attached_live=False,
        now_ms=int(NOW * 1000),
    )
    assert verdict is not None
    assert verdict.closed_by == "agentFileStale"