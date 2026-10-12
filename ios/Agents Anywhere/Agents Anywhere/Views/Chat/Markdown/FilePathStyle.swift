//
//  FilePathStyle.swift
//  文件路径视觉系统：文件卡片 / 句中路径胶囊 / 外部链接
//
//  设计来源：Design 预览 v14（"文件路径样式"）。所有数值均取自该预览。
//  目标：iOS 17+，SwiftUI + UIKit。
//
//  ┌ 三种形态 ─────────────────────────────────────────────────────────┐
//  │ 1. FileCardView   独占一行的路径 → 文件卡片（1:1 复刻 Claude 的文件卡） │
//  │ 2. PathChip /     句中路径 → 深靛蓝胶囊 + 类型图标                    │
//  │    PathChipLabel  （非可点代码 → 中性灰胶囊，无图标）                   │
//  │ 3. ExternalLinkStyle  外部链接 → 只加下划线，颜色同正文，无图标/无卡片   │
//  └──────────────────────────────────────────────────────────────────┘
//
//  字体：胶囊用 JetBrains Mono Medium。请把 JetBrainsMono-Medium.ttf 加入工程，
//  并在 Info.plist 的 UIAppFonts 里登记；PostScript 名为 "JetBrainsMono-Medium"。
//  找不到字体时自动回退到系统等宽字体（SF Mono, medium）。
//
//  句中胶囊的富文本集成（设计稿里的 UITextView + NSTextAttachment 位图路线）
//  不适配本工程，未随本文件交付；将由 Textual 附件方案单独实现。
//
//  构建注意：本文件 import UIKit，因此和同目录的 AccountAvatarProcessor.swift
//  一样，必须从 ios/Package.swift 的 `ClientCore` 目标里 exclude（该 SwiftPM 目标
//  会在 macOS 上做类型检查，macOS 没有 UIKit）。App 目标（Xcode）经
//  PBXFileSystemSynchronizedRootGroup 自动纳入，无需登记。
//

import SwiftUI
import UIKit

// MARK: - 颜色工具
//
// These helpers and the pure value types below (FilePathInfo / FileKind /
// FileKindStyle / ChipPalette / ChipMetrics / ChipFont / CardMetrics) are marked
// `nonisolated`: the Textual attachment layer measures an inline chip off the
// main actor (`Attachment.sizeThatFits(_:in:)` is nonisolated), so reading a
// kind's palette/insets/font there must not hop to the main actor. They are pure
// constants — no actor state — so `nonisolated` is exact.

extension UIColor {
    nonisolated convenience init(fp hex: UInt32, a: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a
        )
    }

    nonisolated static func fpDynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// 浅/深两个 hex（不透明）
    nonisolated static func fpDyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        fpDynamic(light: UIColor(fp: light), dark: UIColor(fp: dark))
    }
}

// MARK: - 路径解析

/// 把 "dir/name.ext:12:3" 这类字符串拆成名称、主名、扩展名。
nonisolated struct FilePathInfo {
    let name: String
    let stem: String
    let ext: String            // 小写，无点
    let hadTrailingSlash: Bool

    init(_ raw: String) {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 :行 或 :行:列 后缀
        if let r = p.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            p.removeSubrange(r)
        }
        var slash = false
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
            slash = true
        }
        hadTrailingSlash = slash
        let ns = p as NSString
        let last = ns.lastPathComponent
        name = last
        ext = (last as NSString).pathExtension.lowercased()
        stem = ext.isEmpty ? last : (last as NSString).deletingPathExtension
    }
}

// MARK: - 文件类型（16 类）

