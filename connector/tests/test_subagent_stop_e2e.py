"""Subagent stop — scenario e2e on the real stack (A3 batch, station e2e).

The task sheet (``claude-subagent-preserve-tasks.md`` §3) asks for six
end-to-end arms driven by a fake SDK client against the real machinery:
``ClaudeRuntime``, ``ClaudeTurnRunner``, ``ClaudeConnection``, the timeline
projection and the host reporting. Only the SDK transport and the CLI are
faked. Each arm ships with its own counter-proof — a sibling test, or an
in-test pre-state assertion — showing the same stack behaves the other way
when its condition flips, so no arm can pass on a build where the mechanism
under test is dead.

Arm map
-------

* a — stop one subagent: only its task gets a ``stop_task`` control, its card
  converges on the CLI's own terminal frame, the sibling card is never
  touched. Counter: with no stop call both agents keep running.
* b — the new-semantics main stop (``preserveBackground=true``): the turn
  aborts, every background task survives — no ``stop_task`` fan-out, no
  "killed" fold, and the children keep reporting afterwards. Counter: the
  legacy stop (no flag) fans ``stop_task`` out to exactly the bound
  subagents and folds exactly those kills.
* c — a stop with no subagents is frame-identical between the declared and
  the undeclared path (the regression arm). Counter: the same digest
  distinguishes a stop that does touch a card.
* d — the dispatch-window ghost: a stop inside either window (tool_use only;
  receipt-only, red team F-D) lands the card terminal. Counter: the same
  card sits running before the stop.
* e — the kill switch: declaration off — by config and by an SDK without the
  seam — the interrupt path emits exactly the legacy frame sequence, with no
  ``stop_task`` control and no new field. Counter: with the switch on, the
  same refused stop folds nothing where the legacy path folds the bound set.
* f — the coverage gate, from station 2's census conclusions
  (``.local-dev/recon/subagent-stop/task-type-coverage-findings.md`` §2-§4,
  encoded below as data — the local file is read by the human, never by this
  test; pp 2026-10-05 晚: bash/workflow 先不杀): every reachable background
  type is either covered by the spared policy or has a sanctioned
  disposition, and an unenumerated type inherits the pass-through — the
  disposition is walked id by id, so an unmapped id fails the gate.

Wire fixtures come from ``test_claude_subagent_progress.py`` (real captures)
and ``test_claude_subagent_stop.py`` (the second dispatch); the two-agent
scenario is the burst shape both files already model. The bash/workflow/
unenumerated task frames are modelled on the census recordings (same file,
§2) and marked where synthetic.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any

from test_claude_compact_ghost import (
    _runtime_with,
    _single_client_factory,
    _wait_until,
)
from test_claude_runtime import (
    _default_sdk,
    _FakeClaudeClient,
    _FakeHookMatcher,
    _RecordingHost,
    _ScheduledClaudeClient,
)
from test_claude_stale_frame_turn import _runtime_with_values
from test_claude_subagent_progress import (
    DISPATCH_TUID,
    SESSION,
    TASK_ID,
    WIRE_DISPATCH_RECEIPT,
    WIRE_DISPATCH_TOOL_USE,
    WIRE_MAIN_AGENT_TEXT,
    WIRE_MAIN_AGENT_THINKING,
    WIRE_MAIN_RESULT,
    WIRE_TASK_PROGRESS_LAST,
    WIRE_TASK_STARTED,
    WIRE_TASK_UPDATED,
    _card_agents,
    _card_items,
    _parse,
    _start_dispatch,
)
from test_claude_subagent_stop import (
    SECOND_TASK_ID,
    SECOND_TUID,
    WIRE_SECOND_DISPATCH_RECEIPT,
    WIRE_SECOND_DISPATCH_TOOL_USE,
    WIRE_SECOND_TASK_STARTED,
    _SessionScopedInterrupt,
    _StopSubagentHost,
    _StopSubagentSupervisor,
)

from connector.runtime_protocol import RuntimeConfig
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sdk import stop_affordance
from connector.runtimes.claude.timeline.agent_calls import (
    AGENT_CARD_TERMINAL_STATUSES,
)
from connector.runtimes.claude.timeline.messages import stable_tool_item_id
from connector.server.runtime_rpc import RuntimeRpcHandler

# --------------------------------------------------------------------------
# Synthetic task frames for the non-agent background types
# --------------------------------------------------------------------------
#
# The census (``task-type-coverage-findings.md`` §2, runs 1 and 4) recorded
# the real shapes: a top-level background Bash (is_backgrounded, no
# owned_by_subagent, no card) and a Workflow task (task_type local_workflow,
# a tool_use id, no is_backgrounded key). No capture ships in the repo, so
# these three are modelled on that recording — every field the connector
# reads (task_id, task_type, tool_use_id, session_id) is verbatim from it.
#
# The mcp_task frame stands for the unenumerated remainder: the gate's
# contract is by-id, not by-type, so a type the census could not reach must
# still inherit the sanctioned pass-through instead of falling into an
# uncovered state.

BASH_TUID = "call_00_TopLevelBackgroundBash0000001"
BASH_TASK_ID = "bpp6swae6"

WIRE_BACKGROUND_BASH_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": BASH_TASK_ID,
    "tool_use_id": BASH_TUID,
    "description": "Sleep 30 and write a marker",
    "is_backgrounded": True,
    "task_type": "local_bash",
    "uuid": "e2e-bg-bash-started-1",
    "session_id": SESSION,
}

WORKFLOW_TUID = "call_function_e2eWorkflow000000001"
WORKFLOW_TASK_ID = "wda7conni"

WIRE_WORKFLOW_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": WORKFLOW_TASK_ID,
    "tool_use_id": WORKFLOW_TUID,
    "description": "Run a dynamic workflow",
    "task_type": "local_workflow",
    "uuid": "e2e-workflow-started-1",
    "session_id": SESSION,
}

FOREIGN_TUID = "call_00_e2eMcpTask000000000000001"
FOREIGN_TASK_ID = "k4e2emcptask"

WIRE_FOREIGN_TASK_STARTED = {
    "type": "system",
    "subtype": "task_started",
    "task_id": FOREIGN_TASK_ID,
    "tool_use_id": FOREIGN_TUID,
    "description": "An unenumerated background type",
    "task_type": "mcp_task",
    "uuid": "e2e-foreign-started-1",
    "session_id": SESSION,
}

SESSION_ID = "sub_progress"


# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------


def _reset_declaration() -> None:
    stop_affordance._declared = False


def _rpc(runtime: ClaudeRuntime) -> RuntimeRpcHandler:
    return RuntimeRpcHandler(_StopSubagentSupervisor(runtime), _StopSubagentHost())


def _scoped(**params: Any) -> dict[str, Any]:
    return {"runtime": "claude", "runtimeId": "claude", **params}


def _runtime_with_sdk(
    host: Any,
    client_factory: Any,
    sdk: Any,
    **values: Any,
) -> ClaudeRuntime:
    """The ``_runtime_with_values`` shape, with the SDK itself supplied.

    The kill-switch arm needs an SDK whose initialize seam is absent, which
    is a property of the loaded SDK object, not of a config value.
    """

    sdk.HookMatcher = _FakeHookMatcher
    return ClaudeRuntime(
        config=RuntimeConfig(
            runtime="claude", revision=1, values={"environment": {}, **values}
        ),
        host=host,
        sdk_loader=lambda: sdk,
        client_factory=client_factory,
    )


def _sdk_without_declaration_seam() -> Any:
    """An SDK whose Query class has no initialize-send attribute at all.

    ``install_per_task_stop_declaration`` is fail-soft by contract: with no
    seam to patch it must report ``False`` and leave the pre-declaration
    behavior in place, exactly as an older SDK would.
    """

    sdk = _default_sdk()
    sdk._internal = SimpleNamespace(
        query=SimpleNamespace(Query=type("_Query", (), {}))
    )
    return sdk


class _E2eClient(_SessionScopedInterrupt, _ScheduledClaudeClient):
    """The e2e transport.

    The "hello" turn ships ``frames`` (the Agent dispatch shapes the arm
    asked for) and then the main result; "wait" leaves the follow-up turn
    open so the stop has a live execution whose connection hosts the
    background work. The abort tail is session-scoped (the production
    shape), and per-task stops are recorded, not emulated: the CLI's own
    terminal frame stays the only writer of a card's terminal state.
    """

    def __init__(self, frames: tuple[dict[str, Any], ...] | None = None) -> None:
        super().__init__()
        self.native_id = str(WIRE_DISPATCH_RECEIPT["session_id"])
        self.frames = (
            (WIRE_DISPATCH_TOOL_USE, WIRE_DISPATCH_RECEIPT)
            if frames is None
            else frames
        )
        self.stopped: list[str] = []

    async def _complete_query(self, prompt: str) -> None:
        if prompt == "wait":
            await _FakeClaudeClient.query(self, prompt)
            return
        await _FakeClaudeClient.query(self, prompt)
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in self.frames:
            await self.incoming.put(_parse(frame))
        await self.incoming.put(_parse(WIRE_MAIN_RESULT))

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)


class _TwoAgentE2eClient(_E2eClient):
    """The burst shape: one turn dispatching two background Agents."""

    def __init__(self) -> None:
        super().__init__(
            (
                WIRE_DISPATCH_TOOL_USE,
                WIRE_DISPATCH_RECEIPT,
                WIRE_SECOND_DISPATCH_TOOL_USE,
                WIRE_SECOND_DISPATCH_RECEIPT,
            )
        )


class _RefusingStopE2eClient(_E2eClient):
    """The CLI refuses every per-task stop (the F-A refusal arm)."""

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)
        raise RuntimeError("the CLI refused")


class _PlainSessionClient(_SessionScopedInterrupt, _ScheduledClaudeClient):
    """A session whose main agent simply answers; no background work."""

    def __init__(self) -> None:
        super().__init__()
        self.native_id = str(WIRE_DISPATCH_RECEIPT["session_id"])
        # Records any per-task control that would ever reach this transport:
        # a no-subagent stop must leave it empty on both declaration paths.
        self.stopped: list[str] = []

    async def stop_task(self, task_id: str) -> None:
        self.stopped.append(task_id)

    async def _complete_query(self, prompt: str) -> None:
        if prompt == "wait":
            await _FakeClaudeClient.query(self, prompt)
            return
        await _FakeClaudeClient.query(self, prompt)
        if prompt != "hello":
            await self.reply(f"reply:{prompt}")
            return
        for frame in (
            WIRE_MAIN_AGENT_THINKING,
            WIRE_MAIN_AGENT_TEXT,
            WIRE_MAIN_RESULT,
        ):
            await self.incoming.put(_parse(frame))


async def _start_wait_turn(
    runtime: ClaudeRuntime, session_id: str = SESSION_ID
) -> Any:
    """Open the follow-up turn the stop interrupts; return its connection."""

    await runtime.start_turn(session_id, None, "wait")
    await _wait_until(
        lambda: getattr(runtime._sessions[session_id].execution, "client", None)
        is not None
    )
    return runtime._turns.runner.connections[session_id]


async def _wait_agent_running(host: _RecordingHost, card_id: str, task_id: str) -> None:
    await _wait_until(
        lambda: _card_agents(host, card_id).get(task_id, {}).get("status")
        == "running"
    )


# --- frame recording ---------------------------------------------------------


def _agents_statuses(item: Any) -> tuple[tuple[str, str | None], ...]:
    agents = item.content.get("agents") or {}
    return tuple(sorted((str(k), (v or {}).get("status")) for k, v in agents.items()))


def _item_core(item: Any) -> tuple[Any, ...]:
    """The content fields a regression comparison must see.

    Volatile per-run values (turn tokens, order slots) are excluded by
    construction: the tuple carries the type, status, source event, role and
    the content's display spine — kind, text, and the agents map's statuses
    (the fold-honesty signal).
    """

    content = dict(item.content)
    return (
        item.type,
        item.status,
        item.source.get("event"),
        item.role,
        content.get("kind"),
        content.get("text"),
        _agents_statuses(item),
    )


def _capture(host: _RecordingHost) -> tuple[int, int, int]:
    return (
        len(host.timeline_item_upserts),
        len(host.session_state_updates),
        len(host.session_turn_ends),
    )


def _frames_since(
    host: _RecordingHost, start: tuple[int, int, int]
) -> tuple[Any, ...]:
    """The host-visible frame sequence emitted since ``start``.

    Returns the three published streams in order — timeline items (canonical
    core), session state updates (status/reason/error), turn ends (outcome) —
    which is the client-visible surface a stop can touch.
    """

    items_start, states_start, ends_start = start
    return (
        tuple(
            _item_core(item)
            for item in host.timeline_item_upserts[items_start:]
        ),
        tuple(
            (
                update["status"],
                update.get("status_reason"),
                bool(update.get("error")),
            )
            for update in host.session_state_updates[states_start:]
        ),
        tuple(end["outcome"] for end in host.session_turn_ends[ends_start:]),
    )


#: The verbatim receipt body the dispatch card carries into its terminal
#: fold (the fixture's own text), pinned in the legacy literal below.
_RECEIPT_TEXT = WIRE_DISPATCH_RECEIPT["message"]["content"][0]["content"][0]["text"]

#: What the legacy (pre-declaration) interrupt emits, frame for frame: the
#: fallback arm folds the bound subagent as killed — the pre-A3 reporting,
#: which assumed the CLI's own all-stop had killed it — then the turn settles
#: to idle. Nothing else: no ``claude.agent.stopped`` sweep, no
#: ``stoppedWithoutTask`` field, no second item.
LEGACY_STOP_FRAMES: tuple[Any, ...] = (
    (
        (
            "tool",
            "interrupted",
            "claude.agent.task",
            "tool",
            "agent_call",
            _RECEIPT_TEXT,
            ((TASK_ID, "killed"),),
        ),
    ),
    (("idle", None, False),),
    ("interrupted",),
)


@dataclass(slots=True)
class _AgentStopRun:
    """One bound-subagent stop, captured before the runtime tears down."""

    frames: tuple[Any, ...]
    result: dict[str, Any]
    client: _E2eClient
    connection: Any
    session: Any
    card_id: str
    card: Any
    agents: dict[str, Any]
    host: _RecordingHost


async def _run_agent_stop(
    client: _E2eClient,
    *,
    values: dict[str, Any] | None = None,
    sdk: Any = None,
) -> _AgentStopRun:
    """One background subagent + one default-semantics stop.

    The scenario every kill-switch arm shares: dispatch, bind the task, open
    the turn, then a plain ``session.interrupt`` (no ``preserveBackground``)
    through the RPC handler. Returns the stop's frame sequence and the
    post-stop card snapshot; teardown happens after everything is captured.
    """

    host = _RecordingHost()
    if sdk is None:
        runtime = _runtime_with_values(
            host, _single_client_factory(client), dict(values or {})
        )
    else:
        runtime = _runtime_with_sdk(
            host, _single_client_factory(client), sdk, **dict(values or {})
        )
    try:
        session = await _start_dispatch(runtime)
        card_id = stable_tool_item_id(session, DISPATCH_TUID)
        await client.incoming.put(_parse(WIRE_TASK_STARTED))
        await _wait_agent_running(host, card_id, TASK_ID)
        connection = await _start_wait_turn(runtime)
        start = _capture(host)
        result = await _rpc(runtime).dispatch(
            "session.interrupt",
            _scoped(sessionId=session.session_id, reason="user"),
        )
        return _AgentStopRun(
            frames=_frames_since(host, start),
            result=result,
            client=client,
            connection=connection,
            session=session,
            card_id=card_id,
            card=_card_items(host, card_id)[-1],
            agents=_card_agents(host, card_id),
            host=host,
        )
    finally:
        _reset_declaration()
        await runtime.stop()


# --------------------------------------------------------------------------
# arm a — stop one subagent: only it dies
# --------------------------------------------------------------------------


def test_arm_a_stop_one_subagent_lands_only_its_card() -> None:
    async def run() -> None:
        client = _TwoAgentE2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            first_card = stable_tool_item_id(session, DISPATCH_TUID)
            second_card = stable_tool_item_id(session, SECOND_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_SECOND_TASK_STARTED))
            await _wait_agent_running(host, first_card, TASK_ID)
            await _wait_agent_running(host, second_card, SECOND_TASK_ID)
            connection = await _start_wait_turn(runtime)
            assert {TASK_ID, SECOND_TASK_ID} <= connection.background.active_ids
            second_touches = len(_card_items(host, second_card))

            result = await _rpc(runtime).dispatch(
                "session.stopSubagent",
                _scoped(sessionId=session.session_id, taskId=TASK_ID),
            )

            # The per-task control reached exactly one task.
            assert result["stopped"] is True
            assert client.stopped == [TASK_ID]

            # The CLI's own terminal frame is the only writer of the card's
            # terminal state: it converges, and the live snapshot drops it.
            await client.incoming.put(
                _parse(
                    {
                        **WIRE_TASK_UPDATED,
                        "patch": {"status": "killed", "end_time": 1},
                        "uuid": "e2e-arm-a-killed-1",
                    }
                )
            )
            await _wait_until(
                lambda: _card_items(host, first_card)[-1].status == "interrupted"
            )
            assert _card_agents(host, first_card)[TASK_ID]["status"] == "killed"
            assert TASK_ID not in connection.background.active_ids

            # The sibling is untouched: no new upsert, card and ledger still
            # running, task still in the live snapshot, no stop ever named it.
            assert len(_card_items(host, second_card)) == second_touches
            assert _card_items(host, second_card)[-1].status == "running"
            assert (
                _card_agents(host, second_card)[SECOND_TASK_ID]["status"]
                == "running"
            )
            assert SECOND_TASK_ID in connection.background.active_ids
            assert client.stopped == [TASK_ID]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_arm_a_counter_without_the_stop_both_agents_keep_running() -> None:
    """The control for arm a: with no stop call there is nothing to observe —
    both cards stay running and the snapshot keeps both tasks."""

    async def run() -> None:
        client = _TwoAgentE2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            first_card = stable_tool_item_id(session, DISPATCH_TUID)
            second_card = stable_tool_item_id(session, SECOND_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_SECOND_TASK_STARTED))
            await _wait_agent_running(host, first_card, TASK_ID)
            await _wait_agent_running(host, second_card, SECOND_TASK_ID)
            connection = await _start_wait_turn(runtime)

            assert client.stopped == []
            assert _card_items(host, first_card)[-1].status == "running"
            assert _card_items(host, second_card)[-1].status == "running"
            assert {TASK_ID, SECOND_TASK_ID} <= connection.background.active_ids
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# arm b — the new-semantics main stop keeps the background alive
# --------------------------------------------------------------------------


def test_arm_b_preserving_stop_aborts_the_turn_and_keeps_background_alive() -> None:
    async def run() -> None:
        client = _TwoAgentE2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            first_card = stable_tool_item_id(session, DISPATCH_TUID)
            second_card = stable_tool_item_id(session, SECOND_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_SECOND_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_BACKGROUND_BASH_STARTED))
            await _wait_agent_running(host, first_card, TASK_ID)
            await _wait_agent_running(host, second_card, SECOND_TASK_ID)
            connection = await _start_wait_turn(runtime)
            live = {TASK_ID, SECOND_TASK_ID, BASH_TASK_ID}
            await _wait_until(lambda: live <= connection.background.active_ids)
            first_touches = len(_card_items(host, first_card))
            second_touches = len(_card_items(host, second_card))

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(
                    sessionId=session.session_id,
                    reason="user",
                    preserveBackground=True,
                ),
            )

            # The turn aborted …
            assert result["interrupted"] is True
            assert host.session_turn_ends[-1]["outcome"] == "interrupted"
            # … with zero per-task controls and zero kill reporting: no
            # fan-out call, no killed fold, no sweep closure, no fabricated
            # terminal on any card.
            assert client.stopped == []
            assert len(_card_items(host, first_card)) == first_touches
            assert len(_card_items(host, second_card)) == second_touches
            assert _card_items(host, first_card)[-1].status == "running"
            assert _card_items(host, second_card)[-1].status == "running"
            assert _card_agents(host, first_card)[TASK_ID]["status"] == "running"
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.source.get("event") == "claude.agent.stopped"
            ]
            # Every background task — agent and bash alike — is still live.
            assert live <= connection.background.active_ids

            # And the spared children keep reporting into their cards after
            # the main stop: the policy is live work, not a frozen card.
            await client.incoming.put(_parse(WIRE_TASK_PROGRESS_LAST))
            await _wait_until(
                lambda: _card_agents(host, first_card)
                .get(TASK_ID, {})
                .get("lastToolName")
                == "Bash"
            )
            assert _card_items(host, first_card)[-1].status == "running"
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_arm_b_counter_legacy_stop_fans_out_and_folds_exactly_the_subagents() -> None:
    """The control for arm b: without the flag the stop is the old all-stop —
    an explicit ``stop_task`` per bound subagent, and exactly those folded
    as killed. The unbound bash task is neither stopped nor folded."""

    async def run() -> None:
        client = _TwoAgentE2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            first_card = stable_tool_item_id(session, DISPATCH_TUID)
            second_card = stable_tool_item_id(session, SECOND_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_SECOND_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_BACKGROUND_BASH_STARTED))
            await _wait_agent_running(host, first_card, TASK_ID)
            await _wait_agent_running(host, second_card, SECOND_TASK_ID)
            connection = await _start_wait_turn(runtime)
            await _wait_until(
                lambda: BASH_TASK_ID in connection.background.active_ids
            )

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(sessionId=session.session_id, reason="user"),
            )

            assert result["interrupted"] is True
            # The fan-out owns exactly the bound subagents …
            assert sorted(client.stopped) == sorted([TASK_ID, SECOND_TASK_ID])
            # … the pass-through bash task is never named …
            assert BASH_TASK_ID not in client.stopped
            # … both owned cards fold immediately, as killed …
            assert _card_items(host, first_card)[-1].status == "interrupted"
            assert _card_items(host, second_card)[-1].status == "interrupted"
            assert _card_agents(host, first_card)[TASK_ID]["status"] == "killed"
            assert (
                _card_agents(host, second_card)[SECOND_TASK_ID]["status"]
                == "killed"
            )
            # … and the bash task survives, uncarded.
            assert BASH_TASK_ID in connection.background.active_ids
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.id == stable_tool_item_id(session, BASH_TUID)
            ]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# arm c — the no-subagent stop is a frame-for-frame regression
# --------------------------------------------------------------------------


async def _run_plain_stop(
    declared: bool,
) -> tuple[tuple[Any, ...], tuple[Any, ...], _PlainSessionClient, dict[str, Any]]:
    """The plain session (no background work) run through one stop.

    Returns (full-run frames, stop-phase frames, client, RPC result).
    """

    client = _PlainSessionClient()
    host = _RecordingHost()
    runtime = _runtime_with_values(
        host,
        _single_client_factory(client),
        {"perTaskStopAffordance": declared},
    )
    try:
        await runtime.start_turn("plain", None, "hello")
        await asyncio.wait_for(runtime._sessions["plain"].active_task, 5)
        await _start_wait_turn(runtime, "plain")
        start = _capture(host)
        result = await _rpc(runtime).dispatch(
            "session.interrupt", _scoped(sessionId="plain", reason="user")
        )
        return (
            _frames_since(host, (0, 0, 0)),
            _frames_since(host, start),
            client,
            result,
        )
    finally:
        _reset_declaration()
        await runtime.stop()


def test_arm_c_stop_without_subagents_matches_the_undeclared_baseline() -> None:
    """With no background work the declared path is the undeclared path,
    frame for frame — the new machinery must be invisible to the old shape."""

    async def run() -> None:
        declared_frames, _, declared_client, declared_result = (
            await _run_plain_stop(True)
        )
        undeclared_frames, _, undeclared_client, undeclared_result = (
            await _run_plain_stop(False)
        )

        # Non-vacuous: the stop really produced the turn's frames.
        assert declared_result["interrupted"] is True
        assert declared_frames[2] == ("completed", "interrupted")
        assert ("idle", None, False) in declared_frames[1]
        assert declared_frames[0], "the reply rows must be recorded"
        assert not [
            item for item in declared_frames[0] if item[6]
        ], "no agent cards may exist in this scenario"

        # The regression itself.
        assert declared_frames == undeclared_frames
        assert undeclared_result["interrupted"] is True
        assert declared_client.stopped == []
        assert undeclared_client.stopped == []

    asyncio.run(run())


def test_arm_c_counter_the_digest_sees_a_stop_that_touches_a_card() -> None:
    """The control for arm c: the same recording, over a stop that does own a
    subagent, differs in exactly the card fold — so the equality in the
    regression arm is a real equality, not an empty recording."""

    async def run() -> None:
        _, plain_stop_frames, _, _ = await _run_plain_stop(True)

        client = _E2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await _wait_agent_running(host, card_id, TASK_ID)
            await _start_wait_turn(runtime)
            start = _capture(host)
            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(sessionId=session.session_id, reason="user"),
            )
            agent_stop_frames = _frames_since(host, start)
        finally:
            _reset_declaration()
            await runtime.stop()

        assert result["interrupted"] is True
        # The plain stop publishes no item at all; the owning stop publishes
        # the killed fold. That difference is the digest's sensitivity.
        assert plain_stop_frames[0] == ()
        assert len(agent_stop_frames[0]) == 1
        assert agent_stop_frames[0][0][:3] == (
            "tool",
            "interrupted",
            "claude.agent.task",
        )
        assert agent_stop_frames != plain_stop_frames
        # … and everything else about the two stops is the same shape.
        assert agent_stop_frames[1] == plain_stop_frames[1]
        assert agent_stop_frames[2] == plain_stop_frames[2]

    asyncio.run(run())


# --------------------------------------------------------------------------
# arm d — the dispatch-window ghost dies with the stop
# --------------------------------------------------------------------------


def test_arm_d_dispatch_window_ghost_is_closed_by_the_stop() -> None:
    """The dispatch window: the call is out, the CLI never created a task —
    no receipt, no task frame, no writer that could ever close the card."""

    async def run() -> None:
        client = _E2eClient(frames=(WIRE_DISPATCH_TOOL_USE,))
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            # The ghost as the client sees it (this is also the counter: it
            # sits running, and nothing else will ever judge it).
            assert _card_items(host, card_id)[-1].status == "running"
            assert _card_agents(host, card_id) == {}
            assert runtime._timeline._agent_cards[card_id].status == "running"
            await _start_wait_turn(runtime)

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(sessionId=session.session_id, reason="user"),
            )

            assert result["interrupted"] is True
            card = _card_items(host, card_id)[-1]
            assert card.status == "interrupted"
            assert card.content.get("stoppedWithoutTask") is True
            assert card.source["event"] == "claude.agent.stopped"
            # No ghost survives in the projector ledger either.
            assert (
                runtime._timeline._agent_cards[card_id].status
                in AGENT_CARD_TERMINAL_STATUSES
            )
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_arm_d_receipt_window_ghost_is_closed_by_the_stop() -> None:
    """The receipt-window ghost (red team F-D): ``async_launched`` is a launch
    report, not proof a task exists — the card is still a ghost, and the stop
    judges it. The agents entry keeps the receipt's own word."""

    async def run() -> None:
        client = _E2eClient()  # dispatch + async receipt, no task_started
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            # Before the stop the ghost persists — nothing in the pipeline
            # closes a card whose task never started.
            assert _card_items(host, card_id)[-1].status == "running"
            assert (
                _card_agents(host, card_id)[TASK_ID]["status"]
                == "async_launched"
            )
            assert runtime._timeline._agent_cards[card_id].status == "running"
            await _start_wait_turn(runtime)

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(sessionId=session.session_id, reason="user"),
            )

            assert result["interrupted"] is True
            card = _card_items(host, card_id)[-1]
            assert card.status == "interrupted"
            assert card.content.get("stoppedWithoutTask") is True
            # The sweep invents no agent status: the receipt's marker stays.
            assert (
                _card_agents(host, card_id)[TASK_ID]["status"]
                == "async_launched"
            )
            assert (
                runtime._timeline._agent_cards[card_id].status
                in AGENT_CARD_TERMINAL_STATUSES
            )
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------
# arm e — the kill switch: off means the legacy bytes
# --------------------------------------------------------------------------


