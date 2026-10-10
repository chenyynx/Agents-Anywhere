"""Z2 assembly-surface patch (zombie-agent-card tasks §9, 2026-10-10).

Two true-stack defects the isolated e2e caught and the unit trees could not
(``~/aa-test/e2e-residue/evidence-935571e3``: ``s6-rootcause.log`` plus
``s7-fold-diagnosis.log`` / ``s7-notice-anchor-probe.log``):

**D-A — a history-synced store session carries no meta.** The store is
in-process, so a session this process never live-drove enters it only through
``record_timeline_item``'s bare ``ensure(session_id)``: ``cwd=None``,
``external_session_id=None``. The 60s evidence sweep iterates exactly the
store's sessions, and the oracle's probe refuses to run without *both* fields
(``ClaudeSubagentOracle._probe`` -> ``path_known=False``), so a zombie born
from a history rebuild is unjudgable for the life of the process — the e2e's
double sample at 941s/1002s of file silence stayed ``running``. History sync
is the one path that already reads both fields (the SDK session info the
reader turns into ``SessionMeta``), so it adopts them onto the store session
before it publishes.

**D-B — a terminal notice anchored at the window boundary never folds.** The
sync builds its window with ``messages_after_cursor``, which starts *after*
the cursor's row, and ``_raw_history_notices`` resolves a raw-only notice's
anchor against *that window*. A ``queue-operation`` notice is invisible to the
SDK message view, so it never advances the cursor; its anchor is therefore the
last row the cursor already covered — exactly the row the window excludes.
Every incremental pass after it lands drops the notice, forever (until a
rebase). Measured on the real s7 transcript: the full view keeps the notice
and closes the card ``terminalNotice``; the production window keeps nothing
and projects no card at all.

Non-hollow: ``Z2-T1`` and ``Z2-T2`` fail on the ``9c775734`` baseline. The
compat guards (a live-driven session's ``cwd`` wins over a history read; a
repeat sync publishes nothing) hold on both sides of the fix. The three
``window_origin`` guards pin the new gate and only exist after the fix.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from connector.runtime_protocol import (
    RuntimeConfig,
    RuntimeHostClient,
    RuntimeTimelineItem,
    RuntimeTimelineSnapshot,
    timeline_content_hash,
)
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.history.state import ClaudeHistoryCursorStore
from connector.runtimes.claude.history.syncer import ClaudeHistorySyncer
from connector.runtimes.claude.runtime import ClaudeRuntime
from connector.runtimes.claude.sessions.reader import (
    _raw_history_notices,
    _read_raw_transcript_scan,
)
from connector.runtimes.claude.sessions.subagent_oracle import (
    ClaudeSubagentOracle,
    claude_project_key,
    scan_raw_transcript,
)
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore

EXTERNAL_SESSION_ID = "0fa72370-b9c6-464f-9343-c93d4d59c188"
SESSION_ID = "sess_claude_z2_window_notice"
TASK_ID = "a4e5a4c905abd0a4e"
DISPATCH_TUID = "call_a2657083922b4c71abcbb529"
PROJECT_DIRNAME = "proj"

#: File silence the sweep must act on (past the 900s stale deadline).
FILE_STALE_SECONDS = 7200.0
#: The launch receipt's age: past the start grace, far inside the 24h ceiling.
RECEIPT_AGE_SECONDS = 600.0
#: The completion's age at judgement time: the file stopped growing before it.
NOTICE_AGE_SECONDS = 60.0
FILE_SILENT_BEFORE_NOTICE_SECONDS = 120.0


#: One clock for the whole module. Every timestamp the fixture writes — the
#: raw rows and the subagent file's mtime — is derived from this instant, so
#: the oracle's judgement (it compares the file mtime against the notice and
#: the wall clock) is internally consistent no matter WHEN the test body runs.
#: Calling ``time.time()`` per use made the two drift apart as suite runtime
#: grew: the rows froze at import, the file mtime was set at execution, and a
#: minute-wide gap flipped the "file silent after the notice" test — the card
#: then closed by the fold (no ``closedByEvidence``) instead of the oracle.
_NOW = time.time()


def _iso(offset_seconds: float) -> str:
    moment = datetime.fromtimestamp(_NOW + offset_seconds, tz=UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


T_DISPATCH = _iso(-(RECEIPT_AGE_SECONDS + 5))
T_RECEIPT = _iso(-RECEIPT_AGE_SECONDS)
T_NOTICE = _iso(-NOTICE_AGE_SECONDS)
T_LATER = _iso(-NOTICE_AGE_SECONDS + 5)


# --------------------------------------------------------------------------
# The SDK message view (what the engine surfaces) and the raw transcript rows
# --------------------------------------------------------------------------


def _sdk_dispatch() -> Any:
    return SimpleNamespace(
        type="assistant",
        uuid="d1",
        session_id=EXTERNAL_SESSION_ID,
        message={
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": DISPATCH_TUID,
                    "name": "Agent",
                    "input": {
                        "description": "background probe",
                        "prompt": "wait",
                        "run_in_background": True,
                    },
                }
            ],
        },
    )


def _sdk_receipt() -> Any:
    return SimpleNamespace(
        type="user",
        uuid="d2",
        session_id=EXTERNAL_SESSION_ID,
        message={
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
    )


def _sdk_user(uuid: str, text: str) -> Any:
    return SimpleNamespace(
        type="user",
        uuid=uuid,
        session_id=EXTERNAL_SESSION_ID,
        message={"role": "user", "content": text},
    )


def _agent_input() -> dict[str, Any]:
    return {
        "description": "background probe",
        "prompt": "wait",
        "run_in_background": True,
    }


def _raw_dispatch_row() -> str:
    return json.dumps(
        {
            "type": "assistant",
            "uuid": "d1",
            "timestamp": T_DISPATCH,
            "cwd": PROJECT_DIRNAME,
            "sessionId": EXTERNAL_SESSION_ID,
            "isSidechain": False,
            "parentUuid": None,
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": DISPATCH_TUID,
                        "name": "Agent",
                        "input": _agent_input(),
                    }
                ],
            },
        }
    )


def _raw_receipt_row() -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": "d2",
            "timestamp": T_RECEIPT,
            "cwd": PROJECT_DIRNAME,
            "sessionId": EXTERNAL_SESSION_ID,
            "isSidechain": False,
            "parentUuid": "d1",
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


def _raw_notice_row() -> str:
    """The completion as the CLI persists it: a queue-operation, no uuid.

    This is the s7 shape. The SDK message view never surfaces it, so it never
    moves the stored cursor, and its own row carries no uuid to anchor on — the
    anchor it falls back to is the last uuid row before it, i.e. the receipt
    row the cursor already covered.
    """

    return json.dumps(
        {
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": T_NOTICE,
            "sessionId": EXTERNAL_SESSION_ID,
            "content": (
                "<task-notification>\n"
                f"<task-id>{TASK_ID}</task-id>\n"
                f"<tool-use-id>{DISPATCH_TUID}</tool-use-id>\n"
                "<status>completed</status>\n"
                "</task-notification>"
            ),
        }
    )


def _raw_user_row(uuid: str, text: str, timestamp: str) -> str:
    return json.dumps(
        {
            "type": "user",
            "uuid": uuid,
            "timestamp": timestamp,
            "cwd": PROJECT_DIRNAME,
            "sessionId": EXTERNAL_SESSION_ID,
            "isSidechain": False,
            "parentUuid": None,
            "message": {"role": "user", "content": text},
        }
    )


# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------


class _SyncHost(RuntimeHostClient):
    """Host double: cursor/kv state plus the published-item recording."""

    def __init__(self) -> None:
        self.sync_states: dict[str, dict[str, Any]] = {}
        self.timeline_item_upserts: list[RuntimeTimelineItem] = []
        self.timeline_syncs: list[RuntimeTimelineSnapshot] = []

    @property
    def connector_id(self) -> str:
        return "conn_test"

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.sync_states.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.sync_states[key] = value

    async def timeline_item_upsert(self, item: RuntimeTimelineItem) -> None:
        self.timeline_item_upserts.append(item)

    async def timeline_sync(self, *args: Any, **kwargs: Any) -> None:
        self.timeline_syncs.append(SimpleNamespace(**kwargs))


class _FakeSdk:
    """The SDK surface the syncer reads: message view + info fingerprint."""

    def __init__(self, messages: list[Any], raw_path: Path, cwd: Path) -> None:
        self.messages = messages
        self.raw_path = raw_path
        self.cwd = cwd

    def get_session_info(self, session_id: str) -> Any:
        stat = self.raw_path.stat()
        return SimpleNamespace(
            session_id=session_id,
            custom_title="z2 window notice",
            cwd=str(self.cwd),
            last_modified=int(stat.st_mtime * 1000),
            file_size=stat.st_size,
        )

    def get_session_messages(self, session_id: str) -> list[Any]:
        _ = session_id
        return list(self.messages)


def _config() -> RuntimeConfig:
    return RuntimeConfig(runtime="claude", revision=1, values={"environment": {}})


def _syncer(
    *,
    host: RuntimeHostClient,
    sdk: Any,
    session_store: Any,
    oracle: Any,
) -> ClaudeHistorySyncer:
    return ClaudeHistorySyncer(
        config=_config(),
        host=host,
        session_store=session_store,
        sdk_loader=lambda: sdk,
        cursor_store=ClaudeHistoryCursorStore(host),
        sync_states=ClaudeSessionSyncStateStore(host),
        pending_messages=ClaudePendingClientMessageRegistry("conn_test"),
        oracle=oracle,
    )


def _runtime_with(oracle: Any) -> tuple[_SyncHost, ClaudeRuntime]:
    host = _SyncHost()
    runtime = ClaudeRuntime(config=_config(), host=host, subagent_oracle=oracle)
    return host, runtime


def _published_card() -> RuntimeTimelineItem:
    content: dict[str, Any] = {
        "kind": "agent_call",
        "title": "background probe",
        "agents": {TASK_ID: {"status": "running"}},
    }
    return RuntimeTimelineItem(
        id="claude_tool_z2windownotice00000000",
        session_id=SESSION_ID,
        type="tool",
        status="running",
        order_seq=7,
        content_hash=timeline_content_hash(
            item_type="tool", status="running", role="tool", content=content
        ),
        role="tool",
        turn_id="turn_z2",
        content=content,
        source={
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemType": "tool_use",
            "event": "claude.agent.task",
        },
    )


def _agent_cards(snapshot: RuntimeTimelineSnapshot | None) -> list[Any]:
    if snapshot is None:
        return []
    return [
        item
        for item in snapshot.items
        if item.type == "tool"
        and isinstance(item.content, dict)
        and item.content.get("kind") == "agent_call"
    ]


def _layout(tmp_path: Path) -> tuple[Path, Path, Path]:
    """(config dir, project cwd, raw transcript path) under ``tmp_path``."""

    config = tmp_path / "cfg"
    project = tmp_path / PROJECT_DIRNAME
    project.mkdir(parents=True, exist_ok=True)
    raw = config / "projects" / claude_project_key(str(project)) / (
        f"{EXTERNAL_SESSION_ID}.jsonl"
    )
    raw.parent.mkdir(parents=True, exist_ok=True)
    return config, project, raw


def _write_rows(path: Path, rows: list[str]) -> None:
    path.write_text("".join(f"{row}\n" for row in rows), encoding="utf-8")
    now = time.time()
    os.utime(path, (now, now))


def _touch(path: Path) -> None:
    """Move the fingerprint without changing the rows (forces a sync pass)."""

    now = time.time() + 5
    os.utime(path, (now, now))


def _subagent_file(config: Path, project: Path, *, age_seconds: float) -> Path:
    """The engine's subagent transcript, last written ``age_seconds`` ago."""

    base = config / "projects" / claude_project_key(str(project))
    agent_dir = base / EXTERNAL_SESSION_ID / "subagents"
    agent_dir.mkdir(parents=True, exist_ok=True)
    agent = agent_dir / f"agent-{TASK_ID}.jsonl"
    agent.write_text(
        json.dumps(
            {
                "type": "assistant",
                "uuid": "agent-1",
                "timestamp": T_DISPATCH,
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "working"}],
                },
            }
        )
        + "\n",
        encoding="utf-8",
    )
    stamp = _NOW - age_seconds
    os.utime(agent, (stamp, stamp))
    return agent


