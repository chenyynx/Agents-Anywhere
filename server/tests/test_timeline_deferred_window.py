"""Deferred-activity window (``deferActivity`` + ``excludeAgentChildren``).

A session's newest timeline rows can be all tool/reasoning activity, each tool
row carrying megabytes of output the client only needs collapsed. The opt-in
deferred window spends its ``limit`` on *display* rows (messages, artifacts,
Agent cards, approvals, file changes), rides the activity rows between them
along, and serves a large main tool row from the writer's stored stub
(``stub_json``) instead of its full payload. A single-row endpoint returns the
complete payload behind a summary.

These tests pin that surface:

- the SQL and Python row predicates agree on every row shape;
- anchor selection ignores child rows and tolerates fewer display rows than
  ``limit``; a session with no display row reports ``applied=False``;
- the window excludes child rows, summarises only large main tool activity
  rows whose stub version is current, and keeps the newest activity segment,
  display-kind tools, approvals and reasoning rows complete;
- ``has_more`` uses the composite ``(order_seq, updated_seq, id)`` boundary;
- both endpoints default to the old byte-for-byte behavior, only the
  ``latest``/``history`` modes with both flags honor the window, the echo is
  true only when it did, and ``mode=changes`` / ``mode=children`` ignore it;
- the budget trim keeps the newest display row and raises ``hasMore`` when it
  had to drop older rows;
- the single-row endpoint returns the full payload, 404s for an unknown row
  and for another user's session.
"""

from __future__ import annotations

from typing import Any

import pytest
from session_fixtures import create_session_with_project
from sqlalchemy import select, update
from test_backend_mvp import auth_headers, create_connector_and_session, make_client

from agent_server.api.sessions import SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV
from agent_server.core.models import TimelineItem, TimelineItemIn
from agent_server.infra.db import timeline_items
from agent_server.infra.repositories.facade import Store
from agent_server.infra.timeline_store import (
    DEFERRED_STUB_THRESHOLD_BYTES,
    _deferred_activity_row_expr,
    _deferred_display_row_expr,
    is_deferred_activity_item,
    is_deferred_activity_row,
    is_deferred_display_item,
    is_deferred_display_row,
)

EXTERNAL_SESSION_ID = "claude_ext_deferred"
BIG_OUTPUT = "x" * 12_000
SMALL_OUTPUT = "y" * 1_000


# ---------------------------------------------------------------------------
# Payload builders (store and HTTP paths share them)
# ---------------------------------------------------------------------------


def _message_payload(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    parent_item_id: str | None = None,
) -> dict[str, Any]:
    content: dict[str, Any] = {
        "text": f"text of {item_id}",
        "format": "markdown",
    }
    if parent_item_id is not None:
        content["parentItemId"] = parent_item_id
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "message",
        "status": "done",
        "role": "assistant",
        "content": content,
        "source": {
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemId": item_id,
            "itemType": "agentMessage",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{item_id}",
    }


def _tool_payload(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    kind: str | None = "bash",
    status: str = "done",
    output: str | None = None,
    parent_item_id: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    content: dict[str, Any] = {"title": item_id}
    if kind is not None:
        content["kind"] = kind
    if output is not None:
        content["output"] = output
    if parent_item_id is not None:
        content["parentItemId"] = parent_item_id
    if extra:
        content.update(extra)
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "tool",
        "status": status,
        "role": "tool",
        "content": content,
        "source": {
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemId": item_id,
            "itemType": "toolUse",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{item_id}",
    }


def _reasoning_payload(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    text: str = "reasoning",
) -> dict[str, Any]:
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "system",
        "status": "done",
        "content": {"kind": "reasoning", "text": text},
        "source": {
            "runtime": "claude",
            "sessionId": EXTERNAL_SESSION_ID,
            "itemId": item_id,
            "itemType": "reasoning",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{item_id}",
    }


def _stored_item(
    session_id: str,
    item_id: str,
    *,
    order_seq: int,
    updated_seq: int,
) -> TimelineItem:
    """A full stored row for direct inserts (tests that need tied orderSeq)."""

    return TimelineItem.model_validate(
        {
            **_message_payload(session_id, item_id, order_seq=order_seq),
            "updatedSeq": updated_seq,
            "createdAt": "2026-10-23T00:00:00Z",
            "updatedAt": "2026-10-23T00:00:00Z",
        }
    )


async def _store_with_session() -> tuple[Store, Any]:
    store = Store()
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id=EXTERNAL_SESSION_ID,
        project_name="P-deferred-window",
    )
    return store, session


