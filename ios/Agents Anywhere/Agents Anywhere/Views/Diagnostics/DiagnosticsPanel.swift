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

// MARK: - Claude-style tokens

/// The diagnostics surface deliberately does not reuse the app's own visual
/// language: warm paper, serif display type, one terracotta accent, hairline
/// rules. Probe builds only.
private enum ClaudeUI {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let paper = adaptive(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x262624)
    static let ivory = adaptive(light: 0xF0EEE6, dark: 0x2E2C29)
    static let ink = adaptive(light: 0x1F1E1D, dark: 0xF5F4EF)
    static let muted = adaptive(light: 0x6F6C64, dark: 0xA9A69E)
    static let hairline = adaptive(light: 0xE8E4D8, dark: 0x3A3936)
    static let accent = adaptive(light: 0xD97757, dark: 0xE38B6C)
    static let success = adaptive(light: 0x5F7E5A, dark: 0x8FA97F)
    static let warning = adaptive(light: 0xB7791F, dark: 0xD8A24A)
    static let danger = adaptive(light: 0xB5482F, dark: 0xE07A5F)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Floating HUD

/// The live diagnostics window: a draggable translucent card over the chat.
/// Tapping the card opens the full deck; the camera button marks without
/// leaving the conversation.
@MainActor
struct DiagnosticsHUD: View {
    var context: DiagnosticsContext
    @Binding var isVisible: Bool

    @ObservedObject private var store = TimelineProbeStore.shared
    @State private var expanded = false
    @State private var marked = false
    @GestureState private var drag: CGSize = .zero
    @AppStorage("AA.DiagnosticsHUD.x") private var storedX = 0.0
    @AppStorage("AA.DiagnosticsHUD.y") private var storedY = 0.0

    private static let cardWidth: CGFloat = 250
    private static let cardHeight: CGFloat = 64

