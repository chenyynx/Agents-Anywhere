from __future__ import annotations

from connector.runtimes.claude.timeline.messages import (
    ClaudeToolBlock,
    _tool_result_content,
)

QUESTIONS = [
    {
        "header": "Format",
        "question": "How should I format the output?",
        "multiSelect": False,
        "options": [
            {"label": "Summary", "description": "Brief overview"},
            {"label": "Detailed", "description": "Full explanation"},
        ],
    },
    {
        "header": "Sections",
        "question": "Which sections should I include?",
        "multiSelect": True,
        "options": [
            {"label": "Introduction", "description": "Opening context"},
            {"label": "Conclusion", "description": "Final summary"},
        ],
    },
]


def test_answered_question_content_flattens_questions_and_answers() -> None:
    """The iOS answered card reads `content.questions` + `content.answers`.

    The connector completes the question row with the transcript's
    ``toolUseResult`` (``answers`` keyed by full question text) flattened into
    the content mapping; this pins that shape so the card's history replay
    cannot silently lose its data source.
    """

    call = ClaudeToolBlock(
        block_type="tool_use",
        tool_use_id="ask-1",
        tool_name="AskUserQuestion",
        tool_input={"questions": QUESTIONS},
    )
    result = ClaudeToolBlock(
        block_type="tool_result",
        tool_use_id="ask-1",
        tool_result="Your questions have been answered: ...",
        tool_result_metadata={
            "questions": QUESTIONS,
            "answers": {
                "How should I format the output?": "Summary",
                "Which sections should I include?": "Introduction, Conclusion",
            },
        },
    )

    mapping = dict(_tool_result_content(result, call).to_mapping())

    assert mapping["kind"] == "input_request"
    assert mapping["title"] == "AskUserQuestion"
    assert mapping["isError"] is False
    assert mapping["answers"] == {
        "How should I format the output?": "Summary",
        "Which sections should I include?": "Introduction, Conclusion",
    }
    assert [question["question"] for question in mapping["questions"]] == [
        "How should I format the output?",
        "Which sections should I include?",
    ]


def test_skipped_question_is_absent_from_the_answers_map() -> None:
    call = ClaudeToolBlock(
        block_type="tool_use",
        tool_use_id="ask-2",
        tool_name="AskUserQuestion",
        tool_input={"questions": QUESTIONS},
    )
    result = ClaudeToolBlock(
        block_type="tool_result",
        tool_use_id="ask-2",
        tool_result="Your questions have been answered: ...",
        tool_result_metadata={
            "questions": QUESTIONS,
            "answers": {"How should I format the output?": "Summary"},
        },
    )

    mapping = dict(_tool_result_content(result, call).to_mapping())

    assert mapping["answers"] == {"How should I format the output?": "Summary"}
    assert "Which sections should I include?" not in mapping["answers"]
