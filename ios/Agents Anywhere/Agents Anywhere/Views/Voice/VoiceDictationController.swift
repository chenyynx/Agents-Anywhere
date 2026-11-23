import AVFoundation
import Combine
import Speech

/// Live speech-to-text for the composer.
///
/// The official dictation target carries `needsLiveWords` + `onTranscript`
/// into a `Binding<String>`, so partial words are written while the user is
/// still speaking. Ending is explicit in the official state machine
/// (`kept` / `send` / `discarded`); there is no silence auto-cancel.
final class VoiceDictationController: ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case recording
        case denied
        case failed(String)
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript = ""

    var onPartial: ((String) -> Void)?
    var onAutoFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var transcribeTimeout: Task<Void, Never>?
    private var latestTranscript = ""
    private var smoothedLevel: Float = 0

    private let lock = NSLock()
    private var samples: [(time: Double, level: Float)] = []

    /// Samples used by the waveform; the timeline passes its own clock, which
    /// shares `timeIntervalSinceReferenceDate`.
    func amplitude(at time: Double) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last else { return 0 }
        if time < first.time { return 0 }
        // Peak-hold inside this 0.06 s cell: a syllable keeps its full height
        // on the bar that represents it.
        var peak: Float = 0
        for sample in samples where sample.time > time - 0.06 && sample.time <= time + 0.005 {
            peak = max(peak, sample.level)
        }
        if peak > 0 { return peak }
        if time >= last.time { return last.level }
        // Gap fallback: interpolate between neighbours.
        var previous = first
        for sample in samples {
            if sample.time >= time {
                let span = sample.time - previous.time
                if span <= 0 { return sample.level }
                let progress = Float((time - previous.time) / span)
                return previous.level + (sample.level - previous.level) * progress
            }
            previous = sample
        }
        return last.level
    }

    func start() {
        guard !isRecording, status != .starting else { return }
        status = .starting
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authorization == .authorized else {
                    self.status = .denied
                    return
                }
                Task { @MainActor in
                    let granted = await AVAudioApplication.requestRecordPermission()
                    guard granted else {
                        self.status = .denied
                        return
                    }
                    self.begin()
                }
            }
        }
    }

    /// Ends the take but keeps the engine alive briefly for the final result.
    /// `isTranscribing` drives the official "正在转录....." label.
    func stop() {
        guard isRecording else { return }
        isTranscribing = true
        request?.endAudio()
        transcribeTimeout?.cancel()
        transcribeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.isTranscribing else { return }
            self.complete()
        }
    }

    func cancel() {
        latestTranscript = ""
        transcript = ""
        transcribeTimeout?.cancel()
        transcribeTimeout = nil
        isTranscribing = false
        complete()
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)

            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer()
            guard let recognizer, recognizer.isAvailable else {
                status = .failed(String(localized: "语音识别暂不可用"))
                return
            }
            self.recognizer = recognizer

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                self?.meter(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async { self?.handle(result: result, error: error) }
            }

            transcript = ""
            latestTranscript = ""
            smoothedLevel = 0
            isTranscribing = false
            lock.lock()
            samples.removeAll()
            lock.unlock()
            isRecording = true
            status = .recording
        } catch {
            status = .failed(error.localizedDescription)
            teardown()
        }
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(data[index]))
        }
        let db = 20 * log10f(max(peak, 1e-7))
        // Peak envelope, -55…-10 dBFS: speech transients reach the top of the
        // bar instead of being averaged away by RMS.
        let raw = min(max((db + 55) / 45, 0), 1)
        let follow: Float = raw > smoothedLevel ? 0.9 : 0.5
        smoothedLevel += (raw - smoothedLevel) * follow
        // Noise floor: a silent room must not make the waveform twitch.
        let gated: Float = smoothedLevel < 0.06 ? 0 : smoothedLevel
        // Gamma lifts the quiet half so syllables read as rhythm.
        let level: Float = gated == 0 ? 0 : powf(gated, 0.65)

        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        samples.append((now, level))
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
        lock.unlock()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty, text != latestTranscript {
                latestTranscript = text
                transcript = text
                onPartial?(text)
            }
            if result.isFinal {
                if isTranscribing { complete() } else { finish(auto: true) }
                return
            }
        }
        if let error {
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" {
                // 216 = cancelled when the task is torn down.
                if nsError.code == 216 { return }
                // 1110 = "No speech detected": a normal empty take, not an
                // attachment failure and not worth an alert.
                if nsError.code == 1110 {
                    if isTranscribing { complete() } else { finish(auto: true) }
                    return
                }
            }
            status = .failed(error.localizedDescription)
            if isTranscribing { complete() } else { finish(auto: true) }
        }
    }

    private func finish(auto: Bool) {
        complete()
        if auto {
            DispatchQueue.main.async { [weak self] in self?.onAutoFinish?() }
        }
    }

    private func complete() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transcribeTimeout?.cancel()
            self.transcribeTimeout = nil
            self.teardown()
            self.isRecording = false
            self.isTranscribing = false
            self.status = .idle
        }
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: .notifyOthersOnDeactivation)
    }
}
