import Foundation
import Testing
@testable import ClientCore

/// Official QuestionCard values and the two data edges the card adds:
/// skipped questions (left out of the submitted answers) and the answered
/// card parsed from a completed question row.
@Suite @MainActor struct QuestionCardTests {

    private func inputNotice(revision: Int = 1) throws -> V2RuntimeNotice {
        var value = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        value["type"] = "interaction"
        value["interactionType"] = "input_request"
        value["status"] = "open"
        value["revision"] = revision
        value["blocking"] = ["scope": "session", "targetId": "session"]
        value["actions"] = [["actionId": "submit", "label": "Submit", "style": "primary", "input": [
            "required": true,
            "uiSchema": ["component": "inputRequest", "version": 1, "allowSkip": true, "questions": [
                ["id": "one", "prompt": "Single", "multiple": false,
                 "options": [["id": "a", "label": "A"], ["id": "b", "label": "B"]]],
                ["id": "many", "prompt": "Multiple", "multiple": true,
                 "options": [["id": "a", "label": "A"], ["id": "b", "label": "B"]]],
            ]],
        ]], ["actionId": "cancel", "label": "Cancel", "style": "secondary",
              "input": ["required": false]]]
        return try decode(value)
    }

    // MARK: - Official tokens (CANONICAL/25-question-card.md)

    @Test func officialQuestionCardTokensMatchTheCanonicalTable() {
        #expect(QuestionCardMetrics.cornerRadius == 24)
        #expect(QuestionCardMetrics.contentPadding == 16)
        #expect(QuestionCardMetrics.contentPaddingHorizontal == 24)
        #expect(QuestionCardMetrics.screenMargin == 16)
        #expect(QuestionCardMetrics.cardBottomMargin == 12)
        #expect(QuestionCardMetrics.closeButtonSize == 44)
        #expect(QuestionCardMetrics.closeGlyphSpan == 16)
        #expect(QuestionCardMetrics.closeGlyphStroke == 1.5)
        #expect(QuestionCardMetrics.questionTrailingAvoidance == 32)
        #expect(QuestionCardMetrics.pagingSpacing == 8)
        #expect(QuestionCardMetrics.pagingLeading == 4)
        #expect(QuestionCardMetrics.arrowGlyphSize == 24)
        #expect(QuestionCardMetrics.arrowTapTarget == 44)
        #expect(QuestionCardMetrics.selectionBadgeMinSize == 30)
        #expect(QuestionCardMetrics.selectionBadgeStrokeWidth == 1)
        #expect(QuestionCardMetrics.optionRowBadgePadding == 16)
        #expect(QuestionCardMetrics.optionRowVerticalPadding == 16)
        #expect(QuestionCardMetrics.optionDetailSize == 11)
        #expect(QuestionCardMetrics.optionDetailLineHeight == 17)
        #expect(QuestionCardMetrics.optionRowPlainPadding == 4)
        #expect(QuestionCardMetrics.optionDividerInset == 24)
        #expect(QuestionCardMetrics.submitSpacing == 8)
        #expect(QuestionCardMetrics.submitRowMaxWidth == 208)
        #expect(QuestionCardMetrics.submitRowTrailingInset == 2)
        #expect(QuestionCardMetrics.inputCornerRadius == 24)
        #expect(QuestionCardMetrics.inputPadding == 12)
        #expect(QuestionCardMetrics.buttonPressedScale == 0.98)
        #expect(QuestionCardMetrics.buttonDisabledOpacity == 0.75)

        // Typography (size / line height / variable weight).
        #expect(QuestionCardMetrics.titleSize == 13)
        #expect(QuestionCardMetrics.titleLineHeight == 18.2)
        #expect(QuestionCardMetrics.titleWeight == 550)
        #expect(QuestionCardMetrics.requesterSize == 15)
        #expect(QuestionCardMetrics.requesterLineHeight == 21)
        #expect(QuestionCardMetrics.requesterWeight == 500)
        #expect(QuestionCardMetrics.questionSize == 16.5)
        #expect(QuestionCardMetrics.questionLineHeight == 23.8)
        #expect(QuestionCardMetrics.questionWeight == 500)
        #expect(QuestionCardMetrics.optionSize == 12.5)
        #expect(QuestionCardMetrics.optionLineHeight == 20)
        #expect(QuestionCardMetrics.optionWeight == 500)
        #expect(QuestionCardMetrics.pagingSize == 12)
        #expect(QuestionCardMetrics.pagingLineHeight == 17)

        // Answered card (R9-7 更正后的角色).
        #expect(QuestionCardMetrics.answeredHeaderSize == 15)
        #expect(QuestionCardMetrics.answeredHeaderLineHeight == 21)
        #expect(QuestionCardMetrics.answeredRowSize == 17)
        #expect(QuestionCardMetrics.answeredRowLineHeight == 23.8)
        #expect(QuestionCardMetrics.answeredRowWeight == 550)
        #expect(QuestionCardMetrics.answeredCornerRadius == 24)
        #expect(QuestionCardMetrics.answeredHorizontalPadding == 16)
        #expect(QuestionCardMetrics.answeredVerticalPadding == 12)
        #expect(QuestionCardMetrics.answeredSpacing == 12)

        // Selected badge / ring / divider (light values).
        #expect(QuestionCardMetrics.selectedBadge.light.red == 0.165)
        #expect(QuestionCardMetrics.selectedBadge.light.green == 0.471)
        #expect(QuestionCardMetrics.selectedBadge.light.blue == 0.839)
        #expect(QuestionCardMetrics.unselectedRing.light.alpha == 0.465)
        #expect(QuestionCardMetrics.divider.light.alpha == 0.3)
    }

