import SwiftUI
import UIKit

/// A quiet status dot for the settings row: green when the retained window has
/// no diagnostic entries, orange when it has any. It deliberately shows no
/// count or summary text.
struct DiagnosticsStatusDot: View {
    @State private var hasEntries = false

    var body: some View {
        Circle()
            .fill(hasEntries ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
            .task { hasEntries = ClientDiagnosticsLog.shared.hasRecentEntries() }
    }
}

/// Opt-in daily client diagnostics: a toggle, the retained days, preview and
/// export. Follows the existing Settings list style; it does not reuse the
/// developer diagnostics panel.
struct DiagnosticsLogSettingsView: View {
    @AppStorage(ClientDiagnosticsLog.enabledKey) private var enabled = false
    @State private var days: [DiagnosticsDay] = []
    @State private var shareItems: [Any] = []
    @State private var showsShare = false
    @State private var confirmsClear = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Label(String(localized: "Record diagnostics"),
                          appSymbol: "doc.text.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
                .tint(.green)
            } footer: {
                Text(String(localized: "Diagnostics stay on this device, never include message content, and are kept for 7 days."))
            }

            Section(String(localized: "Last 7 days")) {
                if days.isEmpty {
                    Text(String(localized: "No diagnostics yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(days) { day in
                        NavigationLink {
                            DiagnosticsDayView(day: day)
                        } label: {
                            HStack {
                                Text(DiagnosticsFormat.day(day.date))
                                Spacer()
                                Circle()
                                    .fill(day.hasEntries ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    if let url = ClientDiagnosticsLog.shared.exportFile() {
                        shareItems = [url]
                        showsShare = true
                    }
                } label: {
                    Label(String(localized: "Export diagnostics"),
                          appSymbol: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(days.isEmpty)

                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label(String(localized: "Clear diagnostics"),
                          appSymbol: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(days.isEmpty)
            }
        }
        .settingsPage(String(localized: "Diagnostics log"))
        .task { reload() }
        .onChange(of: enabled) { _, isOn in
            if isOn { ClientDiagnosticsLog.shared.markEnabled() }
            reload()
        }
        .confirmationDialog(
            String(localized: "Clear diagnostics?"),
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear diagnostics"), role: .destructive) {
                ClientDiagnosticsLog.shared.clear()
                reload()
            }
        }
        .sheet(isPresented: $showsShare) {
            DiagnosticsShareSheet(items: shareItems)
        }
    }

    private func reload() {
        days = ClientDiagnosticsLog.shared.days()
    }
}

struct DiagnosticsDayView: View {
    let day: DiagnosticsDay
    @State private var entries: [DiagnosticsEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text(String(localized: "No entries"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(DiagnosticsFormat.time(entry.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.kind)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let session = entry.sessionID, !session.isEmpty {
                            Text(session)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(DiagnosticsFormat.detail(entry.detail))
                            .font(.caption.monospaced())
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .settingsPage(DiagnosticsFormat.day(day.date))
        .task { entries = ClientDiagnosticsLog.shared.entries(for: day) }
    }
}

private enum DiagnosticsFormat {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func detail(_ detail: [String: String]) -> String {
        detail.keys.sorted()
            .map { "\($0)=\(detail[$0] ?? "")" }
            .joined(separator: "  ")
    }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items, applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ controller: UIActivityViewController, context: Context
    ) {}
}
