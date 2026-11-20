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


def test_live_projection_carries_the_answers_noted_by_the_interaction() -> None:
    """The live SDK frame drops ``toolUseResult``; the interaction controller
    records the structured result instead, and the completed row must use it
    immediately (no history rebuild needed) so the answered card can draw.
    """

    from claude_agent_sdk._internal.message_parser import parse_message

    from connector.runtimes.claude.domain.session import ClaudeSession
    from connector.runtimes.claude.timeline.messages import ClaudeMessageProjector

    def frame(payload: dict[str, object]) -> object:
        message = parse_message(payload)
        assert message is not None
        return message

    projector = ClaudeMessageProjector()
    projector.note_tool_result_metadata(
        "ask-live",
        {
            "questions": QUESTIONS,
            "answers": {"How should I format the output?": "Summary"},
        },
    )
    session = ClaudeSession(session_id="sess-live", external_session_id="claude-live")
    projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=frame(
            {
                "type": "assistant",
                "message": {
                    "id": "msg-1",
                    "role": "assistant",
                    "model": "deepseek-v4.1-flash",
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "ask-live",
                            "name": "AskUserQuestion",
                            "input": {"questions": QUESTIONS},
                        }
                    ],
                },
                "parent_tool_use_id": None,
                "session_id": "claude-live",
                "uuid": "assistant-ask-live",
            }
        ),
    )
    rows = projector.tool_items_for_message(
        session=session,
        turn_id="turn-1",
        message=frame(
            {
                "type": "user",
                "message": {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "ask-live",
                            "content": [
                                {
                                    "type": "text",
                                    "text": "Your questions have been answered: ...",
                                }
                            ],
                        }
                    ],
                },
                "parent_tool_use_id": None,
                "session_id": "claude-live",
                "uuid": "result-ask-live",
            }
        ),
    )

    assert len(rows) == 1
    content = dict(rows[0].content)
    assert content["kind"] == "input_request"
    assert content["answers"] == {"How should I format the output?": "Summary"}
