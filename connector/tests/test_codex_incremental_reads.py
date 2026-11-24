"""Exercise native SQLite guards, RPC paging and durable Connector checkpoints."""
import asyncio
import copy
import hashlib
import json
import os
import sqlite3
from dataclasses import asdict
from unittest.mock import AsyncMock

import pytest
from test_codex_runtime import FakeCodexClient, _config

from connector.runtimes.codex.runtime import CodexRuntime
from connector.runtimes.codex.sdk.runtime_client import CodexThreadTurnsPage
from connector.runtimes.codex.sessions import history_index as codex_history_index
from connector.runtimes.codex.sessions.history_index import read_history_index
from connector.server.runtime_host import ConnectorRuntimeHost
from connector.server.sync_state import JsonSyncStateStore


class NativeHistory(FakeCodexClient):
    def __init__(self, root, count=240):
        super().__init__()
        self.path = root / "sessions/2026/09/17/thread.jsonl"
        self.path.parent.mkdir(parents=True)
        self.path.write_text(json.dumps({"type": "session_meta", "payload": {
            "id": "thread_1", "history_mode": "paginated"}}) + "\n")
        self.db_path = root / "thread_history_1.sqlite"
        with sqlite3.connect(self.db_path) as db:
            db.executescript("""
                CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_byte_offset INTEGER);
                CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
                    error_json TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER);
                CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
                    updated_at_ordinal INTEGER, created_at_ms INTEGER, item_type TEXT);
            """)
        self.turns = [self.turn(n) for n in range(count)]
        self.revisions = {}
        self.pages = []
        self.on_page = None
        self.persist()

    @staticmethod
    def turn(n):
        return {"id": f"turn_{n}", "status": "completed", "items": [
            {"id": f"item_{n}", "type": "agentMessage", "text": f"answer {n}"}]}

    def persist(self):
        with self.path.open("a") as stream:
            stream.write(json.dumps({"type": "event_msg", "payload": {"type": "test_projection_update"}}) + "\n")
        with sqlite3.connect(self.db_path) as db:
            db.execute("DELETE FROM thread_turns")
            db.execute("DELETE FROM thread_items")
            db.execute("DELETE FROM thread_history_projection_state")
            db.execute("INSERT INTO thread_history_projection_state VALUES (?, ?)", ("thread_1", self.path.stat().st_size))
            for n, turn in enumerate(self.turns):
                db.execute("INSERT INTO thread_turns VALUES (?, ?, ?, ?, NULL, 1, 2, 1000)", ("thread_1", turn["id"], n * 100, turn["status"]))
                for pos, item in enumerate(turn["items"]):
                    db.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?, ?)", (
                        "thread_1", turn["id"], item["id"], n * 100 + pos + 1,
                        self.revisions.get(item["id"], n * 100 + pos + 1), 1, item["type"]))
        self.ref = {"id": "thread_1", "path": str(self.path), "updatedAt": 1, "historyMode": "paginated"}
        self.results["thread/list"] = {"threads": [self.ref]}
        self.results["thread/read"] = {"thread": {**self.ref, "turns": self.turns}}

    async def list_thread_turns_page(self, thread_id, cursor=None, limit=20):
        self.pages.append(cursor)
        start = int(cursor or 0)
        turns = copy.deepcopy(list(reversed(self.turns))[start:start + limit])
        if self.on_page:
            callback, self.on_page = self.on_page, None
            callback()
        return CodexThreadTurnsPage(tuple(turns), str(start + limit) if start + limit < len(self.turns) else None)


def boot(path, client):
    store = JsonSyncStateStore(path)
    host = ConnectorRuntimeHost("conn_test", AsyncMock(), AsyncMock(), store)
    return CodexRuntime(config=_config(), host=host, client=client), host, store


async def prepare(runtime, base_turn_id=None):
    session = (await runtime.list_sessions())[0]
    return await runtime.prepare_session_timeline_sync(
        session.session_id,
        "thread_1",
        base_turn_id=base_turn_id,
    )


def test_restart_reads_zero_history_and_append_reads_one_page_with_retry(tmp_path):
    async def run():
        client = NativeHistory(tmp_path / "native")
        runtime, _host, store = boot(tmp_path / "checkpoint.json", client)
        initial = await prepare(runtime)
        assert len(initial.snapshot.items) == 240
        assert len(client.pages) == 12
        await initial.commit()
        store.flush()
        runtime, _host, store = boot(tmp_path / "checkpoint.json", client)
        client.pages.clear()
        unchanged = await prepare(runtime)
        assert unchanged.snapshot is None
        assert client.pages == []
        assert not any(method == "thread/read" for method, _ in client.requests)
        client.turns.append(client.turn(240))
        client.persist()
        added = await prepare(runtime)
        assert len(client.pages) == 1
        assert len(added.snapshot.items) == 1
        assert added.snapshot.items[0].order_seq == 240
        assert added.snapshot.complete is False
        # No ingestion ACK: the durable checkpoint must still describe the old history.
        retry = await prepare(runtime)
        assert retry.snapshot.items == added.snapshot.items
        await retry.commit()
        store.flush()
        runtime, _host, _ = boot(tmp_path / "checkpoint.json", client)
        client.pages.clear()
        assert (await prepare(runtime)).snapshot is None
        assert client.pages == []
    asyncio.run(run())


