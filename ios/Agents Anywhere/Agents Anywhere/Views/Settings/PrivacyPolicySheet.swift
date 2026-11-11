import SwiftUI

/// Available before sign-in without a server connection or account state.
struct PrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PrivacyPolicyContent()
                .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.expanded)
    }
}

/// Settings pushes the same content inside its existing navigation stack.
struct PrivacyPolicyContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsScreen(title: String(localized: "privacyPolicy.title")) {
            SettingsSection("Agents Anywhere",
                            footer: String(localized: "privacyPolicy.updated")) {
                paragraph("privacyPolicy.introduction")
            }
            SettingsSection(String(localized: "privacyPolicy.server.title")) {
                paragraph("privacyPolicy.server.body")
            }
            SettingsSection(String(localized: "privacyPolicy.agents.title")) {
                paragraph("privacyPolicy.agents.body")
                SettingsRowDivider(leading: SettingsStyle.rowPadding)
                paragraph("privacyPolicy.externalContent.body")
            }
            SettingsSection(String(localized: "privacyPolicy.localStorage.title")) {
                paragraph("privacyPolicy.localStorage.body")
            }
            SettingsSection(String(localized: "privacyPolicy.permissions.title")) {
                paragraph("privacyPolicy.permissions.body")
            }
            SettingsSection(String(localized: "privacyPolicy.retention.title")) {
                paragraph("privacyPolicy.retention.body")
            }
            SettingsSection(String(localized: "privacyPolicy.contact.title")) {
                paragraph("privacyPolicy.contact.body")
                SettingsRowDivider(leading: SettingsStyle.rowPadding)
                Link(destination: URL(string: "https://github.com/anywhere-labs/Agents-Anywhere")!) {
                    HStack(spacing: SettingsStyle.iconGap) {
                        AppSymbol("arrow.up.right", size: 18)
                            .frame(width: SettingsStyle.iconFrame)
                        Text(String(localized: "privacyPolicy.projectSupport"))
                            .font(.system(size: 17))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                    .padding(.horizontal, SettingsStyle.rowPadding)
                    .padding(.vertical, 12)
                    .frame(minHeight: SettingsStyle.rowMinHeight)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func paragraph(_ text: LocalizedStringResource) -> some View {
        SettingsRowContainer(verticalPadding: 16) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    PrivacyPolicySheet()
}
