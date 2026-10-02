"""Execute the compact command through the ordinary Claude turn machinery."""

from __future__ import annotations

import re
from dataclasses import dataclass

from connector.runtime_protocol import (
    RuntimeCommand,
    RuntimeCommandResult,
    RuntimeSessionStateCache,
)
from connector.runtimes.claude.domain.commands import list_claude_commands
from connector.runtimes.claude.sessions.cache import ClaudeSessionStore
from connector.runtimes.claude.turns.actions import ClaudeTurnActionHandler

# AA sends the native command line through the SDK prompt, so the CLI dispatches
# it as its own slash command instead of a model turn (2026-10-02 probe).
CLAUDE_COMPACT_PROMPT = "/compact"

_COMMAND_NAME_PATTERN = re.compile(r"/?[A-Za-z][A-Za-z0-9_-]*")
_RAW_COMMAND_PATTERN = re.compile(r"\s*/([A-Za-z][A-Za-z0-9_-]*)(?:\s+([\s\S]*))?")


@dataclass(slots=True)
class ClaudeCommandController:
    """Validate, then run a command turn without owning a second turn path."""

    session_states: RuntimeSessionStateCache
    session_store: ClaudeSessionStore
    actions: ClaudeTurnActionHandler

    def catalog(
        self,
        session_id: str,
        external_session_id: str | None,
        query: str | None = None,
        limit: int = 50,
    ) -> tuple[RuntimeCommand, ...]:
        state = self.session_states.get(session_id)
        if state is None and external_session_id is not None:
            state = self.session_states.get_by_external_session_id(external_session_id)
        return list_claude_commands(
            self.external_session_id(session_id, external_session_id),
            query,
            limit,
            status=state.status if state is not None else "idle",
        )

    async def execute_command(
        self,
        session_id: str,
        command: str,
        external_session_id: str | None = None,
        raw: str | None = None,
        args: tuple[str, ...] = (),
    ) -> RuntimeCommandResult:
        requested = command.removeprefix("/") if isinstance(command, str) else ""
        try:
            name, text = command_input(command, raw, args)
            descriptor = next(
                (
                    candidate
                    for candidate in self.catalog(session_id, external_session_id)
                    if candidate.id == name
                ),
                None,
            )
            if descriptor is None:
                return RuntimeCommandResult(
                    command=requested,
                    ok=False,
                    code="unknown_command",
                    message=f"Unknown Claude command: /{requested}",
                )
            if text.strip():
                raise ValueError("This command takes no arguments")
        except (ValueError, TypeError) as exc:
            return RuntimeCommandResult(
                command=requested,
                ok=False,
                code="invalid_command",
                message=str(exc),
            )
        if not descriptor.enabled:
            return RuntimeCommandResult(
                command=requested,
                ok=False,
                code="command_unavailable",
                message=descriptor.disabled_reason,
            )
        try:
            started = await self.actions.start_turn(
                session_id=session_id,
                external_session_id=self.external_session_id(
                    session_id,
                    external_session_id,
                ),
                content=CLAUDE_COMPACT_PROMPT,
                command=name,
            )
        except Exception:  # noqa: BLE001 - the prompt may already have been sent
            return RuntimeCommandResult(
                command=requested,
                ok=False,
                code="command_outcome_unknown",
                message="Command outcome is unknown. Refresh before taking further action.",
                result={"executionState": "unknown", "retryable": False},
            )
        if not started.ok:
            return RuntimeCommandResult(
                command=requested,
                ok=False,
                code="command_rejected",
                message=started.message,
                result={"executionState": "completed"},
            )
        return RuntimeCommandResult(
            command=requested,
            result={**dict(started.result), "executionState": "accepted"},
        )

    def external_session_id(
        self,
        session_id: str,
        external_session_id: str | None,
    ) -> str | None:
        if external_session_id:
            return external_session_id
        session = self.session_store.get(session_id)
        return session.external_session_id if session is not None else None


def command_input(
    command: str,
    raw: str | None,
    args: tuple[str, ...],
) -> tuple[str, str]:
    """Split a submitted command line into its name and free-form text."""

    if not isinstance(command, str) or not _COMMAND_NAME_PATTERN.fullmatch(command):
        raise ValueError("Invalid command name")
    name = command.removeprefix("/").lower()
    if not isinstance(args, (tuple, list)) or any(
        not isinstance(arg, str) for arg in args
    ):
        raise ValueError("Command arguments must be strings")
    if raw is not None:
        if not isinstance(raw, str) or len(raw) > 4096:
            raise ValueError("Command raw input must contain at most 4096 characters")
        match = _RAW_COMMAND_PATTERN.fullmatch(raw)
        if not match or match[1].lower() != name:
            raise ValueError("Raw command must match the requested command")
        text = match[2] or ""
    else:
        if len(args) > 1:
            raise ValueError("Provide one free-form argument or exact raw input")
        text = args[0] if args else ""
    return name, text
