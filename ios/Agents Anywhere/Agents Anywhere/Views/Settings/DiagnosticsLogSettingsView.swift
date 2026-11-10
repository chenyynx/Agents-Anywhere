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

            Section {
                if days.isEmpty {
                    Text(String(localized: "No diagnostics yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(days) { day in
                        NavigationLink {
                            DiagnosticsDayView(day: day)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(DiagnosticsFormat.day(day.date))
                                    Text("\(day.fileURL.lastPathComponent) · \(DiagnosticsFormat.bytes(day.size))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle()
                                    .fill(day.hasEntries ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "Last 7 days"))
            } footer: {
                Text(String(localized: "Each day is one JSONL file. Open it to view the raw text, copy or share it."))
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
    @State private var text = ""
    @State private var copied = false
    @State private var showsShare = false

    var body: some View {
        List {
            Section {
                if text.isEmpty {
                    Text(String(localized: "No entries"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text(day.fileURL.lastPathComponent)
                    .font(.caption.monospaced())
            } footer: {
                Text("\(DiagnosticsFormat.day(day.date)) · \(DiagnosticsFormat.bytes(day.size))")
            }

            Section {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Copied")
                                 : String(localized: "Copy log"),
                          appSymbol: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(text.isEmpty)

                Button {
                    showsShare = true
                } label: {
                    Label(String(localized: "Share log file"),
                          appSymbol: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(text.isEmpty)
            }
        }
        .settingsPage(DiagnosticsFormat.day(day.date))
        .task { text = ClientDiagnosticsLog.shared.rawText(for: day) }
        .sheet(isPresented: $showsShare) {
            DiagnosticsShareSheet(items: [day.fileURL])
        }
    }
}

private enum DiagnosticsFormat {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
