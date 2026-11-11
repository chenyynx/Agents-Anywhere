"""Codex's own context-window figures, read off `thread/tokenUsage/updated`.

The app-server notification carries `{ total, last, modelContextWindow }`:
`last` is the most recent turn's usage (the closest thing to "what is in the
window now"), `total` is the session's running sum. The ring sizes itself on
`last` when present and falls back to `total`; the window is the model's own
`modelContextWindow`. No per-category breakdown exists on this runtime, so the
wire answer is summary-only.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class CodexContextUsageSnapshot:
    used_tokens: int
    max_tokens: int | None
    measured_at: str


def _int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except ValueError:
            return None
    return None


def _mapping(value: Any) -> Mapping[str, Any] | None:
    return value if isinstance(value, Mapping) else None


def _breakdown_total(value: Any) -> int | None:
    breakdown = _mapping(value)
    if breakdown is None:
        return None
    for key in ("totalTokens", "total_tokens"):
        total = _int(breakdown.get(key))
        if total is not None:
            return total
    return None


def context_usage_from_notification(
    params: Mapping[str, Any],
    *,
    measured_at: str,
) -> CodexContextUsageSnapshot | None:
    """One `thread/tokenUsage/updated` params payload -> snapshot (or None)."""

    usage = _mapping(params.get("tokenUsage")) or _mapping(
        params.get("token_usage")
    )
    if usage is None:
        return None
    used = _breakdown_total(usage.get("last"))
    if used is None:
        used = _breakdown_total(usage.get("total"))
    if used is None:
        return None
    window = _int(usage.get("modelContextWindow"))
    if window is None:
        window = _int(usage.get("model_context_window"))
    return CodexContextUsageSnapshot(
        used_tokens=used,
        max_tokens=window,
        measured_at=measured_at,
    )
