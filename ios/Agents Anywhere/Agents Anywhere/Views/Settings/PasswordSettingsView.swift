import SwiftUI

struct PasswordSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @Binding var draft: AccountPasswordDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsScreen(title: String(localized: "Password")) {
            SettingsSection(String(localized: "New password")) {
                SettingsRowContainer(verticalPadding: 14) {
                    SecureField(String(localized: "New password"), text: $draft.password)
                        .textContentType(.newPassword)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SettingsSection(String(localized: "Confirm password"),
                            footer: String(localized: "Use at least 8 characters. Changing the password does not sign out this device.")) {
                SettingsRowContainer(verticalPadding: 14) {
                    SecureField(String(localized: "Confirm password"), text: $draft.confirmation)
                        .textContentType(.newPassword)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textFieldStyle(.plain)
        .toolbar {
            SheetSaveToolbar(isWorking: appState.isAccountWorking,
                saveDisabled: draft.password.count < 8 || draft.password != draft.confirmation,
                onSave: savePassword)
        }
        .disabled(appState.isAccountWorking)
    }

    private func savePassword() {
        Task {
            let saved = await appState.changeAccountPassword(
                newPassword: draft.password,
                confirmation: draft.confirmation
            )
            if saved {
                draft = AccountPasswordDraft()
                dismiss()
            }
        }
    }
}