async def _seed_store(
    store: Store,
    session_id: str,
    payloads: list[dict[str, Any]],
) -> None:
    await store.sync_timeline_items(
        session_id=session_id,
        items=[TimelineItemIn.model_validate(payload) for payload in payloads],
    )


def _ids(items: list[TimelineItem]) -> list[str]:
    return [item.id for item in items]


# ---------------------------------------------------------------------------
# Row predicates
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_python_and_sql_row_predicates_agree(tmp_path) -> None:
    """Every seeded row shape classifies identically in SQL and in Python.

    The window's correctness rests on the two predicates making the same
    display/activity decision: the SQL one picks the anchor and the payload
    branch, the Python one drives the budget trim. A drift would make the trim
    drop rows the store counted (or vice versa).
    """

    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "message", order_seq=1),
                _message_payload(
                    session.id,
                    "message_child",
                    order_seq=2,
                    parent_item_id="card-A",
                ),
                {
                    "id": "artifact_diff",
                    "sessionId": session.id,
                    "type": "artifact",
                    "status": "done",
                    "content": {"kind": "diff", "text": "diff --git a b"},
                    "source": {
                        "runtime": "claude",
                        "sessionId": EXTERNAL_SESSION_ID,
                        "itemId": "artifact_diff",
                        "itemType": "artifact",
                    },
                    "orderSeq": 3,
                    "revision": 1,
                    "contentHash": "sha256:artifact_diff",
                },
                _tool_payload(
                    session.id,
                    "tool_bash",
                    order_seq=4,
                    kind="bash",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id,
                    "tool_waiting",
                    order_seq=5,
                    kind="bash",
                    status="waiting_approval",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id, "tool_file", order_seq=6, kind="file_change"
                ),
                _tool_payload(
                    session.id, "tool_agent", order_seq=7, kind="agent_call"
                ),
                _tool_payload(
                    session.id, "tool_input", order_seq=8, kind="input_request"
                ),
                _tool_payload(
                    session.id, "tool_no_kind", order_seq=9, kind=None
                ),
                _tool_payload(
                    session.id,
                    "tool_child",
                    order_seq=10,
                    kind="bash",
                    parent_item_id="card-A",
                ),
                _reasoning_payload(session.id, "reasoning", order_seq=11),
                # An artifact without ``kind`` must not be swallowed by SQL's
                # three-valued logic: Python keeps it as a display row.
                {
                    "id": "artifact_no_kind",
                    "sessionId": session.id,
                    "type": "artifact",
                    "status": "done",
                    "content": {"title": "file"},
                    "source": {
                        "runtime": "claude",
                        "sessionId": EXTERNAL_SESSION_ID,
                        "itemId": "artifact_no_kind",
                        "itemType": "artifact",
                    },
                    "orderSeq": 12,
                    "revision": 1,
                    "contentHash": "sha256:artifact_no_kind",
                },
            ],
        )
        async with store._engine.connect() as conn:
            sql_display = set(
                (
                    await conn.execute(
                        select(timeline_items.c.id).where(
                            _deferred_display_row_expr(timeline_items.c)
                        )
                    )
                )
                .scalars()
                .all()
            )
            sql_activity = set(
                (
                    await conn.execute(
                        select(timeline_items.c.id).where(
                            _deferred_activity_row_expr(timeline_items.c)
                        )
                    )
                )
                .scalars()
                .all()
            )
        items, _ = await store.list_timeline_latest(
            session_id=session.id, limit=50
        )
        python_display = {item.id for item in items if is_deferred_display_item(item)}
        python_activity = {
            item.id for item in items if is_deferred_activity_item(item)
        }

        # ``artifact_diff`` is the one artifact shape that never displays; a
        # child row of either type is neither display nor activity.
        assert python_display == sql_display == {
            "message",
            "tool_waiting",
            "tool_file",
            "tool_agent",
            "tool_input",
            "tool_no_kind",
            "artifact_no_kind",
        }
        assert python_activity == sql_activity == {"tool_bash", "reasoning"}
        # Child rows and the artifact diff are neither: the window excludes the
        # former and the timeline never renders the latter.
        assert not (python_display | python_activity) & {
            "message_child",
            "artifact_diff",
            "tool_child",
        }
    finally:
        await store.close()


