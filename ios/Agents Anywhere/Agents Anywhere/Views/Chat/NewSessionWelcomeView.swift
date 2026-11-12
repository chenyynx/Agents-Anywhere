import SwiftUI

/// The Agent's name is the title and opens the target picker; the copy below
/// describes what the agent does, centred under Clawd like the official Code
/// screen.
struct NewSessionWelcomeView: View {
    let deviceName: String?
    let agentName: String?
    let onChooseTarget: () -> Void
    private static var revealDuration: Double { 0.4 }
    /// Known copy cascades: each phrase starts before the previous one ends.
    private static var phraseInterval: Duration { .milliseconds(200) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    @State private var titlePhraseCount = 0
    @State private var detailPhraseCount = 0
    @State private var hasStarted = false
    @State private var initialFrame = CGRect.zero
    @State private var isRevealing = false
    @State private var revealCompletion = 0
    @State private var titleLedger = GlyphRevealLedger(duration: NewSessionWelcomeView.revealDuration)
    @State private var detailLedger = GlyphRevealLedger(duration: NewSessionWelcomeView.revealDuration)

    private var title: String { agentName ?? String(localized: "选择 Agent") }
    private var detail: String {
        String(localized: "直接在您的代码库中与您协作，添加功能、修复 bug 并解释代码。")
    }

    var body: some View {
        welcomeText
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            // Observe real layout without locking its width or height. Once
            // drawing begins, geometry updates must not cancel the reveal task.
            if !hasStarted { initialFrame = frame }
        }
        .sidebarDrawerSettledTask(id: WelcomeRevealKey(reduceMotion: reduceMotion, frame: initialFrame)) { settled in
            await reveal(canReveal: settled)
        }
        .completionFeedback(trigger: revealCompletion)
    }

    private var welcomeText: some View {
        VStack(alignment: .center, spacing: 14) {
            Button(action: onChooseTarget) {
                streamingText(title, underlined: title.startIndex..<title.endIndex,
                              revealedPhrases: titlePhraseCount, ledger: titleLedger)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(String(localized: "选择设备和 Agent"))
            .accessibilityIdentifier("chat.new.agent")
            streamingText(detail, underlined: nil,
                          revealedPhrases: detailPhraseCount, ledger: detailLedger)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2...)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.new.detail")
        }
        .frame(maxWidth: .infinity)
    }

    private func streamingText(_ text: String, underlined: Range<String.Index>?, revealedPhrases: Int,
                               ledger: GlyphRevealLedger) -> some View {
        // Future phrases take part in line breaking from the first
        // frame. The shared renderer alone controls their visibility and reveal.
        StreamingTextPhrase.text(text, underlined: underlined)
            .modifier(StreamingGlyphReveal(ledger: ledger, revealedPhraseCount: revealedPhrases))
            .environment(\.streamingGlyphAnimation, isRevealing)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private func reveal(canReveal: Bool) async {
        guard canReveal, !hasStarted, initialFrame.width > 0, initialFrame.height > 0 else { return }
        if !reduceMotion {
            // Navigation chrome and composer sizing get
            // their first layout before glyphs appear. A changing frame restarts
            // this quiet interval; no network request gates the welcome.
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        hasStarted = true
        isRevealing = !reduceMotion
        // Cancellation, leaving the page, and Reduce Motion always settle the
        // complete copy. They cannot leave a partial heading or an active clock.
        defer {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Names can arrive or change after the reveal; show all phrases.
                titlePhraseCount = .max
                detailPhraseCount = .max
                isRevealing = false
            }
        }
        guard !reduceMotion else { revealCompletion += 1; return }
        var schedule = ReplyFlushSchedule(start: .now, interval: Self.phraseInterval)
        do {
            for count in TextPhraseSequence.chunks(in: title).indices {
                try Task.checkCancellation()
                titlePhraseCount = count + 1
                try await Task.sleep(until: schedule.deadline, clock: .continuous)
                schedule.advance(after: .now)
            }
            for count in TextPhraseSequence.chunks(in: detail).indices {
                try Task.checkCancellation()
                detailPhraseCount = count + 1
                try await Task.sleep(until: schedule.deadline, clock: .continuous)
                schedule.advance(after: .now)
            }
            try await Task.sleep(for: .seconds(Self.revealDuration + ReplyPresentation.drawSlack))
            try Task.checkCancellation()
            if canReveal { revealCompletion += 1 }
        } catch {
            // The defer completes the presentation if its lifecycle interrupts it.
        }
    }
}

private struct WelcomeRevealKey: Equatable {
    let reduceMotion: Bool
    let frame: CGRect
}
