"""Every outbound timeline boundary slims an image tool result the same way."""

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


def _image_item(session_id: str, data: str) -> tuple[dict, list[dict]]:
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
    return (
        {
            "id": _ITEM_ID,
            "sessionId": session_id,
            "type": "tool",
            "status": "done",
            "role": "tool",
            "content": {
                "kind": "tool_result",
                "toolUseId": _ITEM_ID,
                "output": output,
                "text": output,
                "outputText": output,
                "outputPreview": output[-4000:],
                "outputLength": len(output),
                "result": result,
            },
            "source": {"runtime": "claude", "itemId": _ITEM_ID},
            "orderSeq": 1,
            "revision": 1,
            "contentHash": f"sha256:{_ITEM_ID}",
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


def _read_surface(surface: str, client, session_id: str, headers: dict) -> list[dict]:
    if surface == "timeline":
        response = client.get(f"/sessions/{session_id}/timeline", headers=headers)
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["items"]]
    if surface == "snapshot":
        response = client.get(f"/sessions/{session_id}/snapshot", headers=headers)
        assert response.status_code == 200, response.text
        return [item["content"] for item in response.json()["timeline"]["items"]]
    if surface == "detail":
        response = client.get(
            f"/sessions/{session_id}/timeline/items/{_ITEM_ID}",
            headers=headers,
        )
        assert response.status_code == 200, response.text
        return [response.json()["content"]]
    if surface == "events":
        response = client.get(f"/sessions/{session_id}/events?after=seq:0", headers=headers)
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["snapshotRequired"] is False
        # The whole recovery response — every event envelope included — stays
        # below the 3 MiB gate even though the stored row had four copies.
        assert len(response.content) < 3 * 1024 * 1024
        return [
            event["payload"]["item"]["content"]
            for event in body["events"]
            if event["payload"].get("item", {}).get("id") == _ITEM_ID
        ]
    raise AssertionError(f"unknown surface {surface!r}")


@pytest.mark.parametrize("surface", ["timeline", "snapshot", "detail", "events"])
def test_image_payload_is_slimmed_on_every_timeline_egress(tmp_path, surface) -> None:
    client = make_client(tmp_path)
    _, access_token, session_id, headers = create_connector_and_session(
        client, runtime="claude"
    )
    item, result = _image_item(session_id, _png_base64())
    _ingest(client, access_token, session_id, item)

    contents = _read_surface(surface, client, session_id, headers)

    assert len(contents) == 1
    _assert_slim(contents[0], result)


def test_public_share_read_is_slimmed_without_touching_the_snapshot(tmp_path) -> None:
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
