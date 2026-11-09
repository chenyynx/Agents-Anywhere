"""A rebased history sync must place backfilled rows by chain order.

Incident 2026-11-09 (sess_qqyxFhGrjUyRgQ): a stuck Claude turn's rows never
reached the server. After a connector restart the next turn's live rows landed
first, then the turn-end history sync backfilled the older rows. The server
appended every new row at ``max(order_seq) + 1`` because the batch's own order
numbers (1..N) were smaller than the session's current maximum, so the UI
rendered the pre-stuck steps *after* the final message.

A rebased batch (``metadata.rebased``) covers the whole visible chain; the rows
it **adds** are placed by chain order. Since 2026-11-10 the plan is
insert-only: a row that is already stored keeps its exact number, whether or
not the batch names it (one rebuild had renumbered 431 batch-external rows and
still left the visible order wrong). These tests pin that:

- backfilled **new** rows land before the rows that already existed, in a free
  integer below the next stored anchor;
- stored rows keep their position even when the chain disagrees (an already
  misordered row is not repaired by a rebuild);
- an already-ordered rebase is a no-op (no rewrites);
- a plain incremental merge keeps the old append behaviour (the flag is the
  authority signal, not "this batch happens to carry older rows").
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from test_backend_mvp import (
    create_connector_and_session,
    make_client,
    session_view_for_assertions,
)

from agent_server.core.timeline import (
    chain_reorder_plan,
    chain_reorder_plan_with_diagnostics,
)


def test_chain_reorder_plan_is_none_when_the_stored_order_matches() -> None:
    assert (
        chain_reorder_plan(
            stored_order=[("a", 1), ("b", 2)],
            batch_ids=["a", "b"],
        )
        is None
    )


def test_chain_reorder_plan_keeps_gaps_before_the_first_mismatch() -> None:
    # Stored numbers have gaps (deletions). An append-only rebuild must add
    # only the new row and leave the existing numbers alone — compacting the
    # gaps would rewrite a long session for nothing.
    assert chain_reorder_plan(
        stored_order=[("a", 1), ("b", 5)],
        batch_ids=["a", "b", "c"],
    ) == {"c": 6}


def test_a_new_row_with_no_free_slot_renumbers_the_local_block() -> None:
    # ``x`` belongs between ``a`` (1) and ``b`` (2), but there is no integer
    # between them. The smallest block around the insertion (b, c) is
    # renumbered in its existing order to make room: b and c move up, x takes
    # 2. Nothing outside the block changes.
    diagnostics = chain_reorder_plan_with_diagnostics(
        stored_order=[("a", 1), ("b", 2), ("c", 3)],
        batch_ids=["a", "x", "b", "c"],
    )
    assert diagnostics.plan == {"x": 2, "b": 3, "c": 4}
    assert diagnostics.renumbered_stored == 2


def test_an_existing_only_batch_plans_nothing() -> None:
    """A batch with no new row has nothing to insert; stored order is kept.

    2026-11-10: one rebuild renumbered 431 rows it did not cover. The plan no
    longer repositions an existing (even misordered) row that no new row
    displaces; repairing that is a separate one-off pass.
    """

    assert (
        chain_reorder_plan(
            stored_order=[("b", 1), ("platform", 2), ("a", 3)],
            batch_ids=["a", "b"],
        )
        is None
    )


def _message(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    text: str,
    created_at: str | None = None,
    status: str = "done",
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "id": item_id,
        "sessionId": session_id,
        "type": "message",
        "status": status,
        "role": "assistant",
        "content": {"kind": "markdown", "format": "markdown", "text": text},
        "source": {
            "runtime": "claude",
            "sessionId": "claude_ext_1",
            "itemId": item_id,
            "itemType": "message",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{item_id}:{text}",
    }
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def _post_sync(
    client: Any,
    access_token: str,
    session_id: str,
    items: list[dict[str, Any]],
    *,
    metadata: dict[str, Any] | None = None,
    complete: bool = False,
) -> None:
    params: dict[str, Any] = {
        "sessionId": session_id,
        "complete": complete,
        "items": items,
    }
    if metadata is not None:
        params["metadata"] = metadata
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={"notifications": [{"method": "timeline.sync", "params": params}]},
    )
    assert response.status_code == 200, response.text


REBASED = {"source": "claude.history.sync", "rebased": True}


def _ordered_items(
    client: Any,
    session_id: str,
    headers: dict[str, str],
) -> list[dict[str, Any]]:
    items = session_view_for_assertions(client, session_id, headers)["items"]
    return sorted(items, key=lambda item: item["orderSeq"])


def test_rebased_batch_places_backfilled_rows_before_existing(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    # The newer rows reached the server first (live publication of the turn
    # that started after the restart).
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_new_1", session_id=session_id, order_seq=1, text="new-1"),
            _message("msg_new_2", session_id=session_id, order_seq=2, text="new-2"),
        ],
    )

    # The full-chain rebase carries the older rows (backfill) plus the newer
    # rows the server already holds. Its order is the chain order.
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_old_1", session_id=session_id, order_seq=1, text="old-1"),
            _message("msg_old_2", session_id=session_id, order_seq=2, text="old-2"),
            _message("msg_new_1", session_id=session_id, order_seq=3, text="new-1"),
            _message("msg_new_2", session_id=session_id, order_seq=4, text="new-2"),
        ],
        metadata=REBASED,
    )

    assert [item["id"] for item in _ordered_items(client, session_id, headers)] == [
        "msg_old_1",
        "msg_old_2",
        "msg_new_1",
        "msg_new_2",
    ]


def test_rebased_batch_keeps_uncovered_rows_between_their_neighbours(
    tmp_path,
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
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_platform", session_id=session_id, order_seq=2, text="p"),
            _message("msg_b", session_id=session_id, order_seq=3, text="b"),
        ],
    )

    # The rebuild covers the chain rows but not the platform slot between them.
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_b", session_id=session_id, order_seq=2, text="b"),
        ],
        metadata=REBASED,
    )

    assert [item["id"] for item in _ordered_items(client, session_id, headers)] == [
        "msg_a",
        "msg_platform",
        "msg_b",
    ]


def test_rebased_batch_is_a_noop_when_the_order_already_matches(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_b", session_id=session_id, order_seq=2, text="b"),
        ],
    )
    before = {
        item["id"]: item["updatedSeq"]
        for item in _ordered_items(client, session_id, headers)
    }

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_b", session_id=session_id, order_seq=2, text="b"),
        ],
        metadata=REBASED,
    )

    after = {
        item["id"]: item["updatedSeq"]
        for item in _ordered_items(client, session_id, headers)
    }
    assert after == before


def test_plain_merge_backfill_still_appends(tmp_path) -> None:
    """Non-rebased batches are not authoritative: the append rule stays.

    This is the documented boundary of the fix — only a full-chain rebuild
    declares the whole order, so only it may renumber the session.
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
            _message("msg_new_1", session_id=session_id, order_seq=1, text="new-1"),
        ],
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_old_1", session_id=session_id, order_seq=1, text="old-1"),
        ],
    )

    assert [item["id"] for item in _ordered_items(client, session_id, headers)] == [
        "msg_new_1",
        "msg_old_1",
    ]


