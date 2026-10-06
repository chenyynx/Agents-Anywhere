from __future__ import annotations

from dataclasses import dataclass

from connector.runtime_protocol import (
    CAPABILITY_CATALOG_EFFORT,
    CAPABILITY_CATALOG_MODEL,
    CAPABILITY_CATALOG_PERMISSION,
    CAPABILITY_RUNTIME_ATTACHMENT,
    CAPABILITY_SESSION_COMMANDS,
    CAPABILITY_SESSION_INTERACTION_APPROVAL,
    CAPABILITY_SESSION_INTERRUPT,
    CAPABILITY_SESSION_SEND_MESSAGE,
    CAPABILITY_SESSION_STEER,
    CAPABILITY_SESSION_SUBAGENT_CONTROL,
    RuntimeCapability,
    RuntimeCapabilitySet,
    SessionState,
)
from connector.runtimes.claude import provider_config


@dataclass(frozen=True, slots=True)
class ClaudeCapabilityContext:
    connector_id: str
    revision: int
    session_id: str | None = None
    external_session_id: str | None = None
    has_active_turn: bool = False
    #: The SDK this connector loaded offers ``stop_task`` (the per-task stop
    #: control). False on an SDK without the method.
    subagent_control_supported: bool = False
    #: A live (non-closing) runtime connection hosts this session. The
    #: per-task stop rides that connection, so this — not the turn — decides
    #: ``session.subagent_control`` availability: background subagents can be
    #: running while the session itself is idle.
    connection_online: bool = False


def claude_runtime_capabilities(
    context: ClaudeCapabilityContext,
) -> RuntimeCapabilitySet:
    capabilities = provider_config.claude_capabilities()
    return RuntimeCapabilitySet(
        runtime="claude",
        revision=context.revision,
        connector_id=context.connector_id,
        capabilities=tuple(
            RuntimeCapability(
                capability_id=protocol_id,
                scope="runtime",
                runtime="claude",
                connector_id=context.connector_id,
                supported=supported,
                available=supported,
                allowed=True,
                unavailable_reason=None if supported else "not_implemented",
                metadata={"source": "claude.runtime"},
            )
            for inventory_key, protocol_id in (
                ("modelCatalog", CAPABILITY_CATALOG_MODEL),
                ("modelCatalog", CAPABILITY_CATALOG_EFFORT),
                ("permissionCatalog", CAPABILITY_CATALOG_PERMISSION),
                ("startTurn", CAPABILITY_SESSION_SEND_MESSAGE),
                ("steerTurn", CAPABILITY_SESSION_STEER),
                ("interruptTurn", CAPABILITY_SESSION_INTERRUPT),
                ("interactions", CAPABILITY_SESSION_INTERACTION_APPROVAL),
                ("attachments", CAPABILITY_RUNTIME_ATTACHMENT),
            )
            for supported in (capabilities.get(inventory_key) is True,)
        ),
        metadata={"source": "claude.runtime"},
    )


def resolve_session_binding(
    external_session_id: str | None,
    state: SessionState | None,
    stored_external_session_id: str | None,
) -> str | None:
    """The CLI conversation id a turn or command would actually act on.

    The caller-supplied id wins, then the live cached state, then the store, which
    is the same precedence ``ClaudeCommandController`` uses; the capability bit and
    the per-command catalog therefore never disagree about a loaded session.

    A session this process has never seen (cold connector, id still known to the
    server) resolves to that id rather than to ``None``: the CLI owns the history
    and ``--resume`` reopens it, so it is loaded for command purposes. Nothing
    here reads a session, so an id the CLI no longer knows simply fails its turn
    visibly instead of being reported as a silent success.
    """

    for candidate in (
        external_session_id,
        state.external_session_id if state is not None else None,
        stored_external_session_id,
    ):
        if candidate:
            return candidate
    return None


def session_loaded(context: ClaudeCapabilityContext) -> bool:
    return context.external_session_id is not None


def session_unloaded_reason(context: ClaudeCapabilityContext) -> str | None:
    if session_loaded(context):
        return None
    return "session_unloaded"


def claude_session_capabilities(
    context: ClaudeCapabilityContext,
) -> RuntimeCapabilitySet:
    session_id = context.session_id
    active = context.has_active_turn
    loaded = session_loaded(context)
    capabilities = provider_config.claude_capabilities()
    return RuntimeCapabilitySet(
        runtime="claude",
        revision=context.revision,
        session_id=session_id,
        connector_id=context.connector_id,
        capabilities=(
            RuntimeCapability(
                capability_id=CAPABILITY_SESSION_SEND_MESSAGE,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=True,
                available=not active,
                unavailable_reason="turn_active" if active else None,
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_SESSION_INTERRUPT,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=True,
                available=active,
                unavailable_reason=None if active else "no_active_turn",
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_SESSION_SUBAGENT_CONTROL,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=context.subagent_control_supported,
                # Deliberately not turn-gated: background subagents keep
                # running while the session is idle, and the per-task stop
                # rides the live connection, not the turn.
                available=(
                    context.subagent_control_supported and context.connection_online
                ),
                unavailable_reason=(
                    None
                    if context.subagent_control_supported
                    and context.connection_online
                    else (
                        "not_implemented"
                        if not context.subagent_control_supported
                        else "session_disconnected"
                    )
                ),
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_SESSION_INTERACTION_APPROVAL,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=True,
                available=True,
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_SESSION_COMMANDS,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=True,
                # Codex-family semantics (2026-10-02, R1-P1-1): this bit answers
                # "does the session have a loaded CLI conversation to act on",
                # never "is it idle right now". Clients render this reason through
                # their own word list, so it must stay a known token; busy gating
                # belongs to the catalog, which reports `session_<status>` per
                # command and stays reachable while a turn runs.
                available=loaded,
                unavailable_reason=session_unloaded_reason(context),
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_CATALOG_PERMISSION,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=True,
                available=True,
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_CATALOG_MODEL,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=capabilities.get("modelCatalog") is True,
                available=capabilities.get("modelCatalog") is True,
                unavailable_reason=(
                    None
                    if capabilities.get("modelCatalog") is True
                    else "not_implemented"
                ),
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_CATALOG_EFFORT,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=capabilities.get("modelCatalog") is True,
                available=capabilities.get("modelCatalog") is True,
                unavailable_reason=(
                    None
                    if capabilities.get("modelCatalog") is True
                    else "not_implemented"
                ),
                metadata={"source": "claude.runtime"},
            ),
            RuntimeCapability(
                capability_id=CAPABILITY_RUNTIME_ATTACHMENT,
                scope="session",
                runtime="claude",
                session_id=session_id,
                connector_id=context.connector_id,
                supported=capabilities.get("attachments") is True,
                available=capabilities.get("attachments") is True,
                unavailable_reason=(
                    None
                    if capabilities.get("attachments") is True
                    else "not_implemented"
                ),
                metadata={"source": "claude.runtime"},
            ),
        ),
        metadata={"source": "claude.runtime"},
    )
