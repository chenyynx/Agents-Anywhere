"""The commands a Claude session exposes: native `/compact` plus its skills."""

from __future__ import annotations

from collections.abc import Sequence

from connector.runtime_protocol import RuntimeCommand
from connector.runtimes.claude.domain.skills import ClaudeSkill

IDLE = ("idle", "error")


def _skill_command(skill: ClaudeSkill) -> RuntimeCommand:
    """One CLI skill as an insert-only command row.

    Skills are prompt templates: selecting one writes `/name` back into the
    composer (the official card's behaviour), it is not executed by the
    command API. `metadata.ui.kind = "insert"` is the client contract for
    that; `accepts_args` is true because the composer appends free text.
    """

    name = skill.display_name.removeprefix("/")
    return RuntimeCommand(
        id=name,
        title=name,
        description=skill.description or None,
        aliases=tuple(alias.removeprefix("/") for alias in skill.aliases),
        enabled=True,
        accepts_args=True,
        metadata={
            "ui": {
                "kind": "insert",
                "acceptsMultiline": True,
            },
            "skill": {
                "name": skill.name,
                "source": skill.source,
                "state": skill.state,
            },
        },
    )


def list_claude_commands(
    external_session_id: str | None,
    query: str | None = None,
    limit: int = 50,
    *,
    status: str = "idle",
    skills: Sequence[ClaudeSkill] = (),
) -> tuple[RuntimeCommand, ...]:
    """Describe the commands a Claude session exposes right now.

    ``/compact`` is always present. ``skills`` are the user-invocable rows of
    the CLI's own skills menu, supplied only when the caller opted in to
    skills (the iOS autocomplete card). They are insert-only: the client
    writes ``/name`` back into the composer instead of executing through the
    command API, and the send path lets the CLI dispatch it from the prompt.
    Availability is decided here rather than by the runtime so the catalog
    always explains *why* a command is greyed out: the ``session.commands``
    capability bit only says whether the session has a loaded CLI
    conversation, and busy gating stays per command here so clients can still
    fetch the catalog while a turn runs.

    A session this process has never seen (cold connector, external id supplied by
    the server) stays enabled on purpose (2026-10-02, R2-P2-6). Execution re-binds
    it on demand through ``ClaudeSessionStore.ensure`` and the CLI reopens it with
    ``--resume <external id>``, so the command works; an id the CLI no longer knows
    fails its turn visibly rather than reporting a false success. Requiring a local
    store entry here would grey out the legitimate "connector restarted" case and
    make commands stricter than ``send_message`` on the very same session.
    """

    reason = None
    if not external_session_id:
        reason = "session_unloaded"
    elif status not in IDLE:
        reason = f"session_{status}"
    command = RuntimeCommand(
        id="compact",
        title="Compact",
        description="Compact the session context.",
        enabled=reason is None,
        disabled_reason=reason,
        # Compaction runs on the whole conversation, so there is nothing for the
        # user to fill in; an appended argument is rejected on execution.
        accepts_args=False,
        metadata={
            "ui": {
                "kind": "execute",
                "allowedStatuses": list(IDLE),
                "acceptsMultiline": False,
            }
        },
    )
    # `/compact` owns its id; a skill that claims the same name would be
    # unreachable, so the action wins and the skill row is dropped.
    seen = {command.id}
    skill_commands: list[RuntimeCommand] = []
    for skill in sorted(skills, key=lambda item: item.display_name.casefold()):
        candidate = _skill_command(skill)
        if candidate.id in seen:
            continue
        seen.add(candidate.id)
        skill_commands.append(candidate)

    needle = (query or "").strip().casefold()
    return tuple(
        c
        for c in (command, *skill_commands)
        if not needle
        or needle
        in " ".join((c.id, c.title, c.description or "", *c.aliases)).casefold()
    )[: max(0, min(limit, 1000))]
