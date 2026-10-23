import Foundation
import Observation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// On-device scroll diagnostics for the SwiftUI timeline.
///
/// The store is inert until a probe build flips `isEnabled`; every hook then
/// costs one boolean check, so the shipping app pays nothing measurable. The
/// overlay and the display link live in the app target
/// (`Views/Chat/TimelineProbe.swift`) and only compile under
/// `-DAA_TIMELINE_PROBE`; this half sits in ClientCore because the timeline
/// model counts its own work here.
///
/// It answers the questions a simulator cannot:
///
/// 1. **How bad is scrolling?** Frame intervals are sampled and framed into
///    hitches (a frame later than 1.5x the nominal period), split into
///    scrolling and idle stretches.
/// 2. **Who costs what per frame?** The timeline's two non-render costs are
///    counted and timed: `TimelineGrouping` (rebuilt inside the content body)
///    and `SessionTimelinePresentation.flush` (the row-model update pass). A
///    body count that climbs while the finger is down points at state churn,
///    not at row count.
/// 3. **Does the window matter?** The report records the row and group count
///    of the last body evaluation, so two sessions compare directly.
@MainActor @Observable
public final class TimelineProbe {
    public static let shared = TimelineProbe()

    struct FrameSample {
        let at: CFTimeInterval
        let interval: Double
        let scrolling: Bool
    }

    public var isEnabled = false
    /// Nominal refresh period, set by the overlay from the screen's maximum
    /// frame rate. Defaults to 60 Hz.
    public var nominalInterval: Double = 1.0 / 60.0
    public private(set) var liveFPS: Double = 0
    private(set) var sessionID: String = "—"

    private var frames: [FrameSample] = []
    private var groupingCalls = 0
    private var groupingRows = 0
    private var groupingTotal = 0.0
    private var groupingWorst = 0.0
    private var flushCalls = 0
    private var flushRows = 0
    private var flushTotal = 0.0
    private var flushWorst = 0.0
    private var bodyEvals = 0
    private var lastBodyRows = 0
    private var lastGroupCount = 0
    private var scrolling = false

    private init() {}

    // MARK: - Hooks

    func recordSession(_ id: String) {
        guard isEnabled else { return }
        if sessionID != id {
            sessionID = id
            resetCounters()
        }
    }

    func recordScrolling(_ value: Bool) {
        guard isEnabled else { return }
        scrolling = value
    }

    func recordBody(rows: Int) {
        guard isEnabled else { return }
        bodyEvals += 1
        lastBodyRows = rows
    }

    func measureGrouping(rows: Int, _ body: () -> [ChatTimelineGroup]) -> [ChatTimelineGroup] {
        let start = CACurrentMediaTime()
        let groups = body()
        let elapsed = (CACurrentMediaTime() - start) * 1000
        groupingCalls += 1
        groupingRows += rows
        groupingTotal += elapsed
        groupingWorst = max(groupingWorst, elapsed)
        lastGroupCount = groups.count
        return groups
    }

    func measureFlush(rows: Int, _ body: () -> Void) {
        let start = CACurrentMediaTime()
        body()
        let elapsed = (CACurrentMediaTime() - start) * 1000
        flushCalls += 1
        flushRows += rows
        flushTotal += elapsed
        flushWorst = max(flushWorst, elapsed)
    }

    public func recordFrame(interval: Double, at timestamp: CFTimeInterval) {
        guard isEnabled else { return }
        frames.append(FrameSample(at: timestamp, interval: interval, scrolling: scrolling))
        let cutoff = timestamp - 30
        if frames.first?.at ?? timestamp < cutoff {
            frames.removeAll { $0.at < cutoff }
        }
        let recent = frames.suffix(30)
        if let first = recent.first, let last = recent.last, last.at > first.at {
            liveFPS = Double(recent.count - 1) / (last.at - first.at)
        }
    }

    // MARK: - Report

    public func report() -> String {
        let now = CACurrentMediaTime()
        let window = frames.filter { $0.at >= now - 15 }
        let scrollFrames = window.filter(\.scrolling).map(\.interval)
        let idleFrames = window.filter { !$0.scrolling }.map(\.interval)

        func stats(_ intervals: [Double]) -> String {
            guard !intervals.isEmpty else { return "0 帧" }
            let hitch = intervals.filter { $0 > nominalInterval * 1.5 }.count
            let worst = intervals.max()! * 1000
            let avg = intervals.reduce(0, +) / Double(intervals.count) * 1000
            return "\(intervals.count) 帧 · 抖动 \(hitch) · 平均 \(String(format: "%.1f", avg))ms · 最差 \(String(format: "%.1f", worst))ms"
        }

        let groupingAvg = groupingCalls > 0 ? groupingTotal / Double(groupingCalls) : 0
        let flushAvg = flushCalls > 0 ? flushTotal / Double(flushCalls) : 0

        return """
        === AA 时间线探针 ===
        构建: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        会话: \(sessionID)
        窗口: 行 \(lastBodyRows) · 分组 \(lastGroupCount)

        [最近 15 秒帧间隔]
        滚动: \(stats(scrollFrames))
        静止: \(stats(idleFrames))

        [分组 TimelineGrouping]
        次数 \(groupingCalls) · 平均 \(String(format: "%.2f", groupingAvg))ms · 最差 \(String(format: "%.2f", groupingWorst))ms · 行合计 \(groupingRows)

        [呈现 flush]
        次数 \(flushCalls) · 平均 \(String(format: "%.2f", flushAvg))ms · 最差 \(String(format: "%.2f", flushWorst))ms · 行合计 \(flushRows)

        [内容 body 重算]
        \(bodyEvals) 次（窗口变化或状态失效才会重算）
        """
    }

    public func reset() { resetCounters() }

    private func resetCounters() {
        frames.removeAll()
        groupingCalls = 0; groupingRows = 0; groupingTotal = 0; groupingWorst = 0
        flushCalls = 0; flushRows = 0; flushTotal = 0; flushWorst = 0
        bodyEvals = 0; lastBodyRows = 0; lastGroupCount = 0
    }
}

/// Static façade so call sites read the same whether the probe is on or off.
/// The disabled path is one branch around the original closure.
extension TimelineProbe {
    @inline(__always) static func session(_ id: String) { shared.recordSession(id) }
    @inline(__always) static func setScrolling(_ value: Bool) { shared.recordScrolling(value) }
    @inline(__always) static func bodyEvaluated(rows: Int) { shared.recordBody(rows: rows) }
    @inline(__always) static func grouping(rows: Int, _ body: () -> [ChatTimelineGroup]) -> [ChatTimelineGroup] {
        shared.isEnabled ? shared.measureGrouping(rows: rows, body) : body()
    }
    @inline(__always) static func flush(rows: Int, _ body: () -> Void) {
        shared.isEnabled ? shared.measureFlush(rows: rows, body) : body()
    }
}
