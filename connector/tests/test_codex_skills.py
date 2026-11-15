from __future__ import annotations

from connector.runtimes.codex.domain.commands import list_codex_commands
from connector.runtimes.codex.domain.skills import (
    CodexSkill,
    match_skill_invocation,
    skills_from_list,
)
from connector.runtimes.codex.sdk.client import codex_turn_user_input
from connector.runtimes.codex.sdk.runtime_client import CodexStartTurnRequest


def _skill(**overrides) -> CodexSkill:
    values = {
        "name": "deep-research",
        "display_name": "deep-research",
        "description": "Research a topic across sources.",
        "path": "/repo/.codex/skills/deep-research/SKILL.md",
        "scope": "repo",
    }
    values.update(overrides)
    return CodexSkill(**values)


def _row(**overrides):
    row = {
        "name": "deep-research",
        "description": "Research a topic across sources.",
        "enabled": True,
        "scope": "repo",
        "path": "/repo/.codex/skills/deep-research/SKILL.md",
        "interface": {"displayName": "deep-research"},
    }
    row.update(overrides)
    return row


def test_list_payload_flattens_enabled_skills() -> None:
    skills = skills_from_list(
        {
            "data": [
                {"cwd": "/repo", "errors": [], "skills": [_row()]},
                {"cwd": "/other", "errors": [], "skills": [_row(name="other")]},
            ]
        }
    )

    assert [skill.name for skill in skills] == ["deep-research", "other"]
    assert skills[0].display_name == "deep-research"
    assert skills[0].scope == "repo"


def test_disabled_and_duplicate_rows_are_dropped() -> None:
    skills = skills_from_list(
        {
            "data": [
                {
                    "skills": [
                        _row(),
                        _row(enabled=False),
                        _row(interface={"displayName": "duplicate"}),
                    ]
                }
            ]
        }
    )

    assert len(skills) == 1


def test_malformed_payload_yields_no_skills() -> None:
    assert skills_from_list({}) == ()
    assert skills_from_list({"data": "nope"}) == ()
    assert skills_from_list({"data": [{"skills": [None, "x", 1]}]}) == ()


def test_invocation_matches_name_and_display_name() -> None:
    skill = _skill(display_name="Deep Research")
    skills = (skill,)

    assert match_skill_invocation("/deep-research topic one", skills) == (
        skill,
        "topic one",
    )
    # Display names with whitespace are not slash tokens.
    assert match_skill_invocation("/Deep Research", skills) == (None, "/Deep Research")
    tight = _skill(display_name="DeepResearch")
    assert match_skill_invocation("/deepresearch", (tight,)) == (tight, "")


def test_prose_and_unknown_skills_are_not_invocations() -> None:
    skills = (_skill(),)

    assert match_skill_invocation("please research this", skills) == (None, "please research this")
    assert match_skill_invocation("/Users/me/file", skills) == (None, "/Users/me/file")
    assert match_skill_invocation("/unknown", skills) == (None, "/unknown")


def test_catalog_appends_skill_rows_as_inserts() -> None:
    catalog = list_codex_commands(
        "thread_1", True, skills=(_skill(display_name="Deep Research"),)
    )

    assert [c.id for c in catalog] == ["compact", "deep-research"]
    row = catalog[1]
    assert row.accepts_args is True
    assert row.metadata == {
        "ui": {"kind": "insert", "acceptsMultiline": True},
        "skill": {"name": "deep-research", "scope": "repo"},
    }


def test_turn_input_carries_skill_before_the_argument_text() -> None:
    request = CodexStartTurnRequest(
        thread_id="thread_1",
        content="topic one",
        skill_name="deep-research",
        skill_path="/repo/.codex/skills/deep-research/SKILL.md",
    )

    values = codex_turn_user_input(request)

    assert values[0].root.type == "skill"
    assert values[0].root.name == "deep-research"
    assert values[0].root.path.endswith("SKILL.md")
    assert values[1].root.type == "text"
    assert values[1].root.text == "topic one"


def test_skill_without_arguments_carries_only_the_skill_input() -> None:
    request = CodexStartTurnRequest(
        thread_id="thread_1",
        content="",
        skill_name="deep-research",
        skill_path="/repo/.codex/skills/deep-research/SKILL.md",
    )

    values = codex_turn_user_input(request)

    assert [item.root.type for item in values] == ["skill"]
