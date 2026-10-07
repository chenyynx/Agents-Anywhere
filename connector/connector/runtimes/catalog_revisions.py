from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from connector.runtime_protocol.instance_models import MAX_CONFIG_REVISION

CATALOG_CONFIG_REVISION_FACTOR = 1000

# Durable shape of one catalog's push state. Stored per runtime instance and
# catalog type; bumped when the wire format needs to change.
CATALOG_PUSH_STATE_VERSION = 1


def runtime_catalog_revision(
    config_revision: int,
    static_catalog_revision: int,
) -> int:
    if isinstance(config_revision, bool) or not isinstance(config_revision, int):
        raise TypeError("config_revision must be an integer")
    if not 0 <= config_revision <= MAX_CONFIG_REVISION:
        raise ValueError("config_revision must be a non-negative safe integer")
    if isinstance(static_catalog_revision, bool) or not isinstance(
        static_catalog_revision, int
    ):
        raise TypeError("static_catalog_revision must be an integer")
    if not 0 <= static_catalog_revision < CATALOG_CONFIG_REVISION_FACTOR:
        raise ValueError(
            "static_catalog_revision must fit within the reserved revision range"
        )

    revision = (
        config_revision * CATALOG_CONFIG_REVISION_FACTOR + static_catalog_revision
    )
    if revision > MAX_CONFIG_REVISION:
        raise ValueError(
            "combined catalog revision exceeds the JavaScript safe integer limit"
        )
    return revision


@dataclass(frozen=True, slots=True)
class CatalogPushState:
    """What this connector last published for one catalog stream.

    `content_signature` is the content of the last push, `revision` the
    revision it was published with. Both survive process restarts, so a
    revision this connector already used is never handed to different content.
    """

    content_signature: str
    revision: int


def catalog_content_signature(payload: Mapping[str, Any]) -> str:
    """Stable signature of the content the Server would store for one catalog.

    `revision` is excluded on purpose: the Server's equality check runs only at
    equal revisions, and a revision move with unchanged content is not a
    content change — it must stay skippable. `default=str` keeps the signature
    defined for values a future runtime might add without pre-serializing.
    """

    content = {key: value for key, value in payload.items() if key != "revision"}
    encoded = json.dumps(
        content,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        default=str,
    )
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def catalog_push_revision(
    base_revision: int,
    state: CatalogPushState | None,
) -> int:
    """Revision to publish for content that differs from the last push.

    The derived revision (`runtime_catalog_revision`) tracks the runtime config
    revision and does not move when discovery output drifts, while the Server
    rejects same-revision content changes ("catalog content changed without a
    revision increase"). Publishing strictly above the last revision this
    connector used keeps the stream acceptable without touching the Server
    rule. With no recorded state — first push after install, or after local
    state loss — one step above the derived revision is used, so a drifted
    catalog is accepted even when the derived revision did not move; that is
    exactly the freeze this function exists to end.
    """

    if isinstance(base_revision, bool) or not isinstance(base_revision, int):
        raise TypeError("base_revision must be an integer")
    if not 0 <= base_revision <= MAX_CONFIG_REVISION:
        raise ValueError("base_revision must be a non-negative safe integer")
    if state is not None and (
        isinstance(state.revision, bool) or not isinstance(state.revision, int)
    ):
        raise TypeError("state.revision must be an integer")
    if state is not None and not 0 <= state.revision <= MAX_CONFIG_REVISION:
        raise ValueError("state.revision must be a non-negative safe integer")

    if state is None:
        candidate = base_revision + 1
    else:
        candidate = max(base_revision, state.revision + 1)
    return min(candidate, MAX_CONFIG_REVISION)


def catalog_push_state_from_mapping(
    value: Mapping[str, Any] | None,
) -> CatalogPushState | None:
    """Parse persisted push state, treating anything malformed as absent."""

    if not isinstance(value, Mapping):
        return None
    if value.get("version") != CATALOG_PUSH_STATE_VERSION:
        return None
    signature = value.get("contentSignature")
    revision = value.get("revision")
    if not isinstance(signature, str) or not signature:
        return None
    if isinstance(revision, bool) or not isinstance(revision, int):
        return None
    if not 0 <= revision <= MAX_CONFIG_REVISION:
        return None
    return CatalogPushState(content_signature=signature, revision=revision)


def catalog_push_state_payload(state: CatalogPushState) -> dict[str, Any]:
    return {
        "version": CATALOG_PUSH_STATE_VERSION,
        "contentSignature": state.content_signature,
        "revision": state.revision,
    }
