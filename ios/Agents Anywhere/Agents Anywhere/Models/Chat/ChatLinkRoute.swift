import Foundation

/// What a tapped link inside transcript body text means to the page.
///
/// The Code rows draw body text in UIKit views, so their taps never pass
/// through SwiftUI's `openURL`. The page's `OpenURLAction` and the text
/// views' tap router both resolve a URL through this one function so the two
/// cannot drift: one decides "preview a device file", "let the system open
/// it", or "swallow it".
nonisolated enum ChatLinkRoute: Equatable {
    /// A device file reference: the page opens the workspace preview sheet.
    case file(SessionFileReference)
    /// A link the system owns (Safari, Mail, Phone).
    case system
    /// Anything else: the tap is swallowed so no window is opened.
    case ignore

    static func route(_ url: URL) -> Self {
        if let reference = SessionFileReference.reference(from: url) {
            return .file(reference)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        return ["http", "https", "mailto", "tel"].contains(scheme) ? .system : .ignore
    }
}
