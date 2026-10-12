"""Durable external-uuid -> Server session-id binding.

Regression suite for the 2026-10-12 ``sess_92gAb`` 502: a platform-created
session is given its id by the Server, but the Connector only ever derived and
persisted its own ``sess_claude_<hash>`` id from the Claude conversation uuid.
After a Connector restart the in-memory map was gone, a history scan rebuilt the
session under the derived id, and the Server rejected the mismatched
``sessionId`` on the next ``session.state`` read.
"""

from __future__ import annotations

import asyncio
import hashlib
from typing import Any

from connector.runtime_protocol import RuntimeConfig, RuntimeHostClient
from connector.runtimes.claude.domain.pending_messages import (
    ClaudePendingClientMessageRegistry,
)
from connector.runtimes.claude.domain.session import (
    ClaudeSession,
    stable_session_id,
)
from connector.runtimes.claude.sessions.bindings import (
    ClaudeSessionBinding,
    ClaudeSessionBindingStore,
    binding_from_state,
    binding_to_state,
    session_binding_key,
)
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.sessions.reader import ClaudeSessionReader
from connector.runtimes.claude.sessions.sync_state import ClaudeSessionSyncStateStore

SERVER_SESSION_ID = "sess_92gAbPjhjE6DXQ"
EXTERNAL_SESSION_ID = "80bbecf5-8274-4f5a-aaa5-ae3208a5cd03"
CONNECTOR_ID = "conn_s2HhYD2EJC0ZOw"
RUNTIME_ID = "rti_Yf-sPig8OL5kRbz3"


class _BindingHost(RuntimeHostClient):
    """Host with the three sync-state hooks the binding store uses."""

    def __init__(self) -> None:
        self.sync_states: dict[str, dict[str, Any]] = {}
        self.fail_write = False
        self.write_count = 0

    @property
    def connector_id(self) -> str:
        return CONNECTOR_ID

    async def sync_state_read(self, key: str) -> dict[str, Any] | None:
        return self.sync_states.get(key)

    async def sync_state_write(self, key: str, value: dict[str, Any]) -> None:
        self.write_count += 1
        if self.fail_write:
            raise RuntimeError("disk full")
        self.sync_states[key] = value

    async def sync_state_delete(self, key: str) -> None:
        self.sync_states.pop(key, None)

    async def session_state_update(
        self,
        session_id: str,
        runtime: str,
        status: Any = None,
        selections: Any = None,
        external_session_id: str | None = None,
        status_reason: str | None = None,
        error: Any = None,
        metadata: Any = None,
    ) -> None:
        # The state cache pushes merges through the host; a fake host that
        # absorbs them keeps the cache usable in tests.
        return None


def _derived_id(external_session_id: str) -> str:
    """Mirror the Connector's own derivation (namespace = conn:claude:rti_)."""
    namespace = f"{CONNECTOR_ID}:claude:{RUNTIME_ID}"
    digest = hashlib.sha256(
        f"{namespace}:claude:{external_session_id}".encode()
    ).hexdigest()[:24]
    return f"sess_claude_{digest}"


def _reader(
    host: _BindingHost,
    *,
    sessions: dict[str, ClaudeSession] | None = None,
) -> ClaudeSessionReader:
    return ClaudeSessionReader(
        config=RuntimeConfig(
            runtime="claude",
            revision=1,
            values={"environment": {}},
            runtime_id=RUNTIME_ID,
        ),
        host=host,
        session_store=ClaudeSessionStore(sessions if sessions is not None else {}),
        sdk_loader=None,
        sync_states=ClaudeSessionSyncStateStore(host),
        pending_messages=ClaudePendingClientMessageRegistry(CONNECTOR_ID),
        bindings=ClaudeSessionBindingStore(host),
    )


# --------------------------------------------------------------------------
# D1 — the 502 reproduction: local store only knows the derived id.
# --------------------------------------------------------------------------