nonisolated enum FileKind: CaseIterable, Hashable {
    case doc, pdf, table, slides, code, config, script, web
    case image, audio, video, archive, database, log, folder, other

    /// - Parameter isDirectory: 明确知道时传入；nil 时按"带尾斜杠 / 无扩展名"推断为文件夹。
    init(path: String, isDirectory: Bool? = nil) {
        let info = FilePathInfo(path)
        if isDirectory == true || (isDirectory == nil && info.hadTrailingSlash) {
            self = .folder
            return
        }
        let lower = info.name.lowercased()
        if let k = Self.byName[lower] { self = k; return }
        if lower.hasPrefix(".env") { self = .config; return }
        if info.ext.isEmpty {
            self = (isDirectory == false) ? .other : .folder
            return
        }
        self = Self.byExt[info.ext] ?? .other
    }

    static let byName: [String: FileKind] = [
        "dockerfile": .config, "podfile": .config, "gemfile": .config,
        "makefile": .script, "rakefile": .script,
        "readme": .doc, "license": .doc, "changelog": .doc, "notice": .doc,
        ".gitignore": .config, ".gitattributes": .config, ".editorconfig": .config,
        ".zshrc": .config, ".bashrc": .config, ".bash_profile": .config, ".profile": .config,
    ]

    static let byExt: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        func put(_ kind: FileKind, _ exts: [String]) { exts.forEach { m[$0] = kind } }
        put(.doc, ["md", "markdown", "txt", "rtf", "doc", "docx", "pages", "rst", "tex", "odt", "adoc"])
        put(.pdf, ["pdf"])
        put(.table, ["csv", "tsv", "xls", "xlsx", "numbers", "ods"])
        put(.slides, ["ppt", "pptx", "key", "odp"])
        put(.code, ["swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "kts", "go", "rs",
                    "c", "h", "cpp", "cc", "hpp", "m", "mm", "rb", "php", "cs", "lua", "dart", "scala",
                    "vue", "svelte", "css", "scss", "less", "r", "pl", "ex", "exs", "zig", "hs", "gradle"])
        put(.config, ["json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "cfg", "plist", "xml",
                      "env", "properties", "lock", "xcconfig", "entitlements", "editorconfig"])
        put(.script, ["sh", "bash", "zsh", "fish", "ps1", "bat", "cmd"])
        put(.web, ["html", "htm", "xhtml"])
        put(.image, ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "bmp", "tif", "tiff", "ico", "avif"])
        put(.audio, ["mp3", "wav", "m4a", "flac", "aac", "ogg", "aiff", "opus"])
        put(.video, ["mp4", "mov", "mkv", "avi", "webm", "m4v"])
        put(.archive, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "ipa", "apk", "jar"])
        put(.database, ["db", "sqlite", "sqlite3", "sql", "realm", "mdb"])
        put(.log, ["log", "out", "trace"])
        return m
    }()

    /// 副标题里的类型名
    var label: String {
        switch self {
        case .doc, .pdf: return "文档"
        case .table: return "表格"
        case .slides: return "演示文稿"
        case .code: return "代码"
        case .config: return "配置"
        case .script: return "脚本"
        case .web: return "网页"
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .archive: return "压缩包"
        case .database: return "数据库"
        case .log: return "日志"
        case .folder: return "文件夹"
        case .other: return "文件"
        }
    }

    /// 卡片标题：去掉扩展名的文件名（文件夹/点文件保留全名）
    func title(for path: String) -> String {
        let info = FilePathInfo(path)
        return self == .folder ? info.name : info.stem
    }

    /// 卡片副标题："类型 · EXT"，文件夹为"文件夹"
    func subtitle(for path: String) -> String {
        if self == .folder { return label }
        let ext = FilePathInfo(path).ext
        return ext.isEmpty ? label : "\(label) · \(ext.uppercased())"
    }

    /// 预览用示例路径
    var samplePath: String {
        switch self {
        case .doc: return "docs/aa-file-list-resolution-plan.md"
        case .pdf: return "docs/design-review.pdf"
        case .table: return "data/q3-metrics.csv"
        case .slides: return "talks/roadmap.pptx"
        case .code: return "Sources/App/FilePathStyle.swift"
        case .config: return "config/settings.yaml"
        case .script: return "scripts/deploy.sh"
        case .web: return "public/index.html"
        case .image: return "assets/screenshot.png"
        case .audio: return "media/voice-note.m4a"
        case .video: return "media/demo-recording.mp4"
        case .archive: return "dist/release-bundle.zip"
        case .database: return "data/sessions.sqlite"
        case .log: return "logs/connector.log"
        case .folder: return "/home/ubuntu/projects/"
        case .other: return "misc/payload.bin"
        }
    }
}

