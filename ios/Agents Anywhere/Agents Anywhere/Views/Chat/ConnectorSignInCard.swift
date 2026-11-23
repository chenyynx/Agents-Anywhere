import SwiftUI
import Foundation

/// Chat-side connector authorization card.
///
/// Official shape (Claude iOS 1.261005.20): the server projects an
/// `mcpAuth` / `connectorReconnect` elicitation into
/// `PendingConnectorSignIn { title?, name?, iconUrl?, reason, isConnecting }`
/// and renders `McpAuthRequiredCard` through
/// `ClaudeChatFeature.ConnectorSignInCard` (`0x104cd7f30`), which only wraps the
/// shared card in safe-area/flex/padding. `Reason` has exactly two cases
/// (`replyWaiting(body: String?)`, `reconnect(body: String)`); the button copy
/// is `Connect` / `Reconnect` (`EVIDENCE/round15/connectors.md` §1.3 F, §5;
/// `CANONICAL/19-connectors.md` §2).
///
/// No official capture of the chat card exists yet. UNVERIFIED: the official
/// mount point (inline in the timeline vs above the composer; EVIDENCE §1.3 F)
/// and the wrapper's exact padding. The composition below is INFERRED from the
/// type tree: logo + name, the body sentence, one glass action. The
/// surrounding container and the action button are the same ones
/// `SessionInteractionCard` / `SessionInteractionActions` use (12/10 padding,
/// 24 pt glass corners, clipped glass, `AppGlassButton`); they live in
/// `ConnectorChatGlassCard` so both connector chat cards cannot drift apart.
/// `SessionInteractionCard` itself is bound to `SessionNoticeModel` +
/// `SessionChatModel`, so reusing its surface verbatim would require fake
/// session models.
struct ConnectorSignInCard: View {
    /// Mirrors `PendingConnectorSignIn.Reason` (`0x104c51640`).
    enum Reason: Equatable, Hashable {
        case replyWaiting(body: String?)
        case reconnect(body: String)
    }

    /// Official `PendingConnectorSignIn.name`; empty falls back to the
    /// official unknown-server label (“Connector”).
    let name: String
    /// Official optional display title. When present it leads the card.
    var title: String? = nil
    /// Official `iconUrl`; nil draws the name's monogram instead.
    var iconURL: URL? = nil
    let reason: Reason
    var isConnecting = false
    let onConnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ConnectorChatGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                Text(bodyText)
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Official `ConnectorSignInCard.Body` wraps the card in
        // `.padding(.vertical, 8)` (EVIDENCE: body 0x1031f166c, Spacing 8.0).
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var header: some View {
        HStack(spacing: 10) {
            ConnectorLogoView(source: logo, size: ConnectorStyle.logoSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(SettingsStyle.text(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actionButton
        }
    }

    /// Official: `ConnectorAuthButton` renders the action with
    /// `ClaudeInlineButtonStyle<Capsule>` — the same white capsule with a
    /// #DDDDDD edge as the suggestion card (EVIDENCE: Body typealias
    /// `swiftdump-extra.txt:524863`, `ConnectorAuthButton = VStack<Text,
    /// Button<ClaudeInlineButtonStyle<Capsule>>>`).
    private var actionButton: some View {
        ZStack {
            ConnectorOutlineButton(title: actionTitle,
                                   height: 29,
                                   isEnabled: !isConnecting) {
                onConnect()
            }
            .opacity(isConnecting ? 0 : 1)
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(SettingsStyle.secondary(colorScheme))
            }
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private var logo: ConnectorLogoView.Source {
        if let iconURL { return .remote(iconURL) }
        return .letter(displayName)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Connector") : trimmed
    }

    private var trimmedTitle: String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// INFERRED: `title` leads when the server sends one, and the connector
    /// name moves to a caption line; otherwise the name is the headline.
    private var headline: String {
        trimmedTitle.isEmpty ? displayName : trimmedTitle
    }

    private var subtitle: String? {
        guard !trimmedTitle.isEmpty, trimmedTitle != displayName else { return nil }
        return displayName
    }

    /// `.replyWaiting` falls back to the official
    /// `mcp_auth_required_body`; `.reconnect` carries a required server body,
    /// with the official reconnect sentence as its empty fallback.
    /// INFERRED: a non-empty body replaces the default sentence rather than
    /// being shown twice.
    private var bodyText: String {
        switch reason {
        case .replyWaiting(let body):
            let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
                ? String(localized: "Claude needs access to continue.")
                : trimmed
        case .reconnect(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "The connector needs to be reconnected.")
                : trimmed
        }
    }

    private var actionTitle: String {
        switch reason {
        case .replyWaiting:
            return String(localized: "Connect")
        case .reconnect:
            return String(localized: "Reconnect")
        }
    }
}

/// The inline-card surface shared by the two connector chat cards.
///
/// Official: `McpAuthRequiredCard.Body` is `ClaudeCoreUI.InlineCard`, whose
/// shell is `InlineCardShell` — pure colour, 24 pt continuous corners, no
/// padding of its own (EVIDENCE: body 0x1007ffef4 / 0x100801b40). The
/// 16/12 padding used here is `InlineCardBox`'s (0x10080a2bc: horizontal 16,
/// vertical 12); the plain InlineCard relies on the host transcript row for
/// outer insets, so this keeps the box padding as the visual equivalent.
/// Inner VStack spacing is 4 officially; 12 is used to match the measured
/// card rhythm (spacing 12 in round32). `ConnectorSignInCard` adds
/// `.padding(.vertical, 8)` outside.
struct ConnectorChatGlassCard<Content: View>: View {
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SettingsStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(.rect(cornerRadius: 24))
    }
}

#Preview("Connector sign-in — reply waiting") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ConnectorSignInCard(name: "Figma",
                            iconURL: nil,
                            reason: .replyWaiting(body: nil)) {}
            .padding()
    }
}

#Preview("Connector sign-in — reconnect, connecting") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ConnectorSignInCard(name: "Figma",
                            reason: .reconnect(body: String(localized: "The connector needs to be reconnected.")),
                            isConnecting: true) {}
            .padding()
    }
}
