"""A resend of rows the Server never received must keep chain order.

The Connector re-publishes its live store when it restarts (or drops the
socket) so rows the Server missed are not lost. Those rows already have a
chain position, but the plain merge path can only append an unseen row after
``max(orderSeq)`` — a missed old message then renders after newer ones.

This is the 2026-11-10 production incident: three assistant message groups
were appended at the tail at 03:51, and the 03:53 history rebuild did not
move them back. The tests below drive the real Connector host into the real
Server app and a real PostgreSQL database, so the batch shape, the merge
rules and the chain plan are all exercised end to end.
"""

from __future__ import annotations

import sys
from pathlib import Path

from test_backend_mvp import create_connector_and_session, make_client

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "connector"))

from connector.runtime_protocol import (
    MarkdownMessageContent,
    MessageTimelineItem,
    TimelineSource,
)
from connector.server.runtime_host import ConnectorRuntimeHost
from connector.server.runtime_rpc_payloads import server_payload_without_turn_data


def _item(item_id: str, *, text: str | None = None) -> MessageTimelineItem:
    return MessageTimelineItem(
        id=item_id,
        type="message",
        status="done",
        role="assistant",
        content=MarkdownMessageContent(text=text or f"body {item_id}"),
        source=TimelineSource(runtime="codex", native_item_id=f"native-{item_id}"),
    )


def _ordered_ids(client, session_id: str, headers) -> list[str]:
    response = client.get(f"/sessions/{session_id}/snapshot?limit=100", headers=headers)
    assert response.status_code == 200, response.text
    items = response.json()["timeline"]["items"]
    return [item["id"] for item in sorted(items, key=lambda item: item["orderSeq"])]


def _make_sender(client, access_token: str):
    connector_headers = {"Authorization": f"Bearer {access_token}"}

    async def send(method, params):
        if method != "session.turnEnded":
            params = server_payload_without_turn_data(params)
        response = client.post(
            "/connector/ingest",
            headers=connector_headers,
            json={"notifications": [{"method": method, "params": params}]},
        )
        assert response.status_code == 200, response.text
        assert response.json()["rejected"] == []

    async def download(*_args):
        raise AssertionError("the order tests need no file service")

    return send, download


def _sync(client, session_id, send, download, items, metadata, order_seqs):
    import asyncio

    host = ConnectorRuntimeHost(
        "test", send, download, defer_payload_projection=True
    )

    async def run():
        await host.timeline_sync(
            session_id,
            "codex",
            tuple(
                item.to_platform_item(session_id, order_seq)
                for item, order_seq in zip(items, order_seqs, strict=True)
            ),
            metadata=metadata,
        )

    asyncio.run(run())


def test_missed_group_resend_without_window_order_is_appended_at_the_tail(tmp_path):
    """Reproduces the production symptom end to end."""

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)
        chain = [_item(f"m{i}") for i in range(1, 6)]

        # The Server receives the chain with m3 missing (it never reached it).
        _sync(
            client,
            session_id,
            send,
            download,
            [chain[0], chain[1], chain[3], chain[4]],
            {"source": "test.seed"},
            [1, 2, 4, 5],
        )
        assert _ordered_ids(client, session_id, headers) == ["m1", "m2", "m4", "m5"]

        # The Connector restarts and re-publishes its live store. The missed
        # row carries its real chain slot (3), which is below the Server max.
        _sync(
            client,
            session_id,
            send,
            download,
            [chain[2]],
            {"source": "claude.session.local", "marker": "1"},
            [3],
        )
        # BUG: m3 is appended after the rows that belong later in the chain.
        assert _ordered_ids(client, session_id, headers) == ["m1", "m2", "m4", "m5", "m3"]


def test_whole_store_resend_with_window_order_lands_in_chain_order(tmp_path):
    """The fix: the live-store resend carries chain authority for its rows.

    That is the shape the Connector actually sends (``ClaudeSessionStore``
    snapshot — the whole store, so the batch contains the stored neighbours
    that anchor a missed row). A batch that names *only* the missed row cannot
    be placed and is appended with a warning instead.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)
        chain = [_item(f"m{i}") for i in range(1, 6)]

        _sync(
            client,
            session_id,
            send,
            download,
            [chain[0], chain[1], chain[3], chain[4]],
            {"source": "test.seed"},
            [1, 2, 4, 5],
        )
        _sync(
            client,
            session_id,
            send,
            download,
            chain,
            {"source": "claude.session.local", "marker": "1", "windowOrder": True},
            [1, 2, 3, 4, 5],
        )
        assert _ordered_ids(client, session_id, headers) == ["m1", "m2", "m3", "m4", "m5"]


def test_rebased_rebuild_does_not_reposition_an_existing_row(tmp_path):
    """Boundary: a rebuild places rows it adds, not rows that already exist.

    Once an old row was appended at the tail by a plain resend, a later rebuild
    cannot move it without rewriting stored order (forbidden by the insert-only
    contract). The production repair path is the resend itself
    (``windowOrder``), not a retroactive rebuild; the fixed resend test above
    covers it.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)
        chain = [_item(f"m{i}") for i in range(1, 6)]

        _sync(
            client,
            session_id,
            send,
            download,
            [chain[0], chain[1], chain[3], chain[4]],
            {"source": "test.seed"},
            [1, 2, 4, 5],
        )
        _sync(
            client,
            session_id,
            send,
            download,
            [chain[2]],
            {"source": "claude.session.local", "marker": "1"},
            [3],
        )
        assert _ordered_ids(client, session_id, headers)[-1] == "m3"

        _sync(
            client,
            session_id,
            send,
            download,
            chain,
            {"source": "claude.history.sync", "rebased": True},
            [1, 2, 3, 4, 5],
        )
        assert _ordered_ids(client, session_id, headers) == [
            "m1",
            "m2",
            "m4",
            "m5",
            "m3",
        ]