def test_owned_native_in_progress_turn_is_exposed_as_running_when_index_lags(
    tmp_path,
    monkeypatch,
):
    async def run():
        client = NativeHistory(tmp_path / "native", count=2)
        client.turns[-1]["status"] = "inProgress"
        client.persist()
        with client.path.open("a") as stream:
            stream.write("{}\n")
        os.utime(client.path, (1, 1))
        monkeypatch.setattr(
            codex_history_index,
            "_source_is_open_by_codex",
            lambda _source: True,
        )
        assert read_history_index(client.ref) is None

        runtime, _, _ = boot(tmp_path / "checkpoint.json", client)
        session = (await runtime.list_sessions())[0]
        state = await runtime.get_session_state(
            session.session_id,
            external_session_id="thread_1",
        )

        assert state is not None
        assert state.status == "running"
        assert state.metadata["source"] == "codex.thread_history.state"
        assert state.metadata["turn_id"] == "turn_1"
        assert state.metadata["native_activity_evidence"] == "owner"

    asyncio.run(run())


def test_stale_unowned_native_in_progress_turn_is_exposed_as_idle(tmp_path):
    async def run():
        client = NativeHistory(tmp_path / "native", count=2)
        client.turns[-1]["status"] = "inProgress"
        client.persist()
        os.utime(client.path, (1, 1))

        runtime, _, _ = boot(tmp_path / "checkpoint.json", client)
        session = (await runtime.list_sessions())[0]
        state = await runtime.get_session_state(
            session.session_id,
            external_session_id="thread_1",
        )

        assert state is not None
        assert state.status == "idle"
        assert state.metadata["source"] == "codex.thread_history.state"
        assert state.metadata["turn_id"] == "turn_1"
        assert state.metadata["native_status"] == "inProgress"

    asyncio.run(run())


def test_prepare_publishes_the_last_completed_turn_id(tmp_path):
    """The settle sync's lastTurnId is the newest terminal turn, not a running one.

    It must use the native index (not the projected delta window): an
    incremental pass can cover an older turn while a newer turn is running.
    """

    async def run():
        client = NativeHistory(tmp_path / "native", count=5)
        runtime, host, _store = boot(tmp_path / "checkpoint.json", client)
        prepared = await prepare(runtime, base_turn_id="turn_4")
        assert prepared.snapshot.metadata["lastTurnId"] == "turn_4"
        assert prepared.snapshot.metadata["baseTurnId"] == "turn_4"
        # The first sync of a process is a full-chain read; the server may
        # replace a stored live id (including an IPC synthetic one).
        assert prepared.snapshot.metadata["rebased"] is True
        await prepared.commit()
        checkpoint = await host.sync_state_read("codex/timeline-sync/thread_1")
        assert checkpoint["version"] == 2

        # A stored version-1 checkpoint is a projection from before the turn
        # id existed; it must rebuild rather than be reused.
        checkpoint["version"] = 1
        await host.sync_state_write("codex/timeline-sync/thread_1", checkpoint)
        rebuilt = await prepare(runtime)
        assert rebuilt.snapshot is not None
        assert rebuilt.snapshot.metadata["lastTurnId"] == "turn_4"

        # The newest turn is still running. A scanner pass with no base must
        # not publish the previous turn: if the index is only lagging (the turn
        # actually ended), that id would replace the Server's newer live id.
        # A settle whose base is the last completed turn may still publish it.
        client.turns[-1]["status"] = "inProgress"
        client.persist()
        runtime, _host, _store = boot(tmp_path / "checkpoint-running.json", client)
        running = await prepare(runtime)
        assert "lastTurnId" not in running.snapshot.metadata
        settled_previous = await prepare(runtime, base_turn_id="turn_3")
        assert settled_previous.snapshot.metadata["lastTurnId"] == "turn_3"
        settled_running = await prepare(runtime, base_turn_id="turn_4")
        assert "lastTurnId" not in settled_running.snapshot.metadata

    asyncio.run(run())