def test_reasoning_type_is_activity_for_stored_legacy_rows() -> None:
    """``type='reasoning'`` is accepted for rows older projections may store."""

    assert is_deferred_activity_row(
        item_type="reasoning", status="done", kind=None
    )
    assert not is_deferred_display_row(
        item_type="reasoning", status="done", kind=None
    )
    assert is_deferred_activity_row(
        item_type="system", status="done", kind="reasoning"
    )
    assert not is_deferred_display_row(
        item_type="system", status="done", kind="reasoning"
    )


# ---------------------------------------------------------------------------
# Store reader: anchor selection
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_anchor_ignores_child_message_rows(tmp_path) -> None:
    """Child rows are excluded before the anchor LIMIT, so they never anchor.

    The default reader's newest row is a child; the deferred window must still
    find the one main display row behind it.
    """

    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "main", order_seq=1),
                *[
                    _message_payload(
                        session.id,
                        f"child_{index}",
                        order_seq=2 + index,
                        parent_item_id="card-A",
                    )
                    for index in range(5)
                ],
            ],
        )

        default_items, _ = await store.list_timeline_latest(
            session_id=session.id, limit=1
        )
        assert _ids(default_items) == ["child_4"]  # the blank-page setup

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=1
        )
        assert applied is True
        assert _ids(items) == ["main"]
        assert has_more is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_anchor_uses_all_display_rows_when_fewer_than_limit(
    tmp_path,
) -> None:
    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m1", order_seq=1),
                _message_payload(session.id, "m2", order_seq=2),
                _tool_payload(session.id, "tool", order_seq=3),
                _reasoning_payload(session.id, "reasoning", order_seq=4),
            ],
        )

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=10
        )
        assert applied is True
        # Both display rows plus the activity segment above the newest one.
        assert _ids(items) == ["m1", "m2", "tool", "reasoning"]
        assert has_more is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_no_display_rows_reports_not_applied(tmp_path) -> None:
    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _tool_payload(session.id, "tool", order_seq=1),
                _reasoning_payload(session.id, "reasoning", order_seq=2),
            ],
        )

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=10
        )
        assert items == []
        assert has_more is False
        assert applied is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_window_never_returns_child_rows(tmp_path) -> None:
    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m1", order_seq=1),
                _tool_payload(
                    session.id,
                    "child_tool",
                    order_seq=2,
                    parent_item_id="card-A",
                ),
                _message_payload(session.id, "m2", order_seq=3),
                _message_payload(
                    session.id,
                    "child_message",
                    order_seq=4,
                    parent_item_id="card-A",
                ),
            ],
        )

        items, _, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=10
        )
        assert applied is True
        assert _ids(items) == ["m1", "m2"]
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Store reader: payload selection
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_large_stub_eligible_tool_row_is_summarized(tmp_path) -> None:
    """Only a large main tool activity row with a current stub is summarised."""

    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m1", order_seq=1),
                _tool_payload(
                    session.id, "big", order_seq=2, output=BIG_OUTPUT
                ),
                _tool_payload(
                    session.id, "small", order_seq=3, output=SMALL_OUTPUT
                ),
                _tool_payload(
                    session.id,
                    "forged_stub",
                    order_seq=4,
                    output=BIG_OUTPUT,
                ),
                _message_payload(session.id, "m2", order_seq=5),
            ],
        )
        # A stub whose format version this reader does not know must be
        # ignored: the full payload is the safe answer.
        async with store._engine.begin() as conn:
            await conn.execute(
                update(timeline_items)
                .where(
                    timeline_items.c.session_id == session.id,
                    timeline_items.c.id == "forged_stub",
                )
                .values(stub_version=99)
            )

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=2
        )
        assert applied is True
        assert has_more is False
        assert _ids(items) == ["m1", "big", "small", "forged_stub", "m2"]

        by_id = {item.id: item for item in items}
        big_content = by_id["big"].content
        assert big_content["deferred"] is True
        assert big_content["deferredBytes"] > DEFERRED_STUB_THRESHOLD_BYTES
        assert "output" not in big_content

        small_content = by_id["small"].content
        assert small_content["output"] == SMALL_OUTPUT
        assert "deferred" not in small_content

        forged_content = by_id["forged_stub"].content
        assert forged_content["output"] == BIG_OUTPUT
        assert "deferred" not in forged_content
    finally:
        await store.close()


