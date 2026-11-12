import SwiftUI

/// The empty New Session screen's illustration: Clawd standing among the
/// tool icons, as on Claude iOS's Code screen.
///
/// Geometry is measured from the official screen at 3× (1179×2556): one pixel
/// cell is 1.49 pt, the character's stage is 72 cells wide (55 framing + the
/// tail), 37 tall. Tapping the character replays its idle animation and plays
/// the accent haptic, matching `ClawdAnimation` in the official app.
struct ClawdWelcomeArt: View {
    /// Points per pixel cell. The official screen draws one cell at 4.49 px
    /// on a 3× display, i.e. 1.49 pt.
    var unit: CGFloat = 1.49

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPlaying = false
    @State private var playToken = 0
    @State private var frameIndex = 0
    @State private var accentToken = 0
    @State private var accentIntensity = 0.6
    @State private var playback: Task<Void, Never>?

    /// The scene the official screen opens with (schedule table not decoded
    /// yet; heart is fully translated).
    private let timeline = ClawdScenes.timeline(for: .heart)

    private var artSize: CGSize {
        CGSize(width: CGFloat(ClawdRenderer.stageWidth) * unit,
               height: CGFloat(ClawdRenderer.height) * unit)
    }

    var body: some View {
        ZStack {
            floatingIcons
            clawd
                .contentShape(.rect)
                .onTapGesture { replay() }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140 * unit)
        .sensoryFeedback(trigger: accentToken) { _, _ in
            .impact(weight: .light, intensity: accentIntensity)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop() }
        }
        .onDisappear { stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Clawd"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "播放动画"))
    }

    private var clawd: some View {
        Canvas { context, _ in
            // Idle animation: the official typing loop bobs Clawd by one cell
            // on an 8-frame cycle ([0, 0, 1, 1, 0, 0, -1, -1], read from the
            // scene builder at 0x106b3b588). The resting pose stands still
            // until the first tap.
            let frames = timeline.frames
            let pose = frames[min(frameIndex, frames.count - 1)]
            let grid = ClawdRenderer.render(pose)
            let width = ClawdRenderer.stageWidth
            for y in 0..<ClawdRenderer.height {
                for x in 0..<width {
                    let value = grid.cells[y * width + x]
                    guard value != 0 else { continue }
                    let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit,
                                      width: unit, height: unit)
                    context.fill(Path(rect), with: .color(color(value)))
                }
            }
        }
        .frame(width: artSize.width, height: artSize.height)
        .contentShape(.rect)
        .scaleEffect(x: 1, y: isPlaying ? 0.97 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.55),
                   value: isPlaying)
    }

    private func color(_ index: UInt8) -> Color {
        let argb = ClawdRenderer.palette[Int(index) - 1]
        return Color(.sRGB,
                     red: Double((argb >> 16) & 0xFF) / 255,
                     green: Double((argb >> 8) & 0xFF) / 255,
                     blue: Double(argb & 0xFF) / 255,
                     opacity: 1)
    }

    /// Icon chrome around Clawd, positioned in the same cell grid as the
    /// official screen. Offsets are measured from the art's center in points.
    private var floatingIcons: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                icon("clawd-code", size: 25).position(x: center.x - 142, y: center.y - 38)
                icon("clawd-mobile", size: 26).position(x: center.x - 98, y: center.y - 1)
                icon("clawd-branch", size: 26).position(x: center.x - 55, y: center.y - 35)
                icon("clawd-terminal", size: 21).position(x: center.x + 74, y: center.y - 41)
                icon("clawd-nodes", size: 24).position(x: center.x + 119, y: center.y - 5)
                icon("clawd-braces", size: 29).position(x: center.x + 155, y: center.y - 41)
            }
        }
    }

    private func icon(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .accessibilityHidden(true)
    }

    @MainActor
    private func replay() {
        guard scenePhase == .active else { return }
        HapticGate.noteUserAction()
        playToken += 1
        guard !reduceMotion else { return }
        playback?.cancel()
        isPlaying = true
        playback = Task { @MainActor in
            // Scene playback at the official 12 fps.
            for index in timeline.frames.indices {
                guard !Task.isCancelled else { return }
                frameIndex = index
                if let accent = timeline.accents.first(where: { $0.frame == index }) {
                    accentIntensity = accent.intensity
                    accentToken += 1
                }
                do { try await Task.sleep(for: .milliseconds(83)) }
                catch { return }
            }
            isPlaying = false
            frameIndex = 0
        }
    }

    @MainActor
    private func stop() {
        playback?.cancel()
        playback = nil
        isPlaying = false
        frameIndex = 0
    }
}
