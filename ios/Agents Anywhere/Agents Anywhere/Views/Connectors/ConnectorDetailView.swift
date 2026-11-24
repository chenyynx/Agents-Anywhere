import SwiftUI

/// Connector detail screen, reproduced from the official 1.261109.19 captures
/// (2026-11-24, 1179×2556 px = 393×852 pt @3x):
///
/// - **Directory entry** (Google Drive): circular back key + inline title,
///   logo/name/verified header, prose card, “Details” card with the directory
///   metadata, a standalone “Tools” card and a floating black “Connect”
///   capsule.
/// - **Custom connector** (“my phone”): name + “Custom” subtitle in the
///   navigation bar, refresh key, unverified banner, connector URL card,
///   “All tools” card, per-tool permission card and the destructive
///   “Disconnect” card.
///
/// Geometry that the captures pin down (row height 49 pt, card radius 28 pt,
/// inner card inset 20 pt, 16 pt gaps on the custom shape) is applied below;
/// values that depend on the sheet chrome (top offsets under the navigation
/// bar, floating button origin) are marked `UNVERIFIED`.
struct ConnectorDetailView: View {
    let data: ConnectorDetailData
    var onConnect: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onCopyURL: () -> Void = {}
    var onOpenTools: () -> Void = {}
    var onOpenAllTools: () -> Void = {}
    var onOpenTool: (String) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    var onOpenLink: (URL) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsTools = false

    var body: some View {
        switch data.content {
        case .directory(let content):
            directoryScreen(content)
        case .custom(let content):
            customScreen(content)
        }
    }

    // MARK: - Directory shape (Google Drive capture)

    private func directoryScreen(_ content: ConnectorDetailContent.Directory) -> some View {
        SettingsScreen(title: data.name) {
            VStack(alignment: .leading, spacing: 0) {
                directoryHeader(oneLiner: content.oneLiner)
                    // Official header starts at x 36 (16 page inset + 20), in
                    // line with the section headers rather than the card text.
                    .padding(.leading, 20)
                    // UNVERIFIED: distance from the sheet’s navigation bar;
                    // the capture puts the name’s ink 176 pt from the top.
                    .padding(.top, 34)
                    .padding(.bottom, 4)
                descriptionCard(content.description)
                    .padding(.top, 24)
                detailsSection(content)
                    .padding(.top, 24)
                toolsCard(toolCount: content.toolCount)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) {
            ConnectorPrimaryButton(title: String(localized: "Connect"), action: onConnect)
                .padding(.trailing, 24)
                // The capture puts the capsule’s ink bottom on the home
                // indicator boundary (y 818 of 852 pt), i.e. the bottom safe
                // area, matching the verified device FAB overlay. 24 pt from
                // the trailing edge.
                .padding(.bottom, 2)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
                    .accessibilityLabel(Text(String(localized: "Back")))
            }
        }
        .navigationDestination(isPresented: $showsTools) {
            ConnectorToolListView(
                title: String(localized: "Tools"),
                toolNames: ConnectorToolListData.googleDriveTools)
        }
    }