    var body: some View {
        Group {
            if isVisible {
                GeometryReader { proxy in
                    let x = clamp(proxy.size.width - Self.cardWidth / 2 - 12
                                  + storedX + drag.width,
                                  Self.cardWidth / 2 + 8,
                                  proxy.size.width - Self.cardWidth / 2 - 8)
                    let y = clamp(88 + Self.cardHeight / 2 + storedY + drag.height,
                                  Self.cardHeight / 2 + 8,
                                  proxy.size.height - Self.cardHeight / 2 - 8)
                    compact
                        .frame(width: Self.cardWidth, height: Self.cardHeight)
                        .position(x: x, y: y)
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    storedX = clamp(storedX + value.translation.width,
                                                    -proxy.size.width, proxy.size.width)
                                    storedY = clamp(storedY + value.translation.height,
                                                    -proxy.size.height, proxy.size.height)
                                }
                        )
                }
                .ignoresSafeArea(.keyboard)
                .transition(.opacity)
            }
        }
        .overlay {
            if isVisible && expanded {
                ZStack {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .onTapGesture { expanded = false }
                    DiagnosticsDeck(context: context,
                                    onClose: { expanded = false },
                                    onHide: {
                                        expanded = false
                                        isVisible = false
                                    })
                    .padding(14)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
    }

    private var compact: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let metrics = LiveMetrics(store: store)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(severityColor(topSeverity))
                            .frame(width: 5, height: 5)
                        Text("诊断")
                            .font(ClaudeUI.serif(12, .semibold))
                            .foregroundStyle(ClaudeUI.ink)
                    }
                    Text("b\(buildNumber)")
                        .font(ClaudeUI.mono(9))
                        .foregroundStyle(ClaudeUI.muted)
                }
                Rectangle()
                    .fill(ClaudeUI.hairline)
                    .frame(width: 0.5, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(metrics.fps)")
                        .font(ClaudeUI.serif(21, .semibold).monospacedDigit())
                        .foregroundStyle(ClaudeUI.ink)
                    Text("fps")
                        .font(ClaudeUI.sans(8))
                        .foregroundStyle(ClaudeUI.muted)
                }
                ClaudeSparkline(values: Array(metrics.gaps.suffix(30)))
                    .frame(width: 44, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    miniMetric("卡顿", "\(metrics.hitches)", color: metrics.hitches > 0 ? ClaudeUI.warning : ClaudeUI.muted)
                    miniMetric("重排", "\(metrics.applyMax)ms", color: metrics.applyMax > 100 ? ClaudeUI.danger : ClaudeUI.muted)
                }
                Spacer(minLength: 0)
                Button {
                    _ = store.mark()
                    marked = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        marked = false
                    }
                } label: {
                    Image(systemName: marked ? "checkmark" : "camera.aperture")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(ClaudeUI.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ClaudeUI.surface.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { expanded = true }
        }
    }

    private func miniMetric(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).font(ClaudeUI.sans(8)).foregroundStyle(ClaudeUI.muted)
            Text(value).font(ClaudeUI.mono(9, .medium)).foregroundStyle(color)
        }
    }

    private var topSeverity: Int {
        store.findings().map(\.severity).max() ?? 0
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

// MARK: - Expanded deck

@MainActor
private struct DiagnosticsDeck: View {
    var context: DiagnosticsContext
    var onClose: (() -> Void)?
    var onHide: (() -> Void)?

    @ObservedObject private var store = TimelineProbeStore.shared
    @State private var shareURLs: [URL] = []
    @State private var showingShare = false
    @State private var showingRaw = false
    @State private var logSource: LogSource = .timeline
    @State private var markMessage: String?

    private enum LogSource: String, CaseIterable, Identifiable {
        case timeline = "时间线报告"
        case anchors = "锚点日志"
        var id: String { rawValue }
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ClaudeUI.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LiveMetricsView(store: store, context: context)
                    findingsBlock
                    marksBlock
                    rawBlock
                }
                .padding(18)
            }
            Divider().overlay(ClaudeUI.hairline)
            actionBar
        }
        .frame(maxWidth: 560, maxHeight: 680)
        .background(ClaudeUI.paper,
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .sheet(isPresented: $showingShare) { ActivityView(items: shareURLs) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("诊断")
                    .font(ClaudeUI.serif(26, .semibold))
                    .foregroundStyle(ClaudeUI.ink)
                HStack(spacing: 6) {
                    pill("b\(buildNumber)", tint: ClaudeUI.accent)
                    if let id = context.sessionID {
                        pill(String(id.prefix(14)), tint: ClaudeUI.muted)
                    }
                    if let runtime = context.runtimeStatus {
                        pill(runtime, tint: ClaudeUI.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ClaudeUI.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ClaudeUI.ivory))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(ClaudeUI.mono(10, .medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ClaudeUI.ivory, in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: Findings

    private var findingsBlock: some View {
        let findings = store.findings()
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("发现", subtitle: findings.isEmpty
                         ? "规则自动聚合，暂无异常"
                         : "\(findings.count) 条，按严重度排序")
            if findings.isEmpty {
                hint("复现后点『打点 + 截图』，这里会出现自动归类的线索。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
                        findingRow(finding)
                        if index < findings.count - 1 {
                            Rectangle().fill(ClaudeUI.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 18)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(ClaudeUI.surface,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
                }
            }
        }
    }

    private func findingRow(_ finding: TimelineProbeStore.Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(severityColor(finding.severity))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(findingTitle(finding.kind))
                    .font(ClaudeUI.sans(14, .semibold))
                    .foregroundStyle(ClaudeUI.ink)
                Text(finding.detail)
                    .font(ClaudeUI.sans(12))
                    .foregroundStyle(ClaudeUI.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func findingTitle(_ kind: String) -> String {
        switch kind {
        case "footer_churn": return "页脚抖动"
        case "footer_transfer": return "页脚迁移"
        case "offset_jump": return "视口跳动"
        case "apply_spike": return "整页重排耗时"
        case "measure_spike": return "行高测量耗时"
        case "frame_hitch": return "滚动掉帧"
        case "blank_frame": return "空白帧"
        default: return kind
        }
    }

    // MARK: Marks

    private var marksBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("现场", subtitle: "打点会截取当前时间线并写进报告")
            if store.markers.isEmpty {
                hint("还没有打点。复现时点下方『打点 + 截图』。")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(store.markers.enumerated()), id: \.offset) { index, mark in
                            VStack(alignment: .leading, spacing: 5) {
                                markThumbnail(mark, index: index)
                                Text("打点 \(index + 1)")
                                    .font(ClaudeUI.sans(10, .medium))
                                    .foregroundStyle(ClaudeUI.muted)
                                Text(Self.timeString(mark.at))
                                    .font(ClaudeUI.mono(9))
                                    .foregroundStyle(ClaudeUI.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A mistaken capture must be removable; export only writes what remains.
    private func markThumbnail(_ mark: TimelineProbeStore.Mark, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = mark.screenshot {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ClaudeUI.ivory)
                    .frame(width: 62, height: 112)
            }
            Button {
                store.removeMark(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("删除这张打点")
        }
    }

    // MARK: Raw log

    private var rawBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("原始日志", subtitle: "给工程侧逐行定位用")
            HStack(spacing: 6) {
                ForEach(LogSource.allCases) { source in
                    Button {
                        logSource = source
                        showingRaw = true
                    } label: {
                        Text(source.rawValue)
                            .font(ClaudeUI.sans(11, .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(logSource == source ? ClaudeUI.ivory : Color.clear,
                                        in: Capsule())
                            .foregroundStyle(logSource == source ? ClaudeUI.ink : ClaudeUI.muted)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button {
                    showingRaw.toggle()
                } label: {
                    Image(systemName: showingRaw ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClaudeUI.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ClaudeUI.ivory))
                }
                .buttonStyle(.plain)
            }
            if showingRaw {
                ScrollView([.vertical, .horizontal]) {
                    Text(logSource == .timeline
                         ? store.report()
                         : AnchorDeviceProbe.shared.report)
                        .font(ClaudeUI.mono(9))
                        .foregroundStyle(ClaudeUI.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .background(ClaudeUI.surface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
                }
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let markMessage {
                Text(markMessage)
                    .font(ClaudeUI.sans(10))
                    .foregroundStyle(ClaudeUI.muted)
            }
            HStack(spacing: 10) {
                Button {
                    let mark = store.mark()
                    markMessage = mark.screenshot == nil
                        ? "已打点（截图不可用）"
                        : "已打点 · \(Self.timeString(mark.at))"
                } label: {
                    Label("打点 + 截图", systemImage: "camera.aperture")
                        .font(ClaudeUI.sans(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(ClaudeUI.accent,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    shareURLs = store.writeExportFiles()
                    showingShare = !shareURLs.isEmpty
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(ClaudeUI.sans(14, .semibold))
                        .frame(maxWidth: 130)
                        .padding(.vertical, 13)
                        .background(ClaudeUI.ivory,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(ClaudeUI.ink)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("复制报告", systemImage: "doc.on.doc") { store.copyReport() }
                    Button("清空采样", systemImage: "eraser") {
                        store.reset()
                        markMessage = nil
                    }
                    Button("清空打点", systemImage: "trash") {
                        store.clearMarks()
                        markMessage = nil
                    }
                    if let onHide {
                        Button("隐藏浮窗", systemImage: "eye.slash") { onHide() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClaudeUI.muted)
                        .frame(width: 46, height: 46)
                        .background(ClaudeUI.ivory,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(ClaudeUI.paper)
    }

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ClaudeUI.serif(16, .semibold))
                .foregroundStyle(ClaudeUI.ink)
            if let subtitle {
                Text(subtitle)
                    .font(ClaudeUI.sans(11))
                    .foregroundStyle(ClaudeUI.muted)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(ClaudeUI.sans(12))
            .foregroundStyle(ClaudeUI.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ClaudeUI.ivory,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
}

// MARK: - Live metrics

@MainActor
private struct LiveMetrics {
    let fps: Int
    let maxGap: Int
    let hitches: Int
    let applyMax: Int
    let applyP95: Int
    let measureMax: Int
    let measureCount: Int
    let samples: Int
    let gaps: [Double]

    init(store: TimelineProbeStore) {
        let gaps = store.frameGaps()
        self.gaps = gaps
        let recent = Array(gaps.suffix(30))
        let average = recent.isEmpty ? 16.7 : recent.reduce(0, +) / Double(recent.count)
        fps = average > 0 ? min(120, Int((1000 / average).rounded())) : 0
        maxGap = Int((gaps.max() ?? 0).rounded())
        let stats = store.performanceStats()
        hitches = stats.hitches
        applyMax = stats.applyMaxMs
        applyP95 = stats.applyP95Ms
        measureMax = stats.measureMaxMs
        measureCount = stats.measureCount
        samples = stats.samples
    }
}

@MainActor
private struct LiveMetricsView: View {
    let store: TimelineProbeStore
    let context: DiagnosticsContext

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let metrics = LiveMetrics(store: store)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    tile("流畅度", "\(metrics.fps)", unit: "fps",
                         detail: "最大帧 \(metrics.maxGap)ms",
                         color: metrics.fps >= 55 ? ClaudeUI.success
                             : metrics.fps >= 40 ? ClaudeUI.warning : ClaudeUI.danger)
                    tile("卡顿", "\(metrics.hitches)", unit: "次",
                         detail: ">33ms",
                         color: metrics.hitches > 0 ? ClaudeUI.warning : ClaudeUI.success)
                }
                HStack(spacing: 10) {
                    tile("整页重排", "\(metrics.applyMax)", unit: "ms",
                         detail: "p95 \(metrics.applyP95)ms",
                         color: metrics.applyMax > 100 ? ClaudeUI.danger : ClaudeUI.success)
                    tile("行高测量", "\(metrics.measureMax)", unit: "ms",
                         detail: "\(metrics.measureCount) 次",
                         color: metrics.measureMax > 16 ? ClaudeUI.warning : ClaudeUI.success)
                }
                if let drawer = store.drawerSummary() {
                    HStack(spacing: 10) {
                        tile("抽屉时长", "\(drawer.durationMs)", unit: "ms",
                             detail: "最近一次", color: ClaudeUI.muted)
                        tile("抽屉卡顿", "\(drawer.hitches)", unit: "次",
                             detail: "最大 \(drawer.maxGapMs)ms",
                             color: drawer.hitches > 0 ? ClaudeUI.warning : ClaudeUI.success)
                    }
                } else {
                    Text("抽屉滑动：还没有记录，开合侧栏会自动记一次")
                        .font(ClaudeUI.sans(10))
                        .foregroundStyle(ClaudeUI.muted)
                }
                ClaudeSparkline(values: metrics.gaps)
                    .frame(height: 52)
                    .padding(.horizontal, 2)
                statusRow
            }
        }
    }

    private func tile(_ title: String, _ value: String, unit: String,
                      detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(ClaudeUI.sans(11))
                .foregroundStyle(ClaudeUI.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(ClaudeUI.serif(24, .semibold).monospacedDigit())
                    .foregroundStyle(ClaudeUI.ink)
                Text(unit)
                    .font(ClaudeUI.sans(10, .medium))
                    .foregroundStyle(ClaudeUI.muted)
            }
            Text(detail)
                .font(ClaudeUI.mono(9))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ClaudeUI.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ClaudeUI.hairline, lineWidth: 0.5)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusDot((context.pendingCount ?? 0) > 0 ? ClaudeUI.warning : ClaudeUI.muted,
                      "pending \(context.pendingCount ?? 0)")
            statusDot(context.historyPaging == true ? ClaudeUI.warning : ClaudeUI.muted,
                      context.historyPaging == true ? "history" : "latest")
            statusDot(context.hasNewer == true ? ClaudeUI.warning : ClaudeUI.muted,
                      context.hasNewer == true ? "newer" : "no newer")
        }
    }

    private func statusDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(ClaudeUI.mono(9))
                .foregroundStyle(ClaudeUI.muted)
        }
    }
}

private struct ClaudeSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, size.width > 1, size.height > 1 else { return }
            let maximum = max(values.max() ?? 16, 40)
            var line = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let clamped = min(value, maximum)
                let y = size.height - size.height * CGFloat(clamped / maximum)
                if index == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [ClaudeUI.accent.opacity(0.18), ClaudeUI.accent.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(ClaudeUI.accent),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Settings entry

/// Full-screen presentation for Settings. The session page uses the HUD.
@MainActor
struct DiagnosticsPanel: View {
    var context: DiagnosticsContext = .none
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ClaudeUI.paper.ignoresSafeArea()
            DiagnosticsDeck(context: context, onClose: { dismiss() }, onHide: nil)
                .padding(16)
        }
    }
}

// MARK: - Helpers

private func severityColor(_ severity: Int) -> Color {
    if severity >= 2 { return ClaudeUI.danger }
    if severity == 1 { return ClaudeUI.warning }
    return ClaudeUI.muted
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
