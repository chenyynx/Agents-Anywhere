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
    @Environment(\.colorScheme) private var colorScheme
    @State private var days: [DiagnosticsDay] = []
    @State private var didLoad = false
    @State private var shareItems: [Any] = []
    @State private var showsShare = false
    @State private var confirmsClear = false

    var body: some View {
        SettingsScreen(title: String(localized: "Diagnostics log")) {
            SettingsSection(footer: String(localized: "Diagnostics stay on this device, never include message content, and are kept for 7 days.")) {
                SettingsToggleRow(icon: "doc.text.magnifyingglass",
                                  title: String(localized: "Record diagnostics"),
                                  isOn: $enabled)
            }

            SettingsSection(String(localized: "Log files")) {
                if !didLoad {
                    // A spinner, not "No diagnostics yet": the directory read
                    // is fast but still finishes after the first frame, and the
                    // false empty state read as a flash of missing files.
                    SettingsRowContainer {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } else if days.isEmpty {
                    SettingsRowContainer {
                        Text(String(localized: "No diagnostics yet"))
                            .font(SettingsStyle.text(16))
                            .foregroundStyle(SettingsStyle.secondary(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        if index > 0 {
                            SettingsRowDivider()
                        }
                        dayRow(day)
                    }
                }
            }

            SettingsSection {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    HStack(spacing: SettingsStyle.iconGap) {
                        AppSymbol("trash", size: 18)
                            .frame(width: SettingsStyle.iconFrame)
                        Text(String(localized: "Clear diagnostics"))
                            .font(SettingsStyle.text(16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, SettingsStyle.rowPadding)
                    .padding(.vertical, 12)
                    .frame(minHeight: SettingsStyle.rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(days.isEmpty)
            }
        }
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

    private func dayRow(_ day: DiagnosticsDay) -> some View {
        NavigationLink {
            DiagnosticsDayView(day: day)
        } label: {
            HStack(spacing: SettingsStyle.iconGap) {
                AppSymbol("doc.text", size: 18)
                    .frame(width: SettingsStyle.iconFrame)
                    .foregroundStyle(SettingsStyle.icon(colorScheme))
                Text(day.fileURL.lastPathComponent)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if day.hasEntries {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(DiagnosticsFormat.bytes(day.size))
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme).opacity(0.8))
            }
            .padding(.horizontal, SettingsStyle.rowPadding)
            .padding(.vertical, 12)
            .frame(minHeight: SettingsStyle.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                ClientDiagnosticsLog.shared.delete(day)
                reload()
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let text {
                if text.isEmpty {
                    Text(String(localized: "No entries"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
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
        .background(SettingsStyle.background(colorScheme).ignoresSafeArea())
        .navigationTitle(day.fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
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
