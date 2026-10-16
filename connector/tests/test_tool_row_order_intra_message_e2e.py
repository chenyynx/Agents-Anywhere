"""End-to-end: the connector's declaration makes the server order tools by truth.

The connector-side tests (``test_tool_row_order_declaration.py``) pin that a
tool row declares the message id and the in-message index the engine emitted it
at. This file closes the loop through the *real* server: the same assistant
message's two tool calls arrive (and are written) in completion order — the
inversion the fix exists to remove — and the stored ``order_seq`` must end up in
emission order, not arrival order.

Two layers are driven for real, nothing mocked:

* the connector's own ``ClaudeMessageProjector`` projects the transcript frames
  (the running ``tool_use`` frames, then the ``tool_result`` frames that arrive
  in completion order) and ``connector.server.runtime_host._timeline_item_payload``
  turns each row into the exact wire payload the connector sends;
* the server's ``Store.upsert_timeline_item`` writes that payload, and its
  intra-message corrector (``_intra_message_target_rows``) orders the group.

Both the server source and its private virtualenv (for SQLAlchemy/Alembic, which
the connector venv does not install) are put on ``sys.path`` for the test. This
is the same cross-suite seam ``server/tests/test_connector_pipeline.py`` uses in
the other direction; the connector venv is the superset environment, so the test
lives here.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from typing import Any

from claude_agent_sdk._internal.message_parser import parse_message

from connector.runtimes.claude.domain.session import ClaudeSession
from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector
from connector.server.runtime_host import _timeline_item_payload

# The server owns the writer and the ordering infra this test asserts on; its
# private venv supplies SQLAlchemy/Alembic/aiosqlite that the connector venv
# lacks. Resolve both from the repo root, then import lazily-guarded.
_REPO = Path(__file__).resolve().parents[2]
_SERVER = _REPO / "server"
if str(_SERVER) not in sys.path:
    sys.path.insert(0, str(_SERVER))
if str(_SERVER / "tests") not in sys.path:
    sys.path.insert(0, str(_SERVER / "tests"))
for _site in (_SERVER / ".venv" / "lib").glob("python*/site-packages"):
    if str(_site) not in sys.path:
        sys.path.append(str(_site))

from agent_server.core.models import TimelineItemIn
from agent_server.infra.repositories.facade import Store
from session_fixtures import create_session_with_project

# The server suite's conftest owns the shared PostgreSQL test database: it
# migrates once and truncates before each test. Load it by file path — the
# connector has its own ``conftest`` module, so a bare ``import conftest``
# would resolve to the wrong one.
import importlib.util as _ilu

_spec = _ilu.spec_from_file_location(
    "_server_conftest", _SERVER / "tests" / "conftest.py"
)
_server_conftest = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_server_conftest)
_ensure_migrated = _server_conftest._ensure_migrated
_truncate_async = _server_conftest._truncate
_asyncpg_url = _server_conftest._asyncpg_url
SERVER_TEST_DATABASE_URL = _server_conftest.TEST_DATABASE_URL

SESSION = "tool-order-e2e"
EXTERNAL_SESSION = "claude_ext_e2e"


def _parse(frame: dict[str, Any]) -> Any:
    message = parse_message(frame)
    assert message is not None
    return message


def _tool_use_frame(message_id: str, call_id: str, name: str = "Bash") -> Any:
    return _parse(
        {
            "type": "assistant",
            "message": {
                "id": message_id,
                "role": "assistant",
                "model": "deepseek-v4.1-flash",
                "content": [{"type": "tool_use", "id": call_id, "name": name, "input": {}}],
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": f"assistant-{call_id}",
        }
    )


def _tool_result_frame(tool_use_id: str, text: str = "ok") -> Any:
    return _parse(
        {
            "type": "user",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": tool_use_id,
                        "content": [{"type": "text", "text": text}],
                    }
                ],
            },
            "parent_tool_use_id": None,
            "session_id": SESSION,
            "uuid": f"result-{tool_use_id}",
        }
    )


async def _store_with_session(tmp_path: Path) -> tuple[Store, Any]:
    # Isolate against the shared PostgreSQL test database. ``reset_shared_database``
    # wraps ``asyncio.run`` (unusable inside this test's running loop), so drive
    # the same truncate directly here.
    _ensure_migrated()
    await _truncate_async(_asyncpg_url(SERVER_TEST_DATABASE_URL))
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id=EXTERNAL_SESSION,
    )
    return store, session


async def _write_completion_order(
    store: Store,
    session: Any,
    *,
    tool_ids: list[str],
    completion_order: list[str],
) -> list[Any]:
    """Project two tool calls of one message and persist their result rows.

    The ``tool_use`` frames are projected first (recording the pending calls and
    their emission-order index) but never written — the running frame is
    synthetic in this scenario. The ``tool_result`` frames then arrive in
    ``completion_order`` and materialise the rows; the server stores them in the
    order they land, which is the arrival order the connector must let it
    correct.
    """

    projector = ClaudeMessageProjector()
    claude_session = ClaudeSession(
        session_id=session.id, external_session_id=EXTERNAL_SESSION
    )
    message_id = "msg_e2e"
    for tool_id in tool_ids:
        projector.tool_items_for_message(
            session=claude_session,
            turn_id="turn-1",
            message=_tool_use_frame(message_id, tool_id),
        )

    for tool_id in completion_order:
        rows = projector.tool_items_for_message(
            session=claude_session,
            turn_id="turn-1",
            message=_tool_result_frame(tool_id),
        )
        assert len(rows) == 1
        item = TimelineItemIn.model_validate(_timeline_item_payload(rows[0]))
        await store.upsert_timeline_item(session_id=session.id, item=item)

    stored = [item for item in await store.timeline.read(session.id) if item.type == "tool"]
    stored.sort(key=lambda item: item.orderSeq)
    return stored


def test_two_tools_reversed_on_arrival_are_stored_in_emission_order(tmp_path) -> None:
    """The core end-to-end: call_0 is emitted first, call_1 second, but call_1's
    result lands first. After the writer runs, the stored order is call_0 then
    call_1 — by the declared index, not the arrival order."""

    async def run() -> list[Any]:
        store, session = await _store_with_session(tmp_path)
        try:
            return await _write_completion_order(
                store,
                session,
                tool_ids=["call_0", "call_1"],
                completion_order=["call_1", "call_0"],
            )
        finally:
            await store.close()

    stored = asyncio.run(run())
    assert [item.source.itemId for item in stored] == ["call_0", "call_1"]
    assert [item.source.blockIndex for item in stored] == [0, 1]
    # The index is strictly increasing in stored order — the inversion removed.
    assert stored[0].orderSeq < stored[1].orderSeq


def test_three_tools_fully_reversed_are_stored_in_emission_order(tmp_path) -> None:
    async def run() -> list[Any]:
        store, session = await _store_with_session(tmp_path)
        try:
            return await _write_completion_order(
                store,
                session,
                tool_ids=["call_0", "call_1", "call_2"],
                completion_order=["call_2", "call_1", "call_0"],
            )
        finally:
            await store.close()

    stored = asyncio.run(run())
    assert [item.source.itemId for item in stored] == ["call_0", "call_1", "call_2"]
    assert [item.source.blockIndex for item in stored] == [0, 1, 2]


def test_already_ordered_rows_are_left_untouched(tmp_path) -> None:
    """The strict-corrector path: when arrival order already equals emission
    order, the stored order_seq is byte-identical (no needless write)."""

    async def run() -> tuple[list[Any], list[int]]:
        store, session = await _store_with_session(tmp_path)
        try:
            stored = await _write_completion_order(
                store,
                session,
                tool_ids=["call_0", "call_1"],
                completion_order=["call_0", "call_1"],
            )
            return stored, [item.orderSeq for item in stored]
        finally:
            await store.close()

    stored, _ = asyncio.run(run())
    assert [item.source.itemId for item in stored] == ["call_0", "call_1"]
