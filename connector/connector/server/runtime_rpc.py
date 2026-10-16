from __future__ import annotations

from collections.abc import Callable
from typing import Any, ClassVar

from connector.logging import logger
from connector.runtime_protocol import (
    AgentRuntime,
    RuntimeHostClient,
    RuntimeInvalidRequestError,
    RuntimeScope,
    RuntimeSupervisor,
)
from connector.runtime_protocol.instance_binding import runtime_config_for_instance
from connector.server.runtime_rpc_params import (
    RuntimeCatalogParams,
    RuntimeConfigParams,
    RuntimeIdParams,
    SessionReadParams,
    scoped_runtime,
)
from connector.server.runtime_rpc_payloads import (
    capability_set_payload,
    model_catalog_payload,
    permission_catalog_payload,
    runtime_config_payload,
    runtime_config_schema_payload,
    runtime_type_descriptor_payload,
)
from connector.server.runtime_session_rpc import (
    discover_sessions,
    read_session_capabilities,
    read_session_notices,
    read_session_state,
    sync_session_snapshot,
)
from connector.server.runtime_turn_rpc import (
    dispatch_interaction_respond,
    dispatch_runtime_commands,
    dispatch_session_command_execute,
    dispatch_session_commands,
    dispatch_session_create,
    dispatch_session_interrupt,
    dispatch_session_selections_update,
    dispatch_session_send_message,
    dispatch_session_steer,
    dispatch_session_stop_subagent,
)

BackgroundScheduler = Callable[[Any], None]