WINDOW = {"source": "claude.history.sync", "windowOrder": True}


def _tool(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    text: str,
    status: str = "failed",
) -> dict[str, Any]:
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "tool",
        "status": status,
        "role": "tool",
        "content": {"kind": "command", "text": text},
        "source": {
            "runtime": "claude",
            "sessionId": "claude_ext_1",
            "itemId": item_id,
            "itemType": "tool_result",
        },
        "orderSeq": order_seq,
        "revision": 1,
        "contentHash": f"sha256:{item_id}:{text}",
    }


def test_window_batch_places_a_new_row_before_later_rows(tmp_path) -> None:
    """A settle-sync window carries a row the live path never published.

    A hook-error tool result reaches the Server only through the cursor window;
    its chain position is before the final body. The append rule would strand
    it after the body — the "tool call at the end" symptom (2026-11-09).
    """

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    _post_sync(
        client,
        access_token,
        session_id,
        [_message("msg_body", session_id=session_id, order_seq=1, text="final")],
    )
    _post_sync(
        client,
        access_token,
        session_id,
        [
            _tool("claude_tool_failed", session_id=session_id, order_seq=1,
                  text="hook error"),
            _message("msg_body", session_id=session_id, order_seq=2, text="final"),
        ],
        metadata=WINDOW,
    )

    assert [item["id"] for item in _ordered_items(client, session_id, headers)] == [
        "claude_tool_failed",
        "msg_body",
    ]


