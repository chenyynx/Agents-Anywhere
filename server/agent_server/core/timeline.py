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


@dataclass(frozen=True, slots=True)
class TimelineBatchWriteResult:
    items: tuple[TimelineItem, ...]
    changed: bool


def timeline_item_state_is_unchanged(
    existing: TimelineItem,
    incoming: TimelineItemIn,
) -> bool:
    """Compare the Runtime-owned state identity for one stable item ID."""

    return existing.contentHash == incoming.contentHash


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
