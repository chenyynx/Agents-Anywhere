#if AA_TIMELINE_PROBE
import Darwin
import Foundation
import QuartzCore
import os

/// Main-thread stack sampler for the on-device scroll investigation.
///
/// Every timing probe we shipped until 2026-11-06 could only say where the
/// 30–80 ms stall was *not*: the run-loop source phase owned the time, and
/// none of the instrumented callbacks (didScroll, cellProvider, prepare,
/// elements, settle, frameSync, pendingMeasure, layoutSubviews, either cell's
/// body) was running. Timing cannot name unknown code; only a stack can.
///
/// This sampler suspends the main thread every 2 ms while the reader scrolls,
/// reads its register state, and walks the frame-pointer chain (the same
/// mechanism `sample(1)` uses). The sampling thread never allocates, locks or
/// logs inside the suspend window, so it cannot deadlock against the thread it
/// stopped.
///
/// The captured stacks feed `TimelineProbeStore.report()`:
/// `--- MAIN THREAD STACKS ---` lists the most frequent stacks and names the
/// stack that owned each recorded >33 ms hitch.
nonisolated final class MainThreadStackSampler: @unchecked Sendable {
    static let shared = MainThreadStackSampler()

    // MARK: - Tuning

    /// One sample every 2 ms: a 30–80 ms stall yields 15–40 samples, a 20 ms
    /// hitch still yields 10.
    private static let intervalMicroseconds: useconds_t = 2_000
    /// Stop sampling this long after the last scroll tick. Fingers lifting at
    /// a deceleration end still produce ticks, so 0.25 s is safe.
    private static let pauseAfter: TimeInterval = 0.25
    /// A session ends this long after the last scroll: the report is exported
    /// while it is finished, and a fresh scroll starts a fresh session.
    private static let finishAfter: TimeInterval = 3
    /// Hard caps. 32k samples × 2 ms ≈ 65 s of scrolling; the frame buffer is
    /// 6 MB and is allocated once.
    private static let maxSamples = 32_768
    private static let maxFrames = 786_432
    private static let maxDepth = 64
    private static let maxWindowSeconds: TimeInterval = 120
    private static let maxActiveSeconds: TimeInterval = 60

    private static let reportedStacks = 15
    private static let reportedFrames = 18

    // MARK: - Shared state (guarded by `lock`)

    private enum Phase {
        static let idle = 0
        static let recording = 1
        static let stopping = 2
        static let finished = 3
        static let clearing = 4
    }

    /// Heap-allocated lock, not a Swift stored property. Passing a class
    /// property as `inout` (`os_unfair_lock_lock(&lock)`) makes Swift emit an
    /// exclusivity check on that property; the sampler thread and the main
    /// thread taking the same lock at once then trap in `swift_beginAccess`
    /// ("Simultaneous accesses"). This crashed b1009 at launch. A pointer has
    /// no exclusivity tracking.
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>
    private var phase = Phase.idle
    private var windowStart: TimeInterval = 0
    private var finishedAt: TimeInterval = 0
    private var lastActiveAt: TimeInterval = 0
    private var sampleCount = 0
    private var frameCount = 0
    private var bufferFull = false

    // MARK: - Fixed buffers

    private let frames: UnsafeMutablePointer<UInt64>
    private let sampleStarts: UnsafeMutablePointer<UInt32>
    private let sampleTimes: UnsafeMutablePointer<Double>
    private let sampleDepths: UnsafeMutablePointer<UInt16>
    private let stateMemory: UnsafeMutableRawPointer

    private let mainThread: mach_port_t
    private var worker: Thread?

    /// `arm_thread_state64_t.__pc/__fp/__lr/__sp` word offsets. The struct is
    /// 29 x-registers followed by fp, lr, sp, pc, cpsr+pad.
    private static let armThreadState64: thread_state_flavor_t = 6
    private static let stateWordCount = 34
    /// arm64e pointers carry a PAC in the high bits; user-space addresses fit
    /// in 47 bits. Masking before every dladdr/vm_read keeps both safe.
    private static let pointerMask: UInt64 = 0x0000_7FFF_FFFF_FFFF

    private init() {
        frames = .allocate(capacity: Self.maxFrames)
        sampleStarts = .allocate(capacity: Self.maxSamples)
        sampleTimes = .allocate(capacity: Self.maxSamples)
        sampleDepths = .allocate(capacity: Self.maxSamples)
        stateMemory = .allocate(byteCount: Self.stateWordCount * 8, alignment: 8)
        _ = stateMemory.bindMemory(to: natural_t.self,
                                   capacity: Self.stateWordCount * 2)
        let lockMemory = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockMemory.initialize(to: os_unfair_lock())
        lockPointer = lockMemory

        // The singleton is only touched from the main actor (`TimelineProbeStore`
        // and the self-test), so `pthread_self()` here is the main thread.
        // `pthread_main_thread_np` is macOS-only and does not exist in the iOS
        // SDK; this avoids it entirely.
        mainThread = pthread_mach_thread_np(pthread_self())
    }

    /// Start the sampling thread on the first scroll, not at app launch: the
    /// launch path already touches `clear()` from the main thread, and keeping
    /// the worker off the startup path removes that interaction entirely.
    private func startWorkerLocked() {
        guard worker == nil else { return }
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "AA-MainThreadStackSampler"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        thread.start()
        worker = thread
    }

    // MARK: - Public API (main thread)

    /// Called from the probe's display-link tick. `true` while the reader is
    /// dragging or coasting; the sampler starts on the first `true` after a
    /// finished session and keeps sampling while ticks keep arriving.
    func noteActivity(scrolling: Bool) {
        guard scrolling else { return }
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(lockPointer)
        switch phase {
        case Phase.idle:
            resetLocked()
            startWorkerLocked()
            windowStart = now
            lastActiveAt = now
            phase = Phase.recording
        case Phase.finished:
            // A new scroll after the idle window started a new session: the
            // report always describes the scroll the reader just performed.
            resetLocked()
            startWorkerLocked()
            windowStart = now
            lastActiveAt = now
            phase = Phase.recording
        case Phase.recording:
            lastActiveAt = now
        default:
            break
        }
        os_unfair_lock_unlock(lockPointer)
    }

    /// Ask the current session to close. The sampling thread performs the
    /// transition, so the buffers are never read while it is still writing.
    func endSession() {
        os_unfair_lock_lock(lockPointer)
        if phase == Phase.recording { phase = Phase.stopping }
        os_unfair_lock_unlock(lockPointer)
    }

    /// Drop every sample. Safe during a session: the sampling thread zeroes
    /// the buffers once it reaches a safe point.
    func clear() {
        os_unfair_lock_lock(lockPointer)
        if phase == Phase.recording || phase == Phase.stopping {
            phase = Phase.clearing
        } else {
            resetLocked()
            phase = Phase.idle
        }
        os_unfair_lock_unlock(lockPointer)
    }

    /// Report lines for `TimelineProbeStore.report()`. Closes an open session
    /// first (the reader already stopped scrolling); returns immediately if
    /// the sampling thread has not finished within the short wait.
    func reportLines(hitches: [(at: TimeInterval, ms: Int)]) -> [String] {
        if needsFinish() {
            endSession()
            waitForFinish(timeout: 0.2)
        }
        guard let aggregate = aggregateFinished() else {
            return ["MT none (scroll, wait 3s, then export)"]
        }
        var lines: [String] = []
        lines.append("--- MAIN THREAD STACKS (2ms during scroll) ---")
        lines.append("MT window=\(Self.f(aggregate.windowSeconds))s "
            + "active=\(Self.f(aggregate.activeSeconds))s "
            + "samples=\(aggregate.sampleCount) frames=\(aggregate.frameCount) "
            + "full=\(aggregate.full ? 1 : 0)")
        var symbolCache: [UInt64: String] = [:]
        for (index, stack) in aggregate.stacks.enumerated() {
            let share = Double(stack.count) / Double(max(aggregate.sampleCount, 1)) * 100
            let runMs = Double(stack.maxRun) * Double(Self.intervalMicroseconds) / 1000
            lines.append("MT #\(index + 1) \(Self.f(share))% \(stack.count)/\(aggregate.sampleCount) "
                + "maxRun=\(Self.f(runMs))ms")
            for pc in stack.pcs.prefix(Self.reportedFrames) {
                lines.append("  \(symbolize(pc, cache: &symbolCache))")
            }
        }
        lines.append(contentsOf: hitchLines(aggregate, hitches: hitches,
                                            cache: &symbolCache))
        return lines
    }

    /// Simulator self-test payload: proves the Mach path captured and
    /// symbolicated a known main-thread function.
    func selfTestResult() -> [String: Any] {
        guard let aggregate = aggregateFinished() else {
            return ["completed": true, "samples": 0, "frames": 0,
                    "containsSelfTest": false, "error": "no finished session"]
        }
        var cache: [UInt64: String] = [:]
        var topSymbols: [String] = []
        var containsSelfTest = false
        for stack in aggregate.stacks {
            for pc in stack.pcs.prefix(12) {
                let symbol = symbolize(pc, cache: &cache)
                if topSymbols.count < 40 { topSymbols.append(symbol) }
                if symbol.lowercased().contains("stacksamplerselftest") {
                    containsSelfTest = true
                }
            }
        }
        return [
            "completed": true,
            "samples": aggregate.sampleCount,
            "frames": aggregate.frameCount,
            "full": aggregate.full,
            "windowSeconds": aggregate.windowSeconds,
            "containsSelfTest": containsSelfTest,
            "top": topSymbols,
        ]
    }

    // MARK: - Sampling thread

    private func runLoop() {
        while true {
            os_unfair_lock_lock(lockPointer)
            let current = phase
            let lastActive = lastActiveAt
            let start = windowStart
            os_unfair_lock_unlock(lockPointer)

            switch current {
            case Phase.clearing:
                os_unfair_lock_lock(lockPointer)
                resetLocked()
                phase = Phase.idle
                os_unfair_lock_unlock(lockPointer)
                usleep(5_000)
            case Phase.stopping:
                os_unfair_lock_lock(lockPointer)
                finishedAt = CACurrentMediaTime()
                phase = Phase.finished
                os_unfair_lock_unlock(lockPointer)
            case Phase.recording:
                let now = CACurrentMediaTime()
                if now - start >= Self.maxWindowSeconds
                    || Double(sampleCount) * Double(Self.intervalMicroseconds) / 1_000_000
                        >= Self.maxActiveSeconds
                    || sampleCount >= Self.maxSamples
                    || frameCount + Self.maxDepth >= Self.maxFrames {
                    bufferFull = sampleCount >= Self.maxSamples
                        || frameCount + Self.maxDepth >= Self.maxFrames
                    os_unfair_lock_lock(lockPointer)
                    finishedAt = now
                    phase = Phase.finished
                    os_unfair_lock_unlock(lockPointer)
                    continue
                }
                if now - lastActive > Self.finishAfter {
                    os_unfair_lock_lock(lockPointer)
                    finishedAt = now
                    phase = Phase.finished
                    os_unfair_lock_unlock(lockPointer)
                    continue
                }
                if now - lastActive > Self.pauseAfter {
                    usleep(4_000)
                    continue
                }
                sampleOnce(now)
                usleep(Self.intervalMicroseconds)
            default:
                // Idle tick: short enough that the first frames of a new
                // scroll are sampled, cheap enough to leave running.
                usleep(5_000)
            }
        }
    }

    /// Suspend → read registers → walk the frame chain → resume. Everything
    /// between suspend and resume is mach traps and bounds-checked reads:
    /// no allocation, no locks, no Swift runtime calls that could need the
    /// stopped thread.
    private func sampleOnce(_ now: TimeInterval) {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var depth = 0
        var count = mach_msg_type_number_t(Self.stateWordCount * 2)
        let kr = thread_get_state(mainThread, Self.armThreadState64,
                                  stateMemory.assumingMemoryBound(to: natural_t.self),
                                  &count)
        if kr == KERN_SUCCESS {
            let pc = stateMemory.load(fromByteOffset: 32 * 8, as: UInt64.self)
                & Self.pointerMask
            let fp = stateMemory.load(fromByteOffset: 29 * 8, as: UInt64.self)
                & Self.pointerMask
            let lr = stateMemory.load(fromByteOffset: 30 * 8, as: UInt64.self)
                & Self.pointerMask
            let base = frameCount
            if pc != 0 {
                frames[base] = pc
                depth = 1
            }
            var cursor = fp
            var walked = 0
            while depth < Self.maxDepth, cursor != 0, walked < Self.maxDepth + 8 {
                // No stack-bounds check: iOS does not export
                // `pthread_get_stackaddr_np`, and `vm_read_overwrite` already
                // fails safely on an address that is not mapped.
                guard cursor % 8 == 0 else { break }
                var next: UInt64 = 0
                var ret: UInt64 = 0
                guard Self.readStackWords(at: cursor, nextFrame: &next, returnAddress: &ret)
                else { break }
                next &= Self.pointerMask
                ret &= Self.pointerMask
                if ret == 0 { break }
                frames[base + depth] = ret
                depth += 1
                cursor = next
                walked += 1
            }
            // A function that does not maintain a frame pointer still leaves
            // pc + lr; keep both rather than dropping the sample.
            if depth <= 1, lr != 0, lr != pc {
                frames[base + depth] = lr
                depth += 1
            }
        }
        thread_resume(mainThread)

        guard depth > 0 else { return }
        sampleStarts[sampleCount] = UInt32(frameCount)
        sampleTimes[sampleCount] = now
        sampleDepths[sampleCount] = UInt16(depth)
        sampleCount += 1
        frameCount += depth
    }

    private static func readStackWords(at address: UInt64,
                                       nextFrame: inout UInt64,
                                       returnAddress: inout UInt64) -> Bool {
        var pair = (UInt64(0), UInt64(0))
        let ok = withUnsafeMutableBytes(of: &pair) { buffer -> Bool in
            var size = vm_size_t(16)
            let kr = vm_read_overwrite(
                mach_task_self_,
                vm_address_t(truncatingIfNeeded: address),
                16,
                vm_address_t(UInt(bitPattern: buffer.baseAddress)),
                &size)
            return kr == KERN_SUCCESS && size == 16
        }
        nextFrame = pair.0
        returnAddress = pair.1
        return ok
    }

    // MARK: - Aggregation (main thread, only after `finished`)

    private struct Stack {
        let hash: UInt64
        let count: Int
        let maxRun: Int
        let pcs: [UInt64]
    }

    private struct Aggregate {
        let sampleCount: Int
        let frameCount: Int
        let full: Bool
        let windowSeconds: Double
        let activeSeconds: Double
        let stacks: [Stack]
        let sampleHashes: [UInt64]
        let sampleTimes: [Double]
    }

    private func needsFinish() -> Bool {
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        return phase == Phase.recording || phase == Phase.stopping
    }

    private func waitForFinish(timeout: TimeInterval) {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            os_unfair_lock_lock(lockPointer)
            let current = phase
            os_unfair_lock_unlock(lockPointer)
            if current == Phase.finished { return }
            if current == Phase.recording { endSession() }
            // The sampling thread may suspend this (main) thread briefly; it
            // resumes immediately and never takes this lock while it does.
            usleep(5_000)
        }
    }

    /// Close a live session for the self-test, then wait for the buffers to be
    /// safe to read.
    func finishForSelfTest(timeout: TimeInterval = 2) {
        endSession()
        waitForFinish(timeout: timeout)
    }

    private func aggregateFinished() -> Aggregate? {
        os_unfair_lock_lock(lockPointer)
        let current = phase
        let samples = sampleCount
        let framesUsed = frameCount
        let full = bufferFull
        let start = windowStart
        let end = finishedAt
        os_unfair_lock_unlock(lockPointer)
        guard current == Phase.finished, samples > 0 else { return nil }

        var hashes = [UInt64](repeating: 0, count: samples)
        var times = [Double](repeating: 0, count: samples)
        var counts: [UInt64: Int] = [:]
        var representative: [UInt64: Int] = [:]
        var maxRun: [UInt64: Int] = [:]
        var previous: UInt64 = 0
        var run = 0

        for index in 0..<samples {
            let start = Int(sampleStarts[index])
            let depth = Int(sampleDepths[index])
            times[index] = sampleTimes[index]
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for offset in 0..<depth {
                hash = (hash ^ frames[start + offset]) &* 0x0000_0100_0000_01b3
            }
            hashes[index] = hash
            counts[hash, default: 0] += 1
            if representative[hash] == nil { representative[hash] = index }
            if index > 0, hash == previous {
                run += 1
            } else {
                if index > 0 { maxRun[previous] = max(maxRun[previous] ?? 0, run) }
                run = 1
                previous = hash
            }
        }
        if samples > 0 { maxRun[previous] = max(maxRun[previous] ?? 0, run) }

        let stacks = counts.sorted { $0.value > $1.value }
            .prefix(Self.reportedStacks)
            .compactMap { pair -> Stack? in
                let hash = pair.key
                guard let index = representative[hash] else { return nil }
                let start = Int(sampleStarts[index])
                let depth = Int(sampleDepths[index])
                var pcs = [UInt64](repeating: 0, count: depth)
                for offset in 0..<depth { pcs[offset] = frames[start + offset] }
                return Stack(hash: hash, count: pair.value,
                             maxRun: maxRun[hash] ?? 0, pcs: pcs)
            }

        return Aggregate(
            sampleCount: samples,
            frameCount: framesUsed,
            full: full,
            windowSeconds: max(end - start, 0),
            activeSeconds: Double(samples) * Double(Self.intervalMicroseconds) / 1_000_000,
            stacks: stacks,
            sampleHashes: hashes,
            sampleTimes: times)
    }

    /// Name the stack that owned each of the three worst hitches the probe
    /// recorded. This is the line that turns a 46 ms gap into a function.
    private func hitchLines(_ aggregate: Aggregate,
                            hitches: [(at: TimeInterval, ms: Int)],
                            cache: inout [UInt64: String]) -> [String] {
        guard !hitches.isEmpty else { return [] }
        var lines: [String] = []
        let worst = hitches.sorted { $0.ms > $1.ms }.prefix(3)
        for hitch in worst {
            let low = hitch.at - Double(hitch.ms) / 1000 - 0.003
            let high = hitch.at + 0.003
            var local: [UInt64: Int] = [:]
            var total = 0
            for index in 0..<aggregate.sampleTimes.count {
                let time = aggregate.sampleTimes[index]
                guard time >= low, time <= high else { continue }
                total += 1
                local[aggregate.sampleHashes[index], default: 0] += 1
            }
            guard total > 0, let top = local.max(by: { $0.value < $1.value }) else {
                continue
            }
            let rank = aggregate.stacks.firstIndex { $0.hash == top.key }
            let share = Double(top.value) / Double(total) * 100
            var frame = "unknown"
            if let index = rank, !aggregate.stacks[index].pcs.isEmpty {
                frame = symbolize(aggregate.stacks[index].pcs[0], cache: &cache)
            }
            lines.append("MH gap=\(hitch.ms)ms samples=\(total) "
                + "top=\(rank.map { "#\($0 + 1)" } ?? "other") "
                + "\(Self.f(share))% \(top.value)/\(total) \(frame)")
        }
        return lines
    }

    // MARK: - Symbolication

    private func symbolize(_ pc: UInt64, cache: inout [UInt64: String]) -> String {
        if let hit = cache[pc] { return hit }
        var result = String(format: "0x%llx", pc)
        var info = Dl_info()
        if pc != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(pc)),
           dladdr(pointer, &info) != 0 {
            let image = info.dli_fname.map { String(cString: $0) }
                .map { ($0 as NSString).lastPathComponent } ?? "?"
            if let symbol = info.dli_sname {
                let name = Self.demangle(String(cString: symbol))
                let base = UInt64(UInt(bitPattern: info.dli_saddr))
                let offset = pc >= base ? pc - base : 0
                result = "\(image)`\(name)+0x\(String(offset, radix: 16))"
            } else if let base = info.dli_fbase.map({ UInt64(UInt(bitPattern: $0)) }) {
                let offset = pc >= base ? pc - base : 0
                result = "\(image)+0x\(String(offset, radix: 16))"
            }
        }
        cache[pc] = result
        return result
    }

    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int,
        UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?,
        UInt32) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: SwiftDemangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: SwiftDemangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("_$s") || name.hasPrefix("$s") else { return name }
        guard let function = swiftDemangle else { return name }
        let demangled = name.withCString { pointer in
            function(pointer, Int(strlen(pointer)), nil, nil, 0)
        }
        guard let demangled else { return name }
        defer { free(demangled) }
        return String(cString: demangled)
    }

    // MARK: - Helpers

    private func resetLocked() {
        sampleCount = 0
        frameCount = 0
        bufferFull = false
        windowStart = 0
        finishedAt = 0
        lastActiveAt = 0
    }

    private static func f(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

#endif
