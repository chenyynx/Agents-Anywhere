import SwiftUI

/// The phone drawer needs a navigation host inside its moving card. The iPad
/// detail already has the NavigationSplitView's host; nesting another stack
/// there would duplicate navigation chrome and safe-area handling.
struct ChatDetailNavigation: ViewModifier {
    @Environment(\.sidebarDrawerPresentation) private var presentation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if presentation == .drawer {
                // [E] The official session page is a full-screen bleed: the
                // transcript owns the scroll view's content inset and the
                // composer is a `safeAreaBar`, so no outer safe-area padding
                // may shrink the page (R21 chrome-verify.md; R19
                // chrome-composer.md §2–§3). The drawer card already spans the
                // window; padding here would push the page inside the status
                // bar and home-indicator strips and paint them opaque.
                NavigationStack { content }
                    .ignoresSafeArea(.keyboard)
            } else {
                content
            }
        }
        .background(Color(uiColor: .systemBackground))
        .tint(AppTheme.primaryControlBackground(colorScheme))
    }
}

/// Native title/subtitle placements and toolbar items own size, spacing, glass
/// grouping and scroll-edge rendering. No header view sits in the timeline.
struct ChatPageToolbar: ViewModifier {
    let title: String
    var subtitle: String?
    var status: ChatHeaderStatus?
    var alignsTitleLeading = false
    let onMenu: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(alignsTitleLeading ? "" : subtitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenu) { SidebarMenuIcon() }
                        .accessibilityLabel(String(localized: "打开侧栏"))
                }
                if alignsTitleLeading {
                    // Use the title region's available width. A leading bar
                    // item is sized as a control and can collapse to its minimum
                    // width even when there is space between the buttons.
                    ToolbarItem(placement: .principal) {
                        VStack(alignment: .leading, spacing: 1) {
                            ChatToolbarTitle(title: title)
                                .modifier(StatusShimmer(active: status?.isGlow == true))
                                .accessibilityAddTraits(.isHeader)
                            if subtitle != nil || status != nil {
                                ChatToolbarSubtitle(subtitle: subtitle, status: status)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else if subtitle != nil || status != nil {
                    ToolbarItem(placement: .subtitle) {
                        ChatToolbarSubtitle(subtitle: subtitle, status: status)
                    }
                }
            }
            // iOS 26 centers a `.principal` item; the editor role lays the title and
            // subtitle out leading, which is the alignment this header contract wants.
            // (SO 79691737 answer 3 — principal + .toolbarRole(.editor), no back-pop
            // artifact, unlike the fixedSize/topBarLeading workaround.)
            .toolbarRole(alignsTitleLeading ? .editor : .automatic)
    }
}

/// The session title in the navigation bar, in the official app's own face.
///
/// Measured from the official screenshot (1179×2556 @3x, 2026-11-16): the
/// Latin run "Light-gallery PWA" is 370 px of ink and its `L` stem is 5 px.
/// The app's own Anthropic Sans at 45 px (15 pt @3x) renders the same run at
/// 373 px of ink, with a 5 px stem at wght 550 and 4 px at wght 400 — so the
/// header is the custom face at 15 pt / 550, not the system font.
private struct ChatToolbarTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 15

    var body: some View {
        Text(title)
            .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                size: size,
                                                weight: 550)))
            .lineLimit(1)
    }
}

private struct ChatToolbarSubtitle: View {
    let subtitle: String?
    let status: ChatHeaderStatus?
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 16
    /// Official subtitle face/size (measured 2026-11-16): "Remote control" is
    /// 268 px of ink and a 4 px stem at 3x — Anthropic Sans at 39 px (13 pt)
    /// renders 277 px and a 4 px stem at wght 400.
    @ScaledMetric(relativeTo: .caption) private var subtitleSize: CGFloat = 13

    private var text: String {
        [subtitle, status?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 4) {
            // The not-ready state has no icon slot: the title and subtitle are
            // swept by the shared activity shimmer (no spinner, no glyph, no copy).
            if let status, !status.isGlow {
                Group {
                    if status.isProgress { ProgressView().controlSize(.mini) }
                    else { AppSymbol(status.symbol, size: 12) }
                }.frame(width: lineHeight, height: lineHeight)
            }
            Text(verbatim: text).lineLimit(1)
                .modifier(StatusShimmer(active: status?.isGlow == true))
        }
        .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                            size: subtitleSize,
                                            weight: 400)))
        // Landed between the two measured ends: `.secondary` composites to
        // ~rgb(138) and the official screenshot's subtitle sits at ~rgb(66)
        // (`text300`). On the device `text300` read too dark (pp 2026-11-16),
        // so the header uses the midpoint — black at 55 % in light (~rgb(115)),
        // white at 55 % in dark (~rgb(140), the `.secondary` weight).
        .foregroundStyle(Color.primary.opacity(0.55))
        .frame(height: lineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([subtitle, status?.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct SidebarMenuIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The official drawer mark (pp 2026-11-18: 用 Claude 官方左上角图标):
        // two long lines over a short one, `anthropicon.menu` from the app's
        // own ClaudeIcons bundle — not the Lucide-style `aa-TextAlignStart`
        // it replaces. `.large` is the nav-bar preset; the artwork's own
        // extent comes from `AnthropiconAssets`. The ink is the official
        // `text300` (#383835 / #C3C2B7), which is what the official device
        // screenshot measures — the bar's default primary would be black.
        AnthropiconView(name: "anthropicon.menu", size: .large)
            .foregroundStyle(AppTheme.text300(colorScheme))
            .accessibilityHidden(true)
    }
}
