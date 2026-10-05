"""Catalog push continuity against the Server's revision ordering rules.

See `.local-dev/catalog-revision-conflict.md`: the catalog revision tracks the
runtime config revision, which does not move when discovery output drifts, and
the Server rejects same-revision content changes as out of order. These tests
drive the real push path against a mirror of the Server's
`update_protocol_catalog` rules and assert that no conflict can occur, that
unchanged content is not re-pushed, and that a used revision is never handed
to different content — including across restarts.
"""

from __future__ import annotations

import asyncio
from typing import Any

from connector.core.config import ConnectorConfig
from connector.runtime_protocol import (
    RuntimeModelCatalog,
    RuntimeModelItem,
    RuntimePermissionCatalog,
    RuntimePermissionItem,
)
from connector.server.runtime_rpc_payloads import (
    model_catalog_payload,
    permission_catalog_payload,
)
from connector.server.runtime_sync import RuntimeSyncRunner

MODEL_BASE_REVISION = 1_791_156_089_904_004
PERMISSION_BASE_REVISION = 1_791_156_089_904_001
RUNTIME_ID = "rti_test"
STATE_KEY_MODEL = f"claude/instances/{RUNTIME_ID}/catalog-push/model"
STATE_KEY_PERMISSION = f"claude/instances/{RUNTIME_ID}/catalog-push/permission"


class ServerCatalogStore:
    """Mirror of the Server's per-catalog ordering rules.

    `server/agent_server/infra/repositories/protocol_catalogs.py`:
    a lower revision is stale (dropped), an equal revision is idempotent or —
    for different content — a conflict, and a higher revision is accepted.
    """

    def __init__(self) -> None:
        self.revision: int | None = None
        self.payload: dict[str, Any] | None = None
        self.outcomes: list[str] = []

    def update(self, revision: int, payload: dict[str, Any]) -> str:
        if self.revision is not None and self.revision > revision:
            outcome = "stale"
        elif self.revision is not None and self.revision == revision:
            outcome = "idempotent" if self.payload == payload else "conflict"
        else:
            self.revision = revision
            self.payload = payload
            outcome = "accepted"
        self.outcomes.append(outcome)
        return outcome

    @property
    def model_ids(self) -> list[str]:
        return [
            str(model["id"]) for model in (self.payload or {}).get("models", [])
        ]

    @property
    def permission_ids(self) -> list[str]:
        return [
            str(item["id"]) for item in (self.payload or {}).get("permissions", [])
        ]


class CatalogHost:
    """Records pushes and keeps sync state in a dict, like the instance store."""

    def __init__(self, *, fail_state_writes: bool = False) -> None:
        self.pushes: list[tuple[str, int]] = []
        self.state: dict[str, dict[str, Any]] = {}
        self.fail_state_writes = fail_state_writes
        self.prepared_runtime_ids: list[str] = []
        self.model_server = ServerCatalogStore()
        self.permission_server = ServerCatalogStore()

    async def prepare_runtime_host(self, runtime_id: str) -> CatalogHost:
        self.prepared_runtime_ids.append(runtime_id)
        return self

    async def model_catalog_update(self, catalog: RuntimeModelCatalog) -> None:
        self.pushes.append(("model", catalog.revision))
        self.model_server.update(catalog.revision, model_catalog_payload(catalog))

    async def permission_catalog_update(
        self, catalog: RuntimePermissionCatalog
    ) -> None:
        self.pushes.append(("permission", catalog.revision))
        self.permission_server.update(
            catalog.revision, permission_catalog_payload(catalog)
        )

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.state.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        if self.fail_state_writes:
            raise OSError("state store unavailable")
        self.state[key] = dict(value)

    @property
    def revisions(self) -> dict[str, list[int]]:
        result: dict[str, list[int]] = {"model": [], "permission": []}
        for catalog_type, revision in self.pushes:
            result[catalog_type].append(revision)
        return result


class StatelessCatalogHost(CatalogHost):
    """A host from before catalog push state existed (no state store)."""

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        raise NotImplementedError

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        raise NotImplementedError


class CatalogRuntime:
    """Runtime double: only the two catalog reads the push path performs."""

    def __init__(self) -> None:
        self.model_base_revision = MODEL_BASE_REVISION
        self.permission_base_revision = PERMISSION_BASE_REVISION
        self.model_ids = ("alpha", "beta")
        self.permission_ids = ("default",)
        self.model_reads = 0
        self.permission_reads = 0

    async def list_model_catalog(
        self, query: str | None = None, limit: int = 100
    ) -> RuntimeModelCatalog:
        self.model_reads += 1
        return RuntimeModelCatalog(
            runtime="claude",
            runtime_id=RUNTIME_ID,
            revision=self.model_base_revision,
            models=tuple(
                RuntimeModelItem(
                    id=model_id,
                    title=model_id,
                    selection_id=f"sel_model_{model_id}",
                )
                for model_id in self.model_ids
            ),
        )

    async def list_permission_catalog(
        self, query: str | None = None, limit: int = 100
    ) -> RuntimePermissionCatalog:
        self.permission_reads += 1
        return RuntimePermissionCatalog(
            runtime="claude",
            runtime_id=RUNTIME_ID,
            revision=self.permission_base_revision,
            permissions=tuple(
                RuntimePermissionItem(
                    id=item_id,
                    title=item_id,
                    selection_id=f"sel_permission_{item_id}",
                )
                for item_id in self.permission_ids
            ),
        )


async def _unexpected_notification(method: str, params: dict[str, Any]) -> None:
    raise AssertionError(f"unexpected notification {method}: {params}")


