from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from agent_server.core.models import TimelineItem, TimelineItemIn


@dataclass(frozen=True, slots=True)
class TimelineItemWriteResult:
    item: TimelineItem
    changed: bool
    # Stable ids of rows this write removed (a converged live/history twin).
    # A deletion has no surviving row to carry the change, so the publisher
    # must express it explicitly — otherwise a client that already cached the
    # removed id keeps rendering it until a full refetch.
    deleted: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class TimelineBatchWriteResult:
    items: tuple[TimelineItem, ...]
    changed: bool
    deleted: tuple[str, ...] = ()


def timeline_item_state_is_unchanged(
    existing: TimelineItem,
    incoming: TimelineItemIn,
) -> bool:
    """Compare the Runtime-owned state identity for one stable item ID."""

    if existing.contentHash != incoming.contentHash:
        return False
    # ``contentHash`` covers type/status/role/content only, never ``source``.
    # A history rebuild that now declares ``turnId`` on an otherwise identical
    # row would look unchanged, so the stored payload would never gain the turn
    # boundary. Force that rewrite whenever the declared id differs: filling a
    # missing id, and also replacing a different one. The second case is the
    # older connector's window-derived history id — it is not stable across
    # sync windows, and freezing the first one would split a turn at a false
    # boundary on the client. A turn-less write still never clears a stored id,
    # and every other source field keeps the old contentHash-only behaviour.
    if incoming.source.turnId and incoming.source.turnId != existing.source.turnId:
        return False
    return True


def native_item_id_from_payload(payload_json: str) -> str | None:
    """Extract ``source.itemId`` from a stored payload, or None.

    The Runtime-native item id lives in the payload (``source.itemId``) but is
    also mirrored to a column for indexed grouping; a row written before the
    column existed (or by an older worker during a rolling upgrade) carries
    NULL and is invisible to the corrector until refilled. A malformed payload,
    or one without an itemId, yields None — such rows are genuinely out of
    scope, not an error.
    """

    try:
        payload = json.loads(payload_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    source = payload.get("source")
    if not isinstance(source, dict):
        return None
    value = source.get("itemId")
    return value if isinstance(value, str) and value else None


def timeline_message_group_key(
    native_message_id: str | None,
    native_item_id: str | None,
) -> str | None:
    """The group key that gathers every row of one assistant message.

    Rows written from one assistant message arrive through different paths and
    carry two distinct Runtime-native identities:

    - a **tool row** carries the enclosing message's id, ``nativeMessageId``
      (its own ``itemId`` is the tool call's id, which is unique per row and so
      cannot gather a message's tool rows) — key = ``nativeMessageId``;

    - a **body or reasoning row** carries the message id as its ``itemId`` (the
      v2_42 invariant groups them on ``native_item_id``) — key =
      ``native_item_id``.

    Both therefore resolve to the same key — the assistant message the row
    belongs to — which is what lets a later pass gather a whole message (tool
    rows plus body/reasoning) into one group. The tool-row identity wins when
    both are present, because a row that declares its enclosing message id
    knows its group directly.

    Returns None when neither id is present: the row cannot be assigned to a
    message group and callers must leave it out, never guess one.
    """

    return native_message_id or native_item_id


def timeline_item_from_runtime_input(
    item: TimelineItemIn,
    *,
    updated_seq: int,
    now: str,
    existing: TimelineItem | None = None,
    order_seq: int | None = None,
    revision: int | None = None,
) -> TimelineItem:
    # ``dict(item)`` is a shallow field copy, so the (potentially large)
    # ``content`` payload is carried by reference.  ``model_dump()`` deep-copies
    # it, which made this normalization one of the most expensive steps of the
    # streaming hot path.
    data = dict(item)
    data["updatedSeq"] = updated_seq
    if order_seq is not None:
        data["orderSeq"] = order_seq
    if revision is not None:
        data["revision"] = revision
    data["createdAt"] = item.createdAt or (existing.createdAt if existing else now)
    data["updatedAt"] = item.updatedAt or now
    return TimelineItem.model_validate(data)


def latest_timeline_items_by_id(
    items: list[TimelineItemIn],
) -> dict[str, TimelineItemIn]:
    """Keep the last Runtime value when one batch repeats an item ID."""

    return {item.id: item for item in items}


def timeline_snapshot_is_unchanged(
    current_by_id: dict[str, TimelineItem],
    incoming_by_id: dict[str, TimelineItemIn],
) -> bool:
    if set(current_by_id) != set(incoming_by_id):
        return False
    return all(
        timeline_item_state_is_unchanged(current_by_id[item_id], incoming)
        and current_by_id[item_id].orderSeq == incoming.orderSeq
        for item_id, incoming in incoming_by_id.items()
    )


def timeline_item_from_snapshot(
    *,
    item: TimelineItemIn,
    existing: TimelineItem | None,
    updated_seq: int,
    now: str,
) -> TimelineItem:
    if (
        existing is not None
        and timeline_item_state_is_unchanged(existing, item)
        and existing.orderSeq == item.orderSeq
    ):
        return existing
    return timeline_item_from_runtime_input(
        item,
        updated_seq=updated_seq,
        now=now,
        existing=existing,
        revision=next_timeline_item_revision(item, existing),
    )


def next_timeline_item_revision(
    item: TimelineItemIn,
    existing: TimelineItem | None,
) -> int:
    if existing is None:
        return item.revision
    return max(item.revision, existing.revision + 1)


def timeline_item_content_hash(
    *,
    item_type: str,
    status: str,
    role: str | None,
    content: Any,
) -> str:
    """Canonical state hash for one timeline item.

    Mirrors the Runtime protocol's ``timeline_content_hash`` (connector
    ``runtime_protocol/timeline.py``): a deterministic digest over the item's
    own state. Any writer that derives a new state for an existing row (an
    approval resolution, the age janitor) must recompute the hash, otherwise
    the row carries a hash that no longer describes it and a later Runtime
    push of the previous state would look unchanged on the no-op fast path
    instead of superseding the derived state.
    """

    payload = {
        "type": item_type,
        "status": status,
        "role": role,
        "content": content,
    }
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return "sha256:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()