def test_read_echoes_caller_id_when_local_id_diverged() -> None:
    """Local store holds the re-derived id; caller gives the Server id.

    Before the fix the reader returned ``local_session.session_id`` (the
    derived one) and the Server rejected it. The reader must echo the caller's
    id, reached through the shared ``external_session_id``.
    """

    async def run() -> None:
        derived = _derived_id(EXTERNAL_SESSION_ID)
        host = _BindingHost()
        sessions = {
            derived: ClaudeSession(
                session_id=derived,
                external_session_id=EXTERNAL_SESSION_ID,
            )
        }
        reader = _reader(host, sessions=sessions)

        state = await reader.get_session_state(SERVER_SESSION_ID, EXTERNAL_SESSION_ID)

        assert state is not None
        assert state.session_id == SERVER_SESSION_ID
        assert state.external_session_id == EXTERNAL_SESSION_ID

    asyncio.run(run())


def test_read_uses_local_id_when_it_matches_caller() -> None:
    """connector_import path: caller and local agree — behaviour is unchanged."""

    async def run() -> None:
        host = _BindingHost()
        sessions = {
            SERVER_SESSION_ID: ClaudeSession(
                session_id=SERVER_SESSION_ID,
                external_session_id=EXTERNAL_SESSION_ID,
            )
        }
        reader = _reader(host, sessions=sessions)

        state = await reader.get_session_state(SERVER_SESSION_ID, EXTERNAL_SESSION_ID)

        assert state is not None
        assert state.session_id == SERVER_SESSION_ID

    asyncio.run(run())


# --------------------------------------------------------------------------
# D2 — durable binding survives a restart (fresh reader, empty memory).
# --------------------------------------------------------------------------


def test_binding_survives_restart() -> None:
    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)

        # Simulate a restart: brand-new reader, empty in-memory session store,
        # but the same persisted sync-state.
        reader = _reader(host, sessions={})
        state = await reader.get_session_state(SERVER_SESSION_ID, EXTERNAL_SESSION_ID)

        assert state is not None
        assert state.session_id == SERVER_SESSION_ID
        assert state.metadata["source"] == "claude.session.binding.state"

    asyncio.run(run())


def test_runtime_cache_hit_with_divergent_id_falls_through() -> None:
    """A cache hit keyed by the wrong id must not shadow the caller's id.

    Red-team P2: ``ClaudeRuntime.get_session_state`` short-circuits on the
    in-memory state cache before reaching the reader. A stale entry reached via
    the external uuid could carry a divergent ``session_id`` and bypass the
    reader's "caller-supplied id wins" rule, reintroducing the 502. The cache
    hit is only trusted when it agrees with the caller.
    """

    async def run() -> None:
        from connector.runtime_protocol import RuntimeConfig as _RC
        from connector.runtimes.claude.runtime import ClaudeRuntime

        host = _BindingHost()
        derived = _derived_id(EXTERNAL_SESSION_ID)
        await ClaudeSessionBindingStore(host).write(
            EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID
        )
        runtime = ClaudeRuntime(
            config=_RC(
                runtime="claude",
                revision=1,
                values={"environment": {}},
                runtime_id=RUNTIME_ID,
            ),
            host=host,
        )
        # Seed the cache with an entry whose id diverged from the Server's,
        # written straight into the cache maps so no host capability hook runs.
        from connector.runtime_protocol import SessionState

        runtime._session_states._states[derived] = SessionState(
            session_id=derived,
            external_session_id=EXTERNAL_SESSION_ID,
            runtime="claude",
            status="idle",
        )
        runtime._session_states._session_ids_by_external_id[
            EXTERNAL_SESSION_ID
        ] = derived
        state = await runtime.get_session_state(SERVER_SESSION_ID, EXTERNAL_SESSION_ID)
        assert state is not None
        # Not the cached divergent id — resolved to the caller's id.
        assert state.session_id == SERVER_SESSION_ID

    asyncio.run(run())