@pytest.mark.anyio
async def test_display_rows_are_never_summarized(tmp_path) -> None:
    """Display-kind tools, approvals, kind-less tools and reasoning stay full.

    Each row here is large enough to summarize; none of them may be, because
    either it is a display row (counted, rendered in place) or it is reasoning,
    which has no stored stub.
    """

    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m0", order_seq=1),
                _tool_payload(
                    session.id,
                    "file_change",
                    order_seq=2,
                    kind="file_change",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id,
                    "agent_call",
                    order_seq=3,
                    kind="agent_call",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id,
                    "input_request",
                    order_seq=4,
                    kind="input_request",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id,
                    "waiting",
                    order_seq=5,
                    kind="bash",
                    status="waiting_approval",
                    output=BIG_OUTPUT,
                ),
                _tool_payload(
                    session.id,
                    "no_kind",
                    order_seq=6,
                    kind=None,
                    output=BIG_OUTPUT,
                ),
                _reasoning_payload(
                    session.id, "reasoning", order_seq=7, text=BIG_OUTPUT
                ),
                _message_payload(session.id, "m1", order_seq=8),
            ],
        )

        items, _, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=10
        )
        assert applied is True
        assert len(items) == 8
        for item in items:
            content = item.content
            assert "deferred" not in content, item.id
        by_id = {item.id: item for item in items}
        assert by_id["file_change"].content["output"] == BIG_OUTPUT
        assert by_id["agent_call"].content["output"] == BIG_OUTPUT
        assert by_id["input_request"].content["output"] == BIG_OUTPUT
        assert by_id["waiting"].content["output"] == BIG_OUTPUT
        assert by_id["no_kind"].content["output"] == BIG_OUTPUT
        assert by_id["reasoning"].content["text"] == BIG_OUTPUT
    finally:
        await store.close()


