import Foundation

/// Colour data for chat *chrome* — the pieces the reference captures pinned
/// down precisely.
///
/// Hex only, no `Color`: `ClientCore` is compiled for macOS in CI, where UIKit
/// does not exist. The `Color`/`UIColor` bridging lives in `ChatPaletteColor`
/// in the iOS-only views, following the same split as `OrbPalette`.
///
/// Deliberately partial: colours the reference never showed (dark-mode diff
/// fills, table zebra stripes) are not invented here. The user bubble's fill
/// and label are **not** here either — those follow `AppAccent` so the app's
/// theme setting still drives them.
nonisolated enum ChatPalette {
    /// 0xRRGGBB per scheme.
    struct Token: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    /// `[measured]` running text and bold.
    static let text = Token(light: 0x111111, dark: 0xFFFFFF)
    /// `[pp 2026-10-17]` inline code and secondary labels. This one is
    /// user-tunable: it is the chat's "body template" ink, and the shipped
    /// default is moonveil's orange rather than the capture's neutral grey.
    /// The static below stays for call sites that cannot read defaults (tests,
    /// previews); live views resolve through `ChatColorStore`.
    static let textSecondary = Token(light: 0xFF6A00, dark: 0xFF6A00)
    /// `[measured]` action-row icons and the timestamp.
    static let iconSecondary = Token(light: 0x5D5D5D, dark: 0xC6C6C6)
    /// `[measured]` code-block border, table rules, dividers.
    static let hairline = Token(light: 0xEBEBEB, dark: 0x2C2C2C)
    /// `[measured]` fenced code background and table header fill.
    static let codeFill = Token(light: 0xF8F8F8, dark: 0x212121)
    /// `[measured]` language label and the copy control.
    static let codeLabel = Token(light: 0x0D0D0D, dark: 0xFFFFFF)
    /// `[pp 2026-10-17]` the shipped capture blue read washed out at text
    /// sizes, so the default is a deeper blue. User-tunable like the body
    /// template.
    static let link = Token(light: 0x1F5C8B, dark: 0x6FA8D6)
    /// `[derived]` dotted underline under a URL inside inline code.
    static let underlineDot = Token(light: 0xA9A9AD, dark: 0x636366)
    /// `[derived]` quote rule.
    static let quoteBar = Token(light: 0xE2E2E2, dark: 0x3A3A3A)
    /// `[derived]` task-list checkbox stroke.
    static let checkboxBorder = Token(light: 0xA9A9AD, dark: 0x636366)

    // MARK: Code card (moonveil's `SelectableMarkdownTheme`)

    /// Card fill: white in light, warm dark grey in the dark. Same pair as the
    /// code block's own background, kept separate because the header strip and
    /// the card body may diverge later.
    static let codeCardFill = Token(light: 0xFFFFFF, dark: 0x20201F)
    /// Card outline, one step lighter than the header divider so edge and
    /// divider stay distinguishable.
    static let codeCardBorder = Token(light: 0xD5D5D1, dark: 0x2A2A29)
    /// Hairline under the header strip.
    static let codeHeaderDivider = Token(light: 0xC9C9C6, dark: 0x5A5957)
    /// Header label ink (the language name).
    static let codeHeaderLabel = Token(light: 0x85857F, dark: 0x98989D)
    /// Header action icons.
    static let codeHeaderIcon = Token(light: 0x72726C, dark: 0x5A5957)
    /// Code ink inside the card.
    static let codeCardText = Token(light: 0x0B0B0B, dark: 0xF0EFEC)

    // MARK: Table (moonveil's borderless Claude style)

    /// Header row fill.
    static let tableHeaderFill = Token(light: 0xF3F3F0, dark: 0x262624)
    /// The single hairline colour used for the header underline and every body
    /// row seam.
    static let tableLine = Token(light: 0xB7B7B6, dark: 0x4A4A48)

    /// `[measured]` on the light capture only; the dark capture never showed
    /// a diff summary, so the same two hues are reused there.
    static let diffAdd = Token(light: 0x65C466, dark: 0x65C466)
    static let diffRemove = Token(light: 0xEB4B46, dark: 0xEB4B46)

    // MARK: Syntax tokens

    /// `[measured]` the TOML run in the reference showed key, string, comment
    /// and punctuation only.
    static let synKey = Token(light: 0x7F6D33, dark: 0xC89C6E)
    static let synString = Token(light: 0xB42F23, dark: 0xA0C281)
    static let synComment = Token(light: 0x31721D, dark: 0x5D626F)
    static let synPunct = Token(light: 0x0D0D0D, dark: 0xACB2BE)
    /// `[derived]` the reference contained no keyword, number, type or call.
    /// These four follow the same One Dark family as the measured green/grey.
    static let synKeyword = Token(light: 0x9B2393, dark: 0xC678DD)
    static let synNumber = Token(light: 0x2F44C0, dark: 0xD19A66)
    static let synType = Token(light: 0x0B5A83, dark: 0xE5C07B)
    static let synFunction = Token(light: 0x326D74, dark: 0x61AFEF)
}