def test_binding_branch_honours_caller_id_over_stale_binding() -> None:
    """A stale binding must not shadow the id the Server just supplied.

    Red-team P2: the binding branch returned ``binding.session_id`` verbatim,
    contradicting the local branch's "caller-supplied id wins" rule. If the
    binding is stale (its write failed on a fail-soft path, or the Server moved
    the session) the returned id disagrees with the Server's and the read 502s
    again — with the local branch empty, the read-defence cannot help.
    """

    async def run() -> None:
        host = _BindingHost()
        stale = "sess_STALE0000000000"
        await ClaudeSessionBindingStore(host).write(
            EXTERNAL_SESSION_ID, stale, RUNTIME_ID
        )
        reader = _reader(host, sessions={})
        state = await reader.get_session_state(SERVER_SESSION_ID, EXTERNAL_SESSION_ID)
        assert state is not None
        # Caller's id wins; the stale binding does not leak through.
        assert state.session_id == SERVER_SESSION_ID

    asyncio.run(run())


def test_binding_write_is_idempotent() -> None:
    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        first_count = host.write_count
        # The per-read RPC path re-records the same pair constantly; it must
        # not churn the sync-state file.
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        assert host.write_count == first_count

    asyncio.run(run())


def test_non_authoritative_write_keeps_existing_binding() -> None:
    """A locally derived id must never overwrite the Server's binding.

    Red-team P3: a legacy scheduled session resumed under its re-derived id
    would otherwise regress a correct binding to the derived id.
    """

    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        # A local (non-authoritative) write with the derived id is dropped.
        await store.write(
            EXTERNAL_SESSION_ID,
            _derived_id(EXTERNAL_SESSION_ID),
            authoritative=False,
        )
        stored = await store.read(EXTERNAL_SESSION_ID)
        assert stored is not None
        assert stored.session_id == SERVER_SESSION_ID

    asyncio.run(run())


def test_non_authoritative_write_sets_binding_when_absent() -> None:
    """With no binding yet, even a local write seeds one (better than none)."""

    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        derived = _derived_id(EXTERNAL_SESSION_ID)
        await store.write(EXTERNAL_SESSION_ID, derived, authoritative=False)
        stored = await store.read(EXTERNAL_SESSION_ID)
        assert stored is not None and stored.session_id == derived

    asyncio.run(run())


def test_authoritative_write_can_change_binding() -> None:
    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        await store.write(
            EXTERNAL_SESSION_ID,
            _derived_id(EXTERNAL_SESSION_ID),
            authoritative=False,
        )
        # The Server moving the session to a new id is authoritative and wins.
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)
        stored = await store.read(EXTERNAL_SESSION_ID)
        assert stored is not None and stored.session_id == SERVER_SESSION_ID

    asyncio.run(run())


def test_binding_write_failure_is_soft() -> None:
    async def run() -> None:
        host = _BindingHost()
        host.fail_write = True
        store = ClaudeSessionBindingStore(host)
        # Must not raise: a persistence failure cannot break the RPC it rides.
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        assert await store.read(EXTERNAL_SESSION_ID) is None

    asyncio.run(run())


def test_binding_read_failure_is_soft() -> None:
    async def run() -> None:
        host = _BindingHost()

        async def boom(_key: str) -> dict[str, Any] | None:
            raise RuntimeError("corrupt")

        host.sync_state_read = boom  # type: ignore[method-assign]
        store = ClaudeSessionBindingStore(host)
        assert await store.read(EXTERNAL_SESSION_ID) is None

    asyncio.run(run())


def test_binding_delete_clears_the_pair() -> None:
    async def run() -> None:
        host = _BindingHost()
        store = ClaudeSessionBindingStore(host)
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        await store.delete(EXTERNAL_SESSION_ID)
        assert await store.read(EXTERNAL_SESSION_ID) is None

    asyncio.run(run())


# --------------------------------------------------------------------------
# Serialization round-trip and malformed state.
# --------------------------------------------------------------------------


def test_binding_state_round_trip() -> None:
    binding = ClaudeSessionBinding(
        session_id=SERVER_SESSION_ID,
        runtime_id=RUNTIME_ID,
        updated_at="2026-10-12T00:00:00+00:00",
    )
    assert binding_from_state(binding_to_state(binding)) == binding


