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
    /// `[measured]` inline code and secondary labels.
    static let textSecondary = Token(light: 0x89898D, dark: 0x8D8D92)
    /// `[measured]` action-row icons and the timestamp.
    static let iconSecondary = Token(light: 0x5D5D5D, dark: 0xC6C6C6)
    /// `[measured]` code-block border, table rules, dividers.
    static let hairline = Token(light: 0xEBEBEB, dark: 0x2C2C2C)
    /// `[measured]` fenced code background and table header fill.
    static let codeFill = Token(light: 0xF8F8F8, dark: 0x212121)
    /// `[measured]` language label and the copy control.
    static let codeLabel = Token(light: 0x0D0D0D, dark: 0xFFFFFF)
    /// `[derived]` no link appeared in the captures; matches the bubble label
    /// so a link reads as tappable without introducing a fifth hue.
    static let link = Token(light: 0x3377AA, dark: 0x7DB8E8)
    /// `[derived]` dotted underline under a URL inside inline code.
    static let underlineDot = Token(light: 0xA9A9AD, dark: 0x636366)
    /// `[derived]` quote rule.
    static let quoteBar = Token(light: 0xE2E2E2, dark: 0x3A3A3A)
    /// `[derived]` task-list checkbox stroke.
    static let checkboxBorder = Token(light: 0xA9A9AD, dark: 0x636366)

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
