"""Zombie agent-card self-heal (zombie-agent-card, 2026-10-10).

Why this file exists
--------------------
Three production cards (session ``sess_GnXkrS4x6bfpXA``) sat
``running``/``async_launched`` forever: a task id pinned in
``background.active_ids`` by a terminal frame the CLI resume/notification
gap never delivered — the register only ever *loses* an id to a live
terminal — kept ``live_agent_task_ids`` (the evidence exemption) vouching
for it, so the oracle answered ``attached -> None`` and every evidence
closure abstained; the pinned id then also refused ``arm_idle``, so the
connection could not recycle and the pin could never clear itself. A
companion gap let unbound tasks' terminal frames be dropped silently
(binding is narrower than the exemption).

What is pinned
--------------
* T1 — ``ClaudeBackgroundTasks.last_snapshot_ids`` tracks the newest
  ``background_tasks_changed`` frame as a whole (empty list = valid empty
  set, malformed entries leave the previous reading, ``None`` until one
  arrives) and ``release()`` drops a pin + syncs ``drained``;
* T2 — ``live_agent_task_ids`` = ``active_ids ∩ last_snapshot_ids`` when a
  snapshot is known; the full register when none ever arrived; the env kill
  switch ``AA_SUBAGENT_LIVE_VOUCH`` = ``0``/``off`` restores the full set;
* T3 — the evidence sweep closes the snapshot-evicted zombie
  (``agentFileStale``) *and* releases its id so the pin cannot outlive the
  judgement;
* T4 — a task the snapshot still lists is never closed on file silence
  (the long-tool-call guard, both trees);
* T5 — F2: the age ceiling pierces the attached exemption on the ceiling's
  own raw anchor only; inside the bound or anchor-less it abstains;
* T6 — a terminal frame with no binding folds through the card's own
  agents map; a task with no card (local_bash) stays unprojected;
* T7 — snapshot eviction + a *fresh* file closes nothing (CLI jitter is
  not death);
* T8 — a connection that never saw a snapshot behaves byte-for-byte as
  before.

Non-hollow: T3/T5a/T6a (and T1/T2, which touch new API) fail on the
``cc3b8109`` baseline; T4/T7/T8 and the T5/T6 guards hold on both.
Fixtures are synthetic: fake clock, dict-backed file probe, a literal
empty ``CLAUDE_CONFIG_DIR``. No real session's content is read.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from connector.runtime_protocol import (
    AgentCallToolContent,
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeTimelineItem,
)
from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk.background import ClaudeBackgroundTasks
from connector.runtimes.claude.sdk.connection import ClaudeConnection
from connector.runtimes.claude.sdk.tasks import ClaudeTaskEvent
from connector.runtimes.claude.sessions.subagent_oracle import (
    AgentFileInfo,
    ClaudeSubagentOracle,
)
from connector.runtimes.claude.timeline.agent_calls import ClaudeAgentTaskOverlay

EXTERNAL_SESSION_ID = "e89abce5-f48c-463b-8d16-d3f78dd504c4"
SESSION_ID = "sess_zombie_card_selfheal"
CWD = "/home/ubuntu"
DISPATCH_TUID = "call_00_ZombieSelfheal0000000000"
#: The pinned zombie: registered by a task frame, evicted by the snapshot.
ZOMBIE_TASK_ID = "z0mb1e7ask9012345"
#: The honest long-runner: still listed by the snapshot.
LIVE_TASK_ID = "a11ve7ask000000001"
PROJECTS_DIR = "/tmp/fake-claude-projects"

T_START = 120.0
T_STALE = 900.0
T_AGE_BOUND = 86_400.0  # 24h — the T2 hard age ceiling
NOW = 1_791_457_800.0


# --------------------------------------------------------------------------
# Fixtures: fake clock, dict-backed file probe, synthetic session shapes
# --------------------------------------------------------------------------


class _Clock:
    def __init__(self, seconds: float) -> None:
        self.seconds = seconds

    def __call__(self) -> float:
        return self.seconds


def _file_table(*entries: tuple[str, AgentFileInfo]) -> Any:
    table = dict(entries)

    def probe(*, projects_dir, project_key, external_session_id, task_id):
        _ = projects_dir, project_key, external_session_id
        return table.get(task_id, AgentFileInfo(exists=False, path_known=True))

    return probe


def _oracle(
    *,
    now: float = NOW,
    files: dict[str, AgentFileInfo],
    age_bound: float | None = T_AGE_BOUND,
) -> ClaudeSubagentOracle:
    return ClaudeSubagentOracle(
        projects_dir=Path(PROJECTS_DIR),
        clock=_Clock(now),
        file_probe=_file_table(*files.items()),
        start_grace_seconds=T_START,
        stale_seconds=T_STALE,
        age_bound_seconds=age_bound,
    )


def _stale_file(now: float = NOW) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int((now - T_STALE - 1) * 1000))


def _fresh_file(now: float = NOW) -> AgentFileInfo:
    return AgentFileInfo(exists=True, mtime_ms=int(now * 1000))


def _session() -> ClaudeSession:
    return ClaudeSession(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        title="Zombie self-heal",
        cwd=CWD,
    )


class _RecordingHost(RuntimeHostClient):
    def __init__(self) -> None:
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)


def _runtime(host: RuntimeHostClient, oracle: ClaudeSubagentOracle) -> ClaudeRuntime:
    return ClaudeRuntime(
        config=RuntimeConfig(runtime="claude", revision=1, values={"environment": {}}),
        host=host,
        subagent_oracle=oracle,
    )


async def _noop(*_args: Any, **_kwargs: Any) -> None:
    return None


def _connection() -> ClaudeConnection:
    return ClaudeConnection(
        client=None,
        on_activity=_noop,
        on_idle=_noop,
        on_background_done=_noop,
        cleanup=lambda: None,
    )


def _harness(
    oracle: ClaudeSubagentOracle,
    *,
    with_card_agents: dict[str, str] | None = None,
) -> tuple[
    _RecordingHost, ClaudeRuntime, ClaudeSession, Any, ClaudeConnection | None
]:
    """A runtime + session + runner + registered connection for the session.

    Returns ``(host, runtime, session, runner, connection)``. When
    ``with_card_agents`` names task statuses, a published *running*
    agent_call card carrying them is restored onto the session's timeline
    (the zombie's shape across a restart); the live connection is always
    registered so ``live_agent_task_ids`` has a transport to vouch from.
    """

    host = _RecordingHost()
    runtime = _runtime(host, oracle)
    session = _session()
    runtime._sessions[session.session_id] = session
    runner = runtime._turns.runner
    if with_card_agents is not None:
        item = _published_card(with_card_agents)
        session.timeline_items[item.id] = item
    connection = _connection()
    runner.connections[session.session_id] = connection
    return host, runtime, session, runner, connection


def _published_card(agents: dict[str, str]) -> RuntimeTimelineItem:
    """One published agent_call item — the restored-timeline zombie shape."""

    content: dict[str, Any] = {
        "kind": "agent_call",
        "title": "research",
        "agents": {task_id: {"status": status} for task_id, status in agents.items()},
    }
    from connector.runtime_protocol import timeline_content_hash

    return RuntimeTimelineItem(
        id="claude_tool_zombie00000000000000000",
        session_id=SESSION_ID,
        type="tool",
        status="running",
        order_seq=7,
        content_hash=timeline_content_hash(
            item_type="tool", status="running", role="tool", content=content
        ),
        role="tool",
        turn_id="turn_zombie",
        content=content,
        source={
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemId": DISPATCH_TUID,
            "itemType": "tool_use",
            "event": "claude.agent.task",
        },
    )


def _snapshot_frame(task_ids: list[str]) -> dict[str, Any]:
    return {
        "subtype": "background_tasks_changed",
        "tasks": [{"task_id": task_id} for task_id in task_ids],
    }


# --------------------------------------------------------------------------
# T1: snapshot tracking and release on the register itself
# --------------------------------------------------------------------------


def test_T1_the_register_tracks_the_newest_snapshot_as_a_whole() -> None:
    tasks = ClaudeBackgroundTasks()
    # Never saw a snapshot frame: the conservative unknown.
    assert tasks.last_snapshot_ids is None
    # Non-snapshot frames never touch the field.
    tasks.observed({"subtype": "task_started", "task_id": LIVE_TASK_ID})
    assert tasks.last_snapshot_ids is None
    # A real snapshot replaces the whole field and still registers its ids.
    tasks.observed(_snapshot_frame([LIVE_TASK_ID, ZOMBIE_TASK_ID]))
    assert tasks.last_snapshot_ids == frozenset({LIVE_TASK_ID, ZOMBIE_TASK_ID})
    assert tasks.active_ids == {LIVE_TASK_ID, ZOMBIE_TASK_ID}
    # Empty list = a valid, meaningful empty set (the CLI has nothing out).
    tasks.observed(_snapshot_frame([]))
    assert tasks.last_snapshot_ids == frozenset()
    # The data.tasks nesting counts as a snapshot too (same wire shape the
    # register has always read).
    tasks.observed(
        {"subtype": "background_tasks_changed", "data": {"tasks": [{"task_id": "C"}]}}
    )
    assert tasks.last_snapshot_ids == frozenset({"C"})
    # The snapshot never edits the register itself: an evicted id stays
    # pinned until a terminal/release (keep-alive semantics untouched).
    assert tasks.active_ids == {LIVE_TASK_ID, ZOMBIE_TASK_ID, "C"}


def test_T1_a_malformed_snapshot_leaves_the_previous_reading_standing() -> None:
    # Entries but no parseable id is not a readable snapshot; manufacturing
    # an empty set from it would strip every exemption (conservative guard).
    tasks = ClaudeBackgroundTasks()
    tasks.observed(_snapshot_frame([LIVE_TASK_ID]))
    tasks.observed({"subtype": "background_tasks_changed", "tasks": [{"nope": 1}]})
    assert tasks.last_snapshot_ids == frozenset({LIVE_TASK_ID})


def test_T1_release_drops_the_pin_and_syncs_drained() -> None:
    tasks = ClaudeBackgroundTasks()
    tasks.observed({"subtype": "task_started", "task_id": ZOMBIE_TASK_ID})
    assert not tasks.drained.is_set()
    tasks.release(ZOMBIE_TASK_ID)
    assert tasks.active_ids == set()
    # The drain signal the selection change waits on: pins gone = drained.
    assert tasks.drained.is_set()
    # Idempotent, and an unknown id is a no-op.
    tasks.release(ZOMBIE_TASK_ID)
    tasks.release("never-registered")
    assert tasks.active_ids == set()
    assert tasks.drained.is_set()


# --------------------------------------------------------------------------
# T2: the exemption's source filter (live_agent_task_ids)
# --------------------------------------------------------------------------


def test_T2_a_known_snapshot_narrows_the_live_set_to_the_intersection(
    monkeypatch: Any,
) -> None:
    monkeypatch.delenv("AA_SUBAGENT_LIVE_VOUCH", raising=False)
    _, _, session, runner, connection = _harness(_oracle(files={}))
    connection.background.active_ids.update({LIVE_TASK_ID, ZOMBIE_TASK_ID})
    connection.background.observed(_snapshot_frame([LIVE_TASK_ID]))
    assert runner.live_agent_task_ids(session) == frozenset({LIVE_TASK_ID})


def test_T2_without_a_snapshot_the_full_register_still_vouches(
    monkeypatch: Any,
) -> None:
    monkeypatch.delenv("AA_SUBAGENT_LIVE_VOUCH", raising=False)
    _, _, session, runner, connection = _harness(_oracle(files={}))
    connection.background.active_ids.update({LIVE_TASK_ID, ZOMBIE_TASK_ID})
    # No background_tasks_changed ever observed — the conservative branch.
    assert runner.live_agent_task_ids(session) == frozenset(
        {LIVE_TASK_ID, ZOMBIE_TASK_ID}
    )


def test_T2_the_env_kill_switch_restores_the_full_set(monkeypatch: Any) -> None:
    for raw in ("0", "off"):
        monkeypatch.setenv("AA_SUBAGENT_LIVE_VOUCH", raw)
        _, _, session, runner, connection = _harness(_oracle(files={}))
        connection.background.active_ids.update({LIVE_TASK_ID, ZOMBIE_TASK_ID})
        connection.background.observed(_snapshot_frame([LIVE_TASK_ID]))
        assert runner.live_agent_task_ids(session) == frozenset(
            {LIVE_TASK_ID, ZOMBIE_TASK_ID}
        ), raw
        runner.connections.pop(session.session_id, None)
    # Any other value (and unset) keeps the new judgement on: an unusable
    # reading may only mean "on", never silently "off".
    monkeypatch.setenv("AA_SUBAGENT_LIVE_VOUCH", "1")
    _, _, session, runner, connection = _harness(_oracle(files={}))
    connection.background.active_ids.update({LIVE_TASK_ID, ZOMBIE_TASK_ID})
    connection.background.observed(_snapshot_frame([LIVE_TASK_ID]))
    assert runner.live_agent_task_ids(session) == frozenset({LIVE_TASK_ID})


# --------------------------------------------------------------------------
# T3: the sweep closes the zombie AND releases its pin
# --------------------------------------------------------------------------


def test_T3_the_sweep_closes_the_evicted_zombie_and_releases_its_pin(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, connection = _harness(
        _oracle(files={ZOMBIE_TASK_ID: _stale_file()}),
        with_card_agents={ZOMBIE_TASK_ID: "running"},
    )
    # The production shape: the register took the id from a task frame, the
    # CLI's newest snapshot no longer lists it (resume gap: no terminal
    # frame will ever arrive), and the subagent file has been silent past
    # the stale deadline.
    connection.background.observed({"subtype": "task_started", "task_id": ZOMBIE_TASK_ID})
    connection.background.observed(_snapshot_frame([]))
    assert not connection.background.drained.is_set()

    published = asyncio.run(runner.sweep_agent_cards_by_evidence(session))

    assert published == 1
    upsert = host.timeline_item_upserts[-1]
    assert upsert.status == "interrupted"
    assert upsert.content["closedByEvidence"] == "agentFileStale"
    assert upsert.content["agents"][ZOMBIE_TASK_ID]["status"] == "interrupted"
    # The release half: the closure published, so the stale pin is dropped
    # and the drain signal — and with it arm_idle — unblocks.
    assert ZOMBIE_TASK_ID not in connection.background.active_ids
    assert connection.background.drained.is_set()


def test_T3_nothing_is_released_when_the_sweep_closes_nothing(
    tmp_path: Any, monkeypatch: Any
) -> None:
    # Mirror of T3 with a *fresh* file: no closure publishes, so no release
    # may fire — releasing on an unjudged task would drop keep-alive for
    # work that never died (the release's publish-success precondition).
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _, _, session, runner, connection = _harness(
        _oracle(files={ZOMBIE_TASK_ID: _fresh_file()}),
        with_card_agents={ZOMBIE_TASK_ID: "running"},
    )
    connection.background.observed({"subtype": "task_started", "task_id": ZOMBIE_TASK_ID})
    connection.background.observed(_snapshot_frame([]))

    assert asyncio.run(runner.sweep_agent_cards_by_evidence(session)) == 0
    assert ZOMBIE_TASK_ID in connection.background.active_ids
    assert not connection.background.drained.is_set()


# --------------------------------------------------------------------------
# T4: the long-tool-call guard — still listed, never closed on silence
# --------------------------------------------------------------------------


def test_T4_a_still_listed_task_is_never_closed_on_file_silence(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, connection = _harness(
        _oracle(files={LIVE_TASK_ID: _stale_file()}),
        with_card_agents={LIVE_TASK_ID: "running"},
    )
    connection.background.observed({"subtype": "task_started", "task_id": LIVE_TASK_ID})
    connection.background.observed(_snapshot_frame([LIVE_TASK_ID]))
    assert runner.live_agent_task_ids(session) == frozenset({LIVE_TASK_ID})

    # Two hours of file silence (>> T_STALE) with the CLI still listing the
    # task: attached exemption holds, nothing closes, nothing releases.
    assert asyncio.run(runner.sweep_agent_cards_by_evidence(session)) == 0
    assert host.timeline_item_upserts == []
    assert LIVE_TASK_ID in connection.background.active_ids


# --------------------------------------------------------------------------
# T5: F2 — the ceiling pierces the attached exemption on its own anchor
# --------------------------------------------------------------------------


def test_T5_attached_past_the_anchored_ceiling_closes_age_bounded() -> None:
    oracle = _oracle(files={ZOMBIE_TASK_ID: _fresh_file()})
    verdict = oracle.evidence(
        task_id=ZOMBIE_TASK_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd=CWD,
        receipt_age_seconds=600.0,
        ceiling_age_seconds=T_AGE_BOUND + 1,
        ceiling_anchored=True,
        attached_live=True,
    )
    assert verdict is not None
    assert verdict.closure_status == "interrupted"
    assert verdict.closed_by == "ageBounded"
    assert verdict.agent_status == "interrupted"
    # The anchor's own time, not the distrusted mtime and not "now".
    assert verdict.end_time_ms == int((NOW - (T_AGE_BOUND + 1)) * 1000)


def test_T5_attached_inside_the_ceiling_still_abstains() -> None:
    oracle = _oracle(files={ZOMBIE_TASK_ID: _fresh_file()})
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND * 10,
            ceiling_age_seconds=T_AGE_BOUND - 1,
            ceiling_anchored=True,
            attached_live=True,
        )
        is None
    )


def test_T5_attached_without_the_raw_anchor_still_abstains() -> None:
    # Anchor missing (no raw transcript) — receipt age does NOT stand in for
    # the attached pierce; the server janitor remains that form's floor.
    # A receipt older than any run must not close a vouched task alone.
    oracle = _oracle(files={ZOMBIE_TASK_ID: _fresh_file()})
    assert (
        oracle.evidence(
            task_id=ZOMBIE_TASK_ID,
            external_session_id=EXTERNAL_SESSION_ID,
            cwd=CWD,
            receipt_age_seconds=T_AGE_BOUND * 10,
            ceiling_age_seconds=T_AGE_BOUND * 10,
            ceiling_anchored=False,
            attached_live=True,
        )
        is None
    )


# --------------------------------------------------------------------------
# T6: F3 — the terminal frame folds through the card's own agents map
# --------------------------------------------------------------------------


def _mint_running_card(runner: Any, session: ClaudeSession) -> str:
    item = runner.timeline.fold_agent_task_event(
        session,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "running"}},
        ),
        status="running",
        base=AgentCallToolContent(
            kind="agent_call", title="research", agents={}
        ),
    )
    return item.id


def test_T6_a_terminal_frame_folds_through_the_cards_own_agents_map(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, _ = _harness(_oracle(files={}))
    card_id = _mint_running_card(runner, session)
    # The companion defect's precondition: a card that names the task (the
    # receipt / task-event overlay wrote the agents map) but no
    # agent_task_calls binding — its task_started was missed or filtered.
    assert runner.agent_task_calls == {}

    asyncio.run(
        runner.fold_agent_task_event(
            session,
            ClaudeTaskEvent(
                kind="updated",
                task_id=ZOMBIE_TASK_ID,
                status="completed",
                end_time=NOW * 1000,
            ),
        )
    )

    assert host.timeline_item_upserts, "the terminal frame must not be dropped"
    upsert = host.timeline_item_upserts[-1]
    assert upsert.id == card_id
    assert upsert.status == "done"
    assert upsert.content["agents"][ZOMBIE_TASK_ID]["status"] == "completed"


def test_T6_a_task_with_no_card_stays_unprojected(
    tmp_path: Any, monkeypatch: Any
) -> None:
    # local_bash semantics (findings §8.11): its tool ids point inside a
    # subagent and no card names it — the fallback finds nothing and the
    # frame stays silent, exactly as before.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, _ = _harness(_oracle(files={}))
    _mint_running_card(runner, session)

    asyncio.run(
        runner.fold_agent_task_event(
            session,
            ClaudeTaskEvent(
                kind="updated",
                task_id="bash_local_inside_subagent",
                status="completed",
            ),
        )
    )

    assert host.timeline_item_upserts == []


def test_T6_an_unbound_frame_for_another_sessions_card_stays_silent(
    tmp_path: Any, monkeypatch: Any
) -> None:
    # The reverse lookup is session-scoped: one projector serves every
    # session, and a foreign card's agents map is not this session's key.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, _ = _harness(_oracle(files={}))
    foreign = ClaudeSession(
        session_id="sess_other_session",
        external_session_id="11111111-2222-3333-4444-555555555555",
        title="Other",
        cwd=CWD,
    )
    runner.timeline.fold_agent_task_event(
        foreign,
        tool_use_id=DISPATCH_TUID,
        overlay=ClaudeAgentTaskOverlay(
            agents={ZOMBIE_TASK_ID: {"status": "running"}},
        ),
        status="running",
        base=AgentCallToolContent(kind="agent_call", title="research", agents={}),
    )

    asyncio.run(
        runner.fold_agent_task_event(
            session,
            ClaudeTaskEvent(
                kind="updated", task_id=ZOMBIE_TASK_ID, status="completed"
            ),
        )
    )

    assert host.timeline_item_upserts == []


# --------------------------------------------------------------------------
# T7: eviction + a fresh file closes nothing (CLI jitter is not death)
# --------------------------------------------------------------------------


def test_T7_snapshot_eviction_with_a_fresh_file_closes_nothing(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    host, _, session, runner, connection = _harness(
        _oracle(files={ZOMBIE_TASK_ID: _fresh_file()}),
        with_card_agents={ZOMBIE_TASK_ID: "running"},
    )
    connection.background.observed({"subtype": "task_started", "task_id": ZOMBIE_TASK_ID})
    connection.background.observed(_snapshot_frame([]))
    # Evicted from the exemption, but the engine's file says the agent is
    # alive and fresh — a snapshot glitch may not kill it. (The eviction's
    # effect on the live set itself is T2's pin; here only the outcome
    # matters, so this guard holds on the baseline too.)
    assert asyncio.run(runner.sweep_agent_cards_by_evidence(session)) == 0
    assert host.timeline_item_upserts == []
    assert ZOMBIE_TASK_ID in connection.background.active_ids


# --------------------------------------------------------------------------
# T8: a connection that never saw a snapshot — byte-for-byte old behaviour
# --------------------------------------------------------------------------


def test_T8_without_a_snapshot_the_stale_zombie_stays_exempt(
    tmp_path: Any, monkeypatch: Any
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    monkeypatch.delenv("AA_SUBAGENT_LIVE_VOUCH", raising=False)
    host, _, session, runner, connection = _harness(
        _oracle(files={ZOMBIE_TASK_ID: _stale_file()}),
        with_card_agents={ZOMBIE_TASK_ID: "running"},
    )
    connection.background.observed({"subtype": "task_started", "task_id": ZOMBIE_TASK_ID})
    # No snapshot frame ever arrived: last_snapshot_ids stays None and the
    # full register vouches — the old, conservative behaviour, unchanged.
    assert runner.live_agent_task_ids(session) == frozenset({ZOMBIE_TASK_ID})
    assert asyncio.run(runner.sweep_agent_cards_by_evidence(session)) == 0
    assert host.timeline_item_upserts == []
    assert ZOMBIE_TASK_ID in connection.background.active_ids


def test_T8_a_closing_connection_vouches_nothing(
    tmp_path: Any, monkeypatch: Any
) -> None:
    # Unchanged guard: a connection on its way out vouches nothing, whatever
    # its registers hold.
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    _, _, session, runner, connection = _harness(_oracle(files={}))
    connection.background.active_ids.add(ZOMBIE_TASK_ID)
    connection.closing = True
    assert runner.live_agent_task_ids(session) == frozenset()
