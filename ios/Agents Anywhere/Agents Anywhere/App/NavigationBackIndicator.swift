import UIKit

/// The official navigation back glyph is the app's caret, not the system's
/// thin chevron (device report 2026-11-26). Installing it as the navigation
/// bar's back-indicator image keeps the system back button's glass chrome,
/// hit target and interactive swipe; only the drawn glyph changes.
enum NavigationBackIndicator {
    static func install() {
        let image = rendered()
        ClientDiagnosticsLog.shared.record(
            kind: "nav.back.indicator",
            detail: ["asset": image == nil ? "missing" : "ok"],
            severity: image == nil ? "warn" : "info",
            dedupe: false)
        guard let image else { return }
        let appearance = UINavigationBar.appearance()
        appearance.backIndicatorImage = image
        appearance.backIndicatorTransitionMaskImage = image
    }

    /// The caret asset is vector; draw it at the back button's point size so
    /// the glyph matches the official circle instead of its 6×11 intrinsic.
    private static func rendered() -> UIImage? {
        guard let source = UIImage(named: "anthropicon.caretLeft") else { return nil }
        let size = CGSize(width: 11, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        .withRenderingMode(.alwaysTemplate)
    }
}
