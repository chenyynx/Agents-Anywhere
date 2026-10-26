import SwiftUI
import UIKit

/// One of the official Anthropicon size presets. The raw value is the preset
/// order; the artwork extents live in `AnthropiconAssets.table`.
nonisolated enum AnthropiconSize: Int, CaseIterable, Sendable {
    case small = 0
    case medium = 1
    case large = 2
}

/// The official Anthropicon artwork, shipped from the app bundle's
/// `ClaudeDesignSystem_ClaudeIcons.bundle/Assets.car`
/// (`/data/com.anthropic.claude-1.261019.51-eeveedecrypter.ipa`, extracted
/// 2026-10-25).
///
/// The SVGs are vector assets; each row below is the **drawn artwork extent**
/// at the small / medium / large preset, read from `DATA/anthropicon-map.tsv`.
/// The official slot size (16 / 20 / 24 pt) is larger than the artwork, which
/// is why the icons are pinned to these extents instead of the slot.
nonisolated enum AnthropiconAssets {
    static func pointSize(_ name: String, _ size: AnthropiconSize) -> CGSize? {
        guard let sizes = table[name],
              sizes.indices.contains(size.rawValue) else { return nil }
        return sizes[size.rawValue]
    }

    /// Name → `[small, medium, large]` artwork extents.
    static let table: [String: [CGSize]] = [
        "anthropicon.eye": [size(15, 11), size(17, 13), size(20, 15)],
        "anthropicon.edit": [size(14, 14), size(16, 16), size(19, 19)],
        "anthropicon.file": [size(11, 15), size(13, 17), size(15, 20)],
        "anthropicon.prompt": [size(15, 11), size(17, 13), size(20, 15)],
        "anthropicon.search": [size(15, 15), size(17, 17), size(20, 20)],
        "anthropicon.globe": [size(14, 14), size(16, 16), size(18, 19)],
        "anthropicon.checklist": [size(14, 14), size(15, 15), size(18, 18)],
        "anthropicon.tasks": [size(14, 14), size(15, 16), size(18, 19)],
        "anthropicon.tool": [size(15, 13), size(17, 15), size(20, 18)],
        "anthropicon.caretRight": [size(8, 13), size(8, 15), size(10, 18)],
        "anthropicon.extendedThinking": [size(14, 14), size(16, 16), size(19, 19)],
        "anthropicon.copy": [size(14, 14), size(16, 16), size(19, 19)],
        "anthropicon.expand": [size(13, 13), size(15, 15), size(18, 18)],
        "anthropicon.check": [size(13, 9), size(15, 10), size(17, 12)],
        "anthropicon.warning": [size(15, 13), size(17, 15), size(20, 18)],
        "anthropicon.play": [size(13, 15), size(15, 17), size(18, 20)],
        "anthropicon.speaker": [size(15, 15), size(17, 17), size(20, 20)],
        "anthropicon.thumbsUp": [size(13, 14), size(15, 16), size(17, 19)],
        "anthropicon.thumbsDown": [size(13, 14), size(15, 16), size(17, 19)],
        "anthropicon.agentsSimple": [size(15, 12), size(17, 13), size(20, 15)],
        "anthropicon.codeBlock": [size(15, 12), size(17, 13), size(20, 16)],
        "anthropicon.commandLinePrompt": [size(11, 10), size(12, 11), size(14, 13)],
        "anthropicon.share": [size(13, 14), size(15, 16), size(18, 19)],
    ]

    private static func size(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }
}

/// Draws one official Anthropicon at its official artwork extent.
struct AnthropiconView: View {
    let name: String
    var size: AnthropiconSize = .large

    var body: some View {
        Group {
            if let extent = AnthropiconAssets.pointSize(name, size) {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: extent.width, height: extent.height)
            } else {
                Image(name)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}