def test_arm_e_kill_switch_off_emits_exactly_the_legacy_frames() -> None:
    async def run() -> None:
        outcome = await _run_agent_stop(
            _E2eClient(), values={"perTaskStopAffordance": False}
        )

        assert outcome.result["interrupted"] is True
        assert outcome.connection.per_task_stop_declared is False
        # No per-task control leaves the connector at all: the mechanism is
        # off, not merely unused.
        assert outcome.client.stopped == []
        # The stop path emits the legacy sequence, top to bottom …
        assert outcome.frames == LEGACY_STOP_FRAMES
        # … including the fallback's killed fold, and no new field on it.
        assert outcome.card.status == "interrupted"
        assert outcome.agents[TASK_ID]["status"] == "killed"
        assert "stoppedWithoutTask" not in outcome.card.content

    asyncio.run(run())


def test_arm_e_missing_sdk_seam_falls_soft_to_the_legacy_frames() -> None:
    """The declaration cannot be installed at all (an SDK without the seam):
    fail-soft means the old behavior, not a missing stop."""

    async def run() -> None:
        outcome = await _run_agent_stop(
            _E2eClient(), values={}, sdk=_sdk_without_declaration_seam()
        )

        assert stop_affordance.is_declared() is False
        assert outcome.connection.per_task_stop_declared is False
        assert outcome.client.stopped == []
        assert outcome.frames == LEGACY_STOP_FRAMES
        assert outcome.card.status == "interrupted"
        assert outcome.agents[TASK_ID]["status"] == "killed"

    asyncio.run(run())


