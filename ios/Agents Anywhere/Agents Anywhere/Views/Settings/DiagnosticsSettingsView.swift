import SwiftUI

/// The diagnostics package surface (pp 2026-10-11): a live on/off switch for the
/// latency tracer plus a one-tap export of the recorded JSONL.
///
/// The switch is a persistent `UserDefaults` toggle, so it works on the shipped
/// (Release) IPA where `#if DEBUG` and environment variables are unavailable:
/// turn it on, reproduce, then export.
struct DiagnosticsSettingsView: View {
    @AppStorage(LatencyDiagnostics.enabledKey) private var enabled = false
    @State private var count = LatencyDiagnostics.shared.count
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Label(String(localized: "启用延迟诊断"), appSymbol: "waveform.path.ecg")
                }
            } footer: {
                Text(String(localized: "开启后记录本机时间线（发送、停止、回复的分秒耗时）。只写本地文件，不含消息内容。"))
            }

            if let url = exportURL, count > 0 || FileManager.default.fileExists(atPath: url.path) {
                Section {
                    LabeledContent(String(localized: "已记录事件"), value: "\(count)")
                    Text(verbatim: url.lastPathComponent)
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: url) {
                        Label(String(localized: "导出诊断包"), appSymbol: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        LatencyDiagnostics.shared.clear()
                        refresh()
                    } label: {
                        Label(String(localized: "清空记录"), appSymbol: "trash")
                    }
                }
            }
        }
        .settingsPage(String(localized: "诊断"))
        .onAppear(perform: refresh)
        .onChange(of: enabled) { _, _ in refresh() }
    }

    private func refresh() {
        count = LatencyDiagnostics.shared.count
        exportURL = LatencyDiagnostics.shared.exportURL
    }
}