    private func directoryHeader(oneLiner: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            ConnectorLogoView(source: data.logo, size: ConnectorStyle.logoSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(data.name)
                        .font(ConnectorStyle.text(16, weight: .semibold))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if data.isVerified { ConnectorVerifiedBadge() }
                }
                // The capture’s one-liner ink is ~11 pt tall (cap ~8 pt) and
                // 198 pt wide — one step below the 15 pt row subtitles.
                Text(oneLiner)
                    .font(ConnectorStyle.text(12))
                    .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func descriptionCard(_ text: String) -> some View {
        Text(text)
            // 13.5 pt reproduces the capture’s ten lines and its first-line
            // break (“…search through”) inside the 321 pt text column.
            .font(ConnectorStyle.text(13.5))
            .foregroundStyle(SettingsStyle.ink(colorScheme))
            // Official line pitch is 21 pt: 16.9 pt line box + 4 pt leading.
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(SettingsStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
    }

    private func detailsSection(_ content: ConnectorDetailContent.Directory) -> some View {
        SettingsSection(String(localized: "Details")) {
            // Two groups keep each ViewBuilder block inside its ten-child
            // limit; Group adds no layout of its own.
            Group {
                linkRow(label: String(localized: "Author"),
                        value: content.author,
                        url: content.authorURL)
                detailDivider(leading: 20)
                textRow(label: String(localized: "Category"), value: content.category)
                detailDivider(leading: 20)
                textRow(label: String(localized: "Sign-in"), value: content.signIn)
                detailDivider(leading: 20)
                connectorURLRow(label: String(localized: "Connector URL"),
                                url: content.connectorURL,
                                minHeight: 67)
                detailDivider(leading: 20)
                textRow(label: String(localized: "Added"), value: content.added)
            }
            Group {
                detailDivider(leading: 20)
                linkRow(label: String(localized: "Documentation"), url: content.documentationURL)
                detailDivider(leading: 20)
                linkRow(label: String(localized: "Support"), url: content.supportURL)
                detailDivider(leading: 20)
                linkRow(label: String(localized: "Privacy Policy"), url: content.privacyPolicyURL)
            }
        }
    }

    private func toolsCard(toolCount: Int) -> some View {
        Button {
            showsTools = true
        } label: {
            SettingsRowContainer(minHeight: 50, verticalPadding: 12) {
                HStack(spacing: 10) {
                    Text(String(localized: "Tools"))
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    Spacer(minLength: 8)
                    Text(verbatim: "\(toolCount)")
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(ConnectorDetailStyle.value(colorScheme))
                    chevron
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SettingsStyle.card(colorScheme),
                    in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
    }

    // MARK: - Custom shape (“my phone” capture)

    private func customScreen(_ content: ConnectorDetailContent.Custom) -> some View {
        // UNVERIFIED: the banner sits ~17 pt under the sheet’s navigation bar;
        // this keeps the shared screen’s 10 pt content inset.
        SettingsScreen(title: data.name) {
            VStack(alignment: .leading, spacing: 16) {
                ConnectorWarningBanner(text: content.warning)
                card {
                    connectorURLRow(label: String(localized: "Connector URL"),
                                    url: content.connectorURL,
                                    minHeight: 66)
                }
                card {
                    // Display only: AA delegates tool permissions to each
                    // runtime, so the official “Always allow” value and the
                    // permission picker are intentionally not reproduced.
                    SettingsRowContainer(minHeight: 50, verticalPadding: 12) {
                        HStack(spacing: 10) {
                            Text(String(localized: "All tools"))
                                .font(ConnectorStyle.text(16))
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                            Spacer(minLength: 8)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                customToolsCard(content.tools)
                disconnectCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
                    .accessibilityLabel(Text(String(localized: "Back")))
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(data.name)
                        .font(ConnectorStyle.text(22, weight: .semibold))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    Text(String(localized: "Custom"))
                        .font(ConnectorStyle.text(13))
                        .foregroundStyle(ConnectorDetailStyle.tertiary(colorScheme))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ConnectorCircleButton(symbol: "arrow.clockwise") { onRefresh() }
                    .accessibilityLabel(Text(String(localized: "Refresh")))
            }
        }
    }

    private func customToolsCard(_ tools: [ConnectorDetailContent.Tool]) -> some View {
        card {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    // Official divider clears the 24 pt monogram: 20 + 24 + 8.
                    detailDivider(leading: 52)
                }
                // Display only — tools are listed by name; permissions follow
                // the runtime's session-level setting and are not shown here.
                SettingsRowContainer(minHeight: 54, verticalPadding: 15) {
                    HStack(spacing: 9) {
                        ConnectorLogoView(source: .letter(data.monogramLetter), size: 24)
                        Text(tool.name)
                            .font(ConnectorStyle.text(16))
                            .foregroundStyle(SettingsStyle.ink(colorScheme))
                        Spacer(minLength: 8)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var disconnectCard: some View {
        card {
            Button(action: onDisconnect) {
                SettingsRowContainer(minHeight: ConnectorStyle.rowHeight, verticalPadding: 12) {
                    HStack(spacing: 8) {
                        Text(String(localized: "Disconnect"))
                            .font(ConnectorStyle.text(16))
                            .foregroundStyle(ConnectorStyle.dangerInk(colorScheme))
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shared pieces

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(SettingsStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
    }

    /// One value row of the Details card: 16 pt label, 16 pt grey value.
    private func textRow(label: String, value: String) -> some View {
        SettingsRowContainer(minHeight: ConnectorStyle.rowHeight, verticalPadding: 12) {
            HStack(spacing: 8) {
                Text(label)
                    .font(ConnectorStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Spacer(minLength: 8)
                Text(value)
                    .font(ConnectorStyle.text(16))
                    .foregroundStyle(ConnectorDetailStyle.value(colorScheme))
                    .lineLimit(1)
            }
        }
        // Official card content is inset 20 pt; the shared row container
        // already contributes the settings-standard 16.
        .padding(.horizontal, 4)
    }

    /// Accent-coloured link row (author, documentation, support, privacy) with
    /// the official 54 pt height and 17 pt external-link glyph.
    private func linkRow(label: String, value: String? = nil, url: URL?) -> some View {
        Button {
            if let url { onOpenLink(url) }
        } label: {
            SettingsRowContainer(minHeight: 54, verticalPadding: 12) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(ConnectorDetailStyle.link(colorScheme))
                    Spacer(minLength: 8)
                    if let value {
                        Text(value)
                            .font(ConnectorStyle.text(16))
                            .foregroundStyle(ConnectorDetailStyle.link(colorScheme))
                            .lineLimit(1)
                    }
                    ConnectorSymbol(name: "anthropicon.arrowOutSquare", size: 17)
                        .foregroundStyle(ConnectorDetailStyle.link(colorScheme))
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Two-line URL row: 16 pt label, 12 pt grey address and the copy glyph
    /// centred on the trailing edge (official glyph ink 13.7×13.7 pt).
    private func connectorURLRow(label: String, url: String, minHeight: CGFloat) -> some View {
        SettingsRowContainer(minHeight: minHeight, verticalPadding: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(ConnectorStyle.text(16))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    Text(url)
                        .font(ConnectorStyle.text(12))
                        .foregroundStyle(ConnectorDetailStyle.tertiary(colorScheme))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: onCopyURL) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(ConnectorDetailStyle.tertiary(colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "Copy URL")))
            }
        }
        .padding(.horizontal, 4)
    }

    /// Hairline inside a card: 20 pt leading (relative to the card) and a
    /// 20 pt trailing inset, versus the settings-standard 53 / 14.
    private func detailDivider(leading: CGFloat) -> some View {
        SettingsRowDivider(leading: leading)
            .padding(.trailing, 6)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ConnectorStyle.chevron(colorScheme))
    }
}

// MARK: - Colours

/// Detail-screen colours sampled from the 2026-11-24 captures that the shared
/// tokens do not carry yet.
nonisolated enum ConnectorDetailStyle {
    /// Header one-liner, detail values, permissions: light #52514E (identical
    /// to `AppTheme.composerRowIcon`).
    static func secondary(_ scheme: ColorScheme) -> Color {
        AppTheme.composerRowIcon(scheme)
    }

    /// URL strings, the copy glyph and the “Custom” subtitle: light #88877F
    /// (subtitle samples #87878A — the same grey within one step). Dark value
    /// projected from light, UNVERIFIED.
    static func tertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.52)
            : Color(red: 0x88 / 255.0, green: 0x87 / 255.0, blue: 0x7F / 255.0)
    }

    /// Detail values (category / sign-in / tool count): token `text400`
    /// (#7B796F light, #97958D dark), one step lighter than the one-liner.
    static func value(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x97 / 255.0, green: 0x95 / 255.0, blue: 0x8D / 255.0)
            : Color(red: 0x7B / 255.0, green: 0x79 / 255.0, blue: 0x6F / 255.0)
    }

    /// Text links (author / documentation / support / privacy):
    /// `accentSecondary000` (#184F95 light, #9EC5F4 dark). The switch/check
    /// accent is the brighter accentSecondary200.
    static func link(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x9E / 255.0, green: 0xC5 / 255.0, blue: 0xF4 / 255.0)
            : Color(red: 0x18 / 255.0, green: 0x4F / 255.0, blue: 0x95 / 255.0)
    }
}

// MARK: - Data

/// Everything the detail screen draws. Server data (author, URLs, tool names)
/// stays verbatim; UI copy is localized.
struct ConnectorDetailData {
    let name: String
    let logo: ConnectorLogoView.Source
    /// Letter drawn by the monogram tiles (custom connectors such as “my
    /// phone”, which the official app renders as an “M” tile).
    let monogramLetter: String
    let isVerified: Bool
    let content: ConnectorDetailContent
}

nonisolated enum ConnectorDetailContent {
    case directory(Directory)
    case custom(Custom)

    struct Directory {
        let oneLiner: String
        let description: String
        /// Directory-provided fields; never localized.
        let author: String
        let authorURL: URL?
        let category: String
        let signIn: String
        let connectorURL: String
        let added: String
        let documentationURL: URL?
        let supportURL: URL?
        let privacyPolicyURL: URL?
        let toolCount: Int
    }

    struct Custom {
        let warning: String
        let connectorURL: String
        let tools: [Tool]
    }

    struct Tool: Identifiable {
        let id: String
        /// Tool identifiers come from the MCP server; kept verbatim.
        /// Permissions are intentionally absent: AA delegates them to the
        /// runtime's session-level permission mode.
        let name: String
    }
}

// MARK: - Demo data

extension ConnectorDetailData {
    /// Google Drive, transcribed from `02-detail-gd-upper.png` /
    /// `03-detail-gd-lower.png`.
    static let googleDrive = ConnectorDetailData(
        name: String(localized: "Google Drive"),
        logo: .image("connector-logo-googledrive"),
        monogramLetter: "G",
        isVerified: true,
        content: .directory(ConnectorDetailContent.Directory(
            oneLiner: String(localized: "Search, read, and upload files instantly"),
            description: String(localized: "Connect Google Drive to Claude to search through your documents, read file contents, upload new files, and analyze your data. Claude can find specific documents even when you don't remember the exact name, read and analyze the content of Google Docs, Sheets, Slides, and PDFs, and upload files directly to your Drive. Useful for finding project notes, extracting data from spreadsheets, preparing meeting materials, or organizing files scattered across your Drive."),
            author: "Google",
            authorURL: URL(string: "https://drive.google.com"),
            category: String(localized: "Productivity"),
            signIn: String(localized: "Required"),
            connectorURL: "https://drivemcp.googleapis.com/mcp/v1",
            added: String(localized: "March 2026"),
            // The capture only shows the link labels; targets are placeholders.
            documentationURL: URL(string: "https://developers.google.com/workspace/drive/mcp"),
            supportURL: URL(string: "https://support.google.com/drive"),
            privacyPolicyURL: URL(string: "https://policies.google.com/privacy"),
            toolCount: 11
        ))
    )

    /// The custom “my phone” connector, transcribed from
    /// `07-detail-my-phone-custom.png`.
    static let myPhone = ConnectorDetailData(
        name: String(localized: "my phone"),
        logo: .image("connector-logo-myphone"),
        monogramLetter: "M",
        isVerified: false,
        content: .custom(ConnectorDetailContent.Custom(
            warning: String(localized: "This connector isn't verified by Anthropic"),
            connectorURL: "https://relay.pipicore.cn",
            tools: [
                ConnectorDetailContent.Tool(id: "Do", name: "Do"),
                ConnectorDetailContent.Tool(id: "Look", name: "Look"),
                ConnectorDetailContent.Tool(id: "Skills", name: "Skills"),
                ConnectorDetailContent.Tool(id: "Status", name: "Status"),
            ]
        ))
    )
}
