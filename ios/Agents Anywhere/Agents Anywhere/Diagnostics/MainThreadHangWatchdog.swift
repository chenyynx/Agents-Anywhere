import Darwin
import Foundation
import QuartzCore
import os

#if canImport(UIKit)
import UIKit
#endif

/// The watchdog's decision rules, pure so the package tests can pin them
/// without a device.
nonisolated struct HangWatchdogPolicy: Sendable {
    /// The b1678 freeze (pp 2026-11-27 01:42:45) stayed silent for 89 s after
    /// a keyboard `willHide`; every ordinary layout pass, however heavy,
    /// returns in well under this.
    static let stallSeconds: TimeInterval = 2
    /// A suspended app wakes with a stale beat and the first post-resume beat
    /// lands inside one heartbeat, so a suspected stall is re-checked before
    /// it is called a hang.
    static let confirmSeconds: TimeInterval = 0.5

    static func isStalled(lastBeat: TimeInterval, now: TimeInterval,
                          foreground: Bool, reportBeat: TimeInterval) -> Bool {
        guard foreground, reportBeat == 0 else { return false }
        return now - lastBeat >= stallSeconds
    }

    /// The beat advanced past the value captured at the stall: the thread is
    /// running again.
    static func hasRecovered(lastBeat: TimeInterval, reportBeat: TimeInterval) -> Bool {
        reportBeat > 0 && lastBeat > reportBeat
    }
}

