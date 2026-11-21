"""The per-session revision fence must not outlive a killed Server process.

``RedisCoordinator.lock`` renews ``min(lease / 3, 10s)`` while the section is
held, so the lease only needs to outlive an event-loop stall. A long lease is
pure blast radius: on 2026-11-21 a Server process was killed while holding the
fence for an idle session, and the 300s lease made the next Server's two
connector capability pushes time out (30s each) on that session.
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager

from agent_server.services.session_revision_allocator import (
    SESSION_REVISION_LOCK_LEASE_SECONDS,
    SessionRevisionAllocator,
)


def test_session_fence_lease_is_bounded_for_orphaned_locks() -> None:
    async def exercise() -> None:
        calls: list[tuple[str, float, float | None]] = []

        class Coordinator:
            distributed = True

            @asynccontextmanager
            async def lock(
                self,
                name: str,
                *,
                timeout_seconds: float = 300,
                lease_seconds: float | None = None,
            ):
                calls.append((name, timeout_seconds, lease_seconds))
                yield

        allocator = SessionRevisionAllocator(
            store=object(),  # type: ignore[arg-type] - unused by the fence
            coordinator=Coordinator(),  # type: ignore[arg-type]
        )
        async with allocator.session_fence("session-1"):
            pass

        assert calls == [
            ("session-revision:session-1", 30, SESSION_REVISION_LOCK_LEASE_SECONDS)
        ]
        # A killed holder must free the session within a minute instead of
        # five, so the next capability batch is not blocked for minutes. Zero
        # would also silently fall back to `timeout_seconds` in the coordinator.
        assert 0 < SESSION_REVISION_LOCK_LEASE_SECONDS <= 60

    asyncio.run(exercise())
