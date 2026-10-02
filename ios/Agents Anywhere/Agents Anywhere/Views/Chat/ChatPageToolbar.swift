import SwiftUI

/// The phone drawer needs a navigation host inside its moving card. The iPad
/// detail already has the NavigationSplitView's host; nesting another stack
/// there would duplicate navigation chrome and safe-area handling.
struct ChatDetailNavigation: ViewModifier {
    let insets: EdgeInsets
    @Environment(\.sidebarDrawerPresentation) private var presentation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if presentation == .drawer {
                NavigationStack { content }
                    .ignoresSafeArea(.keyboard)
                    // Preserve the drawer's stable, untransformed safe area,
                    // including keyboard avoidance. Pages add no other inset.
                    .padding(insets)
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
                            Text(title).font(.headline).lineLimit(1)
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
    }
}

private struct ChatToolbarSubtitle: View {
    let subtitle: String?
    let status: ChatHeaderStatus?
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 16

    private var text: String {
        [subtitle, status?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 4) {
            // The not-ready state has no icon slot: it is the sweep overlay
            // below the row (no spinner, no glyph, no copy).
            if let status, !status.isGlow {
                Group {
                    if status.isProgress { ProgressView().controlSize(.mini) }
                    else { AppSymbol(status.symbol, size: 12) }
                }.frame(width: lineHeight, height: lineHeight)
            }
            Text(verbatim: text).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(height: lineHeight)
        .overlay(alignment: .bottom) {
            if status?.isGlow == true { HeaderGlowSweep().accessibilityHidden(true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([subtitle, status?.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// The header's not-ready indicator: a thin matte light sweeps across the
/// toolbar row. Local compositor animation only — no per-frame model
/// publications — reusing the timeline sweep's 1.6s linear language.
/// Reduce Motion degrades to a static low line.
private struct HeaderGlowSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeps = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        Capsule()
                            .fill(LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .primary.opacity(0.30), location: 0.5),
                                .init(color: .clear, location: 1)
                            ], startPoint: .leading, endPoint: .trailing))
                            .frame(width: width * 1.5)
                            .offset(x: sweeps ? width : -width * 1.5)
                    }
                }
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            guard !reduceMotion else { return }
            sweeps = false
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweeps = true }
        }
        .onDisappear { sweeps = false }
    }
}

struct SidebarMenuIcon: View {
    var body: some View {
        AppSymbol("sidebar.left", size: 22).accessibilityHidden(true)
    }
}