// MARK: - 每类的配色（浅/深）

nonisolated struct FileKindStyle {
    let top: UIColor        // 图标块渐变顶部
    let bottom: UIColor     // 图标块渐变底部
    let border: UIColor     // 图标块 1px 描边（图标色 @ ~0.11 / 0.14）
    let icon: UIColor       // 图标线条色
}

extension FileKind {
    var style: FileKindStyle {
        switch self {
        case .doc:      return Self.make(0xEEF4FD, 0xDDE8F8, 0x20407A, 0x26344D, 0x1E2A40, 0x8FB2F0)
        case .pdf:      return Self.make(0xFDEEEE, 0xF8D9D9, 0xB3261E, 0x4A2626, 0x3A1E1E, 0xF29A94)
        case .table:    return Self.make(0xF0F7DE, 0xDFEDB8, 0x4F7A12, 0x38421E, 0x2D361A, 0xBFE070)
        case .slides:   return Self.make(0xFDEFE6, 0xF8DCC9, 0xB8461A, 0x4A2E22, 0x3A241A, 0xF0A27C)
        case .code:     return Self.make(0xFDF4E4, 0xF7E4C4, 0xA5560F, 0x4A3A22, 0x3A2D1A, 0xF0B060)
        case .config:   return Self.make(0xEEF1F4, 0xDCE2E8, 0x3F4F60, 0x2C3440, 0x232A33, 0xA9B8C8)
        case .script:   return Self.make(0xECECEF, 0xD8D8DE, 0x2B2B33, 0x3A3A40, 0x2E2E33, 0xD6D6DC)
        case .web:      return Self.make(0xE4F3FB, 0xCBE6F5, 0x0E6A99, 0x1F3A4A, 0x192F3C, 0x7CC4EA)
        case .image:    return Self.make(0xFCEBF3, 0xF7D5E6, 0xA8286B, 0x4A2438, 0x3A1C2C, 0xF29BC6)
        case .audio:    return Self.make(0xF1ECFB, 0xE2D8F6, 0x5B3FA8, 0x34294F, 0x2A2140, 0xBBA4F0)
        case .video:    return Self.make(0xECEEFD, 0xDADFF8, 0x3A4BA8, 0x272C52, 0x1F2442, 0x9FAAF2)
        case .archive:  return Self.make(0xF4EFE6, 0xE8DFCD, 0x7A5C2E, 0x433A2A, 0x352E22, 0xD6B98A)
        case .database: return Self.make(0xE4F3F2, 0xCBE6E4, 0x0F6B6B, 0x1F3D3C, 0x193130, 0x7AD0CC)
        case .log:      return Self.make(0xF1F0EE, 0xE4E2DD, 0x5C5A55, 0x34332F, 0x2A2927, 0xB5B1A8)
        case .folder:   return Self.make(0xE3F2E6, 0xCDE6D3, 0x1F6B3A, 0x2A3D2A, 0x223022, 0x8FCB95)
        case .other:    return Self.make(0xF3F2F0, 0xE7E5E1, 0x6B6963, 0x353430, 0x2B2A27, 0xA09C94)
        }
    }

    /// 参数顺序：浅色(顶, 底, 图标)，深色(顶, 底, 图标)
    static func make(_ lt: UInt32, _ lb: UInt32, _ li: UInt32,
                     _ dt: UInt32, _ db: UInt32, _ di: UInt32) -> FileKindStyle {
        FileKindStyle(
            top: .fpDyn(lt, dt),
            bottom: .fpDyn(lb, db),
            border: .fpDynamic(light: UIColor(fp: li, a: 0.11), dark: UIColor(fp: di, a: 0.14)),
            icon: .fpDyn(li, di)
        )
    }
}

// MARK: - 图标（24×24 坐标系的线性图标）

