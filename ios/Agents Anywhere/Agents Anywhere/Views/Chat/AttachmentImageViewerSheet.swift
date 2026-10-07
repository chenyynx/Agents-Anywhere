import OSLog
import SwiftUI
import UIKit

/// Full-screen attachment image viewer on the instant-open path.
///
/// The sheet shows the bubble's thumbnail the moment it presents, so the tap
/// never waits on the network (`initialImage` is the image already on screen
/// in the bubble). `AttachmentImageLoader` then serves the original behind it:
/// a disk-cache hit swaps the image in with zero network, a miss streams to
/// disk under a light, non-blocking progress badge that never covers the
/// image. Failures stay inside the viewer — an in-place notice with a retry
/// button — instead of the old toast path, and sharing falls back to the
/// visible image until the original lands.
struct AttachmentImageViewerSheet: View {
    let file: V2AttachmentContent
    let initialImage: UIImage?
    /// Wall-clock of the bubble tap; anchors the `[ImageOpen]` acceptance
    /// metrics (tap→present ms, tap→fullres ms).
    let tappedAt: Date
    let loader: AttachmentImageLoader

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var fullResolutionURL: URL?
    @State private var loadError: String?
    @State private var showsProgress = false
    @State private var attempt = 0
    @State private var didLogPresent = false

    /// Acceptance metrics of the instant-open path. `.notice` level so a
    /// device-recording run keeps them without a debug build.
    private static let log = Logger(subsystem: "agents.anywhere", category: "image-open")

    init(file: V2AttachmentContent, initialImage: UIImage?, tappedAt: Date = Date(), loader: AttachmentImageLoader) {
        self.file = file
        self.initialImage = initialImage
        self.tappedAt = tappedAt
        self.loader = loader
        // T1: the thumbnail is on screen from the first frame, not after a load.
        _image = State(initialValue: initialImage)
    }

    private var title: String {
        guard let name = file.name, !name.isEmpty else { return String(localized: "查看图片") }
        return name
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color(uiColor: .systemBackground)
                    if let image {
                        // Re-identify on every swap (thumbnail → original) so
                        // the scroll view is rebuilt and refits the new image.
                        ZoomableAttachmentImage(image: image).id(ObjectIdentifier(image))
                    } else if loadError == nil {
                        ProgressView().progressViewStyle(.circular)
                            .accessibilityLabel(String(localized: "正在加载原图…"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { statusChip }
                .task(id: attempt) { await loadFullResolution(container: proxy.size) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { shareControl }
                SheetCloseToolbar { dismiss() }
            }
        }
        .appSheetPresentation(.expanded)
        .onAppear {
            guard !didLogPresent else { return }
            didLogPresent = true
            Self.log.notice("[ImageOpen] tap→present \(Self.milliseconds(since: tappedAt), privacy: .public) ms")
        }
    }

    // MARK: - Status

    /// One bottom chip: the failure notice with its retry, or the light
    /// progress badge. Neither covers the image; the badge never takes taps.
    @ViewBuilder private var statusChip: some View {
        if let loadError {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    AppSymbol("exclamationmark.triangle", size: 16).foregroundStyle(.orange)
                    Text(loadError).font(.footnote).multilineTextAlignment(.leading)
                }
                Button(String(localized: "重试")) { attempt += 1 }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 20).padding(.bottom, 28)
        } else if showsProgress, image != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "正在加载原图…")).font(.footnote)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .padding(.bottom, 28)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Share

    /// Shares the original file once it has landed; before that it shares the
    /// image currently on screen, so the entry keeps working at every phase.
    @ViewBuilder private var shareControl: some View {
        if let fullResolutionURL {
            ShareLink(item: fullResolutionURL) { AppSymbol("square.and.arrow.up") }
                .accessibilityLabel(String(localized: "分享原图"))
        } else if let image {
            let visible = Image(uiImage: image)
            ShareLink(item: visible, preview: SharePreview(file.name ?? String(localized: "查看图片"), image: visible)) {
                AppSymbol("square.and.arrow.up")
            }
            .accessibilityLabel(String(localized: "分享当前图片"))
        }
    }

    // MARK: - Full resolution

    private func loadFullResolution(container: CGSize) async {
        guard fullResolutionURL == nil else { return }
        loadError = nil
        // A cache hit resolves in a frame or two; the badge waits briefly so a
        // hit never flashes a spinner over an image already on screen.
        let badge = Task {
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { showsProgress = true }
        }
        defer { badge.cancel(); showsProgress = false }
        do {
            let output = try await loader.open(file)
            Self.log.notice("[ImageOpen] cache=\(output.isCacheHit ? "hit" : "miss", privacy: .public)")
            let target = Self.targetPixelSize(container: container, displayScale: displayScale)
            // ImageIO downsamples off the main actor; the thumbnail stays on
            // screen until the original is ready to swap in.
            let data = await Task.detached(priority: .userInitiated) {
                ChatImageThumbnail.make(url: output.url, maxPixelSize: target)
            }.value
            guard !Task.isCancelled else { return }
            guard let data, let decoded = UIImage(data: data) else {
                throw AttachmentImageDownloadError.downloadUnreadable
            }
            fullResolutionURL = output.url
            image = decoded
            Self.log.notice("[ImageOpen] tap→fullres \(Self.milliseconds(since: tappedAt), privacy: .public) ms")
        } catch is CancellationError {
            // The sheet went away, or a retry replaced this attempt.
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            Self.log.notice("[ImageOpen] fullres failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Long-edge pixel cap for the full-resolution decode: ≈2× the container's
    /// short edge (the screen width) in device pixels — a full-screen image at
    /// 2× display scale. This is the memory guard for 25 MiB originals: the
    /// decode never allocates the unclamped original.
    private static func targetPixelSize(container: CGSize, displayScale: CGFloat) -> Int {
        let shortEdge = min(container.width, container.height)
        guard shortEdge.isFinite, shortEdge > 0, displayScale.isFinite, displayScale > 0 else {
            return ChatImageThumbnail.defaultMaximumPixelSize
        }
        return max(1, Int((shortEdge * displayScale * 2).rounded()))
    }

    private static func milliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }
}
