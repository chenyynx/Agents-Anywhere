from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

ROOT = Path(__file__).resolve().parents[2] / "contracts" / "phone-bridge" / "1.0"


def _load(name: str) -> dict:
    return json.loads((ROOT / name).read_text(encoding="utf-8"))


def _fixture(path: str) -> dict:
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def _validate(schema: dict, definition: str, instance: dict) -> None:
    wrapper = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$defs": schema["$defs"],
        "$ref": f"#/$defs/{definition}",
    }
    Draft202012Validator(wrapper).validate(instance)


@pytest.mark.parametrize(
    ("fixture", "definition"),
    [
        ("fixtures/valid/bridge-request.json", "BridgeRequest"),
        ("fixtures/valid/bridge-response.json", "BridgeResponse"),
        ("fixtures/valid/devices.json", "DeviceList"),
    ],
)
def test_http_fixtures_validate(fixture, definition):
    _validate(_load("http.schema.json"), definition, _fixture(fixture))


@pytest.mark.parametrize(
    ("fixture", "definition"),
    [
        ("fixtures/valid/hello.json", "PhoneHello"),
        ("fixtures/valid/open.json", "ServerToPhoneOpen"),
        ("fixtures/valid/data.json", "PhoneData"),
        ("fixtures/valid/close.json", "PhoneClose"),
        ("fixtures/valid/connector-data.json", "ConnectorToServerData"),
        ("fixtures/valid/connector-close.json", "ConnectorToServerClose"),
    ],
)
def test_frame_fixtures_validate(fixture, definition):
    _validate(_load("frames.schema.json"), definition, _fixture(fixture))


def test_invalid_port_is_rejected():
    with pytest.raises(ValidationError):
        _validate(
            _load("http.schema.json"),
            "BridgeRequest",
            _fixture("fixtures/invalid/port-not-allowed.json"),
        )


def test_data_without_seq_is_rejected():
    with pytest.raises(ValidationError):
        _validate(
            _load("frames.schema.json"),
            "PhoneData",
            _fixture("fixtures/invalid/data-missing-seq.json"),
        )