extension Path {
    mutating func seg(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        move(to: CGPoint(x: x1, y: y1))
        addLine(to: CGPoint(x: x2, y: y2))
    }

    mutating func poly(_ pts: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let first = pts.first else { return }
        move(to: CGPoint(x: first.0, y: first.1))
        for q in pts.dropFirst() { addLine(to: CGPoint(x: q.0, y: q.1)) }
        if closed { closeSubpath() }
    }

    mutating func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
        addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
    }

    mutating func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    /// 圆头线帽下，零长度线段会画成一个点
    mutating func dot(_ x: CGFloat, _ y: CGFloat) { seg(x, y, x + 0.01, y) }

    /// 带折角的页面轮廓 + 折角线
    mutating func foldedPage() {
        // 外轮廓：M7 3 h7.5 L19 7.5 V19 a2 … 圆角 r=2
        move(to: CGPoint(x: 7, y: 3))
        addLine(to: CGPoint(x: 14.5, y: 3))
        addLine(to: CGPoint(x: 19, y: 7.5))
        addLine(to: CGPoint(x: 19, y: 21))
        addArc(tangent1End: CGPoint(x: 19, y: 21), tangent2End: CGPoint(x: 5, y: 21), radius: 2)
        addArc(tangent1End: CGPoint(x: 5, y: 21), tangent2End: CGPoint(x: 5, y: 3), radius: 2)
        addArc(tangent1End: CGPoint(x: 5, y: 3), tangent2End: CGPoint(x: 19, y: 3), radius: 2)
        closeSubpath()
        // 折角
        poly([(14.5, 3.2), (14.5, 7.5), (19, 7.5)])
    }
}

struct FileGlyph: Shape {
    var kind: FileKind
    /// 小尺寸（胶囊内）下 PDF 用两条线代替 "PDF" 字样
    var compact: Bool = false

