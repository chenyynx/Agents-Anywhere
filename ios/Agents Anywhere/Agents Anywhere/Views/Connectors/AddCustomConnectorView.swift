import SwiftUI
import Foundation

/// The native “Add custom connector” form.
///
/// Reverse-engineered skeleton (Claude iOS 1.261005.20,
/// `ClaudeConnectors/AddCustomConnectorView.swift` + `AddCustomConnectorModel`):
/// the model owns the draft and a
/// `Failure = rejected(message) | generic | postCreateAuthFailed | alreadyInstalled`
/// (`0x104c93a10`); the screen is one settings-style form with a name and URL,
/// a “Requires sign-in” switch that reveals the OAuth client fields, the
/// untrusted-connector warning, and a submit action. Copy comes from the
/// official `ClaudePackage_ClaudeConnectors.bundle` table
/// (`EVIDENCE/round15/connectors.md` §4.3, `DATA/strings-diff.csv`).
///
/// There is no official screenshot of this sheet yet (VISUAL-SPEC 2026-11-24
/// lists “自定义连接器表单” under missing captures), so every layout decision
/// below is marked `// INFERRED` and reuses the tokens measured on the sibling
/// connector screens (paper background, 16 pt inset, 28 pt white cards, 50 pt
/// rows) plus the official 63×28 connector switch from `ConnectorComponents`.
///
/// UI-only: this view never performs a request. `onSubmit` is the seam the
/// create/install call will plug into. The submission state machine
/// (idle/submitting/failed) and the four official failure copies are already
/// rendered so the real call can drive them without another layout pass.
///
/// UNVERIFIED: whether this native form or `AddCustomConnectorWebFormModel`
/// is shown (`isAddCustomConnectorWebFormEnabled`); this file implements the
/// native variant only, per the task.
struct AddCustomConnectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var name = ""
    @State private var url = ""
    @State private var requiresSignIn = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var submission: ConnectorFormSubmission

    private let onSubmit: (ConnectorDraft) -> Void

    /// - Parameters:
    ///   - submission: seeding hook for previews / UI review. Hosts leave it at
    ///     `.idle`; the view owns every later transition.
    ///   - onSubmit: reserved callback. The draft is fully normalized
    ///     (trimmed text, OAuth fields cleared when the switch is off).
    init(submission: ConnectorFormSubmission = .idle,
         onSubmit: @escaping (ConnectorDraft) -> Void = { _ in }) {
        _submission = State(initialValue: submission)
        self.onSubmit = onSubmit
    }

    var body: some View {
        SettingsScreen(title: String(localized: "Add custom connector")) {
            VStack(alignment: .leading, spacing: 16) {
                intro
                fieldsCard
                signInSection
                if let failure {
                    inlineError(failure)
                }
                warningBanner
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // The connector screens close with the same circular key as the
                // official directory (04-directory.png); the X matches the
                // sheet's role. INFERRED that the form uses the same chrome.
                ConnectorCircleButton(symbol: "xmark", isEnabled: !isSubmitting) {
                    dismiss()
                }
                .accessibilityLabel(Text(String(localized: "Close")))
            }
        }
        .safeAreaInset(edge: .bottom) {
            submitBar
        }
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: url) { _, _ in clearFailure() }
    }

    // MARK: - Sections

    /// INFERRED: the official intro sits above the fields as plain secondary
    /// copy (no card), matching the settings explanatory footers.
    private var intro: some View {
        Text(String(localized: "Connect directly to an MCP server by entering its URL."))
            .font(ConnectorStyle.text(15))
            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// Name + URL share one card. INFERRED: label above the field, because a
    /// URL does not fit a trailing-value row at 361 pt.
    private var fieldsCard: some View {
        SettingsSection {
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(String(localized: "Name"))
                    TextField(String(localized: "My connector"), text: $name)
                        .textFieldStyle(.plain)
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityLabel(Text(String(localized: "Name")))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRowDivider(leading: SettingsStyle.rowPadding)
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(String(localized: "URL"))
                    TextField(String(localized: "https://mcp.example.com/sse"), text: $url)
                        .textFieldStyle(.plain)
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(Text(String(localized: "URL")))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The switch row and, while it is on, the OAuth client fields and the
    /// automatic-registration hint. The hint is the official section footer.
    private var signInSection: some View {
        SettingsSection(
            footer: requiresSignIn
                ? String(localized: "Leave these blank if the server supports automatic client registration.")
                : nil
        ) {
            requiresSignInRow
            if requiresSignIn {
                SettingsRowDivider(leading: SettingsStyle.rowPadding)
                credentialField(label: String(localized: "Client ID"),
                                text: $clientID,
                                secure: false)
                SettingsRowDivider(leading: SettingsStyle.rowPadding)
                credentialField(label: String(localized: "Client secret"),
                                text: $clientSecret,
                                secure: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: requiresSignIn)
    }

    /// `ConnectorSwitchStyle` draws only the switch (it ignores the Toggle
    /// label), so the title/description live beside a label-less Toggle — the
    /// same split the official settings capture uses for its 63×28 switch.
    private var requiresSignInRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Requires sign-in"))
                    .font(ConnectorStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Text(String(localized: "Turn on if this server needs you to authenticate. You can enter OAuth client details below."))
                    .font(ConnectorStyle.text(15))
                    .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(isOn: $requiresSignIn) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(ConnectorSwitchStyle())
            .accessibilityLabel(Text(String(localized: "Requires sign-in")))
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: SettingsStyle.rowMinHeight)
    }

    /// One OAuth credential row. Both fields use the official “Optional”
    /// placeholder; the secure one never echoes its value.
    @ViewBuilder
    private func credentialField(label: String, text: Binding<String>, secure: Bool) -> some View {
        SettingsRowContainer {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(label)
                Group {
                    if secure {
                        SecureField(String(localized: "Optional"), text: text)
                    } else {
                        TextField(String(localized: "Optional"), text: text)
                    }
                }
                .textFieldStyle(.plain)
                .font(ConnectorStyle.text(16))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(label))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(ConnectorStyle.text(13))
            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
    }

    private var warningBanner: some View {
        ConnectorWarningBanner(
            text: String(localized: "Only add connectors from developers you trust. A connector can offer tools that Claude will use, and those tools may access data you share in your conversation.")
        )
    }

    /// INFERRED: an inline destructive line between the form and the warning.
    /// The four copies are the official `Failure` messages; `rejected` carries
    /// the server's own message.
    private func inlineError(_ failure: ConnectorFormFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 15, weight: .regular))
            Text(failure.message)
                .font(ConnectorStyle.text(14))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ConnectorStyle.dangerInk(colorScheme))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Submit

    /// INFERRED: a full-width black capsule pinned to the bottom, the same
    /// primary-control pattern AA uses for other sheets. The official screen
    /// may instead put “Add connector” in the toolbar; copy is official either
    /// way, and the bottom inset keeps the action visible above the keyboard.
    private var submitBar: some View {
        Button(action: submit) {
            ZStack {
                Text(String(localized: "Add connector"))
                    .font(ConnectorStyle.text(16, weight: .semibold))
                    .opacity(isSubmitting ? 0 : 1)
                if isSubmitting {
                    ProgressView()
                        .tint(ConnectorStyle.actionLabel(colorScheme))
                }
            }
            .foregroundStyle(ConnectorStyle.actionLabel(colorScheme))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(ConnectorStyle.actionFill(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isSubmitEnabled)
        .opacity(isSubmitEnabled || isSubmitting ? 1 : 0.45)
        .accessibilityLabel(Text(String(localized: "Add connector")))
        .padding(.horizontal, SettingsStyle.inset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(SettingsStyle.background(colorScheme).opacity(0.96))
    }

    private var isSubmitting: Bool {
        submission == .submitting
    }

    /// INFERRED: only the URL is required; the official placeholder (“My
    /// connector”) reads as a fallback name, not a mandatory field.
    private var isSubmitEnabled: Bool {
        !isSubmitting && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var failure: ConnectorFormFailure? {
        if case .failed(let failure) = submission { return failure }
        return nil
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isMCPURL(trimmedURL) else {
            // Official `generic` copy: “Check the URL and try again.”
            submission = .failed(.generic)
            return
        }
        submission = .submitting
        onSubmit(ConnectorDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: trimmedURL,
            requiresSignIn: requiresSignIn,
            clientID: requiresSignIn
                ? clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            clientSecret: requiresSignIn ? clientSecret : ""
        ))
    }

    private func clearFailure() {
        if case .failed = submission { submission = .idle }
    }

    private static func isMCPURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else { return false }
        return true
    }
}

/// The form's draft, normalized before `onSubmit` runs. Mirrors the fields of
/// the official `AddCustomConnectorModel` (name, URL, sign-in + OAuth client).
struct ConnectorDraft: Equatable, Hashable {
    var name: String
    var url: String
    var requiresSignIn: Bool
    var clientID: String
    var clientSecret: String
}

/// The official custom-connector failure cases (`0x104c93a10`).
enum ConnectorFormFailure: Equatable {
    /// The server refused with its own message.
    case rejected(String)
    case generic
    case postCreateAuthFailed
    case alreadyInstalled

    /// Copy straight from `ClaudePackage_ClaudeConnectors.bundle`.
    var message: String {
        switch self {
        case .rejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "Couldn’t add this connector. Check the URL and try again.")
                : trimmed
        case .generic:
            return String(localized: "Couldn’t add this connector. Check the URL and try again.")
        case .postCreateAuthFailed:
            return String(localized: "The connector was added, but sign-in failed. You can retry from Connectors settings.")
        case .alreadyInstalled:
            return String(localized: "This URL is already installed. Open it from your connectors list to connect.")
        }
    }
}

/// Idle / in-flight / failed, matching the model's submission surface.
enum ConnectorFormSubmission: Equatable {
    case idle
    case submitting
    case failed(ConnectorFormFailure)
}

#Preview("Add custom connector") {
    NavigationStack {
        AddCustomConnectorView()
    }
}

#Preview("Add custom connector — failed") {
    NavigationStack {
        AddCustomConnectorView(submission: .failed(.alreadyInstalled))
    }
}
