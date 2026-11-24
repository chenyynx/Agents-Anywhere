"""The session's durable last-ended-turn id (``latestTurnId``).

The footer's "this turn is over" fact must survive a restart, a stale runtime
state and a scheduled turn whose live id was re-keyed by the history rebuild.
The server stores the Runtime's own id from two writers:

* the live ``session.turnEnded`` notification, which also bumps the unread /
  usage watermark, and
* the connector's history/settle sync, which only fills the id and must not
  fabricate unread or usage facts.
"""

from __future__ import annotations

from test_backend_mvp import (
    create_connector_and_session,
    make_client,
    receive_session_ws_event,
    ws_ticket,
)


def _ingest(client, access_token: str, notifications: list[dict]) -> dict:
    return client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={"notifications": notifications},
    ).json()


def _meta(client, session_id: str, headers: dict[str, str]) -> dict:
    response = client.get(f"/sessions/{session_id}/meta", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()["session"]


def test_turn_end_persists_the_declared_turn_id_and_a_bare_end_keeps_it(
    tmp_path,
) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_native_1",
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        assert body["rejected"] == []
        session = _meta(client, session_id, headers)
        assert session["latestTurnId"] == "turn_native_1"
        assert session["latestTurnEndSeq"] > 0
        # The snapshot uses the protocol SessionView (a second copy of the
        # model); it must expose the field too, or iOS never sees it on open.
        snapshot = client.get(
            f"/sessions/{session_id}/snapshot", headers=headers
        )
        assert snapshot.status_code == 200, snapshot.text
        assert snapshot.json()["session"]["latestTurnId"] == "turn_native_1"
        # The list route serializes the same model; a stale list response must
        # not omit the field either.
        listed = client.get("/sessions", headers=headers)
        assert listed.status_code == 200, listed.text
        row = next(
            item
            for item in listed.json()["sessions"]
            if item["id"] == session_id
        )
        assert row["latestTurnId"] == "turn_native_1"

        # An old connector (or a runtime that declares no turn id) still sends
        # a valid turn end. It must not clear the id a newer writer stored.
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "interrupted",
                    },
                }
            ],
        )
        assert body["rejected"] == []
        session = _meta(client, session_id, headers)
        assert session["latestTurnId"] == "turn_native_1"


def test_timeline_sync_seeds_the_last_turn_id_without_unread_or_seq(
    tmp_path,
) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        before = _meta(client, session_id, headers)

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {
                            "source": "test.history.sync",
                            "lastTurnId": "turn_from_history",
                        },
                    },
                }
            ],
        )
        assert body["rejected"] == []
        after = _meta(client, session_id, headers)
        assert after["latestTurnId"] == "turn_from_history"
        # A history pass must not manufacture a live turn-end fact.
        assert after["latestTurnEndSeq"] == before["latestTurnEndSeq"]
        assert after["unread"] == before["unread"]

        # Re-sending the same value is a no-op: no revision, no extra frame.
        _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {"lastTurnId": "turn_from_history"},
                    },
                }
            ],
        )
        again = _meta(client, session_id, headers)
        assert again["latestTurnId"] == "turn_from_history"
        assert again["updatedSeq"] == after["updatedSeq"]


def test_history_sync_replaces_a_live_scheduled_turn_id(tmp_path) -> None:
    """The settle sync is the authority after a scheduled turn re-key.

    Claude's live scheduled turn can keep a provisional id when its anchor
    arrives after rows were published; the transcript rebuild re-keys the rows
    to the deterministic id. The sync must replace the stored live id (the
    footer compares against the rebuilt row id), while leaving the live
    turn-end seq and unread untouched.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_claude_provisional",
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        live = _meta(client, session_id, headers)
        assert live["latestTurnId"] == "turn_claude_provisional"

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {
                            "lastTurnId": "turn_claude_rebuilt",
                            "baseTurnId": "turn_claude_provisional",
                        },
                    },
                }
            ],
        )
        assert body["rejected"] == []
        rebuilt = _meta(client, session_id, headers)
        assert rebuilt["latestTurnId"] == "turn_claude_rebuilt"
        assert rebuilt["latestTurnEndSeq"] == live["latestTurnEndSeq"]
        assert rebuilt["unread"] == live["unread"]


def test_a_late_older_sync_cannot_replace_a_newer_live_turn(tmp_path) -> None:
    """A settle for turn N arriving after N+1 ended must not regress the id.

    The sync has no base (or a base that is not the stored turn); replacing
    the newer live id would suppress N+1's footer until its own settle.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_live_new",
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        live = _meta(client, session_id, headers)

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {"lastTurnId": "turn_old"},
                    },
                }
            ],
        )
        assert body["rejected"] == []
        assert _meta(client, session_id, headers)["latestTurnId"] == "turn_live_new"

        # Even a base that names the older turn cannot replace the newer id.
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {
                            "lastTurnId": "turn_old",
                            "baseTurnId": "turn_older_still",
                        },
                    },
                }
            ],
        )
        assert body["rejected"] == []
        after = _meta(client, session_id, headers)
        assert after["latestTurnId"] == "turn_live_new"
        assert after["updatedSeq"] == live["updatedSeq"]