def test_binding_from_malformed_state_is_none() -> None:
    assert binding_from_state(None) is None
    assert binding_from_state({}) is None
    assert binding_from_state({"sessionId": ""}) is None
    assert binding_from_state({"sessionId": 123}) is None
    # A non-Mapping stored value must not raise: read/write call this outside
    # their try, so an AttributeError would escape the fail-soft contract.
    assert binding_from_state(["not", "a", "mapping"]) is None  # type: ignore[arg-type]
    assert binding_from_state("scalar") is None  # type: ignore[arg-type]
    assert binding_from_state(42) is None  # type: ignore[arg-type]


def test_binding_read_survives_non_mapping_state() -> None:
    async def run() -> None:
        host = _BindingHost()
        host.sync_states[session_binding_key(EXTERNAL_SESSION_ID)] = "garbage"  # type: ignore[assignment]
        store = ClaudeSessionBindingStore(host)
        assert await store.read(EXTERNAL_SESSION_ID) is None
        # A write on top of a malformed value must also stay fail-soft.
        await store.write(EXTERNAL_SESSION_ID, SERVER_SESSION_ID, RUNTIME_ID)
        stored = await store.read(EXTERNAL_SESSION_ID)
        assert stored is not None and stored.session_id == SERVER_SESSION_ID

    asyncio.run(run())


def test_binding_key_is_namespaced() -> None:
    assert session_binding_key(EXTERNAL_SESSION_ID) == (
        f"claude/session-binding/{EXTERNAL_SESSION_ID}"
    )


def test_stable_session_id_differs_from_server_id() -> None:
    """Guard the premise: the derived id really does differ from the Server's.

    If a future change makes these coincide, the repro this suite encodes stops
    being a repro — the assertion makes that visible instead of silently
    passing.
    """

    derived = stable_session_id(CONNECTOR_ID, EXTERNAL_SESSION_ID)
    assert derived != SERVER_SESSION_ID


# --------------------------------------------------------------------------
# D3 — the RPC entry point records the binding; the runtime exposes the hook.
# --------------------------------------------------------------------------


class _RecordingRuntime:
    """Minimal runtime standing in for ClaudeRuntime at the RPC boundary."""

    def __init__(self) -> None:
        self.bound: list[tuple[str, str]] = []

    @property
    def identity(self) -> Any:
        from connector.runtime_protocol import RuntimeIdentity

        return RuntimeIdentity(
            runtime="claude",
            runtime_version="native-0",
            runtime_id=RUNTIME_ID,
        )

    async def bind_external_session(
        self, external_session_id: str, session_id: str
    ) -> None:
        self.bound.append((external_session_id, session_id))


class _StubSupervisor:
    def __init__(self, runtime: Any) -> None:
        self._runtime = runtime

    def resolve_runtime(self, runtime_id: str, runtime_type: str | None = None) -> Any:
        return self._runtime


def test_dispatch_records_binding_from_params() -> None:
    """Any RPC carrying both ids records the binding (existing-library heal)."""

    async def run() -> None:
        from connector.server.runtime_rpc import RuntimeRpcHandler

        runtime = _RecordingRuntime()
        handler = RuntimeRpcHandler(_StubSupervisor(runtime), _BindingHost())  # type: ignore[arg-type]
        params = {
            "runtime": "claude",
            "runtimeId": RUNTIME_ID,
            "sessionId": SERVER_SESSION_ID,
            "externalSessionId": EXTERNAL_SESSION_ID,
        }
        await handler._record_external_session_binding(params)
        assert runtime.bound == [(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)]

    asyncio.run(run())


def test_dispatch_binding_skipped_without_external_id() -> None:
    async def run() -> None:
        from connector.server.runtime_rpc import RuntimeRpcHandler

        runtime = _RecordingRuntime()
        handler = RuntimeRpcHandler(_StubSupervisor(runtime), _BindingHost())  # type: ignore[arg-type]
        await handler._record_external_session_binding(
            {
                "runtime": "claude",
                "runtimeId": RUNTIME_ID,
                "sessionId": SERVER_SESSION_ID,
            }
        )
        assert runtime.bound == []

    asyncio.run(run())