@pytest.mark.anyio
async def test_tail_tool_rows_are_summarized_while_reasoning_stays_complete(
    tmp_path,
) -> None:
    """The live tail stays bounded too.

    Serving every tail row in full made the server read a long burst's whole
    payload before trimming it. A large tail tool row now arrives as its
    stored summary; reasoning is never summarized (its stub would hide the
    row and no read could bring it back).
    """

    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m1", order_seq=1),
                _tool_payload(
                    session.id,
                    "tail_tool",
                    order_seq=2,
                    output="\n".join(
                        f"tail result line {index}" for index in range(1200)
                    ),
                ),
                _reasoning_payload(
                    session.id, "tail_reasoning", order_seq=3, text=BIG_OUTPUT
                ),
            ],
        )

        items, _, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=1
        )
        assert applied is True
        assert _ids(items) == ["m1", "tail_tool", "tail_reasoning"]
        by_id = {item.id: item for item in items}
        assert by_id["tail_tool"].content["deferred"] is True
        assert "output" not in by_id["tail_tool"].content
        assert by_id["tail_tool"].content["outputPreview"]
        assert by_id["tail_reasoning"].content["text"] == BIG_OUTPUT
        assert "deferred" not in by_id["tail_reasoning"].content
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# Store reader: has_more and history paging
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_has_more_uses_the_composite_row_boundary(tmp_path) -> None:
    """A tied ``order_seq`` must not make the older sibling invisible."""

    store, session = await _store_with_session()
    try:
        async with store._engine.begin() as conn:
            await store.timeline.replace_all(
                conn,
                session.id,
                [
                    _stored_item(
                        session.id, "a", order_seq=5, updated_seq=5
                    ),
                    _stored_item(
                        session.id, "b", order_seq=5, updated_seq=10
                    ),
                ],
            )

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id, limit=1, span_rows=1
        )
        assert applied is True
        # The tighter (order_seq, updated_seq) row wins the single slot; the
        # tie-mate is strictly before it on the composite boundary.
        assert _ids(items) == ["b"]
        assert has_more is True

        async with store._engine.begin() as conn:
            await store.timeline.replace_all(
                conn,
                session.id,
                [
                    _stored_item(session.id, "c", order_seq=1, updated_seq=1),
                    _stored_item(session.id, "d", order_seq=2, updated_seq=2),
                    _stored_item(session.id, "e", order_seq=3, updated_seq=3),
                ],
            )
        items, has_more, _ = await store.list_timeline_deferred_window(
            session_id=session.id, limit=10, span_rows=10
        )
        assert _ids(items) == ["c", "d", "e"]
        assert has_more is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_history_before_order_seq_pages_back_through_display_rows(
    tmp_path,
) -> None:
    store, session = await _store_with_session()
    try:
        await _seed_store(
            store,
            session.id,
            [
                _message_payload(session.id, "m1", order_seq=1),
                _tool_payload(
                    session.id, "tool_a", order_seq=2, output=BIG_OUTPUT
                ),
                _message_payload(session.id, "m2", order_seq=3),
                _tool_payload(session.id, "tool_b", order_seq=4),
                _message_payload(session.id, "m3", order_seq=5),
            ],
        )

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id,
            limit=1,
            before_order_seq=5,
        )
        assert applied is True
        # The newest display row before the cursor is m2; the page starts
        # there and stops strictly before the cursor, so m3 (already held by
        # the client) never comes back.
        assert _ids(items) == ["m2", "tool_b"]
        assert all(item.orderSeq < 5 for item in items)
        assert has_more is True

        items, has_more, applied = await store.list_timeline_deferred_window(
            session_id=session.id,
            limit=1,
            before_order_seq=3,
        )
        assert applied is True
        assert _ids(items) == ["m1", "tool_a"]
        assert all(item.orderSeq < 3 for item in items)
        assert has_more is False
    finally:
        await store.close()


# ---------------------------------------------------------------------------
# HTTP window
# ---------------------------------------------------------------------------


def _post_sync(
    client: Any,
    access_token: str,
    session_id: str,
    items: list[dict[str, Any]],
) -> None:
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "notifications": [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "complete": False,
                        "items": items,
                    },
                }
            ]
        },
    )
    assert response.status_code == 200, response.text


