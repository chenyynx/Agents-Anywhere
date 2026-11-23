import SwiftUI
import Foundation

/// The connector-suggestion card shown by chat / Code when the agent proposes
/// connectors it can use.
///
/// Official shape (Claude iOS 1.261005.20): `ConnectorSuggestionsCardView`
/// renders `ConnectorList` — title + `ClaudeBadge`, a divider, one
/// `ConnectorRow` per suggestion, and a “No thanks” button — and forwards
/// `ConnectorRow(connector, state, installed, isActionable, isLoading,
/// onTap(action:))` (`EVIDENCE/round15/connectors.md` §3.5). Action strings and
/// state labels come from `ClaudePackage_ClaudeConnectors.bundle`
/// (`suggest_connectors_connect_button/use_button/no_thanks_button/
/// connected_label/needs_reconnect`, `disabled_by_your_organization`).
///
/// No official screenshot exists for this card, so the arrangement is INFERRED
/// from the view tree. The card reuses the chat glass container shared with
/// `ConnectorSignInCard` (the container half of `SessionInteractionCard`) and
/// the compact black capsule from the connector detail screen
/// (`ConnectorPrimaryButton`). The Claude mark is drawn with the app's template
/// starburst asset until the official badge artwork is recovered.
struct ConnectorSuggestionsCard: View {
    let rows: [ConnectorSuggestionRow]
    /// Official `isActionable`: false in shared chats, where suggestions must
    /// not start an OAuth flow (`connector_hidden_in_shared_chats` is the
    /// official telemetry name; hiding is the caller's choice).
    var isActionable = true
    /// `rowID` is nil for `.noThanks`, which is a card-level action.
    let onAction: (_ rowID: String?, _ action: ConnectorSuggestionAction) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ConnectorChatGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !rows.isEmpty {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                        rowView(row)
                    }
                    // The official card drops “No thanks” once every row is
                    // connected/restricted (capture 2026-11-24: the connected
                    // card keeps only the header + row).
                    if rows.contains(where: { $0.state != .connected && $0.state != .restricted }) {
                        noThanksButton
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// Official header (2026-11-24 capture): the connector glyph + the
    /// stringsdict title, no badge and no divider inside the card.
    private var header: some View {
        HStack(spacing: 10) {
            AppSymbol("anthropicon.connectors", size: 18)
                .foregroundStyle(SettingsStyle.ink(colorScheme))
            Text(cardTitle)
                .font(SettingsStyle.text(16, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The official title is a stringsdict (`suggest_connectors_card_title`):
    /// “%lld suggested connector” / “%lld suggested connectors”. AA's catalog
    /// uses literal keys, so the two variants are requested separately.
    private var cardTitle: String {
        let count = rows.count
        let format = count == 1
            ? String(localized: "%lld suggested connector")
            : String(localized: "%lld suggested connectors")
        return String(format: format, count)
    }

    // MARK: - Rows

    private func rowView(_ row: ConnectorSuggestionRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ConnectorLogoView(source: row.logo, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(SettingsStyle.text(16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // Official connected card: the row subtitle becomes the state
                // (“已连接”, green #296117); no action button, no summary.
                if let status = statusText(for: row.state) {
                    Text(status)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(statusColor(for: row.state))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if row.state != .connected && row.state != .restricted {
                actionButton(for: row)
            }
        }
        .padding(.vertical, 4)
    }

    /// INFERRED: status and action share one trailing column. Connected rows
    /// show “Connected” above “Use”; reconnect rows show “Needs reconnecting”
    /// above “Reconnect”; restricted rows carry only the organization label and
    /// no action.
    @ViewBuilder
    private func trailing(for row: ConnectorSuggestionRow) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let status = statusText(for: row.state) {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(statusColor(for: row.state))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.state != .restricted {
                actionButton(for: row)
            }
        }
    }

    private func actionButton(for row: ConnectorSuggestionRow) -> some View {
        let phase = effectivePhase(for: row)
        return ZStack {
            ConnectorOutlineButton(title: actionTitle(for: row.action),
                                   height: 29,
                                   isEnabled: phase == .ready) {
                onAction(row.id, row.action)
            }
            .accessibilityLabel(Text(verbatim: accessibleActionTitle(for: row.action,
                                                                     name: row.name)))
            .opacity(phase == .loading ? 0 : 1)
            if phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(SettingsStyle.secondary(colorScheme))
            }
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private var noThanksButton: some View {
        ConnectorOutlineButton(title: String(localized: "No thanks"),
                               height: 41,
                               isFullWidth: true,
                               isEnabled: isActionable) {
            onAction(nil, .noThanks)
        }
        .accessibilityLabel(Text(String(localized: "No thanks")))
    }

    // MARK: - Copy and phase

    private func effectivePhase(for row: ConnectorSuggestionRow) -> ConnectorSuggestionActionPhase {
        isActionable ? row.phase : .disabled
    }

    private func statusText(for state: ConnectorSuggestionState) -> String? {
        switch state {
        case .connected:
            return String(localized: "Connected")
        case .needsReconnect:
            return String(localized: "Needs reconnecting")
        case .restricted:
            return String(localized: "Disabled by your organization")
        case .notInstalled, .unknown:
            return nil
        }
    }

    private func statusColor(for state: ConnectorSuggestionState) -> Color {
        switch state {
        case .connected:
            // Token success000: sRGB #006300 / #91D68B (P3 capture #296117).
            return ConnectorStyle.successInk(colorScheme)
        case .needsReconnect:
            return ConnectorStyle.warningInk(colorScheme)
        case .restricted, .notInstalled, .unknown:
            return SettingsStyle.secondary(colorScheme)
        }
    }

    private func actionTitle(for action: ConnectorSuggestionAction) -> String {
        switch action {
        case .connect:
            return String(localized: "Connect")
        case .use:
            return String(localized: "Use")
        case .reconnect:
            return String(localized: "Reconnect")
        case .noThanks:
            return String(localized: "No thanks")
        }
    }

    /// Official accessibility formats: `suggest_connectors_connect_named`,
    /// `_use_named`, `_reconnect_named`.
    private func accessibleActionTitle(for action: ConnectorSuggestionAction,
                                       name: String) -> String {
        switch action {
        case .connect:
            return String(format: String(localized: "Connect %@"), name)
        case .use:
            return String(format: String(localized: "Use %@"), name)
        case .reconnect:
            return String(format: String(localized: "Reconnect %@"), name)
        case .noThanks:
            return String(localized: "No thanks")
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(SettingsStyle.hairline(colorScheme))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// One suggested connector. Mirrors the official
/// `ConnectorRow(connector, state, installed, isActionable, isLoading, …)`.
struct ConnectorSuggestionRow: Identifiable, Equatable {
    let id: String
    var name: String
    /// The official `SuggestedConnector.description` one-liner.
    var summary: String
    var logo: ConnectorLogoView.Source
    var state: ConnectorSuggestionState = .notInstalled
    var phase: ConnectorSuggestionActionPhase = .ready

    /// INFERRED mapping from `ConnectorInstallState` to the row action
    /// (the official button strings are fixed; the enum names are evidence).
    var action: ConnectorSuggestionAction {
        switch state {
        case .connected:
            return .use
        case .needsReconnect:
            return .reconnect
        case .notInstalled, .restricted, .unknown:
            return .connect
        }
    }
}

/// Mirrors `ConnectorInstallState` for the suggestion card's row states
/// (`0x104c51250`). `restricted` renders the organization label only.
enum ConnectorSuggestionState: Equatable {
    case notInstalled
    case connected
    case needsReconnect
    case restricted
    case unknown
}

/// The official action strings (`suggest_connectors_*_button`). `.noThanks` is
/// emitted with a nil row id because it belongs to the card, not a row.
enum ConnectorSuggestionAction: Equatable {
    case connect
    case use
    case reconnect
    case noThanks
}

/// Button phase requested by the task surface; `disabled` also covers a card
/// that is not actionable.
enum ConnectorSuggestionActionPhase: Equatable {
    case ready
    case loading
    case disabled
}

/// The official `ClaudeBadge` slot. UNVERIFIED artwork: the official asset was
/// not captured, so this uses the app's existing Claude starburst vector in the
/// brand clay (#D97757, measured for the runtime mark).
private struct ConnectorClaudeBadge: View {
    var body: some View {
        Image("aa-AgentClaudeCode")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .foregroundStyle(Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255))
            .accessibilityLabel(Text(verbatim: "Claude"))
    }
}

#Preview("Connector suggestions") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ConnectorSuggestionsCard(rows: [
            ConnectorSuggestionRow(id: "figma",
                                   name: "Figma",
                                   summary: "Inspect and edit your designs",
                                   logo: .image("connector-logo-figma")),
            ConnectorSuggestionRow(id: "gmail",
                                   name: "Gmail",
                                   summary: "Search your inbox and draft replies",
                                   logo: .image("connector-logo-gmail"),
                                   state: .connected),
            ConnectorSuggestionRow(id: "google-drive",
                                   name: "Google Drive",
                                   summary: "Find and read files",
                                   logo: .image("connector-logo-googledrive"),
                                   state: .needsReconnect),
            ConnectorSuggestionRow(id: "slack",
                                   name: "Slack",
                                   summary: "Read channels",
                                   logo: .letter("S"),
                                   state: .restricted)
        ]) { _, _ in }
        .padding()
    }
}