def test_settle_ignores_a_stale_in_progress_turn_before_the_newest(tmp_path):
    """A stale inProgress row in the middle must not make `settled` lie.

    Codex can leave one behind when a desktop-owned task is unloaded. The old
    `ids[-2]` rule then published that stale turn with the just-ended live id
    as its base, and the Server accepted the regression.
    """

    async def run():
        client = NativeHistory(tmp_path / "native", count=5)
        runtime, host, store = boot(tmp_path / "checkpoint.json", client)
        first = await prepare(runtime)
        await first.commit()
        store.flush()

        client.turns.append(
            {
                "id": "turn_5_stale",
                "status": "inProgress",
                "items": [{"id": "item_5s", "type": "agentMessage", "text": "stale"}],
            }
        )
        client.turns.append(
            {
                "id": "turn_6",
                "status": "completed",
                "items": [{"id": "item_6", "type": "agentMessage", "text": "done"}],
            }
        )
        client.persist()

        prepared = await prepare(runtime, base_turn_id="turn_6")
        assert prepared.snapshot.metadata["lastTurnId"] == "turn_6"
        assert prepared.snapshot.metadata["baseTurnId"] == "turn_6"

        # A settle for the stale row itself publishes nothing: the index has
        # not caught up on that turn.
        stale = await prepare(runtime, base_turn_id="turn_5_stale")
        assert "lastTurnId" not in stale.snapshot.metadata

    asyncio.run(run())


@pytest.mark.parametrize("mutation", ["old_edit", "old_tool_edit", "delete_turn", "delete_item", "reorder", "unfinished", "invalid_checkpoint"])
def test_incremental_checkpoint_matches_full_projection_after_mutation(tmp_path, mutation):
    async def run():
        client = NativeHistory(tmp_path / "native", count=65)
        if mutation in {"old_tool_edit", "delete_item"}:
            client.turns[5]["items"].append({"id": "tool", "type": "commandExecution", "command": "echo hi", "status": "completed", "aggregatedOutput": "hi"})
        if mutation == "unfinished":
            client.turns[-1]["status"] = "inProgress"
        client.persist()
        runtime, host, store = boot(tmp_path / "checkpoint.json", client)
        initial = await prepare(runtime)
        await initial.commit()
        store.flush()
        runtime, host, _ = boot(tmp_path / "checkpoint.json", client)
        client.pages.clear()
        if mutation == "old_edit":
            client.turns[5]["items"][0]["text"] = "edited old response"
            client.revisions["item_5"] = 99999
        elif mutation == "old_tool_edit":
            client.turns[5]["items"][-1]["aggregatedOutput"] = "changed old tool output"
            client.revisions["tool"] = 99999
        elif mutation == "delete_turn":
            client.turns.pop(5)
        elif mutation == "delete_item":
            client.turns[5]["items"].pop()
        elif mutation == "reorder":
            client.turns[3], client.turns[4] = client.turns[4], client.turns[3]
        elif mutation == "unfinished":
            client.turns[-1]["items"][0]["text"] = "finished"
            client.turns[-1]["status"] = "completed"
            client.revisions["item_64"] = 99999
        else:
            checkpoint = await host.sync_state_read("codex/timeline-sync/thread_1")
            checkpoint["readState"]["counts"] = {}
            await host.sync_state_write("codex/timeline-sync/thread_1", checkpoint)
        client.persist()
        delta = await prepare(runtime)
        if mutation.startswith("delete"):
            assert delta.snapshot.complete is True
        await delta.commit()
        session = (await runtime.list_sessions())[0]
        full = await runtime.get_session_snapshot(session.session_id, "thread_1")
        expected = {item.id: hashlib.sha256(json.dumps(asdict(item), sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
                    for item in full.items if item.type not in {"turn.start", "turn.end"}}
        assert (await host.sync_state_read("codex/timeline-sync/thread_1"))["items"] == expected
        if mutation in {"old_edit", "old_tool_edit"}:
            assert len(client.pages) > 1, "a tail-only heuristic missed an older mutation"
    asyncio.run(run())


@pytest.mark.parametrize("problem", ["schema", "lag", "fork", "missing_file"])
def test_unknown_or_stale_native_index_falls_back_to_full_rpc(tmp_path, problem):
    async def run():
        client = NativeHistory(tmp_path / "native", count=5)
        if problem == "schema":
            with sqlite3.connect(client.db_path) as db:
                db.execute("DROP TABLE thread_items")
        elif problem == "lag":
            with client.path.open("a") as stream:
                stream.write("{}\n")
        elif problem == "fork":
            client.path.write_text(json.dumps({"type": "session_meta", "payload": {
                "id": "thread_1", "history_mode": "paginated", "history_base": {"source_thread_id": "parent"}}}) + "\n")
            client.persist()
        else:
            client.path.unlink()
        assert read_history_index(client.ref) is None
        runtime, _, _ = boot(tmp_path / "checkpoint.json", client)
        result = await prepare(runtime)
        assert len(result.snapshot.items) == 5
        assert client.pages == []
        assert any(method == "thread/read" for method, _ in client.requests)
    asyncio.run(run())


def test_history_changing_between_pages_does_not_commit_checkpoint(tmp_path):
    async def run():
        client = NativeHistory(tmp_path / "native")
        runtime, host, _ = boot(tmp_path / "checkpoint.json", client)
        client.on_page = lambda: client.persist()
        with pytest.raises(RuntimeError, match="changed while reading"):
            await prepare(runtime)
        assert await host.sync_state_read("codex/timeline-sync/thread_1") is None
        result = await prepare(runtime)
        assert len(result.snapshot.items) == 240
    asyncio.run(run())