def _seed_deferred_window(client: Any, access_token: str, session_id: str) -> None:
    """m1, a large activity tool row, m2, then a child row."""

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _tool_payload(session_id, "big_tool", order_seq=2, output=BIG_OUTPUT),
            _message_payload(session_id, "m2", order_seq=3),
            _message_payload(
                session_id,
                "child",
                order_seq=4,
                parent_item_id="card-A",
            ),
        ],
    )


def test_default_reads_are_unchanged(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_deferred_window(client, access_token, session_id)

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "latest", "limit": 10},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert [item["id"] for item in body["items"]] == [
        "m1",
        "big_tool",
        "m2",
        "child",
    ]
    big = next(item for item in body["items"] if item["id"] == "big_tool")
    assert big["content"]["output"] == BIG_OUTPUT  # complete, never a stub
    assert body["deferredActivity"] is False
    assert body["excludesAgentChildren"] is False

    snapshot = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"limit": 10},
    )
    assert snapshot.status_code == 200, snapshot.text
    snapshot_body = snapshot.json()
    assert snapshot_body["deferredActivity"] is False
    assert "deferredActivity" not in snapshot_body["timeline"]


def test_defer_activity_without_exclude_is_ignored(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_deferred_window(client, access_token, session_id)

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "latest", "limit": 10, "deferActivity": True},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert [item["id"] for item in body["items"]] == [
        "m1",
        "big_tool",
        "m2",
        "child",
    ]
    big = next(item for item in body["items"] if item["id"] == "big_tool")
    assert big["content"]["output"] == BIG_OUTPUT
    assert body["deferredActivity"] is False


def test_latest_deferred_window_summarizes_activity_rows(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_deferred_window(client, access_token, session_id)

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "latest",
            "limit": 2,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["deferredActivity"] is True
    assert body["excludesAgentChildren"] is True
    assert [item["id"] for item in body["items"]] == [
        "m1",
        "big_tool",
        "m2",
    ]
    big = next(item for item in body["items"] if item["id"] == "big_tool")
    assert big["content"]["deferred"] is True
    assert big["content"]["deferredBytes"] > DEFERRED_STUB_THRESHOLD_BYTES
    assert "output" not in big["content"]


def test_history_deferred_window_respects_the_cursor(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _tool_payload(session_id, "tool_a", order_seq=2),
            _message_payload(session_id, "m2", order_seq=3),
            _tool_payload(session_id, "tool_b", order_seq=4),
            _message_payload(session_id, "m3", order_seq=5),
        ],
    )

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "history",
            "beforeOrderSeq": 5,
            "limit": 1,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    ids = [item["id"] for item in body["items"]]
    assert body["deferredActivity"] is True
    assert ids == ["m2", "tool_b"]
    assert all(item["orderSeq"] < 5 for item in body["items"])
    assert "m3" not in ids
    assert body["hasMore"] is True


def test_history_deferred_window_does_not_overlap_the_newer_page(
    tmp_path,
) -> None:
    """A history read must not re-serve rows the client already holds.

    The newer page is what the default history reader returns for an open
    cursor; the deferred read is anchored on that page's oldest row. Every row
    it returns must fall strictly below the cursor, and no id may repeat.
    """

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _tool_payload(session_id, "tool_a", order_seq=2),
            _message_payload(session_id, "m2", order_seq=3),
            _tool_payload(session_id, "tool_b", order_seq=4),
            _message_payload(session_id, "m3", order_seq=5),
            _tool_payload(session_id, "tool_c", order_seq=6),
        ],
    )

    newer = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={"mode": "history", "beforeOrderSeq": 100, "limit": 2},
    )
    assert newer.status_code == 200, newer.text
    newer_body = newer.json()
    assert [item["id"] for item in newer_body["items"]] == ["m3", "tool_c"]
    cursor = newer_body["items"][0]["orderSeq"]

    older = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "history",
            "beforeOrderSeq": cursor,
            "limit": 2,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert older.status_code == 200, older.text
    older_body = older.json()
    older_ids = [item["id"] for item in older_body["items"]]
    assert older_body["deferredActivity"] is True
    assert all(item["orderSeq"] < cursor for item in older_body["items"])
    assert set(older_ids).isdisjoint(
        {item["id"] for item in newer_body["items"]}
    )
    assert "m1" in older_ids


