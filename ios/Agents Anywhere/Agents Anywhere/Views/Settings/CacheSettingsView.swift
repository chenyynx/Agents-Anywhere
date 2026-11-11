import SwiftUI

/// Local cache controls: current usage, the user-selected budget, and a
/// clear action that keeps user work (drafts, queued messages, notifications)
/// and pinned sessions.
struct CacheSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var usage: LocalCacheUsage?
    @State private var limit = LocalCachePolicy.current
    @State private var confirmsClear = false
    @State private var isWorking = false

    private var service: LocalCacheService? {
        appState.nativeChatServices?.localCache
    }

    private var usageText: String {
        guard let usage else { return "—" }
        return "\(LocalCachePolicy.formatted(usage.bytes)) / \(limit.title)"
    }

    private var progress: Double {
        guard let usage else { return 0 }
        let budget = limit.bytes ?? LocalCachePolicy.hardSafetyCeiling
        guard budget > 0 else { return 0 }
        return min(1, max(0, Double(usage.bytes) / Double(budget)))
    }

    var body: some View {
        SettingsScreen(title: String(localized: "Cache")) {
            SettingsSection(footer: String(localized: "Cached message rows, SubAgent activity and attachment previews.")) {
                SettingsRowContainer(verticalPadding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(String(localized: "Used"))
                                .font(SettingsStyle.text(16))
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                            Spacer(minLength: 8)
                            Text(usageText)
                                .font(SettingsStyle.text(16))
                                .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        }
                        ProgressView(value: progress)
                            .tint(SettingsStyle.controlTint(colorScheme))
                        if let usage {
                            Text(String(localized: "\(usage.sessions) sessions cached"))
                                .font(SettingsStyle.text(13))
                                .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection(String(localized: "Cache limit"),
                            footer: String(localized: "Fixed sessions are never cleared. Unlimited still respects the device's free space.")) {
                ForEach(Array(LocalCacheLimit.allCases.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    SettingsSelectRow(title: option.title, isSelected: option == limit) {
                        choose(option)
                    }
                }
            }

            SettingsSection(footer: String(localized: "Takes effect on the next app launch. Turn off to fall back to the JSON archive.")) {
                SettingsToggleRow(icon: "archivebox",
                                  title: String(localized: "Local transcript cache (Beta)"),
                                  isOn: Binding(get: { LocalTimelineStore.appEnabled },
                                                set: { LocalTimelineStore.appEnabled = $0 }))
            }

            SettingsSection(footer: String(localized: "Drafts, queued messages and notification state are kept.")) {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    HStack(spacing: SettingsStyle.iconGap) {
                        AppSymbol("trash", size: 18)
                            .frame(width: SettingsStyle.iconFrame)
                        Text(String(localized: "Clear cache"))
                            .font(SettingsStyle.text(16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, SettingsStyle.rowPadding)
                    .padding(.vertical, 12)
                    .frame(minHeight: SettingsStyle.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || service == nil)
            }
        }
        .task { await refresh() }
        .confirmationDialog(String(localized: "Clear cached session content?"),
                            isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(String(localized: "Clear cache"), role: .destructive) {
                Task { await clear() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This removes cached message rows, SubAgent activity and attachment previews. Drafts and queued messages stay."))
        }
    }

    private func refresh() async {
        guard let service else { return }
        usage = await service.usage()
    }

    private func choose(_ option: LocalCacheLimit) {
        limit = option
        guard let service else { return }
        isWorking = true
        Task {
            usage = await service.setLimit(option)
            isWorking = false
        }
    }

    private func clear() async {
        guard let service else { return }
        isWorking = true
        let before = usage
        usage = await service.clearCache()
        isWorking = false
        ClientDiagnosticsLog.shared.record(
            kind: "cache.clear",
            detail: [
                "beforeBytes": String(before?.bytes ?? 0),
                "beforeSessions": String(before?.sessions ?? 0),
                "afterBytes": String(usage?.bytes ?? 0),
                "afterSessions": String(usage?.sessions ?? 0),
            ],
            dedupe: false
        )
    }
}
