import SwiftUI

/// Web's Lucide paths rendered as native template vectors. Native controls keep
/// their system drawing; app-owned actions share this mapping across screens.
struct AppSymbol: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var image: Image {
        if let asset = AppSymbolAssets.names[name] { Image(asset) }
        else { Image("aa-CircleHelp") }
    }

    var body: some View {
        image.resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }

    func resizable() -> Image { image.resizable() }
}

extension Label where Title == Text, Icon == AppSymbol {
    init(_ title: String, appSymbol: String) {
        self.init { Text(verbatim: title) } icon: { AppSymbol(appSymbol) }
    }
    /// Menu rows draw the official artwork at the system menu scale — smaller
    /// than the 20 pt row icons the other initializers keep (pp 2026-11-19).
    init(_ title: String, appSymbol: String, size: CGFloat) {
        self.init { Text(verbatim: title) } icon: { AppSymbol(appSymbol, size: size) }
    }
    init(_ title: LocalizedStringResource, appSymbol: String) {
        self.init { Text(title) } icon: { AppSymbol(appSymbol) }
    }
}

extension Button where Label == SwiftUI.Label<Text, AppSymbol> {
    init(_ title: String, appSymbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, appSymbol: appSymbol) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, AppSymbol>, Description == Text?, Actions == EmptyView {
    init(_ title: String, appSymbol: String, description: Text? = nil) {
        self.init {
            SwiftUI.Label { Text(verbatim: title) } icon: { AppSymbol(appSymbol, size: 36) }
        } description: { description }
    }
}

enum AppFileSymbol {
    /// Same extension groups as Web's FileTypeIcon.
    static func name(for filename: String) -> String {
        let ext = filename.lowercased().split(separator: ".").last.map(String.init) ?? ""
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico"].contains(ext) { return "doc.text.image" }
        if ["zip", "tar", "gz", "7z", "rar"].contains(ext) { return "doc.zipper" }
        if ["mp3", "wav", "ogg", "aac", "m4a"].contains(ext) { return "music.note" }
        if ["mp4", "mov", "webm", "avi"].contains(ext) { return "video" }
        if ["csv", "xlsx", "xls"].contains(ext) { return "tablecells" }
        if ["ts", "tsx", "js", "jsx", "json", "py", "rs", "go", "java", "c", "cpp", "h", "css", "html", "vue", "sh", "yaml", "yml", "toml", "swift"].contains(ext) { return "doc.text.magnifyingglass" }
        if ["md", "mdx", "txt", "log", "pdf"].contains(ext) { return "doc.text" }
        return "doc"
    }
}

/// Menu-row artwork at its natural size. iOS renders menu labels through its
/// own image slot: a resizable SwiftUI view is shrunk to that slot whatever
/// frame it declares (a declared 28 still measured 11 pt of ink on device),
/// while an image with a declared intrinsic size keeps it
/// (pp 2026-11-20, experiment A).
struct MenuArtwork: View {
    let name: String
    /// Destructive rows draw a pre-coloured rendition. The menu rasters this
    /// view into a template image tinted with the action colour's shape: red
    /// never reaches the icon through the destructive role, and an explicit
    /// foregroundStyle is dropped as well (b1375 device check: red title,
    /// black icon). So the red is part of the artwork, rendered as original.
    var destructive = false

    private static let redArtwork: [String: String] = [
        "anthropicon.archive": "anthropicon.archive.red",
        "anthropicon.trash": "anthropicon.trash.red",
    ]

    var body: some View {
        if destructive, let red = Self.redArtwork[name] {
            Image(red).renderingMode(.original)
        } else {
            Image(name).renderingMode(.template)
        }
    }
}

extension Label where Title == Text, Icon == MenuArtwork {
    init(_ title: String, menuSymbol: String, destructive: Bool = false) {
        self.init { Text(verbatim: title) } icon: { MenuArtwork(name: menuSymbol, destructive: destructive) }
    }
}
