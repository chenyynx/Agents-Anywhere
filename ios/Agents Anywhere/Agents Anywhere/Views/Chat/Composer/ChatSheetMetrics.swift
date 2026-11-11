import CoreGraphics

/// Geometry shared by the "添加到会话" sheet and the pages it pushes.
///
/// The values are measured from the official 3x screenshots and compared
/// against the screen edge, not the sheet edge: iOS 26 insets a presented
/// sheet by 8 pt per side, while the official sheet is full width. A 16 pt
/// margin inside our inset sheet would land 24 pt from the screen edge, so
/// the in-sheet margin is 16 − 8 = 8 pt to keep the capsules flush with the
/// official ones.
nonisolated enum ChatSheetMetrics {
    static let horizontalInset: CGFloat = 8
    /// Official row: 53.7 pt total with 15 pt text (~17 pt line box), so the
    /// vertical padding is 18 pt on each side.
    static let rowVerticalPadding: CGFloat = 18
    /// Hairlines start where the row text starts: 16 pt row padding +
    /// 28 pt icon frame + 12 pt spacing.
    static let dividerLeadingInset: CGFloat = 56
    /// Official hairlines stop 16 pt short of the card's trailing edge.
    static let dividerTrailingInset: CGFloat = 16
}
