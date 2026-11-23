import SwiftUI

/// Notification preferences. The server decides which session events deserve
/// a notification; these switches control display only. Background
/// keep-alive is unconditional while notifications are on.
struct NotificationSettingsView: View {
    @AppStorage(NotificationSettings.enabledKey) private var enabled = true
    @AppStorage(NotificationSettings.previewKey) private var preview = true
    @AppStorage(NotificationSettings.sessionSocketKey) private var sessionSocket = false
    @AppStorage(NotificationSettings.foregroundKey) private var foreground = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "Notifications")) {
            SettingsSection(footer: String(localized: "A local notification, not a remote push: the app keeps its own background connection so one can arrive while iOS lets it run, falling back to silent audio or coarse location if needed (it never reads or sends your location). This does not depend on the session switch below. If background execution is unavailable, it waits until the app opens again.")) {
                SettingsToggleRow(icon: "text.bubble",
                                  title: String(localized: "Notifications"),
                                  isOn: $enabled)
                SettingsRowDivider()
                SettingsToggleRow(icon: "anthropicon.eye",
                                  title: String(localized: "Show message preview"),
                                  isOn: $preview,
                                  isEnabled: enabled)
            }

            SettingsSection(footer: String(localized: "This switch only keeps the conversation on screen updating while the app is in the background; notifications do not depend on it. Foreground notifications controls banners for other sessions while you are in the app.")) {
                SettingsToggleRow(icon: "text.bubble",
                                  title: String(localized: "Keep the current session updating in background"),
                                  isOn: $sessionSocket,
                                  isEnabled: enabled)
                SettingsRowDivider()
                SettingsToggleRow(icon: "anthropicon.eye",
                                  title: String(localized: "Foreground notifications"),
                                  isOn: $foreground,
                                  isEnabled: enabled)
            }
        }
        .onChange(of: enabled) { _, isOn in
            if isOn {
                NotificationService.shared.requestAuthorization()
            }
        }
    }
}
