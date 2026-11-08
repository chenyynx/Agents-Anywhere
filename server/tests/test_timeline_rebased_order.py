"""A rebased history sync must place backfilled rows by chain order.

Incident 2026-11-09 (sess_qqyxFhGrjUyRgQ): a stuck Claude turn's rows never
reached the server. After a connector restart the next turn's live rows landed
first, then the turn-end history sync backfilled the older rows. The server
appended every new row at ``max(order_seq) + 1`` because the batch's own order
numbers (1..N) were smaller than the session's current maximum, so the UI
rendered the pre-stuck steps *after* the final message.

A rebased batch (``metadata.rebased``) covers the whole visible chain and its
order IS the chain order, so the server is allowed to treat it as the
authoritative order and renumber the session. These tests pin that:

- backfilled older rows land before the rows that already existed;
- rows the batch does not cover keep their position relative to the chain;
- an already-ordered rebase is a no-op (no rewrites);
- a plain incremental merge keeps the old append behaviour (the flag is the
  authority signal, not "this batch happens to carry older rows").
"""

from __future__ import annotations

from typing import Any

from test_backend_mvp import (
    create_connector_and_session,
    make_client,
    session_view_for_assertions,
)

from agent_server.core.timeline import chain_reorder_plan


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


def test_chain_reorder_plan_renumbers_only_the_misordered_suffix() -> None:
    # The prefix ("a") keeps its number and stays out of the plan.
    assert chain_reorder_plan(
        stored_order=[("a", 1), ("b", 2), ("c", 3)],
        batch_ids=["a", "x", "b", "c"],
    ) == {"x": 2, "b": 3, "c": 4}


def test_chain_reorder_plan_anchors_uncovered_rows_to_their_neighbours() -> None:
    assert chain_reorder_plan(
        stored_order=[("b", 1), ("platform", 2), ("a", 3)],
        batch_ids=["a", "b"],
    ) == {"a": 1, "b": 2, "platform": 3}


def _message(
    item_id: str,
    *,
    session_id: str,
    order_seq: int,
    text: str,
) -> dict[str, Any]:
    return {
        "id": item_id,
        "sessionId": session_id,
        "type": "message",
        "status": "done",
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
        "contentHash": f"sha256:{item_id}",
    }


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
