import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// On-device scroll diagnostics for the SwiftUI timeline.
///
/// Everything here is a plain main-actor store: no SwiftUI observation, no
/// timers, no I/O. The first probe build auto-started a CADisplayLink and
/// published per-frame values through an `@Observable`; SwiftUI then rebuilt
/// the overlay — report() included — on every frame, which froze the session
/// view on device. This version does nothing at all until the floating 探针
/// button opens an explicit measurement window, and every hook below is one
/// boolean check while that window is closed.
///
/// What the report answers:
///
/// 1. **How bad was scrolling?** Frame intervals are sampled by the app target
///    and framed into hitches (a frame later than 1.5x the nominal period),
///    split into scrolling and idle stretches.
/// 2. **Who costs what?** The timeline's two non-render costs are counted and
///    timed: `TimelineGrouping` (rebuilt inside the content body) and
///    `SessionTimelinePresentation.flush` (the row-model update pass). A body
///    count that climbs while the finger is down points at state churn, not at
///    row count.
/// 3. **Does the window matter?** The report records the row and group count
///    of the last body evaluation, so two sessions compare directly.
@MainActor
public final class TimelineProbe {
    public static let shared = TimelineProbe()

    struct FrameSample {
        let at: CFTimeInterval
        let interval: Double
        let scrolling: Bool
    }

    /// True only inside an explicit measurement window. All hooks except
    /// `recordSession` return immediately when this is false.
    public private(set) var isEnabled = false
    public private(set) var sessionID: String = "—"
    /// Nominal refresh period, supplied when the window opens. Defaults to
    /// 60 Hz so a report taken before the screen value is known stays sane.
    public private(set) var nominalInterval: Double = 1.0 / 60.0

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

    // MARK: - Measurement window

    /// Opens a fresh window. Called only by the probe overlay, on a user tap.
    public func startSampling(fps: Int) {
        nominalInterval = 1.0 / Double(max(1, fps))
        resetCounters()
        isEnabled = true
    }

    /// Closes the window. Collected data stays available to `report()`.
    public func stopSampling() {
        isEnabled = false
        scrolling = false
    }

    // MARK: - Hooks

    /// Cheap even outside a window: one string compare against the current id.
    func recordSession(_ id: String) {
        if sessionID != id { sessionID = id }
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
        // A 30 s window at 120 Hz is 3600 samples; trim only past 4000 so the
        // per-frame path stays two appends and no scanning.
        if frames.count > 4000 {
            let cutoff = timestamp - 30
            frames.removeAll { $0.at < cutoff }
        }
    }

    // MARK: - Report

    public func report() -> String {
        let scrollFrames = frames.filter(\.scrolling).map(\.interval)
        let idleFrames = frames.filter { !$0.scrolling }.map(\.interval)

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
        状态: \(isEnabled ? "测量中" : "已停止")

        [帧间隔]
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
        scrolling = false
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