def test_skewed_stored_anchors_append_without_rewriting_stored_order(tmp_path):
    """Boundary: a batch whose stored anchors contradict it must not fail.

    The Connector's chain order can disagree with rows already stored — that
    is the incident's symptom itself. Placing the run between the anchors would
    rewrite a stored row, so the plan appends it and the request still succeeds.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)
        a, b = _item("a"), _item("b")

        _sync(
            client,
            session_id,
            send,
            download,
            [a, b],
            {"source": "test.seed"},
            [1, 2],
        )
        assert _ordered_ids(client, session_id, headers) == ["a", "b"]

        # The chain claims b precedes a — the opposite of the stored order.
        x = _item("x")
        _sync(
            client,
            session_id,
            send,
            download,
            [b, x, a],
            {"source": "claude.session.local", "marker": "1", "windowOrder": True},
            [2, 3, 1],
        )
        assert _ordered_ids(client, session_id, headers) == ["a", "b", "x"]


def test_rebased_build_places_a_new_row_and_leaves_stored_rows_alone(tmp_path):
    """A rebuild adds the row it alone knows; stored rows keep their numbers.

    ``platform`` is a platform-only row (subagent/turn bookkeeping) the history
    chain cannot see. The old plan renumbered it when a chain row moved; the
    insert-only plan only inserts and never touches a stored row.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)
        m_a, m_b = _item("m_a"), _item("m_b")
        platform = _item("platform")

        _sync(
            client,
            session_id,
            send,
            download,
            [m_a, platform, m_b],
            {"source": "test.seed"},
            [10, 11, 12],
        )
        assert _ordered_ids(client, session_id, headers) == ["m_a", "platform", "m_b"]

        # The rebuild adds a row the Server never had, before the stored chain.
        m_new = _item("m_new")
        _sync(
            client,
            session_id,
            send,
            download,
            [m_new, m_a, m_b],
            {"source": "claude.history.sync", "rebased": True},
            [1, 2, 3],
        )
        assert _ordered_ids(client, session_id, headers) == [
            "m_new",
            "m_a",
            "platform",
            "m_b",
        ]
        timeline = client.get(
            f"/sessions/{session_id}/snapshot?limit=100", headers=headers
        ).json()["timeline"]["items"]
        by_id = {item["id"]: item["orderSeq"] for item in timeline}
        assert by_id["platform"] == 11
        assert by_id["m_a"] == 10
        assert by_id["m_b"] == 12


def test_production_shape_resend_inserts_the_three_groups_before_their_anchors(
    tmp_path,
):
    """The 2026-11-10 session's real occupancy and anchors, end to end.

    The Server already held rows inside every gap (the middle gap's real
    occupancy 2888-2897 is seeded here; 2893/2894/2898 were the only free
    integers). The whole-store resend carries ``windowOrder``; the middle
    group has no three consecutive free integers, so the plan renumbers that
    small block and inserts the group before 3592 instead of appending it.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        send, download = _make_sender(client, access_token)

        lower_c = _item("lower_c")
        anchor_c = _item("anchor_c")  # msg_740f7910
        lower_56 = _item("lower_56")
        anchor_56 = _item("anchor_56")  # msg_3592fd8f
        lower_39 = _item("lower_39")
        anchor_39 = _item("anchor_39")  # msg_4530c6dd
        real56 = [
            ("occ2888", 2888), ("occ2889", 2889), ("occ2890", 2890),
            ("occ2891", 2891), ("occ2892", 2892), ("occ2895", 2895),
            ("occ2896", 2896), ("occ2897", 2897),
        ]
        seed = [lower_c, anchor_c, lower_56]
        seed_orders = [2801, 2872, 2887]
        for item_id, order_seq in real56:
            seed.append(_item(item_id))
            seed_orders.append(order_seq)
        seed.extend([anchor_56, lower_39, anchor_39])
        seed_orders.extend([2899, 2953, 3017])
        _sync(
            client,
            session_id,
            send,
            download,
            seed,
            {"source": "test.seed"},
            seed_orders,
        )

        def group(prefix: str) -> list:
            return [_item(f"{prefix}_system"), _item(f"{prefix}_body"),
                    _item(f"{prefix}_tool")]

        c263, g565, g399 = group("c263"), group("565"), group("399")
        resend = [
            lower_c, *c263, anchor_c, lower_56, *g565, anchor_56,
            lower_39, *g399, anchor_39,
        ]
        _sync(
            client,
            session_id,
            send,
            download,
            resend,
            {"source": "claude.session.local", "marker": "1", "windowOrder": True},
            list(range(1, len(resend) + 1)),
        )

        ordered = _ordered_ids(client, session_id, headers)
        for group_prefix, anchor in (
            ("c263", "anchor_c"),
            ("565", "anchor_56"),
            ("399", "anchor_39"),
        ):
            assert ordered.index(f"{group_prefix}_system") < ordered.index(anchor)
            assert ordered.index(f"{group_prefix}_body") < ordered.index(anchor)
            assert ordered.index(f"{group_prefix}_tool") < ordered.index(anchor)
        # The middle block was renumbered but its relative order is intact.
        assert ordered.index("occ2888") < ordered.index("occ2897")
        assert ordered.index("occ2897") < ordered.index("anchor_56")

