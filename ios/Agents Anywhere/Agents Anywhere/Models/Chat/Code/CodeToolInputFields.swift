import Foundation

// The official tool-detail input is not one JSON blob: it is `InputFieldRows`,
// a `VStack` of one `InputFieldRow` per top-level input key, each drawing
// `LabeledContent(key, value)` unless that value's String exceeds 0x40000
// characters, in which case the row falls back to `CodeBlockContent`
// (R-T §3/§5, evidence E4: `0x1035fefcc` does `cmp count, #0x40000`).
//
// The `InputField.Value` tag (`text` / `json`) is read but never used by that
// decision (R-T E4: `0x100a41cc4` ignores its x2 tag argument), so a
// JSON-looking short value still renders as a field row. The label is the raw
// JSON key; the official row does not run the key through the
// `2c67.tool_detail_*` table (R-T §2 — the l10n getters belong to section
// titles, not field labels).

nonisolated struct CodeToolInputField: Hashable, Identifiable {
    /// The input JSON's key verbatim (R-T §2/§5).
    let key: String
    /// The field's payload rendered as text. Strings stay verbatim; any other
    /// JSON value becomes its JSON text, mirroring `InputField.Value`'s
    /// `text(String)` / `json(String)` payloads.
    let value: String

    var id: String { key }

    /// R-T §3 / E4: `0x1035fefcc` compares the String count against
    /// `0x40 << 12` = 262144 and returns true (field row) when `<=`.
    static let codeBlockThreshold = 262_144

    /// The official comparison reads the String's `countAndFlags` low bits —
    /// the UTF-8 code-unit count — so the threshold is on `utf8.count`.
    /// Strictly greater than 262144 falls to the code block.
    var rendersAsCodeBlock: Bool {
        value.utf8.count > Self.codeBlockThreshold
    }
}

nonisolated enum CodeToolInputFields {

    /// The input object's fields, sorted by key. JSON objects have no order on
    /// the wire, so sorting keeps row order stable across reloads (the same
    /// rule `CodeToolOutput.answerDictionary` uses). `nil` means the input is
    /// absent/empty or not an object; the detail page then hides the section
    /// (absent/empty) or keeps the raw code card (non-object input).
    static func fields(for call: CodeToolCall) -> [CodeToolInputField]? {
        guard let input = inputValue(for: call),
              let object = input.objectValue,
              !object.isEmpty else { return nil }
        return object.keys.sorted().map { key in
            CodeToolInputField(key: key, value: displayValue(object[key] ?? .null))
        }
    }

    /// The raw input text the section header's copy button hands over. This is
    /// the pre-field-row payload, so copying keeps taking the whole input.
    static func rawText(for call: CodeToolCall) -> String? {
        guard let input = inputValue(for: call) else { return nil }
        if let text = input.stringValue { return text.isEmpty ? nil : text }
        let json = input.formattedJSON
        return json.isEmpty ? nil : json
    }

    /// AA's mapping of the official `detectsJSON` bit (R-U §1): the official
    /// value is a static bit over the `ToolInput` enum case; AA's wire carries
    /// no such enum, so a structured (object) input is the equivalent
    /// evidence. The Prettify button still needs the body to sniff as JSON.
    static func detectsJSON(for call: CodeToolCall) -> Bool {
        inputValue(for: call)?.objectValue != nil
    }

    private static func inputValue(for call: CodeToolCall) -> JSONValue? {
        let content = call.item.raw["content"] ?? .object([:])
        guard let input = content["input"] ?? content["arguments"],
              input != .null else { return nil }
        if case let .object(fields) = input, fields.isEmpty { return nil }
        if case let .array(items) = input, items.isEmpty { return nil }
        if let text = input.stringValue, text.isEmpty { return nil }
        return input
    }

    /// R-T does not close the exact text carried by `InputField.Value.json`;
    /// this uses the app's existing `formattedJSON` (pretty, sorted keys,
    /// unescaped slashes) so nested values stay readable, and keeps string
    /// values verbatim to match `Value.text`.
    private static func displayValue(_ value: JSONValue) -> String {
        if case let .string(text) = value { return text }
        let json = value.formattedJSON
        return json.isEmpty ? value.displayString : json
    }
}
