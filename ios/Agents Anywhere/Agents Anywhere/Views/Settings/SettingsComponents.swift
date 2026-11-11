import SwiftUI

struct SettingsLanguageView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsScreen(title: String(localized: "Language")) {
            SettingsSection(footer: String(localized: "Choose English or Simplified Chinese in the app's iOS language settings. Without an override, the app follows your preferred system language.")) {
                SettingsRowLabelContent(icon: "globe",
                                        title: String(localized: "Current language"),
                                        value: Self.currentLanguage, showsChevron: false)
            }
            SettingsSection {
                SettingsDisclosureRow(icon: "arrow.up.right",
                                      title: String(localized: "Open iOS Settings"),
                                      showsChevron: false) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        }
    }

    static var currentLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "简体中文" : "English"
    }
}

struct SettingsServerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "Server")) {
            SettingsSection(String(localized: "Connection")) {
                SettingsRowLabelContent(
                    icon: "server.rack",
                    title: String(localized: "Status"),
                    value: appState.isServerConnected
                        ? String(localized: "Connected")
                        : String(localized: "Offline"),
                    showsChevron: false)
                if let url = appState.serverURL {
                    SettingsRowDivider(leading: SettingsStyle.rowPadding)
                    SettingsRowContainer(verticalPadding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(url.absoluteString)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                            } label: {
                                Label(String(localized: "Copy server address"), appSymbol: "doc.on.doc")
                                    .font(.system(size: 15))
                                    .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let error = appState.restoreConnectionError {
                SettingsSection {
                    Text(error)
                        .font(.system(size: 15))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SettingsStyle.rowPadding)
                }
            }
        }
    }
}

struct SettingsAboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "About")) {
            SettingsSection {
                SettingsRowLabelContent(icon: "info.circle",
                                        title: String(localized: "Version"),
                                        value: Self.version, showsChevron: false)
                SettingsRowDivider(leading: SettingsStyle.rowPadding)
                SettingsRowLabelContent(icon: "number",
                                        title: String(localized: "Build"),
                                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
                                        showsChevron: false)
            }
            SettingsSection {
                SettingsNavigationRow(icon: "doc.text",
                                      title: String(localized: "Open-source notices"),
                                      destination: OpenSourceNoticesView())
            }
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct OpenSourceNoticesView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "Open-source notices")) {
            SettingsSection {
                SettingsRowContainer(verticalPadding: 16) {
                    Text(license)
                        .font(.footnote.monospaced())
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var license: String {
        Bundle.main.url(forResource: "Lucide", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Lucide · ISC"
    }
}
