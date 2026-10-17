import SwiftUI

/// Live preview + two colour wells for the chat's body-template grey and link
/// blue. Storage and defaults live in `ChatColorSettings`, same
/// `@AppStorage` shape as the Thinking orb's palette so the two settings pages
/// behave alike.
struct ChatColorSettingsView: View {
    @AppStorage(ChatColorSettings.bodyTemplateKey)
    private var bodyTemplateRaw = ChatColorSettings.encode(ChatColorSettings.defaultBodyTemplate)
    @AppStorage(ChatColorSettings.linkKey)
    private var linkRaw = ChatColorSettings.encode(ChatColorSettings.defaultLink)
    /// `@AppStorage` writes the raw value; the resolved (clamped) size is what
    /// the chat reads. Keeping the binding optional-free means the slider has
    /// a stable value before the user ever touches it.
    @AppStorage(ChatColorSettings.bodySizeKey)
    private var bodySize = Double(ChatColorSettings.defaultBodySize)
    @Environment(\.colorScheme) private var colorScheme

    private var bodyTemplate: ChatColorSettings.Pair {
        ChatColorSettings.decode(bodyTemplateRaw, fallback: ChatColorSettings.defaultBodyTemplate)
    }
    private var link: ChatColorSettings.Pair {
        ChatColorSettings.decode(linkRaw, fallback: ChatColorSettings.defaultLink)
    }

    var body: some View {
        List {
            Section(String(localized: "预览")) {
                ChatColorPreview(bodyTemplate: bodyTemplate, link: link)
                    .padding(.vertical, 6)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "正文字号"))
                        Spacer()
                        Text(verbatim: String(format: "%.0f pt", bodySize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $bodySize,
                        in: Double(ChatColorSettings.bodySizeRange.lowerBound)...Double(ChatColorSettings.bodySizeRange.upperBound),
                        step: 0.5
                    ) {
                        Text(String(localized: "正文字号"))
                    } minimumValueLabel: {
                        Text(verbatim: "A").font(.caption2)
                    } maximumValueLabel: {
                        Text(verbatim: "A").font(.title3)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(String(localized: "只影响助手回复的正文，不改气泡和界面其它文字。"))
            }

            Section(String(localized: "正文辅助文字")) {
                ColorPicker(
                    String(localized: "颜色"),
                    selection: picker(raw: $bodyTemplateRaw, fallback: ChatColorSettings.defaultBodyTemplate)
                )
            }

            Section(String(localized: "链接")) {
                ColorPicker(
                    String(localized: "颜色"),
                    selection: picker(raw: $linkRaw, fallback: ChatColorSettings.defaultLink)
                )
            }

            Section {
                Button(String(localized: "恢复默认")) {
                    bodyTemplateRaw = ChatColorSettings.encode(ChatColorSettings.defaultBodyTemplate)
                    linkRaw = ChatColorSettings.encode(ChatColorSettings.defaultLink)
                }
            } footer: {
                Text(String(localized: "只影响聊天里的行内代码、引用等辅助文字与链接，不改动主题色和气泡。"))
            }
        }
        .settingsPage(String(localized: "聊天文字颜色"))
    }

    /// One appearance for both schemes: the picker edits the current scheme's
    /// slot, and the other slot keeps the value it had. Writing both to the
    /// same colour would silently flatten a deliberately paired light/dark
    /// setting the moment the user touches the well in one mode.
    private func picker(raw: Binding<String>, fallback: ChatColorSettings.Pair) -> Binding<Color> {
        Binding(
            get: {
                let pair = ChatColorSettings.decode(raw.wrappedValue, fallback: fallback)
                return Color(orbHex: colorScheme == .dark ? pair.dark : pair.light)
            },
            set: { color in
                var pair = ChatColorSettings.decode(raw.wrappedValue, fallback: fallback)
                let hex = color.orbHex
                pair = ChatColorSettings.Pair(
                    light: colorScheme == .dark ? pair.light : hex,
                    dark: colorScheme == .dark ? hex : pair.dark
                )
                raw.wrappedValue = ChatColorSettings.encode(pair)
            }
        )
    }
}

/// A miniature reply so the two colours are judged in context, next to the
/// prose they actually appear in.
private struct ChatColorPreview: View {
    let bodyTemplate: ChatColorSettings.Pair
    let link: ChatColorSettings.Pair
    @Environment(\.colorScheme) private var colorScheme

    private func ink(_ pair: ChatColorSettings.Pair) -> Color {
        Color(orbHex: colorScheme == .dark ? pair.dark : pair.light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: String(localized: "运行环境的配置写在 `config.toml` 里"))
                .font(.system(size: ChatMetrics.bodySize))
                .tint(ink(link))
                .foregroundStyle(.primary)
                .environment(\.openURL, OpenURLAction { _ in .discarded })

            HStack(spacing: 6) {
                Text(verbatim: "config.toml")
                    .font(.system(size: ChatMetrics.bodySize, design: .monospaced))
                    .foregroundStyle(ink(bodyTemplate))
                Text(verbatim: "·")
                    .foregroundStyle(.secondary)
                Text(verbatim: "https://example.com")
                    .font(.system(size: ChatMetrics.bodySize))
                    .foregroundStyle(ink(link))
                    .underline()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
