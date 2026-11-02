"""HTTP timeline surfaces slim an image tool result the same way.

Covers latest / history / changes / children / item detail / snapshot
(including ``activeAgents``) / public share, plus the recovery ``/events``
envelope and the ``AA_TIMELINE_SLIM=0`` rollback. The live-envelope surfaces
(``ws.live`` / ``ws.revision`` / ``ws.flush`` / ``ws.ingest``) are covered in
``test_timeline_write_buffer.py``.

The deferred-window branch cannot be observed here: its stub rows drop
``result`` and ``output`` before normalization, so the call there is defensive
and would need a stub-format change to become testable.
"""

from __future__ import annotations

import base64
import json

import pytest

from test_backend_mvp import create_connector_and_session, make_client

_ITEM_ID = "tl_image_1"


def _png_base64(*, width: int = 1170, height: int = 4100, padding: int = 200_000) -> str:
    header = (
        b"\x89PNG\r\n\x1a\n"
        + (13).to_bytes(4, "big")
        + b"IHDR"
        + width.to_bytes(4, "big")
        + height.to_bytes(4, "big")
        + bytes([8, 6, 0, 0, 0])
        + b"\x00\x00\x00\x00"
    )
    return base64.b64encode(header + b"\x00" * padding).decode("ascii")


def _image_item(
    session_id: str,
    data: str,
    *,
    item_id: str = _ITEM_ID,
    parent_item_id: str | None = None,
    status: str = "done",
    kind: str = "tool_result",
) -> tuple[dict, list[dict]]:
    result = [
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/png",
                "data": data,
            },
        }
    ]
    output = json.dumps(
        result,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    content = {
        "kind": kind,
        "toolUseId": item_id,
        "output": output,
        "text": output,
        "outputText": output,
        "outputPreview": output[-4000:],
        "outputLength": len(output),
        "result": result,
    }
    if parent_item_id is not None:
        content["parentItemId"] = parent_item_id
    return (
        {
            "id": item_id,
            "sessionId": session_id,
            "type": "tool",
            "status": status,
            "role": "tool",
            "content": content,
            "source": {"runtime": "claude", "itemId": item_id},
            "orderSeq": 1,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
        },
        result,
    )


def _ingest(client, access_token: str, session_id: str, item: dict) -> None:
    response = client.post(
        "/connector/ingest",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "notifications": [
                {
                    "method": "timeline.sync",
                    "params": {
                        "sessionId": session_id,
                        "externalSessionId": "native",
                        "items": [item],
                        "complete": False,
                    },
                }
            ]
        },
    )
    assert response.status_code == 200, response.text
    assert response.json().get("rejected", []) == []


def _assert_slim(content: dict, result: list[dict]) -> None:
    assert content["result"] == result
    assert content["output"].startswith("[Image] PNG · 1170×4100 · ")
    assert "base64" not in content["output"]
    assert content["outputPreview"] == content["output"]
    assert content["outputLength"] == len(content["output"])
    assert "text" not in content
    assert "outputText" not in content


def _read_surface(
    surface: str,
    client,
    session_id: str,
    headers: dict,
    item_id: str = _ITEM_ID,
) -> list[dict]:
    if surface == "timeline":
        response = client.get(f"/sessions/{session_id}/timeline", headers=headers)
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["items"]]
    if surface == "history":
        response = client.get(
            f"/sessions/{session_id}/timeline?mode=history&beforeOrderSeq=1000",
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["items"]]
    if surface == "changes":
        response = client.get(
            f"/sessions/{session_id}/timeline?mode=changes&afterSeq=0",
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["items"]]
    if surface == "children":
        response = client.get(
            f"/sessions/{session_id}/timeline?mode=children&parentItemId=parent-1",
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["items"]]
    if surface == "snapshot":
        response = client.get(f"/sessions/{session_id}/snapshot", headers=headers)
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["timeline"]["items"]]
    if surface == "detail":
        response = client.get(
            f"/sessions/{session_id}/timeline/items/{item_id}",
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return [response.json()["content"]]
    if surface == "events":
        response = client.get(f"/sessions/{session_id}/events?after=seq:0", headers=headers)
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["snapshotRequired"] is False
        return [
            event["payload"]["item"]["content"]
            for event in body["events"]
            if event["payload"].get("item", {}).get("id") == item_id
        ]
    raise AssertionError(f"unknown surface {surface!r}")


@pytest.mark.parametrize(
    "surface",
    ["timeline", "history", "changes", "children", "snapshot", "detail", "events"],
)
def test_image_payload_is_slimmed_on_every_timeline_egress(tmp_path, surface) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    item_kwargs = {"parent_item_id": "parent-1"} if surface == "children" else {}
    item, result = _image_item(session_id, _png_base64(), **item_kwargs)
    _ingest(client, access_token, session_id, item)

    contents = _read_surface(surface, client, session_id, headers)

    assert len(contents) == 1
    _assert_slim(contents[0], result)


def test_snapshot_active_agents_are_slimmed(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    item, result = _image_item(
        session_id,
        _png_base64(),
        item_id="active_agent_1",
        status="running",
        kind="agent_call",
    )
    item["content"]["agents"] = {"task_a": {"status": "running"}}
    _ingest(client, access_token, session_id, item)

    response = client.get(f"/sessions/{session_id}/snapshot", headers=headers)
    assert response.status_code == 200, response.text
    active = [
        entry
        for entry in response.json()["activeAgents"]
        if entry["id"] == "active_agent_1"
    ]
    assert len(active) == 1
    _assert_slim(active[0]["content"], result)


def test_events_normalize_before_the_three_mib_gate(tmp_path) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    # Four copies of ~1.2 MB would be ~4.8 MB unnormalized. The normalized
    # response must pass the 3 MiB gate without a snapshot.
    item, result = _image_item(session_id, _png_base64(padding=900_000))
    _ingest(client, access_token, session_id, item)

    response = client.get(f"/sessions/{session_id}/events?after=seq:0", headers=headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["snapshotRequired"] is False
    assert len(response.content) < 3 * 1024 * 1024
    contents = [
        event["payload"]["item"]["content"]
        for event in body["events"]
        if event["payload"].get("item", {}).get("id") == _ITEM_ID
    ]
    assert len(contents) == 1
    _assert_slim(contents[0], result)


def test_rollback_switch_leaves_the_payload_untouched(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("AA_TIMELINE_SLIM", "0")
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    item, _result = _image_item(session_id, _png_base64())
    _ingest(client, access_token, session_id, item)

    response = client.get(f"/sessions/{session_id}/timeline", headers=headers)
    assert response.status_code == 200, response.text
    content = response.json()["items"][0]["content"]

    assert content["output"] == item["content"]["output"]
    assert content["text"] == item["content"]["output"]
    assert content["outputText"] == item["content"]["output"]


def test_public_share_read_is_slimmed(tmp_path) -> None:
    # Storage invariance is asserted where the stored row is readable
    # (test_timeline_write_buffer.py); this only covers the read surface.
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    item, result = _image_item(session_id, _png_base64())
    _ingest(client, access_token, session_id, item)

    created = client.post(
        f"/sessions/{session_id}/shares",
        headers=headers,
        json={"scope": "session", "itemIds": []},
    )
    assert created.status_code == 201, created.text
    share_id = created.json()["shareId"]

    # ``/public`` is not one of the test client's auto-prefixed API roots.
    public = client.get(f"/api/v2/public/shares/{share_id}")
    assert public.status_code == 200, public.text
    contents = [item["content"] for item in public.json()["items"]]
    assert len(contents) == 1
    _assert_slim(contents[0], result)
