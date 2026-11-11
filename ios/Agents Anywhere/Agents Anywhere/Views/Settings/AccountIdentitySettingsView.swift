import SwiftUI

struct AccountIdentitySettingsView: View {
    enum Mode { case nickname, email }
    let mode: Mode
    @Binding var draft: AccountIdentityDraft
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var config: AuthConfig?
    @State private var isLoadingConfig = false
    @State private var cooldown = 0
    @State private var codeSent = false
    @State private var error: String?

    private var normalized: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: LocalizedStringResource { mode == .nickname ? "Nickname" : "Email" }
    private var validEmail: Bool { normalized.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil }
    private var verificationRequired: Bool { config?.emailVerificationRequired == true }
    private var canSave: Bool {
        mode == .nickname ? (1...64).contains(normalized.count) && draft.text != draft.initialText :
            config != nil && validEmail && (draft.text != draft.initialText || appState.me?.emailVerified != true) && (!verificationRequired || draft.code.count == 6)
    }

    var body: some View {
        SettingsScreen(title: String(localized: title)) {
            SettingsSection(String(localized: title)) {
                SettingsRowContainer(verticalPadding: 14) {
                    TextField(String(localized: title), text: $draft.text)
                        .textContentType(mode == .nickname ? .nickname : .emailAddress)
                        .keyboardType(mode == .email ? .emailAddress : .default)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .onChange(of: draft.text) { _, _ in draft.code = ""; codeSent = false }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if mode == .email {
                if draft.text == draft.initialText && !draft.initialText.isEmpty {
                    SettingsSection {
                        SettingsRowLabelContent(icon: "envelope",
                                                title: String(localized: "Email status"),
                                                value: appState.me?.emailVerified == true
                                                    ? String(localized: "Verified")
                                                    : String(localized: "Not verified"),
                                                showsChevron: false)
                    }
                }
                SettingsSection(footer: config.map { !$0.emailVerificationRequired }
                                == true ? String(localized: "This service accepts email without a verification code.") : nil) {
                    if isLoadingConfig {
                        SettingsRowContainer {
                            ProgressView(String(localized: "Loading email settings…"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if config == nil {
                        SettingsDisclosureRow(icon: "arrow.clockwise",
                                              title: String(localized: "Retry loading email settings"),
                                              showsChevron: false) {
                            Task { await loadConfig() }
                        }
                    } else if verificationRequired {
                        SettingsRowContainer(verticalPadding: 14) {
                            TextField(String(localized: "Email verification code"), text: $draft.code)
                                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                                .font(SettingsStyle.text(16))
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                                .onChange(of: draft.code) { _, _ in draft.code = String(draft.code.filter(\.isNumber).prefix(6)) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SettingsRowDivider()
                        SettingsDisclosureRow(icon: "arrow.up.right",
                                              title: cooldown > 0
                                                  ? String(localized: "Resend in \(cooldown) s")
                                                  : String(localized: "Send verification code"),
                                              showsChevron: false,
                                              isEnabled: validEmail && cooldown == 0 && !draft.isWorking) {
                            sendCode()
                        }
                        if codeSent {
                            SettingsRowDivider()
                            SettingsRowContainer {
                                Text(String(localized: "Code sent. Check your inbox."))
                                    .font(SettingsStyle.text(15))
                                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .textFieldStyle(.plain)
        .disabled(draft.isWorking)
        .toolbar { SheetSaveToolbar(isWorking: draft.isWorking, saveDisabled: !canSave, onSave: save) }
        .task {
            if !draft.didInitialize {
                draft.didInitialize = true
                draft.text = mode == .nickname ? appState.me?.displayName ?? "" : appState.me?.email ?? ""
                draft.initialText = draft.text
            }
            if mode == .email { await loadConfig() }
        }
        .task(id: cooldown) {
            guard cooldown > 0 else { return }
            do { try await Task.sleep(for: .seconds(1)); cooldown -= 1 } catch {}
        }
        .alert(String(localized: "Account update failed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func loadConfig() async {
        isLoadingConfig = true
        defer { isLoadingConfig = false }
        do { config = try await appState.accountAuthConfig() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard canSave, !draft.isWorking else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        draft.isWorking = true
        Task {
            await Task.yield()
            defer { draft.isWorking = false }
            do {
                if mode == .nickname { try await appState.updateAccountProfile(displayName: normalized) }
                else { try await appState.bindAccountEmail(email: normalized, code: verificationRequired ? draft.code : nil) }
                draft.initialText = draft.text; draft.code = ""; dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func sendCode() {
        guard !draft.isWorking, validEmail, cooldown == 0 else { return }
        draft.isWorking = true
        Task {
            defer { draft.isWorking = false }
            do {
                let response = try await appState.sendAccountEmailCode(email: normalized)
                cooldown = max(response.retryAfter, 1); codeSent = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
