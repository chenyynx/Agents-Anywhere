import SwiftUI

/// Notification preferences. The server decides which session events deserve
/// a notification; these switches control display and whether the app keeps
/// its background connection so a notification can actually arrive.
struct NotificationSettingsView: View {
    @AppStorage(NotificationSettings.enabledKey) private var enabled = false
    @AppStorage(NotificationSettings.previewKey) private var preview = true
    @AppStorage(NotificationSettings.keepAliveKey) private var keepAlive = true
    @AppStorage(NotificationSettings.sessionSocketKey) private var sessionSocket = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "Notifications")) {
            SettingsSection(footer: String(localized: "A local notification, not a remote push: it can arrive only while iOS keeps the app running. If background execution is unavailable, no notification is sent until the app opens again.")) {
                SettingsToggleRow(icon: "text.bubble",
                                  title: String(localized: "Notifications"),
                                  isOn: $enabled)
                SettingsRowDivider()
                SettingsToggleRow(icon: "anthropicon.eye",
                                  title: String(localized: "Show message preview"),
                                  isOn: $preview,
                                  isEnabled: enabled)
            }

            SettingsSection(footer: String(localized: "While a turn runs, the app keeps a background connection so it can tell you when the reply is ready or an approval is waiting. iOS may end that early; the app then falls back to silent audio, then coarse location. It never reads or sends your location.")) {
                SettingsToggleRow(icon: "anthropicon.clock",
                                  title: String(localized: "Keep the connection in background"),
                                  isOn: $keepAlive,
                                  isEnabled: enabled)
                SettingsRowDivider()
                SettingsToggleRow(icon: "text.bubble",
                                  title: String(localized: "Keep the session connected in background"),
                                  isOn: $sessionSocket,
                                  isEnabled: enabled && keepAlive)
            }
        }
        .onChange(of: enabled) { _, isOn in
            if isOn {
                NotificationService.shared.requestAuthorization()
            }
        }
    }
}
