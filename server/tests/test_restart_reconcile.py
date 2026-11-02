"""Restart reconciliation: a reconnect proves a dead turn, then heals it.

The sweep must only write when the connector itself answers that nothing is
running for the session and the server holds no active run. These tests pin
that evidence gate, the exact write shape (status/interrupted + evidence +
hash + revision), idempotence, boundedness, kill switch, and the untouched
neighbour rows.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import update

from agent_server.core.models import TimelineItemIn
from agent_server.core.timeline import timeline_item_content_hash
from agent_server.infra.connector_rpc import ConnectorRpcError
from agent_server.infra.db import sessions as sessions_t
from agent_server.infra.repositories.facade import Store
from agent_server.services.restart_reconcile import (
    CLOSED_BY_EVIDENCE,
    ENV_ENABLED,
    RestartReconcileService,
)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def item_row(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    status: str = "running",
    item_type: str = "tool",
    role: str = "tool",
    content: dict[str, Any] | None = None,
) -> TimelineItemIn:
    stamp = _now_iso()
    return TimelineItemIn.model_validate(
        {
            "id": item_id,
            "sessionId": session_id,
            "type": item_type,
            "status": status,
            "role": role,
            "content": content
            if content is not None
            else {"kind": "bash", "toolName": "Bash"},
            "source": {
                "runtime": "claude",
                "sessionId": "claude_ext_main",
                "itemId": item_id,
                "itemType": "toolUse",
            },
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
            "createdAt": stamp,
            "updatedAt": stamp,
        }
    )


class FakeConnectorRpc:
    """One response per session; a raised exception models an RPC failure."""

    missing = object()

    def __init__(self, responses: dict[str, Any]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, str, dict[str, Any], float]] = []

    async def request(
        self,
        connector_id: str,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float = 30,
    ) -> Any:
        self.calls.append((connector_id, method, dict(params), timeout))
        response = self.responses.get(params["sessionId"], self.missing)
        if response is self.missing:
            raise AssertionError(f"unexpected probe for {params['sessionId']!r}")
        if isinstance(response, BaseException):
            raise response
        return response


def state_response(
    session_id: str,
    status: str,
    *,
    runtime: str = "claude",
    runtime_id: str = "claude",
    external_session_id: str = "claude_ext_main",
) -> dict[str, Any]:
    return {
        "state": {
            "sessionId": session_id,
            "runtime": runtime,
            "runtimeId": runtime_id,
            "externalSessionId": external_session_id,
            "status": status,
        }
    }


async def _store_and_running_session(
    *,
    tag: str = "main",
) -> tuple[Store, Any, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name=f"dev-{tag}", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_main",
        project_name=f"P-{tag}",
    )
    await store.set_session_status(session.id, "running")
    return store, connector, session


async def _items(store: Store, session_id: str) -> dict[str, Any]:
    return {item.id: item for item in await store.timeline.read(session_id)}


@pytest.mark.anyio
async def test_idle_connector_closes_the_row_and_settles_the_session(tmp_path) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                item_row("tool_running", session_id=session.id, order_seq=1),
                item_row(
                    "tool_done",
                    session_id=session.id,
                    order_seq=2,
                    status="done",
                ),
                item_row(
                    "message",
                    session_id=session.id,
                    order_seq=3,
                    item_type="message",
                    role="assistant",
                    content={"text": "hello"},
                ),
            ],
        )
        session_before = await store.get_session(session.id)
        count_before = len(await store.timeline.read(session.id))
        message_before = (await _items(store, session.id))["message"]
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )
        service = RestartReconcileService(store, rpc)

        summary = await service.reconcile_connector(connector.id)

        assert summary.sessions == 1
        assert summary.sessions_changed == 1
        assert summary.tool_items_closed == 1
        # The probe carries the full runtime binding, not just the session id.
        (connector_id, method, params, timeout) = rpc.calls[0]
        assert connector_id == connector.id
        assert method == "session.state"
        assert params == {
            "sessionId": session.id,
            "runtime": "claude",
            "runtimeId": "claude",
            "externalSessionId": "claude_ext_main",
        }
        assert timeout == 10

        items = await _items(store, session.id)
        tool = items["tool_running"]
        assert tool.status == "interrupted"
        assert tool.content["closedByEvidence"] == CLOSED_BY_EVIDENCE
        assert tool.content["kind"] == "bash"
        assert tool.contentHash == timeline_item_content_hash(
            item_type="tool",
            status="interrupted",
            role="tool",
            content=tool.content,
        )
        assert tool.revision == 2
        assert tool.updatedSeq > session_before.updatedSeq
        assert items["tool_done"].status == "done"
        assert "closedByEvidence" not in items["tool_done"].content

        session_after = await store.get_session(session.id)
        assert session_after.status == "idle"
        assert session_after.updatedSeq > session_before.updatedSeq

        # Hard acceptance: nothing was added or removed, and message rows are
        # byte-for-byte the same.
        assert len(await store.timeline.read(session.id)) == count_before
        assert items["message"].content == message_before.content
        assert items["message"].contentHash == message_before.contentHash
        assert items["message"].status == message_before.status
    finally:
        await store.close()


@pytest.mark.anyio
async def test_missing_state_also_counts_as_not_running(tmp_path) -> None:
    """After a connector restart the Runtime may have no state at all."""

    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        rpc = FakeConnectorRpc({session.id: {"state": None}})

        summary = await RestartReconcileService(store, rpc).reconcile_connector(
            connector.id
        )

        assert summary.tool_items_closed == 1
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "interrupted"
        assert (await store.get_session(session.id)).status == "idle"
    finally:
        await store.close()


@pytest.mark.anyio
@pytest.mark.parametrize(
    "connector_state",
    ["waiting", "pending", "running", "stopping", "waiting_approval", "error", "blocked"],
)
async def test_any_live_state_writes_nothing(tmp_path, connector_state: str) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        seq_before = await store.get_session_seq(session.id)
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, connector_state)}
        )

        summary = await RestartReconcileService(store, rpc).reconcile_connector(
            connector.id
        )

        assert summary.tool_items_closed == 0
        assert summary.sessions_changed == 0
        assert await store.get_session_seq(session.id) == seq_before
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "running"
        assert "closedByEvidence" not in item.content
        assert (await store.get_session(session.id)).status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
@pytest.mark.parametrize(
    "failure",
    [
        TimeoutError("session.state timed out"),
        ConnectorRpcError("runtime_not_running", "runtime is not running"),
    ],
)
async def test_probe_failure_writes_nothing(tmp_path, failure: BaseException) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        seq_before = await store.get_session_seq(session.id)
        rpc = FakeConnectorRpc({session.id: failure})

        summary = await RestartReconcileService(store, rpc).reconcile_connector(
            connector.id
        )

        assert summary.tool_items_closed == 0
        assert await store.get_session_seq(session.id) == seq_before
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "running"
        assert (await store.get_session(session.id)).status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_active_run_blocks_the_write(tmp_path) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        await store.start_active_run(
            session_id=session.id,
            runtime="claude",
            external_session_id="claude_ext_main",
        )
        seq_before = await store.get_session_seq(session.id)
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )

        summary = await RestartReconcileService(store, rpc).reconcile_connector(
            connector.id
        )

        assert summary.tool_items_closed == 0
        assert await store.get_session_seq(session.id) == seq_before
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "running"
        assert (await store.get_session(session.id)).status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_second_run_is_idempotent(tmp_path) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )
        service = RestartReconcileService(store, rpc)

        assert (await service.reconcile_connector(connector.id)).tool_items_closed == 1
        seq_after_first = await store.get_session_seq(session.id)

        second = await service.reconcile_connector(connector.id)

        assert second.sessions == 0
        assert second.tool_items_closed == 0
        assert len(rpc.calls) == 1
        assert await store.get_session_seq(session.id) == seq_after_first
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.revision == 2

        # The repository write itself is idempotent even if called directly.
        third = await store.close_running_tool_items(
            session_id=session.id,
            closed_by_evidence=CLOSED_BY_EVIDENCE,
        )
        assert list(third.items) == []
        assert third.changed is False
        assert await store.get_session_seq(session.id) == seq_after_first
    finally:
        await store.close()


@pytest.mark.anyio
async def test_non_tool_running_rows_are_untouched(tmp_path) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[
                item_row("tool_running", session_id=session.id, order_seq=1),
                item_row(
                    "message_running",
                    session_id=session.id,
                    order_seq=2,
                    item_type="message",
                    role="assistant",
                    content={"text": "streaming"},
                ),
                item_row(
                    "system_running",
                    session_id=session.id,
                    order_seq=3,
                    item_type="system",
                    role="system",
                    content={"text": "thinking"},
                ),
            ],
        )
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )

        await RestartReconcileService(store, rpc).reconcile_connector(connector.id)

        items = await _items(store, session.id)
        assert items["tool_running"].status == "interrupted"
        assert items["message_running"].status == "running"
        assert items["system_running"].status == "running"
        assert "closedByEvidence" not in items["message_running"].content
        assert "closedByEvidence" not in items["system_running"].content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_error_status_keeps_its_diagnosis_but_its_rows_are_closed(
    tmp_path,
) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.set_session_status(session.id, "error")
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )

        await RestartReconcileService(store, rpc).reconcile_connector(connector.id)

        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "interrupted"
        assert (await store.get_session(session.id)).status == "error"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_sweep_is_bounded_and_newest_first(tmp_path) -> None:
    store, connector, newest = await _store_and_running_session(tag="newest")
    try:
        oldest = await create_session_with_project(
            store,
            connector_id=connector.id,
            runtime="claude",
            external_session_id="claude_ext_old",
            project_name="P-oldest",
        )
        await store.set_session_status(oldest.id, "running")
        await store.sync_timeline_items(
            session_id=newest.id,
            items=[item_row("tool_new", session_id=newest.id, order_seq=1)],
        )
        await store.sync_timeline_items(
            session_id=oldest.id,
            items=[item_row("tool_old", session_id=oldest.id, order_seq=1)],
        )
        async with store.engine.begin() as conn:
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == oldest.id)
                .values(updated_at="2020-01-01T00:00:00Z")
            )
            await conn.execute(
                update(sessions_t)
                .where(sessions_t.c.id == newest.id)
                .values(updated_at="2026-01-01T00:00:00Z")
            )
        rpc = FakeConnectorRpc(
            {
                newest.id: state_response(newest.id, "idle"),
                oldest.id: state_response(oldest.id, "idle"),
            }
        )
        service = RestartReconcileService(store, rpc, max_sessions=1)

        summary = await service.reconcile_connector(connector.id)

        assert summary.sessions == 1
        assert [call[2]["sessionId"] for call in rpc.calls] == [newest.id]
        (new_item,) = await store.timeline.read_many(newest.id, {"tool_new"})
        assert new_item.status == "interrupted"
        (old_item,) = await store.timeline.read_many(oldest.id, {"tool_old"})
        assert old_item.status == "running"
        assert (await store.get_session(oldest.id)).status == "running"
    finally:
        await store.close()


@pytest.mark.anyio
async def test_kill_switch_disables_the_sweep(tmp_path) -> None:
    store, connector, session = await _store_and_running_session()
    try:
        await store.sync_timeline_items(
            session_id=session.id,
            items=[item_row("tool_running", session_id=session.id, order_seq=1)],
        )
        seq_before = await store.get_session_seq(session.id)
        rpc = FakeConnectorRpc(
            {session.id: state_response(session.id, "idle")}
        )

        summary = await RestartReconcileService(
            store, rpc, enabled=False
        ).reconcile_connector(connector.id)

        assert summary.sessions == 0
        assert rpc.calls == []
        assert await store.get_session_seq(session.id) == seq_before
        (item,) = await store.timeline.read_many(session.id, {"tool_running"})
        assert item.status == "running"
    finally:
        await store.close()


def test_from_environment_default_and_malformed(monkeypatch) -> None:
    monkeypatch.delenv(ENV_ENABLED, raising=False)
    assert RestartReconcileService.from_environment(object(), object()).enabled is True

    monkeypatch.setenv(ENV_ENABLED, "0")
    assert RestartReconcileService.from_environment(object(), object()).enabled is False

    monkeypatch.setenv(ENV_ENABLED, "not-a-flag")
    assert RestartReconcileService.from_environment(object(), object()).enabled is False