def _history_oracle() -> ClaudeSubagentOracle:
    """Real probe, clock pinned to the fixture's ``_NOW``.

    The probe is the product's own (real filesystem); the clock is frozen so
    the oracle's "now" is the same instant every fixture timestamp and file
    mtime is anchored to. Left on the wall clock, a suite that reaches this
    test tens of seconds after import would judge the file and the notice
    against a drifting now — the exact coupling that made these cases pass in
    isolation and fail in the full run.
    """

    return ClaudeSubagentOracle(clock=lambda: _NOW)


# --------------------------------------------------------------------------
# Z2-T1 (D-A): history sync adopts the meta the store entry is missing
# --------------------------------------------------------------------------


def test_Z2_T1_history_sync_gives_the_store_session_the_meta_the_sweep_needs(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """Never-live session -> store cwd/external set -> sweep closes the card.

    Pre-fix no store session is ever created by the history sync (the store
    only ever learns of a session through ``record_timeline_item``'s bare
    ``ensure(session_id)``), so ``store.get(...)`` is ``None``, the raw
    transcript scan cannot resolve a path, and the sweep never iterates the
    session at all. The e2e's s6-rootcause probe printed exactly:
    ``cwd=None external=None`` / ``_read_raw_transcript_scan -> None``.
    """

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    monkeypatch.delenv("AA_SUBAGENT_AGE_BOUND_SECONDS", raising=False)
    _subagent_file(config, project, age_seconds=FILE_STALE_SECONDS)
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    # The production shape (e2e s6-rootcause step 1): the store entry exists
    # but bare — the live timeline-activity path created it through
    # ``record_timeline_item``'s ``ensure(session_id)``, which fills neither
    # cwd nor the external id. The history read is what knows both, and the
    # sweep iterates exactly this store set, so the read must enrich it.
    store.ensure(session_id=SESSION_ID)
    bare = store.get(SESSION_ID)
    assert bare is not None and bare.cwd is None
    assert bare.external_session_id is None

    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )

    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None and prepared.snapshot is not None

    stored = store.get(SESSION_ID, EXTERNAL_SESSION_ID)
    assert stored is not None, (
        "history sync published a session it never gave the store -- the "
        "evidence sweep iterates only the store's sessions"
    )
    assert stored.cwd, "store session has no cwd: the oracle probe cannot run"
    assert stored.external_session_id == EXTERNAL_SESSION_ID

    # The exact probe s6-rootcause.log showed returning None.
    scan = _read_raw_transcript_scan(stored)
    assert scan is not None
    assert scan.notices == ()

    # With the meta present the sweep can reach a stale card at all.
    card = _published_card()
    stored.timeline_items[card.id] = card
    runner = runtime._turns.runner
    published = asyncio.run(runner.sweep_agent_cards_by_evidence(stored))
    assert published == 1
    closed = host.timeline_item_upserts[-1]
    assert closed.status == "interrupted"
    assert closed.content["closedByEvidence"] == "agentFileStale"
    assert closed.content["agents"][TASK_ID]["status"] == "interrupted"


