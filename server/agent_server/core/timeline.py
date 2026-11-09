from __future__ import annotations

import hashlib
import json
from collections.abc import Sequence
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


@dataclass(frozen=True, slots=True)
class ChainReorderDiagnostics:
    """One chain reorder plan plus what it could not honour.

    ``plan`` only ever names rows the batch **adds**; a stored row's number is
    never in it. ``tail_anchored`` names new rows that had no stored batch
    neighbour at all — they could only be appended, never placed. Rows whose
    batch neighbours are stored in the opposite order are appended too and
    named in ``skewed_anchors``; placing them would mean rewriting a stored
    row the batch does not ask to move.
    """

    plan: dict[str, int]
    batch_items: int
    renumbered_stored: int
    tail_anchored: tuple[str, ...] = ()
    #: Runs whose batch anchors are in the opposite order in storage (a
    #: pre-existing misordered row); they are appended, not placed.
    skewed_anchors: tuple[str, ...] = ()


def chain_reorder_plan(
    *,
    stored_order: Sequence[tuple[str, int]],
    batch_ids: Sequence[str],
) -> dict[str, int] | None:
    """``orderSeq`` for the rows a rebased batch moves, or ``None`` if none.

    Compatibility wrapper around :func:`chain_reorder_plan_with_diagnostics`.
    """

    plan = chain_reorder_plan_with_diagnostics(
        stored_order=stored_order,
        batch_ids=batch_ids,
    ).plan
    return plan or None


def chain_reorder_plan_with_diagnostics(
    *,
    stored_order: Sequence[tuple[str, int]],
    batch_ids: Sequence[str],
) -> ChainReorderDiagnostics:
    """Place a batch's new rows by chain order, with a bounded local renumber.

    ``stored_order`` is ``(id, orderSeq)`` already ordered by ``orderSeq``
    (ties by id). ``batch_ids`` is the batch's chain order. A rebased history
    sync covers the whole visible chain; a cursor window covers a chain suffix;
    a live-store retry re-publishes a subset of the chain.

    The plan is insert-only whenever the integers allow it:

    - a row the Server has never seen is inserted as a run between its nearest
      stored batch neighbours, into consecutive free integers. A front run may
      use any free positive slot below its first anchor. This path never
      touches a stored row.
    - when the interval has no run of free integers, the smallest block of
      stored rows around the insertion point is renumbered in its existing
      order until the run fits. The block grows to the right and may reach the
      session's end in a dense session (order 1..N has no gaps); only rows
      inside the block change number, and every other stored row keeps its
      exact ``orderSeq``. ``renumbered_stored`` reports the count.
    - a run with no later batch anchor has nowhere to be placed and is
      appended above the session high-water mark, reported in
      ``tail_anchored``.

    Why the bounded block: ``orderSeq`` is an integer, and a dense interval
    cannot hold a new run. Refusing to renumber leaves the new row appended
    after newer rows — the 2026-11-09 regression reproduced on a fresh session.
    The block is the minimum span that makes the insertion legal, so churn is
    local instead of the whole suffix the 2026-11-10 rebuild rewrote.

    The plan is idempotent: applying it makes the next identical batch plan
    nothing. Repairing an already-misordered row that no batch names remains
    out of scope; that is a separate one-off pass.
    """

    stored_value = dict(stored_order)
    stored_ids = set(stored_value)
    ordered_batch = list(dict.fromkeys(batch_ids))
    number = dict(stored_value)
    plan: dict[str, int] = {}
    used: set[int] = set(number.values())
    highest = max(used, default=0)
    tail_anchored: list[str] = []
    skewed_anchors: list[str] = []

    index = 0
    while index < len(ordered_batch):
        if ordered_batch[index] in stored_ids:
            index += 1
            continue
        run_end = index
        while (
            run_end < len(ordered_batch)
            and ordered_batch[run_end] not in stored_ids
        ):
            run_end += 1
        run = ordered_batch[index:run_end]
        run_start = index
        index = run_end

        previous = (
            number.get(ordered_batch[run_start - 1]) if run_start > 0 else None
        )
        anchor_id = (
            ordered_batch[run_end] if run_end < len(ordered_batch) else None
        )
        following = number.get(anchor_id) if anchor_id is not None else None
        if following is None or (
            previous is not None and previous >= following
        ):
            # No later batch anchor: nothing says where this run belongs
            # relative to the stored tail. Or the stored order contradicts the
            # batch: the row that should precede this run is stored after the
            # next anchor, and placing it between them would mean rewriting a
            # stored row the batch does not ask to move. Append; a run with a
            # contradicting predecessor is reported so the stranded row stays
            # visible. A run that merely has no later anchor (the normal
            # newest rows of a cursor window) appends without noise.
            if following is not None:
                skewed_anchors.extend(run)
            elif previous is None:
                # Neither stored neighbour exists: the batch names no anchor
                # at all.
                tail_anchored.extend(run)
            slots = []
            for _ in run:
                highest += 1
                slots.append(highest)
        else:
            # Every stored row between the previous batch anchor and the next
            # one anchors before this run, so the run goes above all of them,
            # immediately below the next anchor.
            floor_value = max(
                (
                    value
                    for value in used
                    if value < following
                    and (previous is None or value > previous)
                ),
                default=(previous if previous is not None else 0),
            )
            slots = _free_run_between(floor_value, following, len(run), used)
            if slots is None:
                assert anchor_id is not None  # following is not None
                plan.update(
                    _bounded_insert(
                        number=number,
                        used=used,
                        lower=floor_value,
                        upper=following,
                        anchor_id=anchor_id,
                        run=run,
                    )
                )
                highest = max(used, default=0)
                continue
        for item_id, slot in zip(run, slots, strict=True):
            plan[item_id] = slot
            number[item_id] = slot
            used.add(slot)
            highest = max(highest, slot)

    renumbered_stored = sum(1 for item_id in plan if item_id in stored_ids)
    return ChainReorderDiagnostics(
        plan=plan,
        batch_items=len(ordered_batch),
        renumbered_stored=renumbered_stored,
        tail_anchored=tuple(tail_anchored),
        skewed_anchors=tuple(skewed_anchors),
    )