def test_window_batch_is_a_noop_when_the_order_already_matches(tmp_path) -> None:
    """A healthy window must not rewrite the session (no churn on settle)."""

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_b", session_id=session_id, order_seq=2, text="b"),
        ],
    )
    before = {
        item["id"]: item["updatedSeq"]
        for item in _ordered_items(client, session_id, headers)
    }

    _post_sync(
        client,
        access_token,
        session_id,
        [
            _message("msg_a", session_id=session_id, order_seq=1, text="a"),
            _message("msg_b", session_id=session_id, order_seq=2, text="b"),
        ],
        metadata=WINDOW,
    )

    after = {
        item["id"]: item["updatedSeq"]
        for item in _ordered_items(client, session_id, headers)
    }
    assert after == before


def test_rebased_rewrite_without_timestamps_keeps_the_stored_item_time(
    tmp_path,
) -> None:
    """A history rebuild must not move an old row's ``item_time`` to now.

    The sidebar sorts by ``max(latest item_time, last_activity_at)``. When a
    rebased sync rewrites an old row and the Runtime declares no timestamps,
    the Server used to stamp ``updatedAt = now``; ``item_time`` (the max of
    createdAt/completedAt/updatedAt) then jumped to now and the session climbed
    to the top of the list on every connector restart (2026-11-09).
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
            _message(
                "msg_a",
                session_id=session_id,
                order_seq=1,
                text="a",
                created_at="2026-11-01T10:00:00Z",
            )
        ],
    )
    before = _ordered_items(client, session_id, headers)[0]
    assert before["createdAt"] == "2026-11-01T10:00:00Z"
    assert before["updatedAt"] == "2026-11-01T10:00:00Z"

    # Same row, changed content (a rebuild rewrites it), no timestamps.
    _post_sync(
        client,
        access_token,
        session_id,
        [_message("msg_a", session_id=session_id, order_seq=1, text="a v2")],
        metadata=REBASED,
    )

    after = _ordered_items(client, session_id, headers)[0]
    assert after["createdAt"] == "2026-11-01T10:00:00Z"
    assert after["updatedAt"] == "2026-11-01T10:00:00Z"


def _post_upsert(
    client: Any,
    access_token: str,
    session_id: str,
    item: dict[str, Any],
) -> None:
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "notifications": [
                {
                    "method": "timeline.itemUpsert",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "claude",
                        "item": item,
                    },
                }
            ]
        },
    )
    assert response.status_code == 200, response.text


def _instant(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def test_live_upsert_advances_the_time_of_a_running_item(tmp_path) -> None:
    """An active row's rewrite IS the activity clock.

    The wire declares no per-row times, so the client times a thinking block
    (and a running agent card) from ``createdAt..updatedAt``. Freezing a
    running row's stamp would make every thought read one second.
    """

    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )

    _post_upsert(
        client,
        access_token,
        session_id,
        _message(
            "msg_run",
            session_id=session_id,
            order_seq=1,
            text="v1",
            status="running",
        ),
    )
    before = _ordered_items(client, session_id, headers)[0]
    _post_upsert(
        client,
        access_token,
        session_id,
        _message(
            "msg_run",
            session_id=session_id,
            order_seq=1,
            text="v2",
            status="running",
        ),
    )
    after = _ordered_items(client, session_id, headers)[0]

    assert after["createdAt"] == before["createdAt"]
    assert _instant(after["updatedAt"]) > _instant(before["updatedAt"])


def test_single_upsert_rewrite_without_timestamps_keeps_the_stored_item_time(
    tmp_path,
) -> None:
    """The live/maintenance single-item path follows the same rule.

    A card sweep or janitor rewrites an old row through ``timeline.itemUpsert``
    without declaring a time; stamping ``updatedAt = now`` there moved the row
    (and its session) to the top of the sidebar.
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
            _message(
                "msg_a",
                session_id=session_id,
                order_seq=1,
                text="a",
                created_at="2026-11-01T10:00:00Z",
            )
        ],
    )
    _post_upsert(
        client,
        access_token,
        session_id,
        _message("msg_a", session_id=session_id, order_seq=1, text="a v2"),
    )

    after = _ordered_items(client, session_id, headers)[0]
    assert after["createdAt"] == "2026-11-01T10:00:00Z"
    assert after["updatedAt"] == "2026-11-01T10:00:00Z"
