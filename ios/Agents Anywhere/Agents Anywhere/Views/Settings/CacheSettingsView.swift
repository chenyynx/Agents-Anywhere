import SwiftUI

/// Local cache controls: current usage, the user-selected budget, and a
/// clear action that keeps user work (drafts, queued messages, notifications)
/// and pinned sessions.
struct CacheSettingsView: View {
    @Environment(AppState.self) private var appState
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
        List {
            Section {
                LabeledContent(String(localized: "Used"), value: usageText)
                ProgressView(value: progress)
                    .tint(.accentColor)
                if let usage {
                    Text(String(localized: "\(usage.sessions) sessions cached"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(String(localized: "Cached message rows, SubAgent activity and attachment previews."))
            }

            Section("Cache limit") {
                ForEach(LocalCacheLimit.allCases) { option in
                    Button {
                        choose(option)
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if option == limit {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(option == limit ? .isSelected : [])
                }
            } footer: {
                Text(String(localized: "Fixed sessions are never cleared. Unlimited still respects the device's free space."))
            }

            Section {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label(String(localized: "Clear cache"), systemImage: "trash")
                }
                .disabled(isWorking || service == nil)
            } footer: {
                Text(String(localized: "Drafts, queued messages and notification state are kept."))
            }
        }
        .settingsPage(String(localized: "Cache"))
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
        usage = await service.clearCache()
        isWorking = false
    }
}