    // MARK: - Skip semantics

    @Test func theSkipFlagIsReadFromTheUiSchema() throws {
        let item = SessionNoticeModel(try inputNotice())
        #expect(item.form?.allowSkip == true)

        var plainValue = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        plainValue["type"] = "interaction"
        plainValue["interactionType"] = "input_request"
        plainValue["actions"] = [["actionId": "submit", "label": "Submit", "style": "primary", "input": [
            "required": true,
            "uiSchema": ["component": "inputRequest", "version": 1, "questions": [
                ["id": "one", "prompt": "Q", "multiple": false,
                 "options": [["id": "a", "label": "A"]]],
            ]],
        ]]]
        let plain = SessionNoticeModel(try decode(plainValue))
        #expect(plain.form?.allowSkip == false)
    }

    @Test func skippedQuestionIsOmittedFromTheSubmittedAnswers() throws {
        let item = SessionNoticeModel(try inputNotice())
        let form = try #require(item.form)
        let action = item.notice.actions[0]

        item.select("a", question: form.questions[0])
        item.skip(form.questions[1])

        #expect(item.hasAnswer(form.questions[0]))
        #expect(item.hasAnswer(form.questions[1]))  // skipped counts as settled
        #expect(item.isSkipped(form.questions[1]))
        let input = try #require(item.payload(for: action))
        #expect(input["answers"]?["one"]?["optionIds"] == .array([.string("a")]))
        #expect(input["answers"]?["many"] == nil)
        #expect(item.hasValidInput(for: action))
    }

    @Test func skippingEveryQuestionSubmitsAnEmptyAnswersObject() throws {
        let item = SessionNoticeModel(try inputNotice())
        let form = try #require(item.form)
        let action = item.notice.actions[0]

        for question in form.questions { item.skip(question) }

        let input = try #require(item.payload(for: action))
        #expect(input == .object(["answers": .object([:])]))
        #expect(item.hasValidInput(for: action))
    }

    @Test func answeringASkippedQuestionClearsTheSkip() throws {
        let item = SessionNoticeModel(try inputNotice())
        let form = try #require(item.form)
        let action = item.notice.actions[0]

        item.skip(form.questions[0])
        item.skip(form.questions[1])
        item.select("b", question: form.questions[0])
        item.setCustom("写点什么", question: form.questions[1])

        #expect(!item.isSkipped(form.questions[0]) && !item.isSkipped(form.questions[1]))
        let input = try #require(item.payload(for: action))
        #expect(input["answers"]?["one"]?["optionIds"] == .array([.string("b")]))
        #expect(input["answers"]?["many"]?["customText"] == .string("写点什么"))
    }

    @Test func skipClearsChoicesAndCustomText() throws {
        let item = SessionNoticeModel(try inputNotice())
        let form = try #require(item.form)

        item.select("a", question: form.questions[0])
        item.skip(form.questions[0])
        #expect(item.choices["one"] == [])
        #expect(item.custom["one"] == nil)
    }

    // MARK: - Answered card parsing

    private func content(questions: [String], answers: [String: JSONValue]) -> JSONValue {
        .object([
            "questions": .array(questions.map { .object(["question": .string($0)]) }),
            "answers": .object(answers),
        ])
    }

    @Test func answeredCardKeepsTheQuestionOrderAndJoinsMultiSelect() throws {
        let model = try #require(QuestionAnsweredModel(content: content(
            questions: ["第一题", "第二题"],
            answers: ["第一题": .string("A"),
                      "第二题": .array([.string("B"), .string("C")])])))
        #expect(model.pairs.map(\.question) == ["第一题", "第二题"])
        #expect(model.pairs[0].answer == "A")
        #expect(model.pairs[1].answer == "B, C")
    }

    @Test func skippedQuestionKeepsItsLineWithoutAnAnswer() throws {
        let model = try #require(QuestionAnsweredModel(content: content(
            questions: ["答了", "跳过了"],
            answers: ["答了": .string("A")])))
        #expect(model.pairs.map(\.question) == ["答了", "跳过了"])
        #expect(model.pairs[1].answer == nil)
    }

    @Test func answeredCardAcceptsTheResultNesting() throws {
        let wire: JSONValue = .object(["result": content(
            questions: ["Q"], answers: ["Q": .string("A")])])
        let model = try #require(QuestionAnsweredModel(content: wire))
        #expect(model.pairs == [QuestionAnsweredPair(question: "Q", answer: "A")])
    }

    @Test func answeredCardWithoutAQuestionListFallsBackToSortedAnswerKeys() throws {
        let model = try #require(QuestionAnsweredModel(content: .object([
            "answers": .object(["Q2": .string("B"), "Q1": .string("A")]),
        ])))
        #expect(model.pairs.map(\.question) == ["Q1", "Q2"])
    }

    @Test func unansweredContentProducesNoCard() {
        #expect(QuestionAnsweredModel(content: .object([
            "questions": .array([.object(["question": .string("Q")])]),
        ])) == nil)
        #expect(QuestionAnsweredModel(content: .object(["answers": .object([:])])) == nil)
    }
}
