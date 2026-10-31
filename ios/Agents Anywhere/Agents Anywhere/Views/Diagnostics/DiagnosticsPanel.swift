#if AA_TIMELINE_PROBE
import SwiftUI
import UIKit

/// What the owning session page knows and the probe store cannot derive.
/// Probe builds only; the shipping app never compiles this file.
struct DiagnosticsContext {
    var sessionID: String?
    var sessionTitle: String?
    var runtimeStatus: String?
    var pendingCount: Int?
    var hasOlder: Bool?
    var hasNewer: Bool?
    var historyPaging: Bool?

    static let none = DiagnosticsContext()
}

/// The developer diagnostics panel: findings first, raw probe report second.
/// Reachable from the session menu and Settings in probe builds.
@MainActor
struct DiagnosticsPanel: View {
    var context: DiagnosticsContext = .none

    @ObservedObject private var store = TimelineProbeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: DiagnosticsTab = .timeline
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var markMessage: String?

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("诊断分区", selection: $tab) {
                    ForEach(DiagnosticsTab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
                tabContent
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空采样") {
                        store.reset()
                        markMessage = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") { store.copyReport() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .sheet(isPresented: $showingShare) {
                ActivityView(items: shareURLs)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("b\(buildNumber)", color: .accentColor)
                if let id = context.sessionID {
                    chip(String(id.prefix(18)), color: .secondary)
                }
                if let title = context.sessionTitle, !title.isEmpty {
                    chip(title, color: .secondary)
                }
                if let runtime = context.runtimeStatus {
                    chip(runtime, color: .green)
                }
                if let pending = context.pendingCount, pending > 0 {
                    chip("pending \(pending)", color: .orange)
                }
                if context.historyPaging == true {
                    chip("history", color: .blue)
                } else if context.hasNewer == true {
                    chip("newer", color: .blue)
                } else if context.hasOlder == true {
                    chip("older", color: .blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .timeline: timelineTab
        case .performance: performanceTab
        case .events: eventsTab
        case .anchors: anchorsTab
        }
    }

    private var timelineTab: some View {
        let findings = store.findings()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if findings.isEmpty {
                    labelCard("暂无自动发现",
                              detail: "复现后点下方『打点 + 截图』，完整报告在下方。",
                              color: .secondary)
                } else {
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                        findingCard(finding)
                    }
                }
                DisclosureGroup {
                    Text(store.report())
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("完整报告")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(12)
                .background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
        }
    }

    private var performanceTab: some View {
        let stats = store.performanceStats()
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    metric("帧样本", "\(stats.samples)")
                    metric("hitch", "\(stats.hitches)",
                           color: stats.hitches > 0 ? .orange : .green)
                    metric("最大帧", "\(stats.maxGapMs)ms",
                           color: stats.maxGapMs > 33 ? .red : .green)
                }
                FrameSparkline(gaps: store.frameGaps())
                    .frame(height: 90)
                    .padding(12)
                    .background(.thinMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("栏高 = 帧间隔；黄 >20ms，橙 >33ms，红 >50ms")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    metric("apply p95", "\(stats.applyP95Ms)ms")
                    metric("apply max", "\(stats.applyMaxMs)ms",
                           color: stats.applyMaxMs > 100 ? .orange : .green)
                    metric("measure max", "\(stats.measureMaxMs)ms",
                           color: stats.measureMaxMs > 16 ? .orange : .green)
                }
                Text("慢帧 \(stats.slowFrames) · apply \(stats.applyCount) 次 · measure \(stats.measureCount) 次")
                    .font(.caption2).foregroundStyle(.secondary)

                if store.markers.isEmpty {
                    labelCard("还没有打点",
                              detail: "复现时点下方『打点 + 截图』。",
                              color: .secondary)
                } else {
                    ForEach(Array(store.markers.enumerated()), id: \.offset) { index, mark in
                        markCard(index: index, mark: mark)
                    }
                }
            }
            .padding(16)
        }
    }

    private var eventsTab: some View {
        let events = store.recentEventLines()
        return List {
            Section("会话") {
                row("build", "b\(buildNumber)")
                row("session", context.sessionID ?? "-")
                row("title", context.sessionTitle ?? "-")
                row("runtime", context.runtimeStatus ?? "-")
                row("pending", context.pendingCount.map { String($0) } ?? "-")
                row("older", context.hasOlder == true ? "yes" : "no")
                row("newer", context.hasNewer == true ? "yes" : "no")
                row("history paging", context.historyPaging == true ? "yes" : "no")
            }
            Section("最近分页事件") {
                if events.isEmpty {
                    Text("无").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var anchorsTab: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(AnchorDeviceProbe.shared.report)
                .font(.system(size: 9.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    // MARK: - Cards

    private func findingCard(_ finding: TimelineProbeStore.Finding) -> some View {
        let color = findingColor(finding.severity)
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.kind)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(finding.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.25))
        }
    }

    private func labelCard(_ title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(_ title: String, _ value: String,
                        color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func markCard(index: Int, mark: TimelineProbeStore.Mark) -> some View {
        HStack(spacing: 10) {
            if let image = mark.screenshot {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("打点 \(index + 1)")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.dateString(mark.at))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !mark.note.isEmpty {
                    Text(mark.note).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func findingColor(_ severity: Int) -> Color {
        if severity >= 2 { return .red }
        if severity == 1 { return .orange }
        return .secondary
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let markMessage {
                Text(markMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    takeMark()
                } label: {
                    Label("打点 + 截图", systemImage: "camera.aperture")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    export()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.thinMaterial,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func takeMark() {
        let mark = store.mark()
        markMessage = mark.screenshot == nil
            ? "已打点（截图不可用）"
            : "已打点 · \(Self.dateString(mark.at))"
    }

    private func export() {
        shareURLs = store.writeExportFiles()
        showingShare = !shareURLs.isEmpty
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}

private enum DiagnosticsTab: String, CaseIterable, Identifiable {
    case timeline, performance, events, anchors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "时间线"
        case .performance: return "性能"
        case .events: return "事件"
        case .anchors: return "锚点"
        }
    }
}

/// Frame-interval sparkline. `Canvas` keeps the bar layout out of the
/// view-update path; a 120-bar row is cheap even while the panel is open.
private struct FrameSparkline: View {
    let gaps: [Double]

    var body: some View {
        Canvas { context, size in
            let values = Array(gaps.suffix(120))
            guard !values.isEmpty, size.width > 0 else { return }
            let maximum = max(values.max() ?? 16, 1)
            let barWidth = size.width / CGFloat(values.count)
            for (index, gap) in values.enumerated() {
                let height = max(2, size.height * CGFloat(gap / maximum))
                let rect = CGRect(x: CGFloat(index) * barWidth,
                                  y: size.height - height,
                                  width: max(1, barWidth - 1),
                                  height: height)
                context.fill(Path(rect), with: .color(color(for: gap)))
            }
        }
    }

    private func color(for gap: Double) -> Color {
        if gap > 50 { return .red }
        if gap > 33 { return .orange }
        if gap > 20 { return .yellow }
        return .green
    }
}

/// Minimal share sheet for the exported report and screenshots.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
#endif