def test_history_missing_cursor_is_still_422(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "history",
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 422, response.text


def test_changes_and_children_modes_ignore_defer_activity(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _message_payload(
                session_id,
                "child",
                order_seq=2,
                parent_item_id="card-A",
            ),
        ],
    )

    changes = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "changes",
            "afterSeq": 0,
            "limit": 10,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert changes.status_code == 200, changes.text
    changes_body = changes.json()
    assert [item["id"] for item in changes_body["items"]] == ["m1", "child"]
    assert changes_body["deferredActivity"] is False

    children = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "children",
            "parentItemId": "card-A",
            "limit": 10,
            "deferActivity": True,
        },
    )
    assert children.status_code == 200, children.text
    children_body = children.json()
    assert [item["id"] for item in children_body["items"]] == ["child"]
    assert children_body["deferredActivity"] is False


def test_snapshot_echoes_deferred_activity_at_top_level(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _tool_payload(
                session_id,
                "card",
                order_seq=1,
                kind="agent_call",
                status="running",
                extra={"agents": {"task_card": {"status": "running"}}},
            ),
            _message_payload(session_id, "m1", order_seq=2),
            _tool_payload(session_id, "big_tool", order_seq=3, output=BIG_OUTPUT),
            _message_payload(session_id, "m2", order_seq=4),
            _message_payload(
                session_id,
                "child",
                order_seq=5,
                parent_item_id="card",
            ),
        ],
    )

    response = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={
            "limit": 2,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["deferredActivity"] is True
    assert "deferredActivity" not in body["timeline"]
    # The Agent card sits outside the two-display-row window but still rides in
    # the sidecar unchanged.
    assert [item["id"] for item in body["activeAgents"]] == ["card"]
    timeline_ids = [item["id"] for item in body["timeline"]["items"]]
    assert timeline_ids == ["m1", "big_tool", "m2"]
    big = next(
        item for item in body["timeline"]["items"] if item["id"] == "big_tool"
    )
    assert big["content"]["deferred"] is True


def test_budget_trimming_keeps_the_newest_display_row(
    tmp_path, monkeypatch
) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _tool_payload(session_id, "big_tool", order_seq=2, output=BIG_OUTPUT),
            _message_payload(session_id, "m2", order_seq=3),
        ],
    )
    # A 1-byte budget forces the trim to drop display rows; the newest display
    # row must survive and hasMore must tell the client what it lost.
    monkeypatch.setenv(SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV, "1")

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "latest",
            "limit": 2,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert [item["id"] for item in body["items"]] == ["m2"]
    assert body["hasMore"] is True
    assert body["deferredActivity"] is True


# ---------------------------------------------------------------------------
# HTTP single row
# ---------------------------------------------------------------------------


