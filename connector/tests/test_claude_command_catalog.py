from __future__ import annotations

import pytest

from connector.runtime_protocol import CAPABILITY_SESSION_COMMANDS, RuntimeStatus
from connector.runtimes.claude import provider_config
from connector.runtimes.claude.domain.capabilities import (
    ClaudeCapabilityContext,
    claude_runtime_capabilities,
    claude_session_capabilities,
)
from connector.runtimes.claude.domain.commands import list_claude_commands

BUSY_STATUSES: tuple[RuntimeStatus, ...] = (
    "waiting",
    "pending",
    "running",
    "stopping",
    "waiting_approval",
    "blocked",
    "disconnected",
)


def _compact(external_session_id: str | None = "sess_ext_1", **kwargs):
    (command,) = list_claude_commands(external_session_id, **kwargs)
    return command


def test_provider_reports_the_command_capability() -> None:
    assert provider_config.claude_capabilities()["commands"] is True


def test_catalog_exposes_only_compact() -> None:
    catalog = list_claude_commands("sess_ext_1")

    assert [c.id for c in catalog] == ["compact"]


def test_compact_descriptor_is_frozen() -> None:
    command = _compact()

    assert command.title == "Compact"
    assert command.description == "Compact the session context."
    assert command.aliases == ()
    assert command.accepts_args is False
    assert command.scope == "session"
    assert command.enabled is True
    assert command.disabled_reason is None
    assert command.metadata == {
        "ui": {
            "kind": "execute",
            "allowedStatuses": ["idle", "error"],
            "acceptsMultiline": False,
        }
    }


@pytest.mark.parametrize("query", (None, "", "   "))
def test_blank_query_keeps_the_command(query: str | None) -> None:
    assert [c.id for c in list_claude_commands("sess_ext_1", query)] == ["compact"]


@pytest.mark.parametrize(
    "query",
    ("compact", "COMPACT", " Compact ", "session context"),
)
def test_query_matches_the_command(query: str) -> None:
    assert [c.id for c in list_claude_commands("sess_ext_1", query)] == ["compact"]


@pytest.mark.parametrize("query", ("goal", "status", "compact-thread"))
def test_query_filters_out_a_non_match(query: str) -> None:
    assert list_claude_commands("sess_ext_1", query) == ()


@pytest.mark.parametrize("limit", (0, -1))
def test_limit_truncates_the_catalog(limit: int) -> None:
    assert list_claude_commands("sess_ext_1", limit=limit) == ()


def test_missing_external_session_disables_the_command() -> None:
    command = _compact(None)

    assert command.enabled is False
    assert command.disabled_reason == "session_unloaded"


@pytest.mark.parametrize("status", BUSY_STATUSES)
def test_busy_session_disables_the_command(status: RuntimeStatus) -> None:
    command = _compact(status=status)

    assert command.enabled is False
    assert command.disabled_reason == f"session_{status}"


@pytest.mark.parametrize("status", ("idle", "error"))
def test_startable_session_enables_the_command(status: RuntimeStatus) -> None:
    command = _compact(status=status)

    assert command.enabled is True
    assert command.disabled_reason is None


def test_unloaded_session_wins_over_a_busy_status() -> None:
    command = _compact(None, status="running")

    assert command.enabled is False
    assert command.disabled_reason == "session_unloaded"


def test_session_capabilities_advertise_session_commands() -> None:
    capabilities = {
        c.capability_id: c
        for c in claude_session_capabilities(
            ClaudeCapabilityContext(
                connector_id="conn_1",
                revision=1,
                session_id="sess_1",
            )
        ).capabilities
    }

    command_capability = capabilities[CAPABILITY_SESSION_COMMANDS]
    assert command_capability.scope == "session"
    assert command_capability.runtime == "claude"
    assert command_capability.session_id == "sess_1"
    assert command_capability.connector_id == "conn_1"
    assert command_capability.supported is True
    assert command_capability.available is True
    assert command_capability.unavailable_reason is None


def test_session_commands_capability_follows_an_active_turn() -> None:
    capabilities = {
        c.capability_id: c
        for c in claude_session_capabilities(
            ClaudeCapabilityContext(
                connector_id="conn_1",
                revision=1,
                session_id="sess_1",
                has_active_turn=True,
            )
        ).capabilities
    }

    command_capability = capabilities[CAPABILITY_SESSION_COMMANDS]
    assert command_capability.supported is True
    assert command_capability.available is False
    assert command_capability.unavailable_reason == "turn_active"


def test_runtime_capabilities_do_not_advertise_session_commands() -> None:
    capability_set = claude_runtime_capabilities(
        ClaudeCapabilityContext(connector_id="conn_1", revision=1)
    )

    assert CAPABILITY_SESSION_COMMANDS not in {
        c.capability_id for c in capability_set.capabilities
    }
    assert capability_set.session_id is None
