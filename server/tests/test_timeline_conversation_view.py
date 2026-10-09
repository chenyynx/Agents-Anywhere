"""Timeline conversation view (session open coverage, batch 2 server half).

The batch-2 wire contract (``.local-dev/session-open-coverage-tasks.md`` §五):

- ``exclude=agent_children`` drops the subagent-internal rows — rows whose
  payload ``content.parentItemId`` is a non-empty string — from the snapshot
  and from the timeline's ``latest``/``history`` modes. It never applies to
  ``mode=changes`` (the live and recovery deltas stay complete).
- ``hasMore`` and the cursor are computed over the *filtered* collection: a
  page whose raw window is entirely children still walks back to the older
  eligible rows, and a page only comes back empty when the filtered timeline
  is genuinely exhausted. The deployed client pages by the first returned
  item's ``orderSeq``, so an empty page with ``hasMore`` would strand it.
- The conversation-view paging surface (``history`` with the exclusion, and
  ``children``) applies the ``AGENT_SERVER_TIMELINE_PAGE_BYTE_BUDGET`` page
  budget (default 1MB) beside the count limit, whichever trips first.
- ``mode=children&parentId=<card id>`` returns one card's own internal rows,
  newest→oldest paging like history, isolated from every other parent.
- Without the ``exclude`` parameter every mode keeps its legacy reader
  byte-for-byte (the default request must not change behavior).
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest
from session_fixtures import create_session_with_project
from test_backend_mvp import create_connector_and_session, make_client

from agent_server.core.models import TimelineItemIn
from agent_server.infra.db.migrations import upgrade_database
from agent_server.infra.repositories.facade import Store

# --------------------------------------------------------------------------
# seeding helpers


def message_content(text: str, *, parent: str | None = None) -> dict[str, Any]:
    content: dict[str, Any] = {"text": text, "format": "markdown"}
    if parent is not None:
        content["parentItemId"] = parent
    return content


def tool_content(
    name: str, *, kind: str = "bash", parent: str | None = None
) -> dict[str, Any]:
    content: dict[str, Any] = {"kind": kind, "toolName": name}
    if parent is not None:
        content["parentItemId"] = parent
    return content


def card_content(description: str) -> dict[str, Any]:
    return {
        "kind": "agent_call",
        "action": "invoke",
        "description": description,
        "agents": {"task_a": {"status": "running"}},
    }


def _row(item_id: str, content: dict[str, Any], *, type: str = "message") -> dict[str, Any]:
    return {"id": item_id, "content": content, "type": type}


def _seed_timeline(
    client: Any, session_id: str, rows: list[dict[str, Any]]
) -> None:
    """Write rows in order; each insert gets the next ``orderSeq``.

    ``upsert_timeline_item`` assigns ``max(order_seq) + 1`` to new rows, so
    the insertion order is the timeline order.
    """

    store = client.app.state.store

    async def seed() -> None:
        for row in rows:
            item_type = row.get("type", "message")
            await store.upsert_timeline_item(
                session_id=session_id,
                item=TimelineItemIn.model_validate(
                    {
                        "id": row["id"],
                        "sessionId": session_id,
                        "type": item_type,
                        "status": "done",
                        "role": "tool" if item_type == "tool" else "assistant",
                        "content": row["content"],
                        "source": {
                            "runtime": "claude",
                            "sessionId": "claude_ext_1",
                            "itemId": row["id"],
                            "itemType": "agentMessage",
                        },
                        "orderSeq": 1,
                        "revision": 1,
                        "contentHash": f"sha256:{row['id']}",
                    }
                ),
            )

    asyncio.run(seed())


# --------------------------------------------------------------------------
# reading helpers


def _read_timeline(
    client: Any, session_id: str, headers: dict[str, str], **params: Any
) -> dict[str, Any]:
    response = client.get(
        f"/sessions/{session_id}/timeline", headers=headers, params=params
    )
    assert response.status_code == 200, response.text
    return response.json()


def _read_snapshot_timeline(
    client: Any, session_id: str, headers: dict[str, str], **params: Any
) -> dict[str, Any]:
    response = client.get(
        f"/sessions/{session_id}/snapshot", headers=headers, params=params
    )
    assert response.status_code == 200, response.text
    return response.json()["timeline"]


def _ids(body: dict[str, Any]) -> list[str]:
    return [item["id"] for item in body["items"]]


def _item_bytes(item: dict[str, Any]) -> int:
    return len(
        json.dumps(
            {"item": item}, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
    )


def _walk_pages(
    default_params: dict[str, Any],
    read_page: Any,
    *,
    start_before: int,
    limit: int,
    max_pages: int = 60,
) -> list[dict[str, Any]]:
    """Page like the deployed client: cursor = first (oldest) item's orderSeq.

    Also pins the never-empty invariant: ``hasMore`` with an empty page would
    strand the client (it cannot derive a next cursor), so the server must
    keep scanning instead.
    """

    pages: list[dict[str, Any]] = []
    before = start_before
    for _ in range(max_pages):
        body = read_page(**default_params, beforeOrderSeq=before, limit=limit)
        pages.append(body)
        if not body["hasMore"]:
            return pages
        assert body["items"], "hasMore=true with an empty page would strand the client"
        before = body["items"][0]["orderSeq"]
    raise AssertionError("paging walk did not terminate")


def _walk_history(
    client: Any,
    session_id: str,
    headers: dict[str, str],
    *,
    start_before: int,
    limit: int,
    exclude: bool = True,
) -> list[dict[str, Any]]:
    params: dict[str, Any] = {"mode": "history"}
    if exclude:
        params["exclude"] = "agent_children"
    return _walk_pages(
        params,
        lambda **kwargs: _read_timeline(client, session_id, headers, **kwargs),
        start_before=start_before,
        limit=limit,
    )


# --------------------------------------------------------------------------
# ① exclusion drops children, keeps messages and main rows whole


def test_latest_and_snapshot_exclude_agent_children_rows(tmp_path) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(
        client,
        session_id,
        [
            _row("tl_m1", message_content("hello one")),
            _row("tl_card", card_content("card a"), type="tool"),
            # Children: judged by content, not by type.
            _row("tl_c1", tool_content("Read", parent="tl_card"), type="tool"),
            _row("tl_c2", message_content("thinking", parent="tl_card")),
            _row("tl_c3", {"kind": "reasoning", "parentItemId": "tl_card"}),
            _row("tl_t1", tool_content("Bash")),
            # An empty parentItemId is not a child ("非空" boundary).
            _row("tl_empty", {"text": "not a child", "parentItemId": ""}),
            _row("tl_m2", message_content("hello two")),
        ],
    )

    expected = ["tl_m1", "tl_card", "tl_t1", "tl_empty", "tl_m2"]

    latest = _read_timeline(
        client, session_id, headers, mode="latest", limit=50, exclude="agent_children"
    )
    assert _ids(latest) == expected
    assert latest["hasMore"] is False

    snapshot = _read_snapshot_timeline(
        client, session_id, headers, limit=50, exclude="agent_children"
    )
    assert _ids(snapshot) == expected
    assert snapshot["hasMore"] is False

    # Kept rows ride whole: the card keeps its live task map, messages keep
    # their text.
    card = next(item for item in latest["items"] if item["id"] == "tl_card")
    assert card["content"]["kind"] == "agent_call"
    assert card["content"]["agents"] == {"task_a": {"status": "running"}}
    message = next(item for item in latest["items"] if item["id"] == "tl_m1")
    assert message["content"]["text"] == "hello one"

    # Sanity: without the parameter every row (children included) is there.
    unfiltered = _read_timeline(client, session_id, headers, mode="latest", limit=50)
    assert _ids(unfiltered) == [
        "tl_m1",
        "tl_card",
        "tl_c1",
        "tl_c2",
        "tl_c3",
        "tl_t1",
        "tl_empty",
        "tl_m2",
    ]


# --------------------------------------------------------------------------
# ② hasMore / cursors over the filtered collection


def test_history_exclude_walks_pages_over_child_blocks(tmp_path) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    rows = [
        _row("tl_m1", message_content("one")),
        _row("tl_card", card_content("card a"), type="tool"),
        *[
            _row(f"tl_c{index}", tool_content(f"Tool{index}", parent="tl_card"), type="tool")
            for index in range(1, 7)
        ],
        _row("tl_m2", message_content("two")),
        *[
            _row(f"tl_c{index}", tool_content(f"Tool{index}", parent="tl_card"), type="tool")
            for index in range(7, 10)
        ],
        _row("tl_t1", tool_content("Bash")),
        _row("tl_c10", message_content("tail child", parent="tl_card")),
        _row("tl_m3", message_content("three")),
    ]
    _seed_timeline(client, session_id, rows)

    pages = _walk_history(
        client, session_id, headers, start_before=len(rows) + 1, limit=2
    )
    assert [_ids(page) for page in pages] == [
        ["tl_t1", "tl_m3"],
        ["tl_card", "tl_m2"],
        ["tl_m1"],
    ]
    assert [page["hasMore"] for page in pages] == [True, True, False]


def test_exclude_scan_crosses_multiple_raw_windows(tmp_path) -> None:
    """A child block far larger than one scan window never ends the walk."""

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    rows = [
        _row("tl_m1", message_content("one")),
        *[
            _row(f"tl_c{index:02d}", tool_content(f"Tool{index}", parent="tl_card"), type="tool")
            for index in range(1, 31)
        ],
        _row("tl_m2", message_content("two")),
        *[
            _row(f"tl_d{index}", tool_content(f"More{index}", parent="tl_card"), type="tool")
            for index in range(1, 5)
        ],
        _row("tl_m3", message_content("three")),
    ]
    _seed_timeline(client, session_id, rows)

    # limit=2 scans in windows of (2+1)*4 rows, so reaching the eligible rows
    # behind the 30-child block takes several keyset windows.
    latest = _read_timeline(
        client, session_id, headers, mode="latest", limit=2, exclude="agent_children"
    )
    assert _ids(latest) == ["tl_m2", "tl_m3"]
    assert latest["hasMore"] is True

    pages = _walk_history(
        client, session_id, headers, start_before=len(rows) + 1, limit=2
    )
    assert [item for page in pages for item in _ids(page)] == ["tl_m2", "tl_m3", "tl_m1"]
    assert [page["hasMore"] for page in pages] == [True, False]


def test_filtered_page_is_never_empty_with_content_behind_it(tmp_path) -> None:
    """The "whole raw window filtered out" boundary: keep scanning, not empty."""

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(
        client,
        session_id,
        [
            *[
                _row(f"tl_c{index}", tool_content(f"Tool{index}", parent="tl_card"), type="tool")
                for index in range(1, 6)
            ],
            _row("tl_m2", message_content("two")),
            *[
                _row(f"tl_d{index}", message_content(f"note {index}", parent="tl_card"))
                for index in range(1, 4)
            ],
            _row("tl_m3", message_content("three")),
        ],
    )

    # The newest raw rows are children; a limit=1 page still returns the
    # newest eligible row, with hasMore pointing at the one behind it.
    latest = _read_timeline(
        client, session_id, headers, mode="latest", limit=1, exclude="agent_children"
    )
    assert _ids(latest) == ["tl_m3"]
    assert latest["hasMore"] is True

    pages = _walk_history(client, session_id, headers, start_before=11, limit=1)
    assert [item for page in pages for item in _ids(page)] == ["tl_m3", "tl_m2"]
    assert [page["hasMore"] for page in pages] == [True, False]


# --------------------------------------------------------------------------
# ③ page byte budget


def test_page_byte_budget_default_and_env_override(monkeypatch) -> None:
    from agent_server.api.sessions import (
        TIMELINE_PAGE_BYTE_BUDGET,
        TIMELINE_PAGE_BYTE_BUDGET_ENV,
        _timeline_page_byte_budget,
    )

    assert TIMELINE_PAGE_BYTE_BUDGET == 1024 * 1024
    monkeypatch.delenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, raising=False)
    assert _timeline_page_byte_budget() == TIMELINE_PAGE_BYTE_BUDGET
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "4096")
    assert _timeline_page_byte_budget() == 4096


def test_history_exclude_truncates_page_at_byte_budget(tmp_path, monkeypatch) -> None:
    from agent_server.api.sessions import TIMELINE_PAGE_BYTE_BUDGET_ENV

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    # Each item is well over 1KB serialized, so a 1.5KB budget keeps exactly
    # one per page.
    rows = [
        _row(f"tl_m{index}", message_content(str(index) + "x" * 700))
        for index in range(1, 7)
    ]
    _seed_timeline(client, session_id, rows)
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "1500")

    first = _read_timeline(
        client,
        session_id,
        headers,
        mode="history",
        beforeOrderSeq=len(rows) + 1,
        limit=100,
        exclude="agent_children",
    )
    assert _ids(first) == ["tl_m6"]
    assert first["hasMore"] is True
    assert sum(_item_bytes(item) for item in first["items"]) <= 1500

    # The cursor continues exactly at the first dropped row — no gap, no
    # duplicate — and the budget truncation never strands the walk.
    pages = _walk_history(
        client, session_id, headers, start_before=len(rows) + 1, limit=100
    )
    assert [item for page in pages for item in _ids(page)] == [
        "tl_m6",
        "tl_m5",
        "tl_m4",
        "tl_m3",
        "tl_m2",
        "tl_m1",
    ]
    assert [page["hasMore"] for page in pages] == [True] * 5 + [False]
    for page in pages:
        assert sum(_item_bytes(item) for item in page["items"]) <= 1500


def test_byte_budget_keeps_an_oversized_single_item_whole(tmp_path, monkeypatch) -> None:
    from agent_server.api.sessions import TIMELINE_PAGE_BYTE_BUDGET_ENV

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(
        client,
        session_id,
        [
            _row("tl_big", message_content("x" * 3000)),
            _row("tl_small", message_content("small")),
        ],
    )
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "512")

    first = _read_timeline(
        client,
        session_id,
        headers,
        mode="history",
        beforeOrderSeq=3,
        limit=100,
        exclude="agent_children",
    )
    assert _ids(first) == ["tl_small"]
    assert first["hasMore"] is True

    # The oversized row is returned whole rather than split or dropped.
    second = _read_timeline(
        client,
        session_id,
        headers,
        mode="history",
        beforeOrderSeq=first["items"][0]["orderSeq"],
        limit=100,
        exclude="agent_children",
    )
    assert _ids(second) == ["tl_big"]
    assert _item_bytes(second["items"][0]) > 512
    assert second["hasMore"] is False


def test_page_budget_does_not_touch_snapshot_or_latest(tmp_path, monkeypatch) -> None:
    """The page budget scopes to history/children pages only.

    ``mode=latest`` and the snapshot keep their own behavior: the snapshot
    still applies its separate 2MB ceiling, not the page budget.
    """

    from agent_server.api.sessions import (
        SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV,
        TIMELINE_PAGE_BYTE_BUDGET_ENV,
    )

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(
        client,
        session_id,
        [
            _row("tl_m1", message_content("one " + "x" * 900)),
            _row("tl_c1", message_content("child", parent="tl_card")),
            _row("tl_m2", message_content("two " + "x" * 900)),
            _row("tl_m3", message_content("three " + "x" * 900)),
        ],
    )
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "512")

    latest = _read_timeline(
        client, session_id, headers, mode="latest", limit=50, exclude="agent_children"
    )
    assert _ids(latest) == ["tl_m1", "tl_m2", "tl_m3"]

    snapshot = _read_snapshot_timeline(
        client, session_id, headers, limit=50, exclude="agent_children"
    )
    assert _ids(snapshot) == ["tl_m1", "tl_m2", "tl_m3"]

    # The snapshot's own byte ceiling is still the only gate on its page.
    monkeypatch.setenv(SNAPSHOT_TIMELINE_BYTE_BUDGET_ENV, "512")
    trimmed = _read_snapshot_timeline(
        client, session_id, headers, limit=50, exclude="agent_children"
    )
    assert _ids(trimmed) == ["tl_m3"]
    assert trimmed["hasMore"] is True


# --------------------------------------------------------------------------
# ④ mode=children


def _children_dataset() -> list[dict[str, Any]]:
    rows = [
        _row("tl_card_a", card_content("card a"), type="tool"),
        _row("tl_card_b", card_content("card b"), type="tool"),
    ]
    for index in range(1, 26):
        rows.append(
            _row(
                f"tl_a{index:02d}",
                message_content(f"child {index}", parent="tl_card_a"),
                type="marker" if index % 5 == 0 else "message",
            )
        )
    rows.append(_row("tl_plain", tool_content("Bash")))
    rows.append(_row("tl_b1", message_content("b child", parent="tl_card_b")))
    rows.append(_row("tl_m", message_content("main")))
    return rows


def test_children_mode_returns_only_one_parents_rows(tmp_path) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(client, session_id, _children_dataset())

    page = _read_timeline(
        client,
        session_id,
        headers,
        mode="children",
        parentId="tl_card_a",
        limit=500,
    )
    assert _ids(page) == [f"tl_a{index:02d}" for index in range(1, 26)]
    assert page["hasMore"] is False
    # Child rows keep their payload (the fold on the client reads it) and the
    # type is irrelevant to the lookup.
    marker = next(item for item in page["items"] if item["id"] == "tl_a05")
    assert marker["type"] == "marker"
    assert marker["content"]["parentItemId"] == "tl_card_a"

    other = _read_timeline(
        client,
        session_id,
        headers,
        mode="children",
        parentId="tl_card_b",
        limit=500,
    )
    assert _ids(other) == ["tl_b1"]
    assert other["hasMore"] is False

    unknown = _read_timeline(
        client,
        session_id,
        headers,
        mode="children",
        parentId="tl_not_a_card",
        limit=500,
    )
    assert unknown["items"] == []
    assert unknown["hasMore"] is False


def test_children_mode_pages_newest_to_oldest(tmp_path) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    rows = _children_dataset()
    _seed_timeline(client, session_id, rows)

    pages = _walk_pages(
        {"mode": "children", "parentId": "tl_card_a"},
        lambda **kwargs: _read_timeline(client, session_id, headers, **kwargs),
        start_before=len(rows) + 1,
        limit=3,
    )
    walked = [item for page in pages for item in _ids(page)]
    # Newest→oldest paging, oldest-first within each page: the walk starts at
    # the newest children and ends at the oldest, each row exactly once.
    assert len(walked) == len(set(walked)) == 25
    assert sorted(walked) == [f"tl_a{index:02d}" for index in range(1, 26)]
    assert _ids(pages[0]) == ["tl_a23", "tl_a24", "tl_a25"]
    assert _ids(pages[-1]) == ["tl_a01"]
    assert [page["hasMore"] for page in pages] == [True] * 8 + [False]


def test_children_mode_applies_the_page_byte_budget(tmp_path, monkeypatch) -> None:
    from agent_server.api.sessions import TIMELINE_PAGE_BYTE_BUDGET_ENV

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    _seed_timeline(
        client,
        session_id,
        [
            _row("tl_card", card_content("card"), type="tool"),
            _row("tl_c1", message_content("one " + "x" * 700, parent="tl_card")),
            _row("tl_c2", message_content("two " + "x" * 700, parent="tl_card")),
            _row("tl_c3", message_content("three " + "x" * 700, parent="tl_card")),
        ],
    )
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "1500")

    first = _read_timeline(
        client, session_id, headers, mode="children", parentId="tl_card", limit=100
    )
    assert _ids(first) == ["tl_c3"]
    assert first["hasMore"] is True
    assert sum(_item_bytes(item) for item in first["items"]) <= 1500

    pages = _walk_pages(
        {"mode": "children", "parentId": "tl_card"},
        lambda **kwargs: _read_timeline(client, session_id, headers, **kwargs),
        start_before=5,
        limit=100,
    )
    assert [item for page in pages for item in _ids(page)] == [
        "tl_c3",
        "tl_c2",
        "tl_c1",
    ]
    assert [page["hasMore"] for page in pages] == [True, True, False]


# --------------------------------------------------------------------------
# ⑤ default (no exclude) regression: byte-for-byte the legacy readers


def test_default_requests_match_legacy_readers_byte_for_byte(tmp_path, monkeypatch) -> None:
    from agent_server.api.sessions import TIMELINE_PAGE_BYTE_BUDGET_ENV

    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")
    rows = _children_dataset()
    _seed_timeline(client, session_id, rows)
    store = client.app.state.store

    # The env override is tiny; if any default path consulted the page budget
    # its page would truncate and these comparisons would fail.
    monkeypatch.setenv(TIMELINE_PAGE_BYTE_BUDGET_ENV, "256")

    async def legacy_reads() -> tuple[Any, Any, Any]:
        latest = await store.list_timeline_latest(session_id=session_id, limit=100)
        history = await store.list_timeline_before_order_seq(
            session_id=session_id,
            before_order_seq=len(rows) + 1,
            limit=100,
        )
        changes = await store.list_timeline_since(
            session_id=session_id,
            after_seq=0,
            limit=1000,
        )
        return latest, history, changes

    (latest_items, latest_more), (history_items, history_more), (changes_items, _) = (
        asyncio.run(legacy_reads())
    )

    def dumped(items: Any) -> list[dict[str, Any]]:
        return [item.model_dump(mode="json") for item in items]

    latest = _read_timeline(client, session_id, headers, mode="latest", limit=100)
    assert latest["items"] == dumped(latest_items)
    assert latest["hasMore"] is latest_more

    history = _read_timeline(
        client,
        session_id,
        headers,
        mode="history",
        beforeOrderSeq=len(rows) + 1,
        limit=100,
    )
    assert history["items"] == dumped(history_items)
    assert history["hasMore"] is history_more

    # mode=changes stays complete: children are part of the live/recovery flow.
    changes = _read_timeline(
        client, session_id, headers, mode="changes", afterSeq=0, limit=500
    )
    assert changes["items"] == dumped(changes_items)
    assert "tl_a01" in _ids(changes)

    snapshot = _read_snapshot_timeline(client, session_id, headers, limit=100)
    assert snapshot["items"] == dumped(latest_items)
    assert snapshot["hasMore"] is latest_more


# --------------------------------------------------------------------------
# ⑥ parameter validation


@pytest.mark.parametrize(
    ("params", "detail"),
    [
        ({"mode": "children"}, "parentId is required for children mode"),
        (
            {"mode": "children", "parentId": "tl_card", "exclude": "agent_children"},
            "exclude is not supported with children mode",
        ),
        (
            {"mode": "children", "parentId": "tl_card", "afterSeq": 5},
            "afterSeq is not supported with children mode",
        ),
        ({"mode": "latest", "parentId": "tl_card"}, "parentId is only supported with children mode"),
        (
            {"mode": "changes", "exclude": "agent_children"},
            "exclude is not supported with changes mode",
        ),
        ({"mode": "history"}, "beforeOrderSeq is required for history mode"),
    ],
)
def test_timeline_rejects_invalid_parameter_combinations(
    tmp_path, params: dict[str, Any], detail: str
) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")

    response = client.get(
        f"/sessions/{session_id}/timeline", headers=headers, params=params
    )
    assert response.status_code == 422, response.text
    assert detail in response.json()["detail"]


@pytest.mark.parametrize(
    "params",
    [
        {"exclude": "all"},
        {"exclude": ""},
        {"mode": "bogus"},
        {"mode": "children", "parentId": ""},
    ],
)
def test_timeline_rejects_malformed_parameters(tmp_path, params: dict[str, Any]) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")

    response = client.get(
        f"/sessions/{session_id}/timeline", headers=headers, params=params
    )
    assert response.status_code == 422, response.text


def test_snapshot_rejects_unknown_exclude_value(tmp_path) -> None:
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client, runtime="claude")

    response = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"exclude": "all"},
    )
    assert response.status_code == 422, response.text

    # The documented value passes.
    ok = client.get(
        f"/sessions/{session_id}/snapshot",
        headers=headers,
        params={"exclude": "agent_children"},
    )
    assert ok.status_code == 200, ok.text


# --------------------------------------------------------------------------
# store-level boundaries


async def _store_with_session(tmp_path: Any, name: str = "conversation.sqlite3"):
    db_path = tmp_path / name
    upgrade_database(sqlite_path=db_path)
    store = Store(db_path)
    connector, _, _ = await store.create_connector(name="dev", user_id="user_1")
    session = await create_session_with_project(
        store,
        connector_id=connector.id,
        runtime="claude",
        external_session_id="claude_ext_1",
    )
    return store, session


async def _store_seed(store: Store, session_id: str, rows: list[dict[str, Any]]) -> None:
    for row in rows:
        item_type = row.get("type", "message")
        await store.upsert_timeline_item(
            session_id=session_id,
            item=TimelineItemIn.model_validate(
                {
                    "id": row["id"],
                    "sessionId": session_id,
                    "type": item_type,
                    "status": "done",
                    "role": "tool" if item_type == "tool" else "assistant",
                    "content": row["content"],
                    "source": {
                        "runtime": "claude",
                        "sessionId": "claude_ext_1",
                        "itemId": row["id"],
                        "itemType": "agentMessage",
                    },
                    "orderSeq": 1,
                    "revision": 1,
                    "contentHash": f"sha256:{row['id']}",
                }
            ),
        )


@pytest.mark.anyio
async def test_store_filtered_reader_matches_legacy_when_no_children(tmp_path) -> None:
    """With no children the filtered reader is a drop-in for ``list_latest``."""

    store, session = await _store_with_session(tmp_path)
    try:
        rows = [
            _row(f"tl_{index}", message_content(f"item {index}"))
            for index in range(1, 6)
        ]
        await _store_seed(store, session.id, rows)

        legacy, legacy_more = await store.timeline.list_latest(
            session.id, limit=3
        )
        filtered, filtered_more = (
            await store.list_timeline_latest_excluding_agent_children(
                session_id=session.id, limit=3
            )
        )
        assert [item.id for item in filtered] == [item.id for item in legacy]
        assert filtered_more is legacy_more
        assert [item.model_dump(mode="json") for item in filtered] == [
            item.model_dump(mode="json") for item in legacy
        ]
    finally:
        await store.close()


@pytest.mark.anyio
async def test_store_filtered_reader_reports_exhaustion_behind_children(tmp_path) -> None:
    store, session = await _store_with_session(tmp_path)
    try:
        # Every raw row is a child: the filtered timeline is empty and
        # exhausted — the only shape where an empty page is allowed.
        await _store_seed(
            store,
            session.id,
            [
                _row(
                    f"tl_c{index}",
                    tool_content(f"Tool{index}", parent="tl_card"),
                    type="tool",
                )
                for index in range(1, 6)
            ],
        )

        items, has_more = await store.list_timeline_latest_excluding_agent_children(
            session_id=session.id, limit=3
        )
        assert items == []
        assert has_more is False

        items, has_more = (
            await store.list_timeline_before_order_seq_excluding_agent_children(
                session_id=session.id,
                before_order_seq=100,
                limit=3,
            )
        )
        assert items == []
        assert has_more is False
    finally:
        await store.close()


@pytest.mark.anyio
async def test_store_children_reader_is_session_scoped(tmp_path) -> None:
    store, session_a = await _store_with_session(tmp_path)
    try:
        session_b = await create_session_with_project(
            store,
            connector_id=session_a.connectorId,
            runtime="claude",
            external_session_id="claude_ext_2",
        )
        await _store_seed(
            store,
            session_a.id,
            [_row("tl_a_child", message_content("a", parent="tl_card"))],
        )
        await _store_seed(
            store,
            session_b.id,
            [_row("tl_b_child", message_content("b", parent="tl_card"))],
        )

        items, has_more = await store.list_timeline_agent_children(
            session_id=session_a.id,
            parent_item_id="tl_card",
            before_order_seq=None,
            limit=100,
        )
        assert [item.id for item in items] == ["tl_a_child"]
        assert has_more is False
    finally:
        await store.close()


def test_agent_child_predicate_is_total() -> None:
    from agent_server.core.timeline import agent_child_parent_item_id

    def item(content: Any):
        from agent_server.core.models import TimelineItem

        return TimelineItem.model_validate(
            {
                "id": "tl_x",
                "sessionId": "sess_x",
                "type": "message",
                "status": "done",
                "role": "assistant",
                "content": content,
                "source": {"runtime": "claude"},
                "orderSeq": 1,
                "revision": 1,
                "contentHash": "sha256:x",
                "updatedSeq": 1,
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
            }
        )

    assert agent_child_parent_item_id(item({"parentItemId": "tl_card"})) == "tl_card"
    assert agent_child_parent_item_id(item({"parentItemId": ""})) is None
    assert agent_child_parent_item_id(item({"parentItemId": None})) is None
    assert agent_child_parent_item_id(item({"parentItemId": 7})) is None
    assert agent_child_parent_item_id(item({})) is None
    # A content that is not a mapping is never a child row.
    assert agent_child_parent_item_id(item([1, 2, 3])) is None
    assert agent_child_parent_item_id(item("plain text content")) is None
