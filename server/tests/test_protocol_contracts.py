from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from agent_server.core.models import TimelineItem
from agent_server.core.protocol import (
    ProtocolCapabilitySet,
    ProtocolEventEnvelope,
    ProtocolModelCatalog,
    ProtocolPermissionCatalog,
    ProtocolSessionSnapshotResponse,
    ProtocolTimelineResponse,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = REPOSITORY_ROOT / "contracts" / "protocol" / "1.0"
SCHEMA_DIR = CONTRACT_DIR / "schemas"

# The fields every timeline item must carry on the wire, from the published
# contract (``session-snapshot-response.schema.json`` -> ``TimelineItem.required``).
# ``orderSeq`` is the client's only ordering truth: the iOS decoder used to
# silently fall back to ``updatedSeq`` when it went missing, and ``updatedSeq``
# runs the opposite way for a message's reasoning rows — the exact "reasoning
# below its body" defect the v2_42 server fix removed (2026-10-14). This is the
# source-side half of that guard: no serialization path may ever drop the field.
TIMELINE_ITEM_REQUIRED_FIELDS = frozenset(
    {
        "id",
        "sessionId",
        "type",
        "status",
        "source",
        "orderSeq",
        "contentHash",
        "createdAt",
        "updatedAt",
        "updatedSeq",
    }
)

FIXTURE_MODELS = {
    "capability-set": ProtocolCapabilitySet,
    "event-envelope": ProtocolEventEnvelope,
    "model-catalog": ProtocolModelCatalog,
    "permission-catalog": ProtocolPermissionCatalog,
}


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def _fixture_paths(kind: str) -> list[Path]:
    return sorted((CONTRACT_DIR / "fixtures" / kind).glob("*/*.json"))


def test_protocol_contract_artifacts_are_fresh(tmp_path: Path) -> None:
    generated_dir = tmp_path / "1.0"
    subprocess.run(
        [
            sys.executable,
            "-m",
            "scripts.export_protocol_schemas",
            "--output",
            str(generated_dir),
        ],
        cwd=REPOSITORY_ROOT / "server",
        check=True,
    )

    expected_files = sorted(
        path.relative_to(CONTRACT_DIR)
        for path in CONTRACT_DIR.glob("schemas/*.schema.json")
    )
    generated_files = sorted(
        path.relative_to(generated_dir)
        for path in generated_dir.glob("schemas/*.schema.json")
    )
    assert generated_files == expected_files
    for relative_path in [Path("manifest.json"), *expected_files]:
        assert (generated_dir / relative_path).read_bytes() == (
            CONTRACT_DIR / relative_path
        ).read_bytes()


@pytest.mark.parametrize(
    "schema_path",
    sorted(SCHEMA_DIR.glob("*.schema.json")),
    ids=lambda path: path.stem.removesuffix(".schema"),
)
def test_protocol_contract_schema_is_valid(schema_path: Path) -> None:
    Draft202012Validator.check_schema(_load_json(schema_path))


@pytest.mark.parametrize(
    "fixture_path",
    _fixture_paths("valid"),
    ids=lambda path: f"{path.parent.name}/{path.stem}",
)
def test_valid_protocol_fixtures_match_schema_and_server_model(
    fixture_path: Path,
) -> None:
    slug = fixture_path.parent.name
    payload = _load_json(fixture_path)
    Draft202012Validator(
        _load_json(SCHEMA_DIR / f"{slug}.schema.json")
    ).validate(payload)

    model = FIXTURE_MODELS[slug].model_validate(payload)
    assert model.model_dump(mode="json") == payload


@pytest.mark.parametrize(
    "fixture_path",
    _fixture_paths("invalid"),
    ids=lambda path: f"{path.parent.name}/{path.stem}",
)
def test_invalid_protocol_fixtures_are_rejected(fixture_path: Path) -> None:
    slug = fixture_path.parent.name
    validator = Draft202012Validator(
        _load_json(SCHEMA_DIR / f"{slug}.schema.json")
    )
    assert not validator.is_valid(_load_json(fixture_path))


def _wire_timeline_item(item_id: str = "item_1", *, order_seq: int = 7) -> TimelineItem:
    return TimelineItem.model_validate(
        {
            "id": item_id,
            "sessionId": "sess_1",
            "type": "message",
            "status": "done",
            "role": "assistant",
            "content": {"text": "hi", "format": "markdown"},
            "source": {"runtime": "codex", "itemId": item_id},
            "orderSeq": order_seq,
            "revision": 1,
            "contentHash": f"sha256:{item_id}",
            "updatedSeq": 42,
            "createdAt": "2026-08-13T00:00:00Z",
            "updatedAt": "2026-08-13T00:00:00Z",
        }
    )


def test_snapshot_schema_requires_the_ordering_truth() -> None:
    """The published contract must keep ``orderSeq`` required.

    ``orderSeq`` is the only ordering truth the client sorts on; the contract
    making it required is what lets the client trust it. If a future edit drops
    it from ``required`` (or drops the field entirely), the silent-degradation
    door reopens — so pin the schema itself, not just the model.
    """

    schema = _load_json(SCHEMA_DIR / "session-snapshot-response.schema.json")
    timeline_item = schema["$defs"]["TimelineItem"]
    assert "orderSeq" in timeline_item["required"], (
        "orderSeq is the client's only ordering truth and must stay required "
        "in the published contract"
    )
    assert "orderSeq" in timeline_item["properties"]


@pytest.mark.parametrize(
    "model",
    [ProtocolTimelineResponse, ProtocolSessionSnapshotResponse],
    ids=["timeline-response", "session-snapshot-response"],
)
def test_snapshot_serialization_never_drops_a_required_timeline_field(model) -> None:
    """No HTTP snapshot/timeline path may serialize an item missing a required field.

    Guards the response-model serialization (``model_dump(mode="json")``) that
    actually feeds the wire: a future ``exclude=`` or a narrowed item model that
    dropped ``orderSeq`` would be caught here rather than on a client screen.
    """

    item = _wire_timeline_item()
    if model is ProtocolTimelineResponse:
        response = model(sessionId="sess_1", items=[item], nextSeq=42, serverTime="t")
    else:
        snapshot = model.model_validate(
            {
                "session": _minimal_session_view(),
                "timeline": {"items": [item], "nextSeq": 42, "hasMore": False},
                "effectiveCapabilities": {"revision": 1, "capabilities": []},
                "runtimeCapabilities": {"revision": 1, "capabilities": []},
                "eventCursor": "seq:42",
                "serverTime": "t",
            }
        )
        response = snapshot

    serialized = response.model_dump(mode="json", by_alias=True)
    items = _items_from_serialized(response, serialized)
    assert items, "the response must carry the timeline item it was built with"
    for serialized_item in items:
        missing = TIMELINE_ITEM_REQUIRED_FIELDS - set(serialized_item)
        assert not missing, f"serialized timeline item is missing {sorted(missing)}"


def test_ws_timeline_item_serialization_never_drops_a_required_field() -> None:
    """The WS live path (``item.model_dump``) must keep every required field.

    ``timeline_write_buffer`` publishes items with
    ``item.model_dump(mode="json")``; this pins that the produced event payload
    carries ``orderSeq`` so a live frame can never desync a client that sorts on it.
    """

    from agent_server.core.events import timeline_events_from_items

    item = _wire_timeline_item()
    events = timeline_events_from_items("sess_1", [item.model_dump(mode="json")])
    assert len(events) == 1
    payload_item = events[0].payload["item"]
    missing = TIMELINE_ITEM_REQUIRED_FIELDS - set(payload_item)
    assert not missing, f"WS timeline item is missing {sorted(missing)}"


def _items_from_serialized(response, serialized: dict) -> list[dict]:
    if isinstance(response, ProtocolTimelineResponse):
        return serialized["items"]
    return serialized["timeline"]["items"]


def _minimal_session_view() -> dict:
    return {
        "id": "sess_1",
        "connectorId": "conn_1",
        "connectorStatus": "online",
        "runtime": "codex",
        "status": "idle",
        "takeover": False,
        "updatedSeq": 42,
    }
