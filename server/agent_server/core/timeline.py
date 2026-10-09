from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass

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


def agent_child_parent_item_id(item: TimelineItem) -> str | None:
    """The card ID a row belongs to when it is a subagent-internal row.

    The connector tags every subagent-internal row — tool, reasoning or text —
    with ``content.parentItemId`` pointing at the item ID of the Agent card
    row that owns it (the client folds those rows under the card). The
    judgment is content-based, never based on the row's ``type``: a row is a
    child exactly when its free-JSON ``content`` carries a non-empty
    ``parentItemId`` string. Total by construction: a payload whose content
    is not a mapping, or whose ``parentItemId`` is not a non-empty string, is
    not a child row.
    """

    content = item.content
    if not isinstance(content, Mapping):
        return None
    parent_item_id = content.get("parentItemId")
    if isinstance(parent_item_id, str) and parent_item_id:
        return parent_item_id
    return None


def timeline_item_json_bytes(item: TimelineItem) -> int:
    """Byte size of one timeline item as protocol responses serialize it.

    Byte-budget gates (the snapshot's 2MB ceiling and the timeline page
    budget) measure this same encoding — compact UTF-8 JSON, the wrapped
    ``{"item": ...}`` envelope kept byte-identical with the snapshot gate's
    historical metric — so the gates cannot drift away from the wire size.
    Mirrors ``event_recovery._serialized_payload_bytes``.
    """

    return len(
        json.dumps(
            {"item": item.model_dump(mode="json")},
            ensure_ascii=False,
            separators=(",", ":"),
            default=str,
        ).encode("utf-8")
    )