def test_a_rebased_full_chain_sync_may_replace_the_stored_id(tmp_path) -> None:
    """The first sync after a connector restart is authoritative.

    It has no settle base, but it read the whole chain; a stored live id from
    before the restart may be the provisional one a scheduled turn kept.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_live_provisional",
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {
                            "lastTurnId": "turn_rebuilt",
                            "rebased": True,
                        },
                    },
                }
            ],
        )
        assert body["rejected"] == []
        assert _meta(client, session_id, headers)["latestTurnId"] == "turn_rebuilt"


def test_a_rebased_sync_with_a_base_still_must_match_the_stored_id(tmp_path) -> None:
    """A base that does not name the stored turn is not a same-turn re-key.

    The provisional anchor sync carries ``baseTurnId`` so a restart can repair
    the id; ``rebased`` must not bypass that proof and overwrite a newer live
    turn.
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_live_new",
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {
                            "lastTurnId": "turn_old",
                            "baseTurnId": "turn_other",
                            "rebased": True,
                        },
                    },
                }
            ],
        )
        assert body["rejected"] == []
        assert _meta(client, session_id, headers)["latestTurnId"] == "turn_live_new"


def test_timeline_sync_pushes_the_session_meta_when_only_the_turn_id_changes(
    tmp_path,
) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        ticket = ws_ticket(client, session_id, headers)
        with client.websocket_connect(
            f"/sessions/{session_id}/ws?ticket={ticket}"
        ) as ws:
            assert ws.receive_json()["type"] == "session.subscribed"
            body = _ingest(
                client,
                access_token,
                [
                    {
                        "method": "timeline.sync",
                        "params": {
                            "sessionId": session_id,
                            "runtime": "codex",
                            "items": [],
                            "complete": False,
                            "metadata": {"lastTurnId": "turn_ws"},
                        },
                    }
                ],
            )
            assert body["rejected"] == []
            event = receive_session_ws_event(
                ws, event_type="session.meta.updated"
            )
            assert event["payload"]["session"]["latestTurnId"] == "turn_ws"


def test_timeline_sync_rejects_a_non_string_last_turn_id(tmp_path) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, _ = create_connector_and_session(client)

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "items": [],
                        "complete": False,
                        "metadata": {"lastTurnId": 123},
                    },
                }
            ],
        )
        assert body["rejected"]
        assert body["rejected"][0]["code"] == "invalid_last_turn_id"


def test_turn_end_from_a_connector_without_the_contract_does_not_store_the_id(
    tmp_path,
) -> None:
    """A 2.2.0 Connector sends the live id but never the settle ``lastTurnId``.

    Storing it would leave a scheduled/command re-key with no writer able to
    repair it. The live turn end itself must still count (unread/end seq).
    """

    with make_client(tmp_path) as client:
        _, access_token, session_id, headers = create_connector_and_session(client)
        before = _meta(client, session_id, headers)
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "codex",
                        "outcome": "completed",
                        "turnId": "turn_from_old_connector",
                    },
                }
            ],
        )
        assert body["rejected"] == []
        after = _meta(client, session_id, headers)
        assert after["latestTurnId"] is None
        assert after["latestTurnEndSeq"] > before["latestTurnEndSeq"]


def test_turn_ids_are_length_bounded(tmp_path) -> None:
    with make_client(tmp_path) as client:
        _, access_token, session_id, _ = create_connector_and_session(client)
        oversized = "t" * 257
        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "session.turnEnded",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "claude",
                        "outcome": "completed",
                        "turnId": oversized,
                        "turnEndContract": 1,
                    },
                }
            ],
        )
        assert body["rejected"]
        assert body["rejected"][0]["code"] == "invalid_turn_id"

        body = _ingest(
            client,
            access_token,
            [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "runtime": "claude",
                        "items": [],
                        "complete": False,
                        "metadata": {"lastTurnId": oversized},
                    },
                }
            ],
        )
        assert body["rejected"]
        assert body["rejected"][0]["code"] == "invalid_last_turn_id"
