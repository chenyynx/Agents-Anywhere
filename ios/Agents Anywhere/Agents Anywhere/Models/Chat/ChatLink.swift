import Foundation

/// Classifies the links a reply can carry.
///
/// Two kinds reach the renderer and they are not the same gesture. A web link
/// leaves the app; a workspace file reference (`aa-workspace-file://`) jumps to
/// a file the connector owns, inside the app. The renderer draws a rule under
/// the first and leaves the second as plain code — telling them apart by scheme
/// is what keeps a path from reading like a URL.
nonisolated enum ChatLink {
    /// The schemes that mean "somewhere on the web".
    private static let webSchemes: Set<String> = ["http", "https"]

    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return webSchemes.contains(scheme)
    }
}