def test_arm_e_counter_the_switch_gates_real_behavior() -> None:
    """The control for arm e: the same refused stop, both switch states.

    Declared, the connector reports exactly what the CLI accepted — here
    nothing, so no kill is folded and the card stays running (F-A honesty).
    Undeclared, the legacy fallback folds the bound set anyway, which is the
    pre-A3 all-stop assumption. The two frame sequences differ in exactly
    that fold, so "switch off = old behavior" is a measured difference, not
    a claim about an idle flag."""

    async def run() -> None:
        declared = await _run_agent_stop(
            _RefusingStopE2eClient(), values={"perTaskStopAffordance": True}
        )
        assert declared.client.stopped == [TASK_ID]  # attempted, refused
        assert declared.connection.per_task_stop_declared is True
        assert declared.frames[0] == ()  # nothing was killed …
        assert declared.card.status == "running"
        assert declared.agents[TASK_ID]["status"] == "running"
        assert TASK_ID in declared.connection.background.active_ids

        undeclared = await _run_agent_stop(
            _RefusingStopE2eClient(), values={"perTaskStopAffordance": False}
        )
        assert undeclared.client.stopped == []  # no attempt in this mode
        assert undeclared.frames == LEGACY_STOP_FRAMES
        assert undeclared.card.status == "interrupted"

        assert declared.frames != undeclared.frames

    asyncio.run(run())