/// Captures the main thread's stack while it is frozen.
///
/// Timing probes cannot say what a thread is doing while it never returns:
/// the b1678 log ends at the keyboard's `willHide` handler and the next line
/// is a fresh `app.launch` 89 s later. This watchdog keeps a main-queue
/// heartbeat; when the beat is more than two seconds late it suspends the
/// main thread, walks its frame chain with the same Mach path as
/// `MainThreadStackSampler`, and writes one `app.hang` line (address +
/// image+offset per frame, plus the executable's load address so a stripped
/// Release build can be symbolicated against its dSYM). A suspended app is
/// not a hang: captures only happen while the app was last seen in the
/// foreground.
nonisolated final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    // MARK: Tuning

    private static let beatInterval: TimeInterval = 0.25
    private static let maxDepth = 32
    /// `arm_thread_state64_t` layout: 29 x-registers, then fp, lr, sp, pc.
    private static let armThreadState64: thread_state_flavor_t = 6
    private static let stateWordCount = 34
    /// arm64e pointers carry a PAC in the high bits; user addresses fit in 47.
    private static let pointerMask: UInt64 = 0x0000_7FFF_FFFF_FFFF

    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>
    private let stateMemory: UnsafeMutableRawPointer
    private let frameBuffer: UnsafeMutablePointer<UInt64>

    private var mainThreadPort: mach_port_t = 0
    private var heartbeat: DispatchSourceTimer?
    /// The app's own executable path, read on the main thread at start; the
    /// report needs the image's load address for `atos -l`.
    nonisolated(unsafe) private static var mainImagePath: String?
    private var worker: Thread?
    private var installed = false

    // Guarded by `lockPointer`.
    private var lastBeat: TimeInterval = 0
    private var foreground = false
    /// The beat value captured at the stall; 0 when no report is outstanding.
    private var reportBeat: TimeInterval = 0
    private var stallStart: TimeInterval = 0

    private init() {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        lockPointer = lock
        stateMemory = .allocate(byteCount: Self.stateWordCount * 8, alignment: 8)
        _ = stateMemory.bindMemory(to: natural_t.self, capacity: Self.stateWordCount * 2)
        frameBuffer = .allocate(capacity: Self.maxDepth)
        frameBuffer.initialize(repeating: 0, count: Self.maxDepth)
    }

    /// Call once from the main thread at launch. A disabled diagnostics log
    /// means no watchdog: there would be nowhere to write the report.
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard ClientDiagnosticsLog.shared.isEnabled else { return }
        os_unfair_lock_lock(lockPointer)
        let alreadyInstalled = installed
        if !alreadyInstalled {
            installed = true
            mainThreadPort = pthread_mach_thread_np(pthread_self())
            lastBeat = CACurrentMediaTime()
            foreground = Self.applicationIsForeground()
            Self.mainImagePath = Bundle.main.executablePath
        }
        os_unfair_lock_unlock(lockPointer)
        guard !alreadyInstalled else { return }
        installHeartbeat()
        startWorker()
        ClientDiagnosticsLog.shared.record(
            kind: "app.hang.armed",
            detail: ["stallMs": String(Int(HangWatchdogPolicy.stallSeconds * 1000))],
            dedupe: false)
    }

    private static func applicationIsForeground() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    // MARK: Heartbeat (main thread)

    private func installHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.beatInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        heartbeat = timer
    }

    private func beat() {
        let now = CACurrentMediaTime()
        let active = Self.applicationIsForeground()
        os_unfair_lock_lock(lockPointer)
        lastBeat = now
        foreground = active
        os_unfair_lock_unlock(lockPointer)
    }

    // MARK: Watchdog thread

    private func startWorker() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "AA-MainThreadHangWatchdog"
        thread.qualityOfService = .utility
        thread.stackSize = 256 * 1024
        thread.start()
        worker = thread
    }

    private func runLoop() {
        while true {
            usleep(250_000)
            let now = CACurrentMediaTime()
            os_unfair_lock_lock(lockPointer)
            let beat = lastBeat
            let active = foreground
            let outstanding = reportBeat
            let start = stallStart
            os_unfair_lock_unlock(lockPointer)

            if outstanding > 0 {
                guard HangWatchdogPolicy.hasRecovered(lastBeat: beat, reportBeat: outstanding) else {
                    continue
                }
                os_unfair_lock_lock(lockPointer)
                reportBeat = 0
                stallStart = 0
                os_unfair_lock_unlock(lockPointer)
                ClientDiagnosticsLog.shared.record(
                    kind: "app.hang.recovered",
                    detail: ["ms": String(Int((beat - start) * 1000))],
                    dedupe: false)
                continue
            }

            guard HangWatchdogPolicy.isStalled(lastBeat: beat, now: now,
                                               foreground: active,
                                               reportBeat: outstanding) else { continue }
            // Confirm outside the lock: an app woken from suspension must not
            // read as a hang, and its first post-resume beat lands within one
            // interval.
            usleep(useconds_t(HangWatchdogPolicy.confirmSeconds * 1_000_000))
            let after = CACurrentMediaTime()
            os_unfair_lock_lock(lockPointer)
            let confirmedBeat = lastBeat
            let confirmedForeground = foreground
            os_unfair_lock_unlock(lockPointer)
            guard confirmedForeground,
                  after - confirmedBeat >= HangWatchdogPolicy.stallSeconds else { continue }

            let depth = captureMainThread()
            guard depth > 0 else { continue }
            os_unfair_lock_lock(lockPointer)
            let resumedMeanwhile = lastBeat > confirmedBeat
            if !resumedMeanwhile {
                reportBeat = confirmedBeat
                stallStart = confirmedBeat
            }
            os_unfair_lock_unlock(lockPointer)
            guard !resumedMeanwhile else { continue }

            let report = describeFrames(depth: depth)
            ClientDiagnosticsLog.shared.record(
                kind: "app.hang",
                detail: ["ms": String(Int((after - confirmedBeat) * 1000)),
                         "appBase": report.appBase,
                         "frames": report.lines.joined(separator: " | ")],
                dedupe: false)
        }
    }

    // MARK: Capture

    /// Suspend → read registers → walk the frame chain → resume. Everything
    /// between suspend and resume is mach traps and bounds-checked reads into
    /// preallocated buffers: no allocation, no locks, no Swift runtime calls
    /// that could need the stopped thread.
    private func captureMainThread() -> Int {
        guard thread_suspend(mainThreadPort) == KERN_SUCCESS else { return 0 }
        var depth = 0
        var count = mach_msg_type_number_t(Self.stateWordCount * 2)
        let result = thread_get_state(
            mainThreadPort, Self.armThreadState64,
            stateMemory.assumingMemoryBound(to: natural_t.self), &count)
        if result == KERN_SUCCESS {
            let pc = stateMemory.load(fromByteOffset: 32 * 8, as: UInt64.self)
                & Self.pointerMask
            let fp = stateMemory.load(fromByteOffset: 29 * 8, as: UInt64.self)
                & Self.pointerMask
            let lr = stateMemory.load(fromByteOffset: 30 * 8, as: UInt64.self)
                & Self.pointerMask
            if pc != 0 {
                frameBuffer[0] = pc
                depth = 1
            }
            var cursor = fp
            var walked = 0
            while depth < Self.maxDepth, cursor != 0, walked < Self.maxDepth + 8 {
                guard cursor % 8 == 0 else { break }
                var next: UInt64 = 0
                var returned: UInt64 = 0
                guard Self.readStackWords(at: cursor,
                                          nextFrame: &next,
                                          returnAddress: &returned) else { break }
                next &= Self.pointerMask
                returned &= Self.pointerMask
                if returned == 0 { break }
                frameBuffer[depth] = returned
                depth += 1
                cursor = next
                walked += 1
            }
            // A function that does not maintain a frame pointer still leaves
            // pc + lr; keep both rather than dropping the sample.
            if depth <= 1, lr != 0, lr != pc {
                frameBuffer[depth] = lr
                depth += 1
            }
        }
        thread_resume(mainThreadPort)
        return depth
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
        guard ok else { return false }
        nextFrame = pair.0
        returnAddress = pair.1
        return true
    }

    /// One line per frame: the raw address (for `atos -l appBase`) plus the
    /// image and offset; a probe build keeps its symbols and names them.
    private func describeFrames(depth: Int) -> (lines: [String], appBase: String) {
        var info = Dl_info()
        var lines: [String] = []
        var appBase = "?"
        let process = ProcessInfo.processInfo.processName
        for index in 0..<min(depth, Self.maxDepth) {
            let address = frameBuffer[index]
            guard address != 0,
                  let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { continue }
            let resolved = dladdr(pointer, &info) != 0
            let path: String? = (resolved && info.dli_fname != nil)
                ? String(cString: info.dli_fname) : nil
            let image = path.map { ($0 as NSString).lastPathComponent } ?? "?"
            let base = (resolved && info.dli_fbase != nil)
                ? UInt64(UInt(bitPattern: info.dli_fbase)) : 0
            let isAppImage = image == process
                || (path != nil && path == Self.mainImagePath)
            if isAppImage, appBase == "?", base > 0 {
                appBase = "0x" + String(base, radix: 16)
            }
            let offset = (base > 0 && address >= base) ? address - base : address
            var name = "\(image)+0x\(String(offset, radix: 16))"
            if resolved, let symbol = info.dli_sname, symbol.pointee != 0 {
                name = "\(image)`\(String(cString: symbol))+0x\(String(offset, radix: 16))"
            }
            lines.append("0x\(String(address, radix: 16)) \(name)")
        }
        return (lines, appBase)
    }
}
