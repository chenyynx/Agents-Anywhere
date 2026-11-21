import SwiftUI
import UIKit

/// 设置 → 编写器 → 链接与代码配色 (pp 2026-11-22).
///
/// The preview is the real chat page shrunk down, not a redrawn mock: the
/// production toolbar buttons, the production user bubble and the production
/// Markdown leaf draw inside a 390 pt-wide page that is scaled to the card.
/// Every control in it is inert. Each colour well writes through immediately,
/// so the miniature is the WYSIWYG surface.
struct CodeLinkColorSettingsView: View {
    @State private var link: Color
    @State private var inlineCode: Color
    /// The leaf's inks are dynamic colours resolved while drawing; a colour
    /// write bumps this so the leaf redraws without rebuilding its document.
    @State private var revision = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight

    init() {
        _link = State(initialValue: Self.color(ChatColorSettings.codeLink()))
        _inlineCode = State(initialValue: Self.color(ChatColorSettings.codeInlineCode()))
    }

    var body: some View {
        SettingsScreen(title: String(localized: "链接与代码配色")) {
            SettingsSection(String(localized: "预览")) {
                preview.padding(12)
            }
            SettingsSection(String(localized: "颜色"),
                            footer: String(localized: "深色模式下颜色会自动提亮，保证看得清。")) {
                colorRow(title: String(localized: "链接"),
                         subtitle: String(localized: "聊天里的文件引用和网址共用这个颜色"),
                         selection: $link,
                         key: ChatColorSettings.codeLinkKey)
                SettingsRowDivider()
                colorRow(title: String(localized: "内联代码"),
                         subtitle: String(localized: "消息里“代码片段”的颜色"),
                         selection: $inlineCode,
                         key: ChatColorSettings.codeInlineCodeKey)
            }
            SettingsSection {
                Button(action: reset) {
                    HStack {
                        Spacer()
                        Text(String(localized: "恢复默认颜色"))
                            .font(SettingsStyle.text(17))
                            .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                        Spacer()
                    }
                    .padding(.horizontal, SettingsStyle.rowPadding)
                    .frame(minHeight: SettingsStyle.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Miniature chat page

    private var preview: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 390
            miniChatPage
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: 400 * scale,
                       alignment: .topLeading)
        }
        .aspectRatio(390.0 / 400.0, contentMode: .fit)
    }

    private var miniChatPage: some View {
        VStack(spacing: 0) {
            miniHeader
            VStack(alignment: .leading, spacing: 14) {
                CodeUserBubble(text: String(localized: "你对人类的看法是什么？"))
                CodeMarkdownTextLeaf(text: sampleAssistantText,
                                     typography: previewTypography,
                                     columnWidth: 350,
                                     inkRevision: revision)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer(minLength: 0)
            miniComposer
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(width: 390, height: 400, alignment: .top)
        .background(CodePageTheme.pageBackgroundColor.resolved(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(SettingsStyle.secondary(colorScheme).opacity(0.16),
                              lineWidth: 0.5)
        }
        // A preview only: no link opens, no bubble selects, no key sends.
        .allowsHitTesting(false)
    }

    /// The session page's real toolbar pieces: the sidebar mark on its own
    /// glass circle, the title, and the trailing folder + overflow glass pill.
    private var miniHeader: some View {
        ZStack {
            Text(String(localized: "人类观察笔记"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: 15, weight: 550)))
                .lineLimit(1)
            HStack {
                SidebarMenuIcon()
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: Circle())
                Spacer()
                HStack(spacing: 14) {
                    AppSymbol("folder")
                    AppSymbol("anthropicon.dotsHorizontal", size: 15)
                }
                .frame(height: 36)
                .padding(.horizontal, 14)
                .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    /// The production composer's chrome: `GlassEffectContainer` + regular
    /// glass, the add key, the placeholder, the mic and the accent send key —
    /// non-interactive, because the preview only needs to look like the page.
    private var miniComposer: some View {
        GlassEffectContainer(spacing: nil) {
            HStack(spacing: 10) {
                AppSymbol("anthropicon.add", size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                Text(String(localized: "发消息…"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                AppSymbol("anthropicon.microphone", size: 16)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(SettingsStyle.controlTint(colorScheme))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24,
                                                        style: .continuous))
        }
    }

    private var sampleAssistantText: String {
        String(localized: "人类是唯一会为自己必死而写诗的物质：明知宇宙不给意义，仍执意为彼此制造意义。研究我整理成了 `~/Downloads/人类观察笔记.pdf`，其中 [Nature Human Behaviour](https://example.com/meaning-making) 把这种能力称为 `meaning-making`。")
    }

    private var previewTypography: TimelineTypographySnapshot {
        TimelineChatContentAdapter.typography(
            dynamicType: String(describing: dynamicTypeSize),
            layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
            boldText: legibilityWeight == .bold,
            scale: CodePageTheme.markdownScale)
    }

    // MARK: - Colour rows

    private func colorRow(title: String, subtitle: String,
                          selection: Binding<Color>, key: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SettingsStyle.text(17))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(SettingsStyle.text(12))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ColorPicker(title, selection: bound(selection, key: key),
                        supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsStyle.rowMinHeight)
    }

    /// Writes through on every pick; the preview's `revision` follows.
    private func bound(_ selection: Binding<Color>,
                       key: String) -> Binding<Color> {
        Binding(get: { selection.wrappedValue },
                set: { newValue in
                    selection.wrappedValue = newValue
                    guard let hex = Self.hex(newValue),
                          ChatColorSettings.setCodeColor(hex, for: key) else { return }
                    revision += 1
                })
    }

    private func reset() {
        ChatColorSettings.resetCodeColors()
        // Direct state writes bypass `bound`, so the defaults are not stored.
        link = Self.color(ChatColorSettings.defaultCodeLink)
        inlineCode = Self.color(ChatColorSettings.defaultCodeInlineCode)
        revision += 1
    }

    private static func color(_ pair: ChatColorSettings.Pair) -> Color {
        guard let (r, g, b) = ChatColorSettings.parse(pair.light) else { return .primary }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255,
                     blue: Double(b) / 255, opacity: 1)
    }

    private static func hex(_ color: Color) -> String? {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }
}