# --------------------------------------------------------------------------
# arm f — the coverage gate
# --------------------------------------------------------------------------
#
# The P0 census (station 2, ``task-type-coverage-findings.md`` §2-§3): the
# only reachable background types in an AA session are Task (local_agent),
# background Bash (local_bash) and the Workflow tool (local_workflow); the
# other seven CLI types are structurally unreachable. Per pp 2026-10-05 晚
# ("先不杀"), bash/workflow are pass-through: spared by the declared-interrupt
# branch, never named by the connector's fan-out, never folded. The gate
# walks every id the live snapshot holds — an id with no sanctioned
# disposition, or a disposition outside {"stopped_owned", "left_running"},
# is an uncovered state and fails.

GATE_DEFAULT_DISPOSITION = {
    TASK_ID: "stopped_owned",  # local_agent: owned through its card binding
    BASH_TASK_ID: "left_running",  # local_bash: pass-through
    WORKFLOW_TASK_ID: "left_running",  # local_workflow: pass-through
    FOREIGN_TASK_ID: "left_running",  # unenumerated type: inherited
}


def test_arm_f_spared_policy_covers_every_reachable_type() -> None:
    async def run() -> None:
        client = _E2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_BACKGROUND_BASH_STARTED))
            await client.incoming.put(_parse(WIRE_WORKFLOW_STARTED))
            await client.incoming.put(_parse(WIRE_FOREIGN_TASK_STARTED))
            await _wait_agent_running(host, card_id, TASK_ID)
            connection = await _start_wait_turn(runtime)
            live = set(GATE_DEFAULT_DISPOSITION)
            await _wait_until(lambda: live <= connection.background.active_ids)

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(
                    sessionId=session.session_id,
                    reason="user",
                    preserveBackground=True,
                ),
            )

            assert result["interrupted"] is True
            # The spared policy covers every reachable type: each id still
            # lives in the snapshot, none was stopped, none was folded.
            assert client.stopped == []
            assert live <= connection.background.active_ids
            assert _card_items(host, card_id)[-1].status == "running"
            assert not [
                item
                for item in host.timeline_item_upserts
                if item.source.get("event") == "claude.agent.stopped"
            ]
            # Only the agent type ever minted a card: the non-agent types
            # have no per-task button surface this round — the accepted
            # G1/G2 trade, pinned so a new card cannot appear silently.
            for tool_use_id in (BASH_TUID, WORKFLOW_TUID, FOREIGN_TUID):
                row_id = stable_tool_item_id(session, tool_use_id)
                assert not [
                    item
                    for item in host.timeline_item_upserts
                    if item.id == row_id
                ]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())