    func path(in rect: CGRect) -> Path {
        var p = Path()

        switch kind {
        case .doc:
            p.foldedPage()
            p.move(to: CGPoint(x: 8.5, y: 12.5))
            p.addCurve(to: CGPoint(x: 11.5, y: 12.5), control1: CGPoint(x: 9.5, y: 11.5), control2: CGPoint(x: 10.5, y: 11.5))
            p.addCurve(to: CGPoint(x: 14.5, y: 12.5), control1: CGPoint(x: 12.5, y: 13.5), control2: CGPoint(x: 13.5, y: 13.5))
            p.move(to: CGPoint(x: 8.5, y: 16))
            p.addCurve(to: CGPoint(x: 11.5, y: 16), control1: CGPoint(x: 9.5, y: 15), control2: CGPoint(x: 10.5, y: 15))
            p.addCurve(to: CGPoint(x: 14.5, y: 16), control1: CGPoint(x: 12.5, y: 17), control2: CGPoint(x: 13.5, y: 17))

        case .pdf:
            p.foldedPage()
            if compact {
                p.seg(8.5, 13, 15.5, 13)
                p.seg(8.5, 16.5, 12.5, 16.5)
            }
            // 非 compact 时 "PDF" 字样由 FileGlyphView 叠加

        case .table:
            p.box(4, 5, 16, 14, 2)
            p.seg(4, 10, 20, 10)
            p.seg(4, 14.5, 20, 14.5)
            p.seg(10, 10, 10, 19)

        case .slides:
            p.box(3.5, 4.5, 17, 12, 2)
            p.seg(12, 16.5, 12, 20)
            p.seg(8.5, 20, 15.5, 20)
            p.seg(8, 13.5, 8, 11)
            p.seg(11.5, 13.5, 11.5, 8.5)
            p.seg(15, 13.5, 15, 12)

        case .code:
            p.poly([(8.5, 8), (4, 12), (8.5, 16)])
            p.poly([(15.5, 8), (20, 12), (15.5, 16)])
            p.seg(13.5, 5.5, 10.5, 18.5)

        case .config:
            p.seg(4, 7, 13, 7)
            p.seg(17, 7, 20, 7)
            p.seg(4, 12, 7, 12)
            p.seg(11, 12, 20, 12)
            p.seg(4, 17, 15, 17)
            p.seg(19, 17, 20, 17)
            p.circle(15, 7, 2)
            p.circle(9, 12, 2)
            p.circle(17, 17, 2)

        case .script:
            p.box(3.5, 4.5, 17, 15, 2.5)
            p.poly([(7.5, 10), (10.5, 12.2), (7.5, 14.4)])
            p.seg(12.5, 15, 16.5, 15)

        case .web:
            p.box(3.5, 4.5, 17, 15, 2.5)
            p.seg(3.5, 9, 20.5, 9)
            p.dot(6.5, 6.8)
            p.dot(9, 6.8)
            p.seg(8.5, 13.5, 15.5, 13.5)
            p.seg(8.5, 16, 12.5, 16)

        case .image:
            p.box(3.5, 5, 17, 14, 2.5)
            p.circle(9, 10, 1.6)
            p.poly([(4, 17), (9, 12.5), (12.5, 15.5), (15, 13), (20, 17.5)])

        case .audio:
            p.seg(5, 10, 5, 14)
            p.seg(8.5, 7, 8.5, 17)
            p.seg(12, 4.5, 12, 19.5)
            p.seg(15.5, 8, 15.5, 16)
            p.seg(19, 10.5, 19, 13.5)

        case .video:
            p.box(3.5, 5.5, 17, 13, 2.5)
            p.poly([(10.5, 9.5), (10.5, 14.5), (14.7, 12)], closed: true)

        case .archive:
            // 箱体（下方两角圆角 r=1.5）
            p.move(to: CGPoint(x: 4, y: 7.5))
            p.addLine(to: CGPoint(x: 20, y: 7.5))
            p.addLine(to: CGPoint(x: 20, y: 20.5))
            p.addArc(tangent1End: CGPoint(x: 20, y: 20.5), tangent2End: CGPoint(x: 4, y: 20.5), radius: 1.5)
            p.addArc(tangent1End: CGPoint(x: 4, y: 20.5), tangent2End: CGPoint(x: 4, y: 7.5), radius: 1.5)
            p.closeSubpath()
            p.box(3.5, 4, 17, 3.5, 1)       // 盖子
            p.seg(10, 12, 14, 12)           // 提手

        case .database:
            p.addEllipse(in: CGRect(x: 5, y: 3.2, width: 14, height: 5.6))
            // 上层侧壁 + 底弧
            p.move(to: CGPoint(x: 5, y: 6))
            p.addLine(to: CGPoint(x: 5, y: 12))
            p.addCurve(to: CGPoint(x: 12, y: 14.8), control1: CGPoint(x: 5, y: 13.5), control2: CGPoint(x: 8.1, y: 14.8))
            p.addCurve(to: CGPoint(x: 19, y: 12), control1: CGPoint(x: 15.9, y: 14.8), control2: CGPoint(x: 19, y: 13.5))
            p.addLine(to: CGPoint(x: 19, y: 6))
            // 下层侧壁 + 底弧
            p.move(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 5, y: 18))
            p.addCurve(to: CGPoint(x: 12, y: 20.8), control1: CGPoint(x: 5, y: 19.5), control2: CGPoint(x: 8.1, y: 20.8))
            p.addCurve(to: CGPoint(x: 19, y: 18), control1: CGPoint(x: 15.9, y: 20.8), control2: CGPoint(x: 19, y: 19.5))
            p.addLine(to: CGPoint(x: 19, y: 12))

        case .log:
            p.foldedPage()
            p.dot(8.5, 11.5)
            p.seg(11, 11.5, 15.5, 11.5)
            p.dot(8.5, 15)
            p.seg(11, 15, 14, 15)

        case .folder:
            // M3 7 a2 2 … 圆角 r=2；标签口在 x 9→11 处斜下
            p.move(to: CGPoint(x: 3, y: 7))
            p.addArc(tangent1End: CGPoint(x: 3, y: 5), tangent2End: CGPoint(x: 9, y: 5), radius: 2)
            p.addLine(to: CGPoint(x: 9, y: 5))
            p.addLine(to: CGPoint(x: 11, y: 7.2))
            p.addLine(to: CGPoint(x: 19, y: 7.2))
            p.addArc(tangent1End: CGPoint(x: 21, y: 7.2), tangent2End: CGPoint(x: 21, y: 17), radius: 2)
            p.addLine(to: CGPoint(x: 21, y: 17))
            p.addArc(tangent1End: CGPoint(x: 21, y: 19), tangent2End: CGPoint(x: 5, y: 19), radius: 2)
            p.addArc(tangent1End: CGPoint(x: 3, y: 19), tangent2End: CGPoint(x: 3, y: 7), radius: 2)
            p.closeSubpath()

        case .other:
            p.foldedPage()
        }

