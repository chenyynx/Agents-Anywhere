"""Map the Codex SDK's `skills/list` rows and recognise `/skill` prompts.

`skills/list` answers one entry per requested cwd:

    {"data": [{"cwd", "errors", "skills": [
        {"name", "description", "enabled", "scope", "path",
         "interface": {"displayName", "shortDescription"}}]}]}

Only enabled rows are exposed. A skill is invoked by putting a
`SkillUserInput(name, path)` in the turn input; the remaining text after
`/name` travels as the ordinary text input.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

_SLASH_INVOCATION = re.compile(r"^\s*/([A-Za-z0-9:._-]+)(?:[ \t]+([\s\S]*))?$")


@dataclass(frozen=True, slots=True)
class CodexSkill:
    """One enabled Codex skill available to the session's workspace."""

    name: str
    display_name: str
    description: str
    path: str
    scope: str | None = None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _mappings(value: Any) -> Sequence[Mapping[str, Any]]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        return ()
    return tuple(item for item in value if isinstance(item, Mapping))


def skills_from_list(payload: Mapping[str, Any]) -> tuple[CodexSkill, ...]:
    """Flatten and filter a `skills/list` response.

    The catalog is keyed by (name, path): the same skill can appear once per
    requested cwd, and a duplicate must not produce two rows. Malformed rows
    are skipped; one bad entry cannot take the command catalog down.
    """

    seen: set[tuple[str, str]] = set()
    skills: list[CodexSkill] = []
    for entry in _mappings(payload.get("data")):
        for row in _mappings(entry.get("skills")):
            name = _string(row.get("name"))
            path = _string(row.get("path"))
            if not name or not path:
                continue
            if row.get("enabled") is not True:
                continue
            key = (name, path)
            if key in seen:
                continue
            seen.add(key)
            interface = row.get("interface")
            display_name = (
                _string(interface.get("displayName"))
                if isinstance(interface, Mapping)
                else None
            )
            skills.append(
                CodexSkill(
                    name=name,
                    display_name=display_name or name,
                    description=_string(row.get("description")) or "",
                    path=path,
                    scope=_string(row.get("scope")),
                )
            )
    return tuple(skills)


def match_skill_invocation(
    text: str,
    skills: Sequence[CodexSkill],
) -> tuple[CodexSkill | None, str]:
    """Match a `/name [args]` prompt against the loaded skills.

    Returns the skill and the remaining argument text, or (None, text) when
    the prompt is prose or names no known skill. Matching is case-insensitive
    on the skill name and its display name; paths such as `/Users/me` never
    match because skill names cannot contain a slash.
    """

    match = _SLASH_INVOCATION.match(text)
    if match is None:
        return None, text
    token = match.group(1).casefold()
    args = match.group(2) or ""
    for skill in skills:
        names = {skill.name.casefold()}
        # A display name with whitespace can never be a slash token; matching
        # it would make `/Deep Research` look invocable when it is not.
        if not any(character.isspace() for character in skill.display_name):
            names.add(skill.display_name.casefold())
        if token in names:
            return skill, args
    return None, text