class RuntimeRpcHandler:
    """Route Runtime Control and Agent Runtime Protocol calls."""

    METHODS: ClassVar[set[str]] = {
        "runtime.discover",
        "runtime.configSchema",
        "runtime.config",
        "runtime.validateConfig",
        "runtime.start",
        "runtime.stop",
        "runtime.capabilities",
        "runtime.commands",
        "runtime.modelCatalog",
        "runtime.permissionCatalog",
        "session.discover",
        "session.create",
        "session.sync",
        "session.state",
        "session.capabilities",
        "session.notices",
        "session.selections.update",
        "session.commands",
        "session.command.execute",
        "interaction.respond",
        "session.send_message",
        "session.steer",
        "session.interrupt",
        "session.stopSubagent",
    }

    def __init__(
        self,
        agent_runtime_supervisor: RuntimeSupervisor,
        agent_runtime_host: RuntimeHostClient,
        schedule_background: BackgroundScheduler | None = None,
    ) -> None:
        self.agent_runtime_supervisor = agent_runtime_supervisor
        self.agent_runtime_host = agent_runtime_host
        self.schedule_background = schedule_background

    def supports(self, method: str) -> bool:
        return method in self.METHODS

    async def dispatch(self, method: str, params: dict[str, Any]) -> Any:
        await self._record_external_session_binding(params)
        if method == "runtime.discover":
            return await self.discover_runtimes(params)
        if method == "runtime.configSchema":
            parsed = RuntimeIdParams.parse(params)
            self._validate_known_scope(parsed.scope)
            schema = await self.agent_runtime_supervisor.provider(
                parsed.runtime_type
            ).get_config_schema()
            result = {"configSchema": runtime_config_schema_payload(schema)}
            return self._scoped_result(parsed.scope, result)
        if method == "runtime.config":
            parsed = RuntimeIdParams.parse(params)
            self._validate_known_scope(parsed.scope)
            entry = self.agent_runtime_supervisor.entry_or_none(parsed.runtime_id)
            if entry is None or entry.runtime is None:
                result = {
                    "runtimeId": parsed.runtime_id,
                    "running": False,
                    "config": None,
                }
            else:
                config = entry.config
                if config is None:
                    config = await entry.runtime.get_config()
                config = runtime_config_for_instance(config, entry.instance)
                result = {
                    "runtimeId": parsed.runtime_id,
                    "running": entry.status == "running",
                    "config": runtime_config_payload(config),
                }
            return self._scoped_result(parsed.scope, result)
        if method == "runtime.validateConfig":
            parsed = self._parse_config_params(params)
            await self.agent_runtime_supervisor.validate_config(
                parsed.instance,
                parsed.config,
                revision=parsed.config_revision,
            )
            return self._scoped_result(
                RuntimeScope(parsed.runtime_id, parsed.runtime_type),
                {"runtimeId": parsed.runtime_id, "valid": True},
            )
        if method == "runtime.start":
            parsed = self._parse_config_params(params)
            await self.agent_runtime_supervisor.start(
                parsed.instance,
                parsed.config,
                revision=parsed.config_revision,
            )
            entry = self.agent_runtime_supervisor.entry(parsed.runtime_id)
            return self._scoped_result(
                RuntimeScope(parsed.runtime_id, parsed.runtime_type),
                {
                    "runtimeId": parsed.runtime_id,
                    "status": entry.status,
                    **({"error": dict(entry.error)} if entry.error is not None else {}),
                    **({"phase": dict(entry.phase)} if entry.phase is not None else {}),
                },
            )
        if method == "runtime.stop":
            parsed = RuntimeIdParams.parse(params)
            self._validate_known_scope(parsed.scope, require_entry=True)
            await self.agent_runtime_supervisor.stop(parsed.runtime_id)
            return self._scoped_result(
                parsed.scope,
                {"runtimeId": parsed.runtime_id, "status": "stopped"},
            )
        if method == "runtime.capabilities":
            runtime = self._resolve_agent_runtime(params)
            capabilities = await runtime.get_runtime_capabilities()
            return self._runtime_result(
                runtime,
                {"capabilitySet": capability_set_payload(capabilities)},
            )
        if method == "runtime.commands":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_runtime_commands(runtime, params),
            )
        if method == "runtime.modelCatalog":
            runtime = self._resolve_agent_runtime(params)
            parsed = RuntimeCatalogParams.parse(params)
            catalog = await runtime.list_model_catalog(
                query=parsed.query,
                limit=parsed.limit,
            )
            return self._runtime_result(
                runtime,
                {"catalog": model_catalog_payload(catalog)},
            )
        if method == "runtime.permissionCatalog":
            runtime = self._resolve_agent_runtime(params)
            parsed = RuntimeCatalogParams.parse(params)
            catalog = await runtime.list_permission_catalog(
                query=parsed.query,
                limit=parsed.limit,
            )
            return self._runtime_result(
                runtime,
                {"catalog": permission_catalog_payload(catalog)},
            )
        if method == "session.discover":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await discover_sessions(runtime, self.agent_runtime_host, params),
            )
        if method == "session.create":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_create(runtime, params),
            )
        if method == "session.sync":
            return self.accept_session_sync(params)
        if method == "session.state":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await read_session_state(runtime, self.agent_runtime_host, params),
            )
        if method == "session.capabilities":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await read_session_capabilities(runtime, params),
            )
        if method == "session.notices":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await read_session_notices(runtime, params),
            )
        if method == "session.selections.update":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_selections_update(runtime, params),
            )
        if method == "session.commands":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_commands(runtime, params),
            )
        if method == "session.command.execute":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_command_execute(runtime, params),
            )
        if method == "interaction.respond":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_interaction_respond(runtime, params),
            )
        if method == "session.send_message":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_send_message(runtime, params),
            )
        if method == "session.steer":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_steer(runtime, params),
            )
        if method == "session.interrupt":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_interrupt(runtime, params),
            )
        if method == "session.stopSubagent":
            runtime = self._resolve_agent_runtime(params)
            return self._runtime_result(
                runtime,
                await dispatch_session_stop_subagent(runtime, params),
            )
        raise ValueError(f"unsupported runtime method: {method}")

    async def _record_external_session_binding(
        self,
        params: dict[str, Any],
    ) -> None:
        """Durably record the Server's session id for an external uuid.

        The Server sends both ids whenever it addresses a session it owns
        (``sessionId`` is ``sessions.id``; ``externalSessionId`` is the Claude
        conversation uuid). Persisting that pair the first time a session is
        touched is what lets a restarted Connector resolve a platform-created
        session straight to the Server id instead of re-deriving its own and
        tripping the binding check (2026-10-12 ``sess_92gAb`` 502).

        Only runtime implementations that own an external session identity are
        asked to bind (``bind_external_session``); the capability is probed
        rather than assumed so runtimes without it are unaffected. The whole
        step is best-effort — a failure here must never fail the RPC.
        """

        if not isinstance(params, dict):
            return
        session_id = params.get("sessionId")
        external_session_id = params.get("externalSessionId")
        if not isinstance(session_id, str) or not session_id:
            return
        if not isinstance(external_session_id, str) or not external_session_id:
            return
        try:
            runtime = self._resolve_agent_runtime(params)
        except Exception:  # noqa: BLE001 - binding must never fail the RPC
            return
        record = getattr(runtime, "bind_external_session", None)
        if record is None:
            return
        try:
            await record(external_session_id, session_id)
        except Exception:  # noqa: BLE001 - binding must never fail the RPC
            logger.exception(
                "session binding record failed session_id={} "
                "external_session_id={}",
                session_id,
                external_session_id,
            )

    async def discover_runtimes(
        self,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if params:
            raise RuntimeInvalidRequestError("runtime.discover takes no parameters")
        descriptors = await self.agent_runtime_supervisor.discover()
        return {
            "runtimeTypes": [
                runtime_type_descriptor_payload(descriptor)
                for descriptor in descriptors
            ],
        }

    def accept_session_sync(self, params: dict[str, Any]) -> dict[str, Any]:
        """Accept a session sync request and finish it in the background."""

        if self.schedule_background is None:
            raise RuntimeError("background scheduler is required for session.sync")
        parsed = SessionReadParams.parse(params)
        runtime = self._resolve_agent_runtime(params)
        self.schedule_background(
            sync_session_snapshot(runtime, self.agent_runtime_host, dict(params))
        )
        return self._runtime_result(
            runtime,
            {
                "accepted": True,
                "background": True,
                "sessionId": parsed.session_id,
                "externalSessionId": parsed.external_session_id,
            },
        )

    def _parse_config_params(self, params: dict[str, Any]) -> RuntimeConfigParams:
        return RuntimeConfigParams.parse(params)

    def _resolve_agent_runtime(self, params: dict[str, Any]) -> AgentRuntime:
        scope = scoped_runtime(params)
        return self.agent_runtime_supervisor.resolve_runtime(
            scope.runtime_id,
            scope.runtime_type,
        )

    def _validate_known_scope(
        self,
        scope: RuntimeScope,
        *,
        require_entry: bool = False,
    ) -> None:
        self.agent_runtime_supervisor.provider(scope.runtime_type)
        entry = self.agent_runtime_supervisor.entry_or_none(scope.runtime_id)
        if entry is None:
            if require_entry:
                raise RuntimeInvalidRequestError(
                    f"unknown runtime instance {scope.runtime_id!r}"
                )
            return
        if entry.runtime_type != scope.runtime_type:
            raise RuntimeInvalidRequestError(
                f"runtime instance {scope.runtime_id!r} belongs to type "
                f"{entry.runtime_type!r}, not {scope.runtime_type!r}"
            )

    def _runtime_result(
        self,
        runtime: AgentRuntime,
        result: dict[str, Any],
    ) -> dict[str, Any]:
        identity = runtime.identity
        runtime_id = identity.runtime_id or identity.runtime
        return self._scoped_result(
            RuntimeScope(runtime_id=runtime_id, runtime_type=identity.runtime),
            result,
        )

    def _scoped_result(
        self,
        scope: RuntimeScope,
        result: dict[str, Any],
    ) -> dict[str, Any]:
        return {
            **result,
            "runtime": scope.runtime_type,
            "runtimeId": scope.runtime_id,
        }
