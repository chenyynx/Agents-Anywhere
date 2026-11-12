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
///
/// Laid out as a document rather than a settings list (pp 2026-11-13): a
/// date-and-lede hero, a three-line summary card, then numbered sections in
/// continuous prose. White cards are kept only where a card carries meaning —
/// the summary and the contact block.
struct PrivacyPolicyContent: View {
    @Environment(\.colorScheme) private var colorScheme

    private let sections: [PolicySectionSpec] = [
        PolicySectionSpec(title: "privacyPolicy.localStorage.title",
                          bodies: ["privacyPolicy.localStorage.body"]),
        PolicySectionSpec(title: "privacyPolicy.diagnostics.title",
                          bodies: ["privacyPolicy.diagnostics.body"]),
        PolicySectionSpec(title: "privacyPolicy.server.title",
                          bodies: ["privacyPolicy.server.body"]),
        PolicySectionSpec(title: "privacyPolicy.agents.title",
                          bodies: ["privacyPolicy.agents.body"]),
        PolicySectionSpec(title: "privacyPolicy.externalContent.title",
                          bodies: ["privacyPolicy.externalContent.body"]),
        PolicySectionSpec(title: "privacyPolicy.permissions.title",
                          bodies: ["privacyPolicy.permissions.body"]),
        PolicySectionSpec(title: "privacyPolicy.retention.title",
                          bodies: ["privacyPolicy.retention.body"]),
        PolicySectionSpec(title: "privacyPolicy.security.title",
                          bodies: ["privacyPolicy.security.body"]),
    ]

    var body: some View {
        SettingsScreen(title: String(localized: "privacyPolicy.title")) {
            hero
            summaryCard
            sectionList
            contactCard
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "privacyPolicy.updated"))
                .font(SettingsStyle.text(13, weight: .medium))
                .foregroundStyle(SettingsStyle.secondary(colorScheme))
                .padding(.horizontal, 2)
            Text("privacyPolicy.introduction")
                .font(SettingsStyle.text(17))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        SettingsSection(String(localized: "privacyPolicy.summary.title")) {
            summaryRow(icon: "iphone", text: "privacyPolicy.summary.local")
            SettingsRowDivider(leading: SettingsStyle.rowPadding)
            summaryRow(icon: "server.rack", text: "privacyPolicy.summary.server")
            SettingsRowDivider(leading: SettingsStyle.rowPadding)
            summaryRow(icon: "hand.raised", text: "privacyPolicy.summary.tracking")
        }
    }

    private func summaryRow(icon: String, text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: SettingsStyle.iconGap) {
            AppSymbol(icon, size: 17)
                .frame(width: SettingsStyle.iconFrame)
                .foregroundStyle(SettingsStyle.icon(colorScheme))
            Text(text)
                .font(SettingsStyle.text(15))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 14)
    }

    // MARK: - Sections

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                sectionView(number: index + 1, section: section)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    private func sectionView(number: Int, section: PolicySectionSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(SettingsStyle.text(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                Text(section.title)
                    .font(SettingsStyle.text(20, weight: .semibold))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
            }
            ForEach(section.bodies.indices, id: \.self) { bodyIndex in
                Text(section.bodies[bodyIndex])
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Contact

    private var contactCard: some View {
        SettingsSection(String(localized: "privacyPolicy.contact.title")) {
            SettingsRowContainer(verticalPadding: 16) {
                Text("privacyPolicy.contact.body")
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRowDivider(leading: SettingsStyle.rowPadding)
            Link(destination: URL(string: "https://github.com/anywhere-labs/Agents-Anywhere")!) {
                HStack(spacing: SettingsStyle.iconGap) {
                    AppSymbol("arrow.up.right", size: 18)
                        .frame(width: SettingsStyle.iconFrame)
                    Text(String(localized: "privacyPolicy.projectSupport"))
                        .font(SettingsStyle.text(16))
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

private struct PolicySectionSpec {
    let title: LocalizedStringResource
    let bodies: [LocalizedStringResource]
}

#Preview {
    PrivacyPolicySheet()
}