def test_single_item_endpoint_returns_the_full_payload(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_deferred_window(client, access_token, session_id)

    window = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "latest",
            "limit": 2,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert window.status_code == 200, window.text
    summarized = next(
        item
        for item in window.json()["items"]
        if item["id"] == "big_tool"
    )
    assert summarized["content"]["deferred"] is True

    response = client.get(
        f"/sessions/{session_id}/timeline/items/big_tool",
        headers=headers,
    )
    assert response.status_code == 200, response.text
    item = response.json()
    assert item["id"] == "big_tool"
    assert item["content"]["output"] == BIG_OUTPUT
    assert "deferred" not in item["content"]

    unknown = client.get(
        f"/sessions/{session_id}/timeline/items/missing",
        headers=headers,
    )
    assert unknown.status_code == 404, unknown.text


def test_single_item_endpoint_hides_other_users_sessions(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _seed_deferred_window(client, access_token, session_id)
    intruder_headers = auth_headers(client, user_id="intruder_user")

    response = client.get(
        f"/sessions/{session_id}/timeline/items/m1",
        headers=intruder_headers,
    )
    assert response.status_code == 404, response.text


# ---------------------------------------------------------------------------
# Span-cap / budget edge cases found in review
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_a_span_without_a_display_row_reports_not_applied(tmp_path) -> None:
    """A display row exists, but only *above* the 800-row span.

    The anchor query sees it, yet the window (the newest 800 rows) is pure
    activity. Serving that window would be a full-payload activity tail with
    no conversational anchor, so the reader must decline and let the API keep
    its pre-existing bounded page.
    """

    store, session = await _store_with_session()
    payloads = [_message_payload(session.id, "m1", order_seq=1)]
    payloads += [
        _tool_payload(session.id, f"t{index}", order_seq=2 + index, output="small")
        for index in range(801)
    ]
    await _seed_store(store, session.id, payloads)

    items, has_more, applied = await store.list_timeline_deferred_window(
        session_id=session.id, limit=100
    )
    assert applied is False
    assert items == []
    assert has_more is False


def test_activity_only_span_falls_back_to_the_default_reader(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [_message_payload(session_id, "m1", order_seq=1)]
        + [
            _tool_payload(session_id, f"t{index}", order_seq=2 + index, output="small")
            for index in range(801)
        ],
    )
    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "latest",
            "limit": 100,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["deferredActivity"] is False
    # The pre-existing main-only reader: the newest 100 rows, all activity.
    assert len(body["items"]) == 100
    assert all(item["type"] == "tool" for item in body["items"])


def test_budget_trimming_never_summarizes_reasoning(
    tmp_path, monkeypatch
) -> None:
    """Reasoning rows stay complete even when the window is over budget.

    A reasoning stub would drop its text; the Chat page hides a reasoning row
    whose text is empty, so the row would silently disappear with no read that
    could bring it back. The trim may drop older display rows instead.
    """

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    long_reasoning = "r" * 300_000
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message_payload(session_id, "m1", order_seq=1),
            _message_payload(session_id, "m2", order_seq=2),
            _reasoning_payload(
                session_id, "r1", order_seq=3, text=long_reasoning
            ),
            _reasoning_payload(
                session_id, "r2", order_seq=4, text=long_reasoning
            ),
        ],
    )
    # Below the 256KB newest-segment allowance and below the total budget.
    monkeypatch.setenv(SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV, "400000")

    response = client.get(
        f"/sessions/{session_id}/timeline",
        headers=headers,
        params={
            "mode": "latest",
            "limit": 100,
            "excludeAgentChildren": True,
            "deferActivity": True,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    reasoning = [item for item in body["items"] if item["type"] == "system"]
    assert reasoning, "reasoning rows must not be dropped or hidden"
    for item in reasoning:
        assert item["content"].get("deferred") is not True
        assert item["content"].get("text")


@pytest.mark.anyio
async def test_the_window_keeps_the_anchor_when_the_span_is_wide_enough(
    tmp_path,
) -> None:
    """The review repro: 100 messages followed by 700 activity rows.

    A 600-row span dropped every message; the window is sized so this shape
    (the observed worst case) still opens on the conversation.
    """

    store, session = await _store_with_session()
    payloads = [
        _message_payload(session.id, f"m{index}", order_seq=index)
        for index in range(1, 101)
    ]
    payloads += [
        _tool_payload(
            session.id, f"t{index}", order_seq=100 + index, output="small"
        )
        for index in range(1, 701)
    ]
    await _seed_store(store, session.id, payloads)

    items, has_more, applied = await store.list_timeline_deferred_window(
        session_id=session.id, limit=100
    )
    assert applied is True
    assert len(items) == 800
    assert sum(1 for item in items if item.type == "message") == 100
    assert has_more is False