        let t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24)
        return p.applying(t)
    }
}

/// 图标视图：线宽按 24 坐标系的 `weight` 等比缩放（卡片 1.7，胶囊 2.1）。
struct FileGlyphView: View {
    let kind: FileKind
    var size: CGFloat = 22
    var color: Color
    var weight: CGFloat = 1.7
    var compact: Bool = false

    var body: some View {
        FileGlyph(kind: kind, compact: compact)
            .stroke(color, style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .overlay {
                if kind == .pdf && !compact {
                    Text("PDF")
                        .font(.system(size: 6.2 * size / 24, weight: .bold))
                        .foregroundColor(color)
                        .position(x: size / 2, y: size * 14.8 / 24)
                }
            }
    }
}

// MARK: - 1. 文件卡片

nonisolated enum CardMetrics {
    static let height: CGFloat = 62
    static let radius: CGFloat = 14
    static let tileSize: CGFloat = 48
    static let tileX: CGFloat = 20
    static let tileY: CGFloat = 14
    static let tileTopRadius: CGFloat = 10
    static let textLeading: CGFloat = 88
    static let textTrailing: CGFloat = 16
    static let iconSize: CGFloat = 22
    static let iconWeight: CGFloat = 1.7
}

enum CardColors {
    static let fill = UIColor.fpDynamic(light: UIColor(white: 0, alpha: 0.018), dark: UIColor(white: 1, alpha: 0.04))
    static let border = UIColor.fpDynamic(light: UIColor(white: 0, alpha: 0.09), dark: UIColor(white: 1, alpha: 0.10))
    static let title = UIColor.fpDyn(0x1D1D1B, 0xECE9E2)
    static let subtitle = UIColor.fpDyn(0x8A867E, 0x8E8A82)
}

/// 独占一行的路径 → 文件卡片。
struct FileCardView: View {
    let path: String
    var isDirectory: Bool? = nil
    var onTap: (() -> Void)? = nil
    /// One Dynamic Type step scales the whole card, so every fixed design value
    /// (height, tile, type, insets) scales together and the proportions the
    /// design fixed are preserved at any text size.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let kind = FileKind(path: path, isDirectory: isDirectory)
        let title = kind.title(for: path)
        let subtitle = kind.subtitle(for: path)

