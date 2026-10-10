import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The on-screen transcript: a floating window over the chat page that follows
/// the log's newest line and can copy or clear it. It is a sibling of the
/// scroll view, never a child — it cannot shift a timeline row, charge a
/// spacer or steal a scroll gesture.
struct TimelineDiagnosticsPanel: View {
    /// Collapse back to the pill; the pill (or the Settings toggle) re-opens.
    let onCollapse: () -> Void
    @State private var diag = TimelineDiag.shared
    @State private var copied = false

    var body: some View {
        // `snapshot()` reads the log's revision on the way out, which is what
        // subscribes this leaf to appends; the buffer itself is ignored.
        let events = diag.snapshot()
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(String(localized: "Timeline diagnostics"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 0)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy all")) {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = diag.formatted()
                    #endif
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
                Button(String(localized: "Clear")) { diag.clear() }
                Button(String(localized: "Collapse")) { onCollapse() }
            }
            .font(.caption2)
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
            ScrollView {
                if events.isEmpty {
                    Text(String(localized: "No events yet"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(events) { event in
                            Text(event.formatted)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
            }
            // Follow the newest entry as it lands, like a console tail.
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
    }
}

/// The chat page's mount: the full panel, or — once collapsed — a small
/// trailing pill that brings it back. Mounted only while the log is on, so the
/// page carries no diagnostics surface by default. The empty area around the
/// window passes every gesture through to the scroll view below.
struct TimelineDiagnosticsOverlay: View {
    @State private var collapsed = false

    var body: some View {
        GeometryReader { proxy in
            if collapsed {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            collapsed = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform.path.ecg")
                                Text(String(localized: "Diagnostics"))
                            }
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            } else {
                TimelineDiagnosticsPanel(onCollapse: { collapsed = true })
                    .frame(height: max(180, proxy.size.height / 3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