def _runner(host: CatalogHost) -> RuntimeSyncRunner:
    return RuntimeSyncRunner(
        config=ConnectorConfig(
            server_url="http://127.0.0.1:8000",
            connector_id="conn_1",
            connector_token="token",
        ),
        supervisor=None,  # type: ignore[arg-type]
        host=host,  # type: ignore[arg-type]
        preferences_reader=dict,
        send_notification=_unexpected_notification,
    )


async def _exercise_first_push_then_skip() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost()
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    # First contact publishes one step above the derived revision so a drifted
    # catalog beats a Server row frozen at the derived revision.
    assert host.pushes == [
        ("model", MODEL_BASE_REVISION + 1),
        ("permission", PERMISSION_BASE_REVISION + 1),
    ]
    assert host.model_server.outcomes == ["accepted"]
    assert host.model_server.model_ids == ["alpha", "beta"]
    assert host.permission_server.permission_ids == ["default"]
    assert host.prepared_runtime_ids == [RUNTIME_ID]
    assert set(host.state) == {STATE_KEY_MODEL, STATE_KEY_PERMISSION}

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    # Unchanged content: the (cached) read still runs, the push does not.
    assert len(host.pushes) == 2
    assert runtime.model_reads == 2
    assert runtime.permission_reads == 2
    assert host.model_server.outcomes == ["accepted"]


async def _exercise_changed_content_bumps_and_revert_bumps_again() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost()
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    runtime.model_ids = ("alpha", "beta", "zcode/GLM-5.3")  # discovery drift
    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    runtime.model_ids = ("alpha", "beta")  # drift back to the earlier content
    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    assert host.revisions["model"] == [
        MODEL_BASE_REVISION + 1,
        MODEL_BASE_REVISION + 2,
        MODEL_BASE_REVISION + 3,
    ]
    assert host.model_server.outcomes == ["accepted", "accepted", "accepted"]
    assert host.model_server.model_ids == ["alpha", "beta"]


async def _exercise_base_revision_regression_never_rewinds() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost()
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    # The config revision can move backwards from the stream's point of view
    # (a runtime record restarted with an older stamp): the next content change
    # must still step above the last revision this connector used.
    runtime.model_base_revision = MODEL_BASE_REVISION - 1000
    runtime.model_ids = ("alpha", "beta", "gamma")
    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    assert host.revisions["model"] == [
        MODEL_BASE_REVISION + 1,
        MODEL_BASE_REVISION + 2,
    ]
    assert host.model_server.outcomes == ["accepted", "accepted"]

    # The Server still drops an out-of-order regression; the connector simply
    # never produces one.
    assert host.model_server.update(
        host.revisions["model"][0], {"runtime": "claude", "revision": 0, "models": []}
    ) == "stale"


async def _exercise_restart_skips_unchanged_and_bumps_after_change() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost()

    first_process = _runner(host)
    await first_process.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    # A new process reads the persisted state back: unchanged content stays
    # unpushed, and the recorded revision is respected.
    restarted = _runner(host)
    await restarted.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    assert host.revisions["model"] == [MODEL_BASE_REVISION + 1]

    runtime.model_ids = ("alpha", "beta", "gamma")
    await restarted.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    assert host.revisions["model"] == [
        MODEL_BASE_REVISION + 1,
        MODEL_BASE_REVISION + 2,
    ]
    assert "conflict" not in host.model_server.outcomes


async def _exercise_failed_state_persistence_keeps_continuity() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost(fail_state_writes=True)
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    runtime.model_ids = ("alpha", "beta", "gamma")
    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    assert host.state == {}
    assert host.revisions["model"] == [
        MODEL_BASE_REVISION + 1,
        MODEL_BASE_REVISION + 2,
    ]
    assert "conflict" not in host.model_server.outcomes


async def _exercise_unavailable_state_store_still_publishes() -> None:
    runtime = CatalogRuntime()
    host = StatelessCatalogHost()
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    assert host.revisions["model"] == [MODEL_BASE_REVISION + 1]
    assert host.model_server.outcomes == ["accepted"]


async def _exercise_catalog_types_track_state_separately() -> None:
    runtime = CatalogRuntime()
    host = CatalogHost()
    runner = _runner(host)

    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]
    runtime.permission_ids = ("default", "accept-edits")
    await runner.push_runtime_catalogs(runtime)  # type: ignore[arg-type]

    assert host.revisions["model"] == [MODEL_BASE_REVISION + 1]
    assert host.revisions["permission"] == [
        PERMISSION_BASE_REVISION + 1,
        PERMISSION_BASE_REVISION + 2,
    ]
    assert "conflict" not in host.permission_server.outcomes


def test_catalog_first_push_bumps_and_unchanged_content_is_skipped() -> None:
    asyncio.run(_exercise_first_push_then_skip())


def test_catalog_changed_content_bumps_and_revert_bumps_again() -> None:
    asyncio.run(_exercise_changed_content_bumps_and_revert_bumps_again())


def test_catalog_base_revision_regression_never_rewinds() -> None:
    asyncio.run(_exercise_base_revision_regression_never_rewinds())


def test_catalog_restart_skips_unchanged_and_bumps_after_change() -> None:
    asyncio.run(_exercise_restart_skips_unchanged_and_bumps_after_change())


def test_catalog_failed_state_persistence_keeps_continuity() -> None:
    asyncio.run(_exercise_failed_state_persistence_keeps_continuity())


def test_catalog_unavailable_state_store_still_publishes() -> None:
    asyncio.run(_exercise_unavailable_state_store_still_publishes())


def test_catalog_types_track_state_separately() -> None:
    asyncio.run(_exercise_catalog_types_track_state_separately())
