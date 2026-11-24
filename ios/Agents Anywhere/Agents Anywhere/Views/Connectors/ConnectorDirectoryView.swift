import SwiftUI

/// Connector directory, reproduced from the official capture: one card of
/// connector rows, a floating search field, and a sort menu in the toolbar.
struct ConnectorDirectoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var sort: ConnectorDirectorySort = .defaultValue
    @State private var selectedEntry: ConnectorDirectoryEntry?

    private var entries: [ConnectorDirectoryEntry] {
        let base = ConnectorDirectoryData.entries
        let filtered = searchText.isEmpty
            ? base
            : base.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.subtitle.localizedCaseInsensitiveContains(searchText)
            }
        switch sort {
        case .defaultValue: return filtered
        case .alphabetical: return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .popular, .trending, .new: return filtered
        }
    }

    var body: some View {
        // Official directory card starts at 155 pt from the screen top, i.e.
        // 26 pt below the navigation bar (settings uses 16).
        SettingsScreen(title: String(localized: "Connectors"), topPadding: 26) {
            SettingsSection {
                let rows = entries
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        SettingsRowDivider(leading: ConnectorStyle.logoDividerLeading,
                                           trailing: ConnectorStyle.logoDividerTrailing)
                    }
                    Button {
                        selectedEntry = entry
                    } label: {
                        ConnectorCardRow(logo: entry.logo,
                                         title: entry.name,
                                         tag: entry.tag,
                                         showsVerified: true,
                                         subtitle: entry.subtitle,
                                         // Official one-line row 69 pt,
                                         // two-line 85 pt.
                                         rowMinHeight: 69)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationDestination(item: $selectedEntry) { entry in
            ConnectorDetailView(data: detailData(for: entry))
        }
        .safeAreaInset(edge: .bottom) {
            searchField
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
            TextField(String(localized: "Search"), text: $searchText)
                .font(ConnectorStyle.text(16))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: ConnectorStyle.searchHeight)
        // Floating search field is liquid glass in the official capture.
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, SettingsStyle.inset)
        .padding(.bottom, 8)
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort by"), selection: $sort) {
                ForEach(ConnectorDirectorySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: ConnectorStyle.circleGlyphSize(for: "arrow.up.arrow.down"),
                              weight: .regular))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
        }
        .accessibilityLabel(Text(String(localized: "Sort and filter connectors")))
    }
}

enum ConnectorDirectorySort: String, CaseIterable, Identifiable {
    case defaultValue, popular, trending, new, alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultValue: String(localized: "Default")
        case .popular: String(localized: "Popular")
        case .trending: String(localized: "Trending")
        case .new: String(localized: "New")
        case .alphabetical: String(localized: "Alphabetical")
        }
    }
}

struct ConnectorDirectoryEntry: Identifiable, Hashable {
    let id: String
    let name: String
    var logo: ConnectorLogoView.Source
    var tag: String?
    let subtitle: String
}

extension ConnectorDirectoryView {
    /// Google Drive ships the full transcribed capture; other rows fall back
    /// to a minimal directory entry so every row still opens a detail screen.
    fileprivate func detailData(for entry: ConnectorDirectoryEntry) -> ConnectorDetailData {
        if entry.id == "google-drive" { return ConnectorDetailData.googleDrive }
        if entry.id == "gmail" { return ConnectorDetailData.gmail }
        return ConnectorDetailData(
            name: entry.name,
            logo: entry.logo,
            monogramLetter: String(entry.name.prefix(1)),
            isVerified: true,
            content: .directory(ConnectorDetailContent.Directory(
                oneLiner: entry.subtitle,
                description: entry.subtitle,
                author: "",
                authorURL: nil,
                category: "",
                signIn: "",
                connectorURL: "",
                added: "",
                documentationURL: nil,
                supportURL: nil,
                privacyPolicyURL: nil,
                toolCount: 0
            ))
        )
    }
}

/// Capture-sampled directory rows (the official order and copy from the
/// 2026-11-24 screenshot). Replaced by the directory query when it lands.
nonisolated enum ConnectorDirectoryData {
    static let entries: [ConnectorDirectoryEntry] = [
        ConnectorDirectoryEntry(id: "google-drive", name: "Google Drive",
                                logo: .image("connector-logo-googledrive"),
                                subtitle: "Search, read, and upload files instantly"),
        ConnectorDirectoryEntry(id: "gmail", name: "Gmail",
                                logo: .image("connector-logo-gmail"),
                                subtitle: "Draft replies, summarize threads, & search your inbox"),
        ConnectorDirectoryEntry(id: "google-sheets", name: "Google Sheets",
                                logo: .image("connector-logo-googlesheets"),
                                subtitle: "Read, analyze, and update your spreadsheets"),
        ConnectorDirectoryEntry(id: "google-calendar", name: "Google Calendar",
                                logo: .image("connector-logo-googlecalendar"),
                                subtitle: "Manage your schedule and coordinate meetings effortlessly"),
        ConnectorDirectoryEntry(id: "microsoft-365", name: "Microsoft 365",
                                logo: .image("connector-logo-microsoft365"),
                                subtitle: "Access SharePoint, OneDrive, Outlook, and Teams directly in Claude"),
        ConnectorDirectoryEntry(id: "canva", name: "Canva",
                                logo: .image("connector-logo-canva"),
                                tag: String(localized: "Interactive"),
                                subtitle: "Search, create, autofill, and export Canva designs"),
        ConnectorDirectoryEntry(id: "google-docs", name: "Google Docs",
                                logo: .image("connector-logo-googledocs"),
                                subtitle: "Edit, comment on, and summarize your documents"),
        ConnectorDirectoryEntry(id: "notion", name: "Notion",
                                logo: .letter("N"),
                                tag: String(localized: "Interactive"),
                                subtitle: "Connect your Notion workspace to search, update, and power workflows across tools"),
        ConnectorDirectoryEntry(id: "slack", name: "Slack",
                                logo: .letter("S"),
                                subtitle: "Send messages, create canvases, and fetch Slack data"),
    ]
}
