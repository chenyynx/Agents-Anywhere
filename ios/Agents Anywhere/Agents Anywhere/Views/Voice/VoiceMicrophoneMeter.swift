import Combine
import SwiftUI

#if os(iOS)
import AVFoundation

/// Live microphone power for the voice visualizer.
///
/// One RMS value shaped into seven band slots: the replica only needs the
/// cloud to breathe with the voice. Per-band FFT can replace `weights` later
/// without touching the renderer.
///
/// The renderer polls `snapshot` from the main thread while the audio tap
/// writes from the audio thread, so the array is guarded by a lock; only
/// `status` is published to SwiftUI.
final class VoiceMicrophoneMeter: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var bands = [Float](repeating: 0, count: 7)
    private var tapInstalled = false

    /// Tilt so the outer bands sit lower than the centre, matching how a
    /// voice's energy reads across the official seven slots.
    private static let weights: [Float] = [0.55, 0.7, 0.85, 1.0, 0.9, 0.75, 0.6]

    /// Lock-protected snapshot for the renderer.
    var snapshot: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return bands
    }

    func start() {
        guard status != .running else { return }
        Task { @MainActor in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                self.status = .denied
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement,
                                        options: [.mixWithOthers])
                try session.setActive(true)
                let input = self.engine.inputNode
                let format = input.inputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.process(buffer)
                }
                self.tapInstalled = true
                self.engine.prepare()
                try self.engine.start()
                self.status = .running
            } catch {
                self.status = .failed(error.localizedDescription)
                self.teardown()
            }
        }
    }

    func stop() {
        teardown()
        status = .idle
        lock.lock()
        bands = [Float](repeating: 0, count: 7)
        lock.unlock()
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for index in 0..<count {
            let sample = data[index]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(count))
        // −50…−5 dBFS maps to 0…1, which keeps quiet rooms near zero.
        let db = 20 * log10f(max(rms, 1e-7))
        let power = min(max((db + 50) / 45, 0), 1)

        lock.lock()
        for index in 0..<7 {
            bands[index] = power * Self.weights[index]
        }
        lock.unlock()
    }
}

#else

/// Mac Catalyst has no AVAudioSession; the lab simply keeps its mock levels.
final class VoiceMicrophoneMeter: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    var snapshot: [Float] { [Float](repeating: 0, count: 7) }

    func start() { status = .failed("microphone unavailable") }
    func stop() { status = .idle }
}

#endif
