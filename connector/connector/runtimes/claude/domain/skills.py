"""Map the Claude CLI's `get_skills_dialog` payload onto AA's skill rows.

The control answers with the rows of the CLI's own `/skills` menu:

    {"skills": [{"name", "display_name", "description", "source", "state",
                 "advertised", "handles": {"aliases"}}]}

Only rows the session actually lists as slash commands are offered: an `off`
skill, or one that is not user-invocable, arrives with `advertised = false`
and cannot be dispatched through the prompt. Description is the same text
the CLI shows in the menu, which is what the official autocomplete card
renders.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ClaudeSkill:
    """One user-invocable skill advertised by the live CLI session."""

    name: str
    display_name: str
    description: str
    source: str | None = None
    state: str | None = None
    aliases: tuple[str, ...] = ()


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _rows(value: Any) -> Sequence[Mapping[str, Any]]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        return ()
    return tuple(item for item in value if isinstance(item, Mapping))


def _aliases(value: Any) -> tuple[str, ...]:
    handles = value if isinstance(value, Mapping) else {}
    raw = handles.get("aliases")
    if not isinstance(raw, Sequence) or isinstance(raw, (str, bytes)):
        return ()
    return tuple(
        alias
        for alias in raw
        if isinstance(alias, str) and alias and alias != ""
    )


def skills_from_dialog(payload: Mapping[str, Any]) -> tuple[ClaudeSkill, ...]:
    """Parse and filter the CLI's skills menu rows.

    The caller passes the control response verbatim. Malformed rows are
    skipped rather than raising: a menu entry we cannot describe must not
    take the whole command catalog down.
    """

    skills: list[ClaudeSkill] = []
    for row in _rows(payload.get("skills")):
        name = _string(row.get("name"))
        display_name = _string(row.get("display_name")) or name
        if not name or not display_name:
            continue
        # `advertised` is the CLI's own "this session lists it as a slash
        # command" fact; off / not-user-invocable rows are false.
        if row.get("advertised") is not True:
            continue
        state = _string(row.get("state"))
        if state == "off":
            continue
        skills.append(
            ClaudeSkill(
                name=name,
                display_name=display_name,
                description=_string(row.get("description")) or "",
                source=_string(row.get("source")),
                state=state,
                aliases=_aliases(row.get("handles")),
            )
        )
    return tuple(skills)
