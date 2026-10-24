from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from pydantic import BaseModel

from agent_server.core.protocol import (
    PROTOCOL_VERSION_1,
    ProtocolCapabilitiesResponse,
    ProtocolCapabilitySet,
    ProtocolEventEnvelope,
    ProtocolEventRecoveryResponse,
    ProtocolHandshakeRequest,
    ProtocolHandshakeResponse,
    ProtocolModelCatalog,
    ProtocolModelCatalogResponse,
    ProtocolPermissionCatalog,
    ProtocolPermissionCatalogResponse,
    ProtocolSessionSnapshotResponse,
    ProtocolWsTicketRequest,
    ProtocolWsTicketResponse,
)

JSON_SCHEMA_DRAFT = "https://json-schema.org/draft/2020-12/schema"
SCHEMA_ID_PREFIX = "urn:agents-anywhere:protocol"

SchemaDirection = Literal["ingress", "egress", "bidirectional"]
SchemaMode = Literal["validation", "serialization"]


@dataclass(frozen=True)
class ProtocolSchema:
    slug: str
    model: type[BaseModel]
    direction: SchemaDirection
    mode: SchemaMode


# Response fields that stay *optional* in the published contract even though
# the current server always emits them. ``ProtocolWireModel`` sets
# ``json_schema_serialization_defaults_required``, so every defaulted response
# field is marked required — accurate for the current server, but wrong for a
# new client reading an older server during a rolling upgrade, which is the
# exact case an additive response flag exists for. Keyed by artifact slug;
# only top-level response fields are supported.
OPTIONAL_SERIALIZATION_FIELDS: dict[str, frozenset[str]] = {
    "session-snapshot-response": frozenset(
        {"deferredActivity", "excludesAgentChildren"}
    ),
}


SCHEMAS = (
    ProtocolSchema("handshake-request", ProtocolHandshakeRequest, "ingress", "validation"),
    ProtocolSchema("handshake-response", ProtocolHandshakeResponse, "egress", "serialization"),
    ProtocolSchema("capability-set", ProtocolCapabilitySet, "bidirectional", "validation"),
    ProtocolSchema("capabilities-response", ProtocolCapabilitiesResponse, "egress", "serialization"),
    ProtocolSchema("model-catalog", ProtocolModelCatalog, "bidirectional", "validation"),
    ProtocolSchema("model-catalog-response", ProtocolModelCatalogResponse, "egress", "serialization"),
    ProtocolSchema("permission-catalog", ProtocolPermissionCatalog, "bidirectional", "validation"),
    ProtocolSchema(
        "permission-catalog-response",
        ProtocolPermissionCatalogResponse,
        "egress",
        "serialization",
    ),
    ProtocolSchema(
        "session-snapshot-response",
        ProtocolSessionSnapshotResponse,
        "egress",
        "serialization",
    ),
    ProtocolSchema("ws-ticket-request", ProtocolWsTicketRequest, "ingress", "validation"),
    ProtocolSchema("ws-ticket-response", ProtocolWsTicketResponse, "egress", "serialization"),
    ProtocolSchema("event-envelope", ProtocolEventEnvelope, "egress", "serialization"),
    ProtocolSchema(
        "event-recovery-response",
        ProtocolEventRecoveryResponse,
        "egress",
        "serialization",
    ),
)


def _json_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode()


def _schema_document(artifact: ProtocolSchema) -> dict[str, object]:
    schema = artifact.model.model_json_schema(by_alias=True, mode=artifact.mode)
    schema["$schema"] = JSON_SCHEMA_DRAFT
    schema["$id"] = (
        f"{SCHEMA_ID_PREFIX}:{PROTOCOL_VERSION_1}:{artifact.slug}"
    )
    schema["x-protocol-version"] = PROTOCOL_VERSION_1
    schema["x-direction"] = artifact.direction
    schema["x-pydantic-mode"] = artifact.mode
    optional_fields = OPTIONAL_SERIALIZATION_FIELDS.get(artifact.slug, frozenset())
    required = schema.get("required")
    if optional_fields and isinstance(required, list):
        schema["required"] = [
            field_name for field_name in required if field_name not in optional_fields
        ]
    return schema


def export_contract(output_dir: Path) -> None:
    schema_dir = output_dir / "schemas"
    schema_dir.mkdir(parents=True, exist_ok=True)
    artifacts: list[dict[str, str]] = []

    for artifact in SCHEMAS:
        relative_path = f"schemas/{artifact.slug}.schema.json"
        schema_bytes = _json_bytes(_schema_document(artifact))
        (output_dir / relative_path).write_bytes(schema_bytes)
        artifacts.append(
            {
                "direction": artifact.direction,
                "model": artifact.model.__name__,
                "path": relative_path,
                "pydanticMode": artifact.mode,
                "sha256": hashlib.sha256(schema_bytes).hexdigest(),
                "slug": artifact.slug,
            }
        )

    manifest = {
        "artifacts": artifacts,
        "jsonSchemaDraft": JSON_SCHEMA_DRAFT,
        "protocolVersion": PROTOCOL_VERSION_1,
        "source": "server/agent_server/core/protocol.py",
    }
    (output_dir / "manifest.json").write_bytes(_json_bytes(manifest))


def main() -> None:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Export the canonical Agents Anywhere protocol JSON Schemas."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repository_root / "contracts" / "protocol" / PROTOCOL_VERSION_1,
    )
    args = parser.parse_args()
    export_contract(args.output.resolve())


if __name__ == "__main__":
    main()