def test_Z2_G_a_history_read_never_outvotes_a_live_driven_cwd(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """A live transport authored the cwd first; the history read only fills."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    live = store.ensure(
        session_id=SESSION_ID,
        external_session_id=EXTERNAL_SESSION_ID,
        cwd="/live/authoritative",
    )
    assert live.cwd == "/live/authoritative"

    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )
    prepared = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert prepared is not None and prepared.snapshot is not None
    assert store.get(SESSION_ID).cwd == "/live/authoritative"


def test_Z2_G_repeating_the_same_history_sync_publishes_nothing(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """Idempotence: a second pass over an unchanged transcript is a no-op."""

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    _subagent_file(config, project, age_seconds=FILE_STALE_SECONDS)
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )

    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None and first.snapshot is not None
    assert first.commit is not None
    asyncio.run(first.commit())

    repeat = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert repeat is not None
    assert repeat.snapshot is None, "an unchanged transcript republished items"


# --------------------------------------------------------------------------
# Z2-T2 (D-B): a window-shaped terminal notice closes the open card
# --------------------------------------------------------------------------


def test_Z2_T2_a_notice_anchored_at_the_window_boundary_closes_the_card(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """The real sync path, the real s7 shape, red on ``9c775734``.

    Beat 1 publishes the running card and stores a cursor at the receipt row.
    Beat 2 appends only the raw ``queue-operation`` notice: the SDK view does
    not move, so the window the sync builds is empty and the notice's anchor is
    the row the cursor already covered. The card must still arrive closed in
    the second snapshot — the fold mints it from the full-chain lookup and the
    oracle stamps ``terminalNotice``.
    """

    config, project, raw = _layout(tmp_path)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config))
    monkeypatch.delenv("AA_SUBAGENT_AGE_BOUND_SECONDS", raising=False)
    # Fresh at beat 1 (the card must land running), stopped writing well before
    # the notice so rule 1 can attribute the completion to it at beat 2.
    _subagent_file(config, project, age_seconds=FILE_SILENT_BEFORE_NOTICE_SECONDS)
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row()])

    host, runtime = _runtime_with(_history_oracle())
    store = runtime._session_store
    sdk = _FakeSdk([_sdk_dispatch(), _sdk_receipt()], raw, project)
    syncer = _syncer(
        host=host, sdk=sdk, session_store=store, oracle=runtime.subagent_oracle
    )

    first = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert first is not None and first.snapshot is not None
    assert first.commit is not None
    asyncio.run(first.commit())
    running = _agent_cards(first.snapshot)
    assert len(running) == 1, "the first sync must publish the open card"
    assert running[0].status == "running"
    assert "closedByEvidence" not in running[0].content

    # The completion lands: raw only, SDK view untouched.
    _write_rows(raw, [_raw_dispatch_row(), _raw_receipt_row(), _raw_notice_row()])

    second = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert second is not None and second.snapshot is not None, (
        "the notice changed the transcript, so a sync must run"
    )
    cards = _agent_cards(second.snapshot)
    assert cards, (
        "the incremental rebuild published no agent card: the notice anchored "
        "at the window boundary never reached the fold (D-B)"
    )
    card = cards[0]
    assert card.status == "done"
    assert card.content["closedByEvidence"] == "terminalNotice"
    assert card.content["agents"][TASK_ID]["status"] == "completed"

    # Idempotence: replaying the same rows republishes one identical card.
    _touch(raw)
    third = asyncio.run(
        syncer.prepare_session_timeline_sync(SESSION_ID, EXTERNAL_SESSION_ID)
    )
    assert third is not None and third.snapshot is not None
    replay = _agent_cards(third.snapshot)
    assert len(replay) == 1
    assert replay[0].id == card.id
    assert replay[0].status == card.status
    assert dict(replay[0].content) == dict(card.content)


# --------------------------------------------------------------------------
# Guards for the gate itself: the new notice in, the older notice still out
# --------------------------------------------------------------------------


def _window_rows() -> tuple[str, ...]:
    return (
        _raw_dispatch_row(),
        _raw_receipt_row(),
        _raw_notice_row(),
        _raw_user_row("w1", "later message", T_LATER),
    )


def test_Z2_G_a_notice_newer_than_the_cursor_origin_is_admitted() -> None:
    """The s7 shape: the cursor sits on the receipt row the notice follows."""

    scan = scan_raw_transcript(_window_rows())
    assert len(scan.notices) == 1
    assert scan.notices[0].anchor == "d2"
    # The window starts after d2 — the row messages_after_cursor excludes.
    window = (_sdk_user("w1", "later message"),)
    placed = _raw_history_notices(window, scan, window_origin_uuid="d2")
    assert len(placed) == 1, "a notice written after the cursor was dropped"
    assert placed[0][1].status == "completed"
    # ...and it is placed BEFORE every window signal, so a resume inside the
    # window still outranks it (the round-2 regression this gate exists for).
    assert placed[0][0] == -1


def test_Z2_G_a_notice_older_than_the_cursor_origin_is_still_dropped() -> None:
    """Once the cursor has moved past it, the old notice never re-fires."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    # The cursor now sits on w1, which the notice precedes in the raw file.
    placed = _raw_history_notices(window, scan, window_origin_uuid="w1")
    assert placed == (), "an out-of-window notice older than the cursor re-fired"


def test_Z2_G_without_an_origin_the_old_window_gate_is_byte_identical() -> None:
    """No origin (rebase / first sync / full snapshot): today's gate, held."""

    scan = scan_raw_transcript(_window_rows())
    window = (_sdk_user("w1", "later message"),)
    assert _raw_history_notices(window, scan) == ()


def test_Z2_G_a_notice_whose_anchor_never_resolves_is_still_declined() -> None:
    """No uuid on the row and none before it: not locatable, so not folded."""

    scan = scan_raw_transcript((_raw_notice_row(),))
    assert len(scan.notices) == 1
    assert scan.notices[0].anchor is None
    window = (_sdk_user("w1", "later message"),)
    assert _raw_history_notices(window, scan, window_origin_uuid="d1") == ()
