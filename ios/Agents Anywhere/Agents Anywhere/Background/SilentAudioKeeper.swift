import AVFoundation

/// Silent-audio keep-alive (Poki's `KeepAlive`, adapted).
///
/// Plays one second of zero-filled PCM in a loop at zero output volume with
/// the `.playback` + `.mixWithOthers` session, which keeps the process out of
/// suspension without interrupting the user's music. It is the ladder's level
/// 2: entered when the continued-processing task is refused or ended early.
/// Other apps' audio can interrupt the session; the keeper restarts its engine
/// when the interruption ends and reports both edges so the coordinator can
/// hold location in the meantime.
@MainActor
final class SilentAudioKeeper {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var interruption: NSObjectProtocol?

    /// A session interruption began; audio is (or is about to be) silent and
    /// the app may be suspended without another keep-alive.
    var onInterrupted: (@MainActor () -> Void)?
    /// The session's interruption ended and audio is playing again.
    var onRestored: (@MainActor () -> Void)?

    var isOn: Bool { engine != nil }

    func start() throws {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate)
        ) else {
            Self.deactivate(session)
            return
        }
        buffer.frameLength = buffer.frameCapacity // zero-filled: silence
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
        } catch {
            Self.deactivate(session)
            throw error
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor [weak self] in self?.handleInterruption(type) }
        }
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.audio.start",
            detail: ["ok": "true"],
            dedupe: false)
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        self.player = nil
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
        }
        interruption = nil
        Self.deactivate(AVAudioSession.sharedInstance())
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.audio.stop",
            dedupe: false)
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.audio.interrupted",
                dedupe: false)
            onInterrupted?()
        case .ended:
            // Match Poki: give the session a moment, then either confirm the
            // engine came back or start it again. A keeper that cannot play
            // keeps the coordinator on its location fallback.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.engine != nil else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                if let engine = self.engine, !engine.isRunning {
                    try? engine.start()
                    self.player?.play()
                }
                ClientDiagnosticsLog.shared.record(
                    kind: "keepalive.audio.restored",
                    dedupe: false)
                self.onRestored?()
            }
        @unknown default:
            break
        }
    }

    private static func deactivate(_ session: AVAudioSession) {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