def _bounded_insert(
    *,
    number: dict[str, int],
    used: set[int],
    lower: int | None,
    upper: int,
    anchor_id: str,
    run: list[str],
) -> dict[str, int]:
    """Renumber the smallest block around ``(lower, upper)`` to fit ``run``.

    ``upper`` is the number of the next stored batch row (``anchor_id``). The
    block grows to the right, one stored row at a time, until its integer
    interval holds every block row plus the run. The run is inserted
    immediately before the anchor; the block rows keep their stored order.
    Mutates ``number``/``used`` and returns the changed numbers.
    """

    floor = lower if lower is not None else 0
    limit: int | None = upper
    while True:
        block = sorted(
            (value, item_id)
            for item_id, value in number.items()
            if value > floor and (limit is None or value < limit)
        )
        capacity = None if limit is None else limit - floor - 1
        if capacity is None or len(block) + len(run) <= capacity:
            break
        limit = next(
            (value for value in sorted(used) if value > limit),
            None,
        )
    combined: list[str] = []
    inserted = False
    for _, item_id in block:
        if not inserted and item_id == anchor_id:
            combined.extend(run)
            inserted = True
        combined.append(item_id)
    if not inserted:
        combined.extend(run)
    if limit is None:
        slots = list(range(floor + 1, floor + 1 + len(combined)))
    else:
        slots = list(range(floor + 1, limit))[: len(combined)]
    changes: dict[str, int] = {}
    for item_id, slot in zip(combined, slots, strict=True):
        old = number.get(item_id)
        number[item_id] = slot
        if old != slot:
            changes[item_id] = slot
    used.clear()
    used.update(number.values())
    return changes


def _free_run_between(
    lower: int,
    upper: int,
    count: int,
    used: set[int],
) -> list[int] | None:
    """The highest run of ``count`` unused integers in ``(lower, upper)``.

    ``lower`` is already the highest stored value in the interval (or 0 for a
    front run), so the run sits above every stored row that anchors before it.
    Slot 0 is never used: every client treats orderSeq <= 0 as "not assigned"
    (Android ``takeIf { it > 0 }``), so the floor is 1.
    """

    floor = max(lower + 1, 1)
    start = upper - count
    while start >= floor:
        slots = list(range(start, start + count))
        if all(slot not in used for slot in slots):
            return slots
        start -= 1
    return None


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
    fallback_updated_at: str | None = None,
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
    # A history rebuild carries the source ``createdAt`` but no ``updatedAt``.
    # Stamping ``now`` would rewrite an old row's time, and ``item_time`` is
    # derived from these fields, so the session would jump to the top of the
    # dashboard. The source creation time is the truthful fallback; then the
    # row's own stored time — a history rewrite that carries nothing must not
    # move an old row forward (2026-11-09: every connector restart re-projects
    # agent cards, rewrote them, and scrambled the sidebar); only a row with
    # neither timestamp is genuinely "now".
    data["updatedAt"] = (
        item.updatedAt or item.createdAt or fallback_updated_at or now
    )
    return TimelineItem.model_validate(data)


#: Statuses that mean the row is still being written live. A live writer may
#: advance ``updatedAt`` for these rows: the client derives the "thought for
#: N s" label and an agent card's running clock from ``createdAt``/``updatedAt``
#: because the wire declares no per-row times. Everything else is settled.
LIVE_TIMELINE_STATUSES = frozenset({"pending", "running", "waiting_approval"})


def stored_time_for_live_rewrite(
    item: TimelineItemIn,
    existing: TimelineItem | None,
) -> str | None:
    """``fallback_updated_at`` for the live single-item writer.

    A live frame carries no timestamps, so the Server stamps ``now`` — that
    stamp is what a client times a thinking block with. A settled row that is
    rewritten (the card evidence sweep closing a stranded card, a startup
    reconcile) is not activity: it must keep its stored time, or the whole
    session jumps to the top of the sidebar (2026-11-09, twice).
    """

    if existing is None or item.status in LIVE_TIMELINE_STATUSES:
        return None
    return existing.updatedAt


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
        # A complete rebuild that rewrites a row without declaring a time must
        # keep the stored time too, for the same reason as the sync path.
        fallback_updated_at=(existing.updatedAt if existing is not None else None),
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