def test_arm_f_default_stop_gives_every_type_a_sanctioned_disposition() -> None:
    async def run() -> None:
        client = _E2eClient()
        host = _RecordingHost()
        runtime = _runtime_with(host, _single_client_factory(client))
        try:
            session = await _start_dispatch(runtime)
            card_id = stable_tool_item_id(session, DISPATCH_TUID)
            await client.incoming.put(_parse(WIRE_TASK_STARTED))
            await client.incoming.put(_parse(WIRE_BACKGROUND_BASH_STARTED))
            await client.incoming.put(_parse(WIRE_WORKFLOW_STARTED))
            await client.incoming.put(_parse(WIRE_FOREIGN_TASK_STARTED))
            await _wait_agent_running(host, card_id, TASK_ID)
            connection = await _start_wait_turn(runtime)
            live = set(GATE_DEFAULT_DISPOSITION)
            await _wait_until(lambda: live <= connection.background.active_ids)
            items_before = len(host.timeline_item_upserts)

            result = await _rpc(runtime).dispatch(
                "session.interrupt",
                _scoped(sessionId=session.session_id, reason="user"),
            )

            assert result["interrupted"] is True
            # The gate: walk the live snapshot and give every id exactly its
            # sanctioned disposition. An id with no table entry raises
            # KeyError here by construction — no uncovered state passes.
            observed: dict[str, str] = {}
            for task_id in sorted(connection.background.active_ids):
                expected = GATE_DEFAULT_DISPOSITION[task_id]
                observed[task_id] = (
                    "stopped_owned"
                    if task_id in client.stopped
                    else "left_running"
                )
                assert observed[task_id] == expected, (
                    f"{task_id}: {observed[task_id]} != {expected}"
                )
            assert observed == GATE_DEFAULT_DISPOSITION
            # And the report side matches the stop side: only the owned
            # subagent is folded, the pass-through types are not.
            stop_items = host.timeline_item_upserts[items_before:]
            folded = [
                item
                for item in stop_items
                if item.source.get("event") == "claude.agent.task"
            ]
            assert [item.id for item in folded] == [card_id]
            assert _agents_statuses(folded[0]) == ((TASK_ID, "killed"),)
            assert _card_agents(host, card_id)[TASK_ID]["status"] == "killed"
            for tool_use_id in (BASH_TUID, WORKFLOW_TUID, FOREIGN_TUID):
                assert not [
                    item
                    for item in stop_items
                    if item.id == stable_tool_item_id(session, tool_use_id)
                ]
        finally:
            _reset_declaration()
            await runtime.stop()

    asyncio.run(run())
