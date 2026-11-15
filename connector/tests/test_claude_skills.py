from __future__ import annotations

from connector.runtimes.claude.domain.skills import skills_from_dialog


def _row(**overrides):
    row = {
        "name": "deep-research",
        "display_name": "deep-research",
        "description": "Use this skill when the user's prompt requires research.",
        "source": "user",
        "state": "on",
        "advertised": True,
        "handles": {"aliases": ["research"]},
    }
    row.update(overrides)
    return row


def test_dialog_rows_become_skills() -> None:
    (skill,) = skills_from_dialog({"skills": [_row()]})

    assert skill.name == "deep-research"
    assert skill.display_name == "deep-research"
    assert skill.description.startswith("Use this skill")
    assert skill.source == "user"
    assert skill.state == "on"
    assert skill.aliases == ("research",)


def test_only_advertised_rows_are_offered() -> None:
    skills = skills_from_dialog(
        {
            "skills": [
                _row(name="shown"),
                _row(name="off", advertised=False),
                _row(name="disabled", state="off"),
            ]
        }
    )

    assert [skill.name for skill in skills] == ["shown"]


def test_display_name_falls_back_to_name() -> None:
    (skill,) = skills_from_dialog({"skills": [_row(display_name=None)]})

    assert skill.display_name == "deep-research"


def test_rows_without_a_name_are_skipped() -> None:
    assert skills_from_dialog({"skills": [_row(name=None)]}) == ()
    assert skills_from_dialog({"skills": [_row(description=None)]})[0].description == ""


def test_malformed_payload_yields_no_skills() -> None:
    assert skills_from_dialog({}) == ()
    assert skills_from_dialog({"skills": "nope"}) == ()
    assert skills_from_dialog({"skills": [None, "x", 1]}) == ()
