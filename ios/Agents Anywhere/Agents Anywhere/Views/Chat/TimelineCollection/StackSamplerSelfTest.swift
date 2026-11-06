#if DEBUG
import SwiftUI
import UIKit

/// Simulator gate for `MainThreadStackSampler` (`aa-stack-sampler-selftest`).
///
/// The sampler is unsafe code by necessity: it suspends the main thread and
/// walks its frame pointers. The only way to prove the Mach path works before
/// asking pp to install a device build is to run it here: the main thread
/// spins in a named `@inline(never)` function for two seconds, the sampler must
/// capture that frame, and the JSON lands in `Documents/stack-sampler.json`
/// for the CI job to assert on.
///
/// Compiled in every Debug build so the app's launch-argument chain stays
/// unconditional; the body is a no-op outside probe builds.
enum StackSamplerSelfTest {
    static let launchArgument = "aa-stack-sampler-selftest"
    static let fileName = "stack-sampler.json"

    static func run() -> [String: Any] {
        #if AA_TIMELINE_PROBE
        let sampler = MainThreadStackSampler.shared
        sampler.clear()
        sampler.noteActivity(scrolling: true)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Self.spin()
            // Keep the session active while the main thread is busy: the
            // probe's display link is not ticking here.
            sampler.noteActivity(scrolling: true)
        }
        sampler.noteActivity(scrolling: false)
        sampler.finishForSelfTest()
        return sampler.selfTestResult()
        #else
        return ["completed": true, "samples": 0, "frames": 0,
                "containsSelfTest": false,
                "error": "build without AA_TIMELINE_PROBE"]
        #endif
    }

    /// @inline(never) so the Debug build keeps a named frame to find.
    @inline(never)
    static func spin() {
        var value = 0
        for index in 0..<2_000 {
            value &+= index
        }
        if value == -1 { print(value) }
    }

    static func write(_ result: [String: Any]) {
        guard let directory = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        else { return }
        let url = directory.appendingPathComponent(fileName)
        let data = try? JSONSerialization.data(withJSONObject: result,
                                               options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: url)
    }
}

struct StackSamplerSelfTestRootView: View {
    @State private var status = "running"

    var body: some View {
        VStack(spacing: 12) {
            Text("Stack sampler self-test").font(.headline)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .task {
            let result = StackSamplerSelfTest.run()
            StackSamplerSelfTest.write(result)
            status = "done samples=\(result["samples"] ?? 0) "
                + "contains=\(result["containsSelfTest"] ?? false)"
        }
    }
}
#endif
