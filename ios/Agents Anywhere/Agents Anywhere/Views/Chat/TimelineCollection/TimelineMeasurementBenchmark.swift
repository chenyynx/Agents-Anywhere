import Foundation

/// Measures the offscreen hosting pass against real rows.
///
/// v7 deliberately leaves the pre-apply budget unset until this gate runs:
/// a number written from intuition (50ms/8ms) would either stall the opening
/// or push measurements into pending without evidence. C3's simulator
/// autorun prints these statistics, then the budget is pinned in the
/// controller.
@MainActor
enum TimelineMeasurementBenchmark {
    struct Statistics: Equatable {
        let count: Int
        let p50: Double
        let p95: Double
        let maximum: Double
    }

    static func run(measurer: TimelineHeightMeasuring, itemIDs: [String],
                    width: CGFloat, repeats: Int = 1) -> Statistics {
        guard !itemIDs.isEmpty else { return Statistics(count: 0, p50: 0, p95: 0, maximum: 0) }
        var samples: [Double] = []
        samples.reserveCapacity(itemIDs.count * max(1, repeats))
        for _ in 0..<max(1, repeats) {
            for itemID in itemIDs {
                let start = ProcessInfo.processInfo.systemUptime
                _ = measurer.measure(itemID: itemID, width: width)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        samples.sort()
        return Statistics(count: samples.count,
            p50: percentile(samples, 0.5),
            p95: percentile(samples, 0.95),
            maximum: samples.last ?? 0)
    }

    /// Nearest-rank percentile over an ascending sample.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