        Button { onTap?() } label: {
            card(kind: kind, title: title, subtitle: subtitle)
        }
        .buttonStyle(FileCardButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    private func card(kind: FileKind, title: String, subtitle: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardMetrics.radius * scale, style: .circular)
        return ZStack(alignment: .topLeading) {
            tile(kind)
                .offset(x: CardMetrics.tileX * scale, y: CardMetrics.tileY * scale)

            VStack(alignment: .leading, spacing: 3 * scale) {
                Text(title)
                    .font(.system(size: 15 * scale, weight: .medium))
                    .foregroundColor(Color(uiColor: CardColors.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 12.5 * scale))
                    .foregroundColor(Color(uiColor: CardColors.subtitle))
                    .lineLimit(1)
            }
            .padding(.leading, CardMetrics.textLeading * scale)
            .padding(.trailing, CardMetrics.textTrailing * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CardMetrics.height * scale)
        .background(shape.fill(Color(uiColor: CardColors.fill)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(uiColor: CardColors.border), lineWidth: 1))
        .contentShape(shape)
    }

    /// 左侧图标块：48×48，顶部圆角 10、底部 0（与卡片下沿齐平），竖向渐变 + 1px 描边（底边无描边）。
    private func tile(_ kind: FileKind) -> some View {
        let s = kind.style
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: CardMetrics.tileTopRadius * scale,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: CardMetrics.tileTopRadius * scale,
            style: .circular
        )
        return shape
            .fill(LinearGradient(
                colors: [Color(uiColor: s.top), Color(uiColor: s.bottom)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.strokeBorder(Color(uiColor: s.border), lineWidth: 1)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: CardMetrics.tileSize * scale - 1)   // 去掉底边描边
                    }
            )
            .overlay {
                FileGlyphView(kind: kind,
                              size: CardMetrics.iconSize * scale,
                              color: Color(uiColor: s.icon),
                              weight: CardMetrics.iconWeight)
                    .offset(y: -1)
            }
            .frame(width: CardMetrics.tileSize * scale, height: CardMetrics.tileSize * scale)
    }
}

struct FileCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - 2. 句中路径胶囊

nonisolated enum ChipFont {
    /// JetBrains Mono Medium；未打包字体时回退到系统等宽 medium。
    static func make(size: CGFloat) -> UIFont {
        if let f = UIFont(name: "JetBrainsMono-Medium", size: size) { return f }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

nonisolated struct ChipPalette {
    let text: UIColor
    let fill: UIColor
    let fillPressed: UIColor
    let border: UIColor
    let borderPressed: UIColor
    let icon: UIColor
    let insets: UIEdgeInsets      // 内边距（不含 1px 描边）

    /// 可点的文件/目录：深靛蓝
    static let link = ChipPalette(
        text: .fpDyn(0x2F4D8E, 0x9DB8F2),
        fill: .fpDynamic(light: UIColor(fp: 0x2F4D8E, a: 0.08), dark: UIColor(fp: 0x9DB8F2, a: 0.12)),
        fillPressed: .fpDynamic(light: UIColor(fp: 0x2F4D8E, a: 0.16), dark: UIColor(fp: 0x9DB8F2, a: 0.20)),
        border: .fpDynamic(light: UIColor(fp: 0x2F4D8E, a: 0.18), dark: UIColor(fp: 0x9DB8F2, a: 0.26)),
        borderPressed: .fpDynamic(light: UIColor(fp: 0x2F4D8E, a: 0.30), dark: UIColor(fp: 0x9DB8F2, a: 0.40)),
        icon: .fpDyn(0x5A74AC, 0x7F9ADB),
        insets: UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 7)
    )

    /// 不可点的普通代码：中性灰，无图标
    static let neutral = ChipPalette(
        text: .fpDyn(0x3A3935, 0xD9D5CC),
        fill: .fpDynamic(light: UIColor(fp: 0x3C3C43, a: 0.08), dark: UIColor(fp: 0xEBEBF5, a: 0.12)),
        fillPressed: .fpDynamic(light: UIColor(fp: 0x3C3C43, a: 0.08), dark: UIColor(fp: 0xEBEBF5, a: 0.12)),
        border: .fpDynamic(light: UIColor(fp: 0x3C3C43, a: 0.14), dark: UIColor(fp: 0xEBEBF5, a: 0.18)),
        borderPressed: .fpDynamic(light: UIColor(fp: 0x3C3C43, a: 0.14), dark: UIColor(fp: 0xEBEBF5, a: 0.18)),
        icon: .fpDyn(0x5A74AC, 0x7F9ADB),
        insets: UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
    )
}

nonisolated enum ChipMetrics {
    static let radius: CGFloat = 6
    static let iconSize: CGFloat = 13
    static let iconWeight: CGFloat = 2.1
    static let iconGap: CGFloat = 4
    static let fontRatio: CGFloat = 0.82       // 相对正文字号
}

/// 胶囊（SwiftUI 版）。`kind == nil` → 中性代码胶囊（无图标）。
struct PathChipLabel: View {
    let text: String
    var kind: FileKind? = nil
    var pressed: Bool = false
    var bodySize: CGFloat = 16

    var body: some View {
        let p = kind == nil ? ChipPalette.neutral : ChipPalette.link
        let shape = RoundedRectangle(cornerRadius: ChipMetrics.radius, style: .circular)
        HStack(spacing: ChipMetrics.iconGap) {
            if let kind {
                FileGlyphView(kind: kind,
                              size: ChipMetrics.iconSize,
                              color: Color(uiColor: p.icon),
                              weight: ChipMetrics.iconWeight,
                              compact: true)
            }
            Text(text)
                .font(Font(ChipFont.make(size: bodySize * ChipMetrics.fontRatio) as CTFont))
                .foregroundColor(Color(uiColor: p.text))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: p.insets.top, leading: p.insets.left,
                            bottom: p.insets.bottom, trailing: p.insets.right))
        .background(shape.fill(Color(uiColor: pressed ? p.fillPressed : p.fill)))
        .overlay(shape.strokeBorder(Color(uiColor: pressed ? p.borderPressed : p.border), lineWidth: 1))
    }
}

/// 可点胶囊（独立使用）。按下态：底色 ≈16%（深色 20%），描边 ≈30%（深色 40%）。
struct PathChip: View {
    let text: String
    var kind: FileKind
    var bodySize: CGFloat = 16
    var onTap: () -> Void

