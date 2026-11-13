"""The durable "this turn was stopped by the user" fact for Codex.

Codex persists every turn with a status (``completed`` / ``interrupted`` /
``failed`` …), so history already knows the cause; the live wire carries the
same verdict as ``turn/interrupted`` / ``turn/cancelled``. What it never said
was *which row* the client should hang the official interrupted-response
notice under — an aborted command lands ``failed`` and an interrupted message
lands ``interrupted`` on its blocks, neither of which is a turn-level fact.

This module projects the status onto the turn's last main-agent row as
``content.turnInterrupted``, the same key Claude and DSH write, so the client
reads one fact across runtimes.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from connector.runtime_protocol import (
    interrupted_turn_ids_from_rows,
    mark_interrupted_turns,
)
from connector.runtime_protocol.models import RuntimeTimelineItem


def interrupted_turn_ids_from_thread(thread: Any) -> set[str]:
    """Turn ids an SDK ``Thread`` or a raw thread snapshot says were stopped."""

    if isinstance(thread, Mapping):
        rows = thread.get("turns")
    else:
        rows = getattr(thread, "turns", None)
    return interrupted_turn_ids_from_rows(rows)


def mark_interrupted_codex_turns(
    items: tuple[RuntimeTimelineItem, ...],
    thread: Any,
) -> tuple[RuntimeTimelineItem, ...]:
    """Stamp each stopped turn's last main row in one projected thread."""

    return mark_interrupted_turns(items, interrupted_turn_ids_from_thread(thread))