def test_dispatch_binding_is_soft_on_runtime_without_hook() -> None:
    async def run() -> None:
        from connector.server.runtime_rpc import RuntimeRpcHandler

        handler = RuntimeRpcHandler(_StubSupervisor(object()), _BindingHost())  # type: ignore[arg-type]
        # A runtime without the hook must not raise — the step is best-effort.
        await handler._record_external_session_binding(
            {
                "runtime": "claude",
                "runtimeId": RUNTIME_ID,
                "sessionId": SERVER_SESSION_ID,
                "externalSessionId": EXTERNAL_SESSION_ID,
            }
        )

    asyncio.run(run())


def test_rpc_hook_reaches_runtime_through_instance_wrapper() -> None:
    """The RPC hook must find the binding method behind the instance wrapper.

    Regression for the production gap found 2026-10-12: ``resolve_runtime``
    returns a ``RuntimeInstance`` wrapper with an explicit method list and no
    ``__getattr__`` passthrough, so ``getattr(runtime, 'bind_external_session',
    None)`` returned ``None`` and the write never fired — the read-defence
    still returned 200, so only a wrapper-level test catches it.
    """

    async def run() -> None:
        from connector.runtime_protocol.instance_binding import RuntimeInstance
        from connector.runtime_protocol.instance_models import RuntimeInstanceSpec
        from connector.server.runtime_rpc import RuntimeRpcHandler

        native = _RecordingRuntime()
        instance = RuntimeInstanceSpec(
            runtime_type="claude",
            runtime_id=RUNTIME_ID,
            name=RUNTIME_ID,
        )
        wrapped = RuntimeInstance(instance=instance, native_runtime=native)  # type: ignore[arg-type]
        handler = RuntimeRpcHandler(_StubSupervisor(wrapped), _BindingHost())  # type: ignore[arg-type]
        await handler._record_external_session_binding(
            {
                "runtime": "claude",
                "runtimeId": RUNTIME_ID,
                "sessionId": SERVER_SESSION_ID,
                "externalSessionId": EXTERNAL_SESSION_ID,
            }
        )
        assert native.bound == [(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)]

    asyncio.run(run())


def test_instance_wrapper_exposes_bind_external_session() -> None:
    async def run() -> None:
        from connector.runtime_protocol.instance_binding import RuntimeInstance
        from connector.runtime_protocol.instance_models import RuntimeInstanceSpec

        native = _RecordingRuntime()
        wrapped = RuntimeInstance(
            instance=RuntimeInstanceSpec(
                runtime_type="claude",
                runtime_id=RUNTIME_ID,
                name=RUNTIME_ID,
            ),
            native_runtime=native,  # type: ignore[arg-type]
        )
        await wrapped.bind_external_session(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)
        assert native.bound == [(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)]

    asyncio.run(run())


def test_base_runtime_bind_external_session_is_noop() -> None:
    """Other providers inherit a no-op so their RPCs are unaffected."""

    async def run() -> None:
        from connector.runtime_protocol.protocol import AgentRuntime

        class _Bare(AgentRuntime):
            def __init__(self) -> None:
                pass

            @property
            def identity(self):  # type: ignore[override]
                raise NotImplementedError

        bare = _Bare()
        # Must not raise and must return nothing.
        assert (
            await bare.bind_external_session(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)
            is None
        )

    asyncio.run(run())


def test_claude_runtime_bind_external_session_persists() -> None:
    """The real ClaudeRuntime writes through to the durable store."""

    async def run() -> None:
        from connector.runtimes.claude.runtime import ClaudeRuntime

        host = _BindingHost()
        runtime = ClaudeRuntime(
            config=RuntimeConfig(
                runtime="claude",
                revision=1,
                values={"environment": {}},
                runtime_id=RUNTIME_ID,
            ),
            host=host,
        )
        await runtime.bind_external_session(EXTERNAL_SESSION_ID, SERVER_SESSION_ID)
        stored = await ClaudeSessionBindingStore(host).read(EXTERNAL_SESSION_ID)
        assert stored is not None
        assert stored.session_id == SERVER_SESSION_ID

    asyncio.run(run())

