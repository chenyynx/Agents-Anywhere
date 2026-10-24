import Foundation

/// First-frame height estimate for a row whose exact height is not available
/// yet.
///
/// Textual parses Markdown in a `Task`, so an offscreen hosting pass sees only
/// the pre-parse stack spacing. The official transcript solves the same shape
/// with `ClaudeTranscriptUI.TranscriptListRowHeightEstimates` — fields
/// `provide: (Row, CGFloat) -> CGFloat?` and `cache: [RowID: CGSize]` — and
/// corrects the row when the cell reports `TranscriptCellHost.heightDidChange`.
/// This type is the AA-side `provide` half: a deliberately generous estimate
/// used only until the visible cell's real height arrives.
///
/// Over-estimating shows a temporary gap; under-estimating clips a long row.
/// The 20% cushion therefore errs high. The value is never written as a
/// `.measured` tier.
nonisolated enum TimelineHeightEstimate {
    struct TextRow: Equatable {
        let text: String
        let attachmentCount: Int

        init(text: String, attachmentCount: Int = 0) {
            self.text = text
            self.attachmentCount = attachmentCount
        }
    }

    /// - Parameters:
    ///   - width: the content column width in points.
    ///   - bodySize: the running-text point size (`ChatTypeScale.body`).
    ///   - lineSpacing: the extra leading between line fragments, in points.
    ///   - paragraphSpacing: the gap between blocks, in points.
    /// - Parameter cushion: Multiplier over the line-count model. The Chat
    ///   rows keep the deliberate 20% cushion; the Code page's estimate is
    ///   assembled from exact structural parts and passes 1 so the estimate
    ///   does not reserve a fifth of a screen it will give back on first fit
    ///   (device report 2026-10-23).
    static func height(rows: [TextRow], width: CGFloat, bodySize: CGFloat,
                       lineSpacing: CGFloat, paragraphSpacing: CGFloat,
                       minimum: CGFloat = 44,
                       cushion: CGFloat = 1.2) -> CGFloat {
        guard width > 0, bodySize > 0 else { return max(minimum, 92) }
        let lineHeight = max(1, bodySize + lineSpacing)
        // 0.55 em is a conservative average advance for mixed Latin text. CJK
        // and emoji scalars count double below, so the same line count holds
        // for Chinese content without a second constant.
        let unitsPerLine = max(8, Int(width / max(1, bodySize * 0.55)))
        var height: CGFloat = 0
        for row in rows {
            let units = textUnits(row.text)
            let lines = max(1, Int(ceil(Double(units) / Double(unitsPerLine))))
            height += CGFloat(lines) * lineHeight
            height += paragraphSpacing * 0.6
            height += CGFloat(row.attachmentCount) * 180
        }
        height += CGFloat(max(0, rows.count - 1)) * 4
        return max(minimum, ceil(height * max(0, cushion)))
    }

    // MARK: - Official row-height estimate

    /// The official `SessionRowHeightEstimator` constants (2026-10-24
    /// reverse engineering; `EVIDENCE/est-r1/FINDINGS.md` in the RE corpus):
    /// width capped at 580 pt, each block capped at 15 display lines, a 0.9
    /// factor over `lines × lineHeight`, and a 44 pt floor. The estimator only
    /// serves rows no cell has measured yet.
    ///
    /// Do not raise `officialLineCap` to stop a live row from growing on its
    /// first fit: the official placeholder caps each block the same way and
    /// the cell's geometry report replaces the seed, so the growth is the
    /// official behaviour (review R8 P2-3, decided 2026-10-24).
    static let officialWidthCap: CGFloat = 580
    static let officialLineCap: CGFloat = 15
    static let officialFactor: CGFloat = 0.9
    static let officialMinimum: CGFloat = 44

    /// `max(lines × lineHeight × 0.9, 44)` — the arithmetic half of the
    /// official estimator. Line counting is the caller's job: the official
    /// code measures each explicit line's width with `size(withAttributes:)`
    /// and adds `floor(lineWidth / width) + 1`, which needs UIKit and lives in
    /// the app target.
    static func officialEstimate(lines: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(ceil(lines * max(0, lineHeight) * officialFactor), officialMinimum)
    }

    /// Display width in half-em units: wide glyphs occupy two Latin advances.
    static func textUnits(_ text: String) -> Int {
        var units = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
                 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                units += 2
            default:
                units += 1
            }
        }
        return units
    }
}
