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

/// Opt-in daily client diagnostics: a toggle and the retained daily files.
/// Each row is a file; tapping it opens the raw log exactly as stored, with
/// copy and share in the navigation bar. It does not reuse the developer
/// diagnostics panel.
struct DiagnosticsLogSettingsView: View {
    @AppStorage(ClientDiagnosticsLog.enabledKey) private var enabled = false
    @State private var days: [DiagnosticsDay] = []
    @State private var didLoad = false
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
                if !didLoad {
                    // A spinner, not "No diagnostics yet": the directory read
                    // is fast but still finishes after the first frame, and the
                    // false empty state read as a flash of missing files.
                    ProgressView()
                } else if days.isEmpty {
                    Text(String(localized: "No diagnostics yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(days) { day in
                        NavigationLink {
                            DiagnosticsDayView(day: day)
                        } label: {
                            HStack(spacing: 10) {
                                if day.hasEntries {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Text(day.fileURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(DiagnosticsFormat.bytes(day.size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for day in offsets.map({ days[$0] }) {
                            ClientDiagnosticsLog.shared.delete(day)
                        }
                        reload()
                    }
                }
            } header: {
                Text(String(localized: "Log files"))
            }

            Section {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let url = ClientDiagnosticsLog.shared.exportFile() {
                        shareItems = [url]
                        showsShare = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(days.isEmpty)
                .accessibilityLabel(String(localized: "Export diagnostics"))
            }
        }
        .task {
            reload()
            didLoad = true
        }
        .onChange(of: enabled) { _, isOn in
            if isOn {
                ClientDiagnosticsLog.shared.markEnabled()
                ClientDiagnosticsLog.shared.record(
                    kind: "diagnostics.enabled", dedupe: false)
            } else {
                ClientDiagnosticsLog.shared.record(
                    kind: "diagnostics.disabled", dedupe: false, force: true)
            }
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

/// One daily file opened like an attachment: the raw text fills the page and
/// the navigation bar carries copy and share. No actions live at the bottom.
///
/// A day may hold up to 5 MB, so the file is read off the main thread and
/// rendered by TextKit 2, which lays out only what is on screen. Reading it
/// in `init` and handing the whole string to a SwiftUI `Text` made the push
/// wait for every glyph and land on a white page (device 2026-11-11); the
/// OpenMinis reader this follows does the same lazy-layout trick.
struct DiagnosticsDayView: View {
    let day: DiagnosticsDay
    @State private var text: String?
    @State private var copied = false

    var body: some View {
        Group {
            if let text {
                if text.isEmpty {
                    Text(String(localized: "No entries"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding()
                } else {
                    DiagnosticsLogTextView(text: text)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .settingsPage(day.fileURL.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(text?.isEmpty != false)
                .accessibilityLabel(String(localized: "Copy log"))

                ShareLink(item: day.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(String(localized: "Share log file"))
            }
        }
        .task {
            let day = self.day
            let loaded = await Task.detached(priority: .userInitiated) {
                ClientDiagnosticsLog.shared.rawText(for: day)
            }.value
            text = loaded
        }
    }
}

/// TextKit 2 backs the log page: it lays out the visible portion only, so a
/// multi-megabyte day opens at once and scrolls without a first-frame stall.
private struct DiagnosticsLogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.dataDetectorTypes = []
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

private enum DiagnosticsFormat {
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
