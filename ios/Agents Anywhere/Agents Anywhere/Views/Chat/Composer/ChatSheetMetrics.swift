import CoreGraphics

/// Geometry shared by the "添加到会话" sheet and the pages it pushes.
///
/// The values are measured from the official 3x screenshots: a 16 pt content
/// margin and a 53.7 pt row. iOS 26 insets a sheet only while it sits below
/// its largest detent, so at rest (full width) the margin lands 16 pt from
/// the screen edge exactly like the official sheet; the system inset is not
/// compensated here.
nonisolated enum ChatSheetMetrics {
    static let horizontalInset: CGFloat = 16
    /// Official row: 53.7 pt total with 15 pt text (~17 pt line box), so the
    /// vertical padding is 18 pt on each side.
    static let rowVerticalPadding: CGFloat = 18
    /// Hairlines start where the row text starts: 16 pt row padding +
    /// 28 pt icon frame + 12 pt spacing.
    static let dividerLeadingInset: CGFloat = 56
    /// Official hairlines stop 16 pt short of the card's trailing edge.
    static let dividerTrailingInset: CGFloat = 16
}
