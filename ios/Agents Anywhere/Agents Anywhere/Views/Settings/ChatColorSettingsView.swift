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
    @AppStorage(ChatColorSettings.inlineCodeBoldKey)
    private var inlineCodeBold = false
    /// `@AppStorage` writes the raw value; the resolved (clamped) size is what
    /// the chat reads. Keeping the binding optional-free means the slider has
    /// a stable value before the user ever touches it.
    @AppStorage(ChatTypeSettings.schemeKey)
    private var schemeRaw = ChatTypeScheme.compact.rawValue
    @AppStorage(ChatTypeSettings.bodySizeKey)
    private var bodySize = Double(ChatTypeScheme.compactScale.body)
    @AppStorage(ChatTypeSettings.customKey)
    private var customRaw = ""
    @Environment(\.colorScheme) private var colorScheme

    private var scheme: ChatTypeScheme { ChatTypeScheme(rawValue: schemeRaw) ?? .compact }

    /// The scale the chat is actually rendering with right now.
    private var activeScale: ChatTypeScale {
        ChatTypeSettings.resolve(schemeRaw: schemeRaw,
                                 bodySizeRaw: bodySize,
                                 customRaw: customRaw)
    }

    private var bodyTemplate: ChatColorSettings.Pair {
        ChatColorSettings.decode(bodyTemplateRaw, fallback: ChatColorSettings.defaultBodyTemplate)
    }
    private var link: ChatColorSettings.Pair {
        ChatColorSettings.decode(linkRaw, fallback: ChatColorSettings.defaultLink)
    }

    var body: some View {
        List {
            Section(String(localized: "预览")) {
                ChatColorPreview(bodyTemplate: bodyTemplate, link: link, inlineCodeBold: inlineCodeBold)
                    .padding(.vertical, 6)
            }

            Section {
                Picker(String(localized: "比例方案"), selection: schemeBinding) {
                    ForEach(ChatTypeScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(String(localized: "比例方案"))
            } footer: {
                Text(String(localized: "一套方案同时决定字号、行距、标题、代码的字号比例。手动改任何一项会自动切到自定义。"))
            }

            Section {
                slider(String(localized: "正文字号"),
                       value: bodySizeBinding,
                       range: ChatTypeSettings.bodySizeRange)
            } footer: {
                Text(String(localized: "只影响助手回复，不改气泡和界面其它文字。其余字号按方案比例跟随。"))
            }

            Section {
                followToggle(String(localized: "行内代码跟随正文"),
                             isOn: followsBodyBinding(\.inlineCodePin))
                if !followsBody(\.inlineCodePin) {
                    slider(String(localized: "行内代码字号"),
                           value: standaloneBinding(\.inlineCodePin, fallback: activeScale.inlineCodeSize),
                           range: ChatTypeSettings.bodySizeRange)
                }
                followToggle(String(localized: "代码块跟随正文"),
                             isOn: followsBodyBinding(\.codeBlockPin))
                if !followsBody(\.codeBlockPin) {
                    slider(String(localized: "代码块字号"),
                           value: standaloneBinding(\.codeBlockPin, fallback: activeScale.codeBlockSize),
                           range: 8...ChatTypeSettings.bodySizeRange.upperBound)
                }
            } header: {
                Text(String(localized: "代码字号"))
            } footer: {
                Text(String(localized: "关闭跟随后可单独调节；两者互不影响。"))
            }

            Section {
                ColorPicker(
                    String(localized: "颜色"),
                    selection: picker(raw: $bodyTemplateRaw, fallback: ChatColorSettings.defaultBodyTemplate)
                )
                Toggle(String(localized: "加粗"), isOn: $inlineCodeBold)
            } header: {
                Text(String(localized: "正文辅助文字"))
            } footer: {
                Text(String(localized: "行内代码默认常规字重；打开后与加粗文字同重。"))
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
                    inlineCodeBold = false
                }
            } footer: {
                Text(String(localized: "只影响聊天里的行内代码、引用等辅助文字与链接，不改动主题色和气泡。"))
            }
        }
        .settingsPage(String(localized: "聊天文字颜色"))
    }

    // MARK: Type bindings

    /// Picking a preset resets the per-scheme body override, so switching
    /// schemes always lands on that scheme's own measured size rather than
    /// carrying the previous scheme's dial-in across.
    private var schemeBinding: Binding<ChatTypeScheme> {
        Binding(
            get: { scheme },
            set: { next in
                // Snapshot what is on screen *before* the scheme changes:
                // resolving after writing `schemeRaw` would read the custom
                // snapshot instead of the preset being left behind.
                let onScreen = activeScale
                schemeRaw = next.rawValue
                bodySize = Double((next.scale(bodyOverride: nil) ?? ChatTypeScheme.compactScale).body)
                if next == .custom {
                    // Seed from the scheme that was active, so the first edit
                    // is a nudge rather than a jump to some stale snapshot.
                    customRaw = ChatTypeSettings.encodeCustom(onScreen)
                }
            }
        )
    }

    /// Dragging the body slider keeps the scheme and re-proportions it; there
    /// is no separate custom snapshot to maintain while a preset is active,
    /// because the preset *is* the rule.
    private var bodySizeBinding: Binding<Double> {
        Binding(
            get: { Double(activeScale.body) },
            set: { next in
                // Re-proportioning a preset keeps that preset's identity: the
                // user changed the size, not the shape of the scheme. The
                // preset's own resolver re-derives the rest from `bodySize`,
                // so nothing else needs writing.
                bodySize = next
                if scheme == .custom {
                    // The custom snapshot is the rule in this mode, so the
                    // re-proportioned copy *is* the new snapshot.
                    customRaw = ChatTypeSettings.encodeCustom(activeScale.scalingBody(to: CGFloat(next)))
                }
            }
        )
    }

    // MARK: Per-element follow toggles

    /// A pin on the active scale means "hold this absolute size"; no pin means
    /// the element derives from the body through the scheme's ratio.
    private func followsBody(_ keyPath: WritableKeyPath<ChatTypeScale, CGFloat?>) -> Bool {
        activeScale[keyPath: keyPath] == nil
    }

    private func followsBodyBinding(_ keyPath: WritableKeyPath<ChatTypeScale, CGFloat?>) -> Binding<Bool> {
        Binding(
            get: { followsBody(keyPath) },
            set: { follow in
                var scale = activeScale
                if follow {
                    scale[keyPath: keyPath] = nil
                } else {
                    // Seed with whatever is on screen right now, so turning the
                    // toggle off does not move the text — it only detaches it.
                    scale[keyPath: keyPath] = keyPath == \ChatTypeScale.inlineCodePin
                        ? scale.inlineCodeSize
                        : scale.codeBlockSize
                }
                commitCustom(scale)
            }
        )
    }

    private func standaloneBinding(
        _ keyPath: WritableKeyPath<ChatTypeScale, CGFloat?>,
        fallback: CGFloat
    ) -> Binding<Double> {
        Binding(
            get: { Double(activeScale[keyPath: keyPath] ?? fallback) },
            set: { next in
                var scale = activeScale
                scale[keyPath: keyPath] = CGFloat(next)
                commitCustom(scale)
            }
        )
    }

    /// Every manual adjustment lands in the custom snapshot and flips the
    /// scheme picker to「自定义」, so the picker and the sliders can never
    /// describe different scales.
    private func commitCustom(_ scale: ChatTypeScale) {
        customRaw = ChatTypeSettings.encodeCustom(scale)
        schemeRaw = ChatTypeScheme.custom.rawValue
        bodySize = Double(scale.body)
    }

    private func followToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: String(format: "%.1f pt", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value,
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   step: 0.5) {
                Text(title)
            } minimumValueLabel: {
                Text(verbatim: "A").font(.caption2)
            } maximumValueLabel: {
                Text(verbatim: "A").font(.title3)
            }
        }
        .padding(.vertical, 4)
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
    let inlineCodeBold: Bool
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
                    .font(.system(size: ChatMetrics.bodySize,
                                  weight: inlineCodeBold ? .semibold : .regular,
                                  design: .monospaced))
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
