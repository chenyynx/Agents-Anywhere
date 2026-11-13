"""Runtime-neutral timeline facts that outlive one connector process.

The first tenant is the interrupted-response notice (pp 2026-11-14): a user's
stop has no faithful row status to leave behind — an aborted tool lands
``failed``, an interrupted thinking block ``done`` — so every runtime stamps a
turn-level content key on the turn's last main-agent row instead. Clients read
one key regardless of whether the turn came from Claude, Codex or DSH.

The flag lives in ``content`` (not item metadata) because the server's change
detection hashes ``type/status/role/content`` only: a metadata-only rewrite
would look unchanged and never reach clients. The content hash is recomputed
for the same reason — every later writer must compare against the state it
actually produced.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from connector.runtime_protocol.models import RuntimeTimelineItem
from connector.runtime_protocol.timeline import timeline_content_hash

#: The content key one item of a user-stopped turn carries.
TURN_INTERRUPTED_CONTENT_KEY = "turnInterrupted"


def is_main_timeline_item(item: RuntimeTimelineItem) -> bool:
    """Whether ``item`` renders in the main chat timeline (not a child row).

    SubAgent child rows share the session's item store but not the chat
    timeline; the interrupted notice must anchor on a row the timeline
    actually draws.
    """

    content = item.content
    return not (isinstance(content, Mapping) and content.get("parentItemId"))


def mark_turn_interrupted(item: RuntimeTimelineItem) -> RuntimeTimelineItem:
    """Stamp one row as the anchor of a user-stopped turn.

    Idempotent: an already-stamped row is returned untouched so a repeated
    history pass or a live re-publish cannot inflate its revision.
    """

    content = dict(item.content) if isinstance(item.content, Mapping) else {}
    if content.get(TURN_INTERRUPTED_CONTENT_KEY) is True:
        return item
    content[TURN_INTERRUPTED_CONTENT_KEY] = True
    return replace(
        item,
        content=content,
        content_hash=timeline_content_hash(
            item_type=item.type,  # type: ignore[arg-type]
            status=item.status,  # type: ignore[arg-type]
            role=item.role,  # type: ignore[arg-type]
            content=content,
        ),
        revision=item.revision + 1,
    )


def interrupted_turn_ids_from_rows(rows: Any) -> set[str]:
    """Turn ids whose persisted status says the turn was stopped by the user.

    ``rows`` may be raw mappings (``{"id": …, "status": …}``) or typed SDK
    objects carrying ``id``/``status``; an enum status is read through
    ``.value``. ``cancelled`` is included because runtimes use both spellings
    for the same user action.
    """

    stopped: set[str] = set()
    if not isinstance(rows, (list, tuple)):
        return stopped
    for row in rows:
        if isinstance(row, Mapping):
            turn_id = row.get("id")
            status = row.get("status")
        else:
            turn_id = getattr(row, "id", None)
            status = getattr(row, "status", None)
        status = getattr(status, "value", status)
        if (
            isinstance(turn_id, str)
            and turn_id
            and status in {"interrupted", "cancelled"}
        ):
            stopped.add(turn_id)
    return stopped


def mark_interrupted_turns(
    items: tuple[RuntimeTimelineItem, ...],
    interrupted_turns: set[str],
) -> tuple[RuntimeTimelineItem, ...]:
    """Stamp each stopped turn's last main row with the turn-level flag."""

    if not items or not interrupted_turns:
        return items
    last_index_by_turn: dict[str, int] = {}
    for index, item in enumerate(items):
        if (
            item.turn_id in interrupted_turns
            and item.type not in {"turn.start", "turn.end"}
            and is_main_timeline_item(item)
        ):
            last_index_by_turn[item.turn_id] = index
    if not last_index_by_turn:
        return items
    marked = list(items)
    for index in last_index_by_turn.values():
        marked[index] = mark_turn_interrupted(marked[index])
    return tuple(marked)
