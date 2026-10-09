"""Age-bounded self-heal for stale ``running`` tool rows (server janitor).

Source files can vanish — a /tmp workspace wiped by a reboot, a rotated
transcript — and no connector-side rebuild can ever reach those rows again.
The server itself is the only layer that still knows them, so this periodic
sweep is the floor under the connector-side evidence paths.

It closes a row only when everything agrees it is dead: the row is a
``running`` tool past the age bound, its session has no active run, and the
session's own activity timestamps are past the bound too. Anything it cannot
prove stays untouched (see
``TimelineRepositoryMixin.close_stale_running_tool_items`` for the exact
guards and the write shape: closed as ``interrupted`` with
``closedByEvidence``, never deleted, never consuming the unread badge).

Configuration (read by ``from_environment``):

- ``AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS`` — age bound, default 48h.
  A value ``<= 0`` disables the janitor entirely (kill-switch).
- ``AGENT_SERVER_TIMELINE_JANITOR_INTERVAL_SECONDS`` — sweep period,
  default 600s; a non-positive value falls back to the default.

A value that cannot be read as a finite number (``""``, ``"  "``, ``"abc"``,
``"48h"``, ``"nan"``, ``"inf"``) is malformed configuration, not a crash: it
disables the janitor and is logged. ``from_environment`` runs inside
``create_app``, so an unparsed float there would take the whole server down
instead of one sweep, and a janitor that cannot read its own bound must not
guess — bad configuration does nothing rather than doing something wrong.
"""

from __future__ import annotations

import asyncio
import math
import os
from datetime import UTC, datetime, timedelta

from loguru import logger

from agent_server.services.repository_ports import TimelineJanitorRepository

CLOSED_BY_EVIDENCE = "ageBoundedServer"
DEFAULT_INTERVAL_SECONDS = 600.0
DEFAULT_MAX_AGE_SECONDS = 48 * 60 * 60.0
DEFAULT_CANDIDATE_LIMIT = 500

ENV_MAX_AGE_SECONDS = "AGENT_SERVER_TIMELINE_JANITOR_MAX_AGE_SECONDS"
ENV_INTERVAL_SECONDS = "AGENT_SERVER_TIMELINE_JANITOR_INTERVAL_SECONDS"


def _env_seconds(name: str, default: float) -> float | None:
    """Read one janitor env var; ``None`` when it is present but unusable.

    Unset (or absent) falls back to the default; present-but-malformed,
    non-finite, or ``timedelta``-unrepresentable values are refused so the
    caller can stand the janitor down — ``nan``/``inf`` and huge-but-finite
    values like ``1e15`` would otherwise explode inside every sweep's bound
    arithmetic (silent janitor death, R2 round-2 P2).
    """

    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value):
        return None
    # Finite is not enough: ``timedelta`` (the bound arithmetic's type) has a
    # smaller range than float, so values like 1e15 survive ``isfinite`` and
    # then raise OverflowError on every sweep. Refuse them at parse time.
    try:
        timedelta(seconds=value)
    except OverflowError:
        return None
    return value


class TimelineJanitor:
    def __init__(
        self,
        store: TimelineJanitorRepository,
        *,
        enabled: bool = True,
        max_age_seconds: float = DEFAULT_MAX_AGE_SECONDS,
        interval_seconds: float = DEFAULT_INTERVAL_SECONDS,
        candidate_limit: int = DEFAULT_CANDIDATE_LIMIT,
    ) -> None:
        self._store = store
        # The env switch is the age bound itself: <= 0 turns the janitor off.
        self.enabled = bool(enabled) and float(max_age_seconds) > 0
        self._max_age_seconds = float(max_age_seconds)
        self._interval_seconds = (
            float(interval_seconds)
            if float(interval_seconds) > 0
            else DEFAULT_INTERVAL_SECONDS
        )
        self._candidate_limit = max(1, int(candidate_limit))

    @classmethod
    def from_environment(
        cls,
        store: TimelineJanitorRepository,
    ) -> TimelineJanitor:
        raw_age = os.environ.get(ENV_MAX_AGE_SECONDS)
        raw_interval = os.environ.get(ENV_INTERVAL_SECONDS)
        max_age = _env_seconds(ENV_MAX_AGE_SECONDS, DEFAULT_MAX_AGE_SECONDS)
        interval = _env_seconds(ENV_INTERVAL_SECONDS, DEFAULT_INTERVAL_SECONDS)
        malformed = [
            name
            for name, parsed in (
                (ENV_MAX_AGE_SECONDS, max_age),
                (ENV_INTERVAL_SECONDS, interval),
            )
            if parsed is None
        ]
        if malformed:
            logger.warning(
                "timeline age janitor disabled by malformed configuration "
                "variables={} values={}; unset the variable to use its default",
                malformed,
                {ENV_MAX_AGE_SECONDS: raw_age, ENV_INTERVAL_SECONDS: raw_interval},
            )
        return cls(
            store,
            enabled=not malformed,
            max_age_seconds=(
                DEFAULT_MAX_AGE_SECONDS if max_age is None else max_age
            ),
            interval_seconds=(
                DEFAULT_INTERVAL_SECONDS if interval is None else interval
            ),
        )

    async def run_once(self) -> list[str]:
        """Run one sweep; returns the closed item ids (empty when nothing is due)."""

        if not self.enabled:
            return []
        older_than = datetime.now(UTC) - timedelta(seconds=self._max_age_seconds)
        candidates = await self._store.stale_running_tool_candidates(
            older_than=older_than,
            limit=self._candidate_limit,
        )
        by_session: dict[str, list[str]] = {}
        for session_id, item_id in candidates:
            by_session.setdefault(session_id, []).append(item_id)
        closed: list[str] = []
        for session_id, item_ids in by_session.items():
            try:
                result = await self._store.close_stale_running_tool_items(
                    session_id=session_id,
                    item_ids=item_ids,
                    older_than=older_than,
                    closed_by_evidence=CLOSED_BY_EVIDENCE,
                )
                closed.extend(item.id for item in result.items)
            except KeyError:
                continue  # The session vanished between the probe and the close.
            except Exception as exc:  # noqa: BLE001 - keep sweeping other sessions
                logger.warning(
                    "timeline age janitor close deferred session_id={} error={}",
                    session_id,
                    exc,
                )
        if closed:
            logger.info(
                "timeline age janitor sweep closed={} sessions={}",
                len(closed),
                len(by_session),
            )
        return closed

    async def run(self) -> None:
        """Sweep on a fixed period; a failing sweep never kills the loop."""

        if not self.enabled:
            return
        logger.info(
            "timeline age janitor started interval_seconds={} max_age_seconds={}",
            self._interval_seconds,
            self._max_age_seconds,
        )
        while True:
            await asyncio.sleep(self._interval_seconds)
            try:
                await self.run_once()
            except Exception as exc:  # noqa: BLE001 - keep the janitor alive
                logger.warning("timeline age janitor sweep deferred error={}", exc)
