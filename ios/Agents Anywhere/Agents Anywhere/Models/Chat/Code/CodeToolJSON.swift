import Foundation

// The official tool detail's Prettify control is a four-state machine over the
// output payload (`ToolPayloadJSON.Prettify`, R-U §3): `raw` by default,
// `formatting` while the async conversion runs, `formatted(text, showing:)`
// when it lands, and `failed` when the parse/serialise step fails. The
// formatted text and the `showing` byte are independent, so "Show raw" only
// flips `showing` and the formatted result stays cached.
//
// It lives in the model layer (no SwiftUI import) so the Code-profile gate can
// drive the same state machine the card uses.

nonisolated enum CodeToolPrettify: Equatable {
    case raw
    case formatting
    case formatted(text: String, showing: Bool)
    case failed

    /// The official default thunk zeroes the String payload and the showing
    /// byte (R-U §3: `0x1035ffe78` `stp xzr,xzr` / `0x1035ffe7c`
    /// `strb wzr`), i.e. `.raw`. The view uses this constant so "default raw"
    /// has one source of truth.
    static let initial: CodeToolPrettify = .raw

    /// `nil` means "draw the raw payload". A `formatted` state with
    /// `showing == false` is the Show raw view.
    var displayText: String? {
        guard case let .formatted(text, showing) = self, showing else { return nil }
        return text
    }

    var isFormatting: Bool {
        if case .formatting = self { return true }
        return false
    }

    var hasFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The button text keys from R-T §1: `2c67.tool_detail_prettify` =
    /// "Prettify" and `2c67.tool_detail_show_raw` = "Show raw". Unofficial
    /// states (raw/formatting/failed) all read "Prettify" (R-U §3: the title
    /// function branches on `_object < 3` first).
    var buttonTitleKey: String {
        if case let .formatted(_, showing) = self, showing { return "Show raw" }
        return "Prettify"
    }

    /// R-U §3 action `0x10360276c`: `.raw` starts formatting; `.formatted`
    /// flips `showing`; `.formatting` and `.failed` are no-ops.
    mutating func tap() {
        switch self {
        case .raw:
            self = .formatting
        case let .formatted(text, showing):
            self = .formatted(text: text, showing: !showing)
        case .formatting, .failed:
            break
        }
    }

    /// R-U §3 completion `0x10360263c`: only a `.formatting` state applies a
    /// result. The official failure path returns an empty String, represented
    /// here as `nil` -> `.failed` (the button then disappears; no copy is
    /// shown).
    mutating func finish(_ result: String?) {
        guard case .formatting = self else { return }
        if let result {
            self = .formatted(text: result, showing: true)
        } else {
            self = .failed
        }
    }
}

nonisolated enum CodeToolJSON {

    /// R-U §1 / E4's sniffer: first/last brace or bracket, a quoted scalar,
    /// or one of the three literals (`0x103602b88`..`0x103602c8c`). The
    /// official button gate uses this heuristic rather than a parse; a wrong
    /// guess falls into `.failed` when the formatter actually runs.
    static func sniffsAsJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        if (first == "{" && last == "}") || (first == "[" && last == "]") {
            return true
        }
        if first == "\"" && last == "\"" { return true }
        return trimmed == "true" || trimmed == "false" || trimmed == "null"
    }

    /// R-U §2 / E5: `JSONObjectWithData:options:` with options 0, then
    /// `dataWithJSONObject:options:` with options 0xb = prettyPrinted |
    /// sortedKeys | withoutEscapingSlashes. FragmentsAllowed is deliberately
    /// absent, so a top-level scalar fails exactly as it does in the official
    /// client. Returns `nil` on any parse/serialise failure.
    static func prettyPrinted(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: []),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    /// R-U §1 / E3 button gate: `detectsJSON && sniffsAsJSON && state !=
    /// .failed`.
    static func showsPrettifyButton(detectsJSON: Bool,
                                    text: String,
                                    state: CodeToolPrettify) -> Bool {
        showsPrettifyButton(detectsJSON: detectsJSON,
                            sniffsAsJSON: sniffsAsJSON(text),
                            state: state)
    }

    /// The same gate with the sniff result cached by the view (the payload may
    /// be a whole file, so the view sniffs once instead of per body pass).
    static func showsPrettifyButton(detectsJSON: Bool,
                                    sniffsAsJSON: Bool,
                                    state: CodeToolPrettify) -> Bool {
        detectsJSON && sniffsAsJSON && !state.hasFailed
    }
}
