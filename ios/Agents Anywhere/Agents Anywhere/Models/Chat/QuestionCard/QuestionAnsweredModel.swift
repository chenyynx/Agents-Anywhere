import Foundation

/// One question/answer row of the official answered card
/// (`QuestionAnsweredPair{question, answer?}` — the answer is optional because
/// a skipped question has none).
nonisolated struct QuestionAnsweredPair: Hashable, Identifiable, Sendable {
    let question: String
    let answer: String?

    var id: String { question }
}

/// The answered (completed) form of one `AskUserQuestion` timeline row.
///
/// Data source: the connector completes the question row with the transcript's
/// `toolUseResult` flattened into the item content (`ToolTimelineContent.
/// to_mapping` → `payload.update(metadata)`), so the row carries both
/// `questions[]` and the `answers{}` map (question text → answer string;
/// multi-select answers are comma-separated by the CLI, Claude Code 2.1.316).
/// Resolved interaction notices are dropped by the connector's notice
/// registry, so the timeline row — not the notice — is the history source.
///
/// Nil means "not answered yet / nothing to draw": such rows keep their
/// existing skip in the Code profile (a pending question lives in the dock).
nonisolated struct QuestionAnsweredModel: Hashable, Sendable {
    let pairs: [QuestionAnsweredPair]

    init?(item: V2TimelineItem) {
        guard item.type == .tool || item.type == .fileChange else { return nil }
        guard CodeToolCall.wireName(for: item) == "AskUserQuestion" else { return nil }
        self.init(content: item.raw["content"] ?? .object([:]))
    }

    init?(content: JSONValue) {
        guard let answers = Self.answers(in: content), !answers.isEmpty else { return nil }

        var pairs = Self.questionTexts(in: content).map { question in
            QuestionAnsweredPair(question: question,
                                 answer: Self.answerText(answers[question]))
        }
        if pairs.isEmpty {
            // No question list on the row: fall back to the answer keys, in a
            // stable order (JSON objects are unordered).
            pairs = answers.keys.sorted().map { question in
                QuestionAnsweredPair(question: question,
                                     answer: Self.answerText(answers[question]))
            }
        }
        self.pairs = pairs
    }

    // MARK: - Wire reads

    private static func answers(in content: JSONValue) -> [String: JSONValue]? {
        content["answers"]?.objectValue
            ?? content["result"]?["answers"]?.objectValue
            ?? content["output"]?.objectValue?["answers"]?.objectValue
    }

    private static func questionTexts(in content: JSONValue) -> [String] {
        let raw = content["questions"]?.arrayValue
            ?? content["result"]?["questions"]?.arrayValue
            ?? content["input"]?["questions"]?.arrayValue
        return (raw ?? []).compactMap {
            $0["question"]?.stringValue ?? $0["prompt"]?.stringValue
        }
    }

    private static func answerText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string, .number, .bool:
            let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        case let .array(items):
            let joined = items.compactMap(\.stringValue).joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        case .object, .null:
            return nil
        }
    }
}