    init(path: String, isDirectory: Bool? = nil, bodySize: CGFloat = 16, onTap: @escaping () -> Void) {
        self.text = path
        self.kind = FileKind(path: path, isDirectory: isDirectory)
        self.bodySize = bodySize
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) { EmptyView() }
            .buttonStyle(PathChipButtonStyle(text: text, kind: kind, bodySize: bodySize))
            .accessibilityLabel(text)
    }
}

struct PathChipButtonStyle: ButtonStyle {
    let text: String
    let kind: FileKind
    let bodySize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PathChipLabel(text: text, kind: kind, pressed: configuration.isPressed, bodySize: bodySize)
    }
}

// MARK: - 文件打开链接

/// 点击文件时用的自定义链接：aafile://open?path=<percent-encoded>
enum FileLink {
    static let scheme = "aafile"

    static func url(path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url
    }

    static func path(from url: URL) -> String? {
        guard url.scheme == scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return c.queryItems?.first(where: { $0.name == "path" })?.value
    }
}

// MARK: - 3. 外部链接：只加下划线

nonisolated enum ExternalLinkStyle {
    /// 正文墨色（深色模式 #ECE9E2）
    static let ink = UIColor.fpDyn(0x1D1D1B, 0xECE9E2)

    /// 给 NSAttributedString 用。注意：UIKit 的下划线无法指定 1.5px 粗细 / 3px 偏移，
    /// 这里用系统 single 下划线近似；要 1:1 需自绘（TextKit 2 的 rendering attributes）。
    static func attributes(url: URL, traits: UITraitCollection) -> [NSAttributedString.Key: Any] {
        let c = ink.resolvedColor(with: traits)
        return [
            .link: url,
            .foregroundColor: c,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: c,
        ]
    }
}

extension Text {
    /// SwiftUI 的 Text 外链样式：下划线 + 正文色。
    func externalLinkStyle() -> Text {
        self.underline(true).foregroundColor(Color(uiColor: ExternalLinkStyle.ink))
    }
}

// MARK: - 预览

struct FilePathStyleGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("胶囊 · 各类型").font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(FileKind.allCases, id: \.self) { k in
                        PathChipLabel(text: k.samplePath, kind: k)
                    }
                    PathChipLabel(text: "make build", kind: nil)
                }

                Text("文件卡片 · 16 类").font(.footnote).foregroundStyle(.secondary)
                ForEach(FileKind.allCases, id: \.self) { k in
                    FileCardView(path: k.samplePath, isDirectory: k == .folder ? true : nil)
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview("浅色") { FilePathStyleGallery().preferredColorScheme(.light) }
#Preview("深色") { FilePathStyleGallery().preferredColorScheme(.dark) }
