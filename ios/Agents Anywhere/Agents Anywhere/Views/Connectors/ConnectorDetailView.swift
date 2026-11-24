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
                    // Official logo slot top 160.15 pt with the bar at 139.4.
                    .padding(.top, 20.75)
                    .padding(.bottom, 4)
                descriptionCard(content.description)
                    .padding(.top, 26.5)
                detailsSection(content)
                    // Card bottom 408.7 → header box top 435.05.
                    .padding(.top, 26.35)
                toolsCard(toolCount: content.toolCount)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) {
            ConnectorPrimaryButton(title: String(localized: "Connect"), action: onConnect)
                .padding(.trailing, 24)
                // Official capsule 302.7..369 × 779.3..818.3: 24 pt from the
                // trailing edge and flush with the bottom safe area
                // (852 − 818.3 = 33.7 ≈ the 34 pt inset).
                .padding(.bottom, 0)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
                    .accessibilityLabel(Text(String(localized: "Back")))
            }
            // One glass circle per key: hide the bar's shared background.
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationDestination(isPresented: $showsTools) {
            ConnectorToolListView(
                title: String(localized: "Tools"),
                toolNames: ConnectorToolListData.googleDriveTools)
        }
    }

    private func directoryHeader(oneLiner: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            // Official header logo ink 21.7 pt wide inside the 28 pt slot
            // (the settings rows draw 22.3 in a 24 pt slot).
            ConnectorLogoView(source: data.logo, size: ConnectorStyle.logoSize,
                              imageInset: 0.104)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(data.name)
                        .font(ConnectorStyle.text(16, weight: .semibold))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if data.isVerified { ConnectorVerifiedBadge() }
                }
                // Official one-liner ink 10.7 pt tall / 272.7 pt wide = 11 pt.
                Text(oneLiner)
                    .font(ConnectorStyle.text(11))
                    .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Official name ink sits 3 pt below the logo tile's top edge.
            .padding(.top, 2)
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
        SettingsSection(String(localized: "Details"),
                        headerFont: ConnectorStyle.text(13),
                        headerSpacing: 10.35) {
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
                                minHeight: 66)
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
                    // Official tools row: 15 pt label (ink 28.3×13), 13 pt
                    // count (corpus 03-detail-gd-lower).
                    Text(String(localized: "Tools"))
                        .font(ConnectorStyle.text(15))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    Spacer(minLength: 8)
                    Text(verbatim: "\(toolCount)")
                        .font(ConnectorStyle.text(13))
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
                // Official banner top edge 145.0 (content origin 139.4).
                ConnectorWarningBanner(text: content.warning)
                    .padding(.top, 5.6)
                card {
                    connectorURLRow(label: String(localized: "Connector URL"),
                                    url: content.connectorURL,
                                    minHeight: 67)
                }
                card {
                    // Display only: AA delegates tool permissions to each
                    // runtime, so the official “Always allow” value and the
                    // permission picker are intentionally not reproduced.
                    SettingsRowContainer(minHeight: 50, verticalPadding: 12) {
                        HStack(spacing: 10) {
                            Text(String(localized: "All tools"))
                                .font(ConnectorStyle.text(15))
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
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                // No glass pill behind the two-line title (official capture).
                VStack(spacing: 0) {
                    Text(data.name)
                        .font(ConnectorStyle.text(22, weight: .semibold))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    Text(String(localized: "Custom"))
                        .font(ConnectorStyle.text(13))
                        .foregroundStyle(ConnectorDetailStyle.tertiary(colorScheme))
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                ConnectorCircleButton(symbol: "arrow.clockwise") { onRefresh() }
                    .accessibilityLabel(Text(String(localized: "Refresh")))
            }
            .sharedBackgroundVisibility(.hidden)
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
                SettingsRowContainer(minHeight: 53, verticalPadding: 14.5) {
                    HStack(spacing: 9) {
                        ConnectorLogoView(source: .letter(data.monogramLetter), size: 24)
                        Text(tool.name)
                            .font(ConnectorStyle.text(15))
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
                            .font(ConnectorStyle.text(15))
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

    /// One value row of the Details card: 15 pt label, 13 pt grey value
    /// (official: 类别 ink 27.7×13.3, 通讯 24.7×11.3, 2026年3月 60×11.7).
    private func textRow(label: String, value: String) -> some View {
        SettingsRowContainer(minHeight: 48, verticalPadding: 12) {
            HStack(spacing: 8) {
                Text(label)
                    .font(ConnectorStyle.text(15))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Spacer(minLength: 8)
                Text(value)
                    .font(ConnectorStyle.text(13))
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
            SettingsRowContainer(minHeight: 53, verticalPadding: 12) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(ConnectorStyle.text(15))
                        .foregroundStyle(ConnectorDetailStyle.link(colorScheme))
                    Spacer(minLength: 8)
                    if let value {
                        Text(value)
                            .font(ConnectorStyle.text(13))
                            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                            .lineLimit(1)
                    }
                    // Official glyph ink 17.7×17.7 in link blue.
                    ConnectorSymbol(name: "anthropicon.arrowOutSquare", size: 18)
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
                // Official label ink 630.7 and address ink 653: 22.3 pt pitch.
                VStack(alignment: .leading, spacing: 5) {
                    Text(label)
                        .font(ConnectorStyle.text(15))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    // Official address ink 207.3×11.3 pt = 11.5 pt.
                    Text(url)
                        .font(ConnectorStyle.text(11.5))
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
    /// Gmail, transcribed from the 2026-11-24 official capture (1179×2556):
    /// 作者 Google / 类别 通讯 / 登录 需要 / 添加时间 2026年3月, connector URL
    /// `gmailmcp.googleapis.com`, seven-line description, 30 tools.
    static let gmail = ConnectorDetailData(
        name: "Gmail",
        logo: .image("connector-logo-gmail"),
        monogramLetter: "G",
        isVerified: true,
        content: .directory(ConnectorDetailContent.Directory(
            oneLiner: "Draft replies, summarize threads, & search your inbox",
            // Server-provided prose stays English in the Chinese UI, exactly
            // as in the official capture.
            description: "Connect Gmail to Claude to quickly find important emails and understand long conversations. Claude can search through your messages, read entire email threads to give you context, and help you stay on top of your inbox. Perfect for finding that message you remember sending, catching up on email chains you missed, or preparing for meetings.",
            author: "Google",
            authorURL: URL(string: "https://workspace.google.com/products/gmail/"),
            category: String(localized: "Communication"),
            signIn: String(localized: "Required"),
            connectorURL: "https://gmailmcp.googleapis.com/mcp/v1",
            added: String(localized: "March 2026"),
            // The capture only shows the labels; targets are placeholders.
            documentationURL: URL(string: "https://developers.google.com/workspace/gmail"),
            supportURL: URL(string: "https://support.google.com/mail"),
            privacyPolicyURL: URL(string: "https://policies.google.com/privacy"),
            toolCount: 30
        ))
    )

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
        logo: .letter("M"),
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
