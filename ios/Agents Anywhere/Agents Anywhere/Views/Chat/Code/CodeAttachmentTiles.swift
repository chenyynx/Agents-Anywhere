import Foundation
import SwiftUI
import UIKit

// The Code page's user-attachment image grid, drawn outside the text bubble.
//
// Every value here comes from CLOSURE.md §1 (Claude iOS 1.261005.20): square
// 140x140, wide 288x140, one large tile capped at 200x200 with its aspect
// clamped to 2/3-3/2, 8 pt grid spacing, 14 pt continuous corners, and the
// count-only layout rule (1 large / 2 squares / 2x2 / first four with `+N` on
// the fourth). Three items has three official shapes: wide on top, wide on
// the bottom, or 2+1 squares when the predicate hits neither end. The geometry
// is shared with the height measurer through `CodeAttachmentLayout`, so the
// first fit and the settled row cannot disagree.

/// The official `AttachmentDisplayState` (CLOSURE.md §1, CORRECTIONS #85):
/// only `complete` and `displayOnly` draw no overlay; `inFlight` adds the ring,
/// `failed` adds the warning glyph, and `unopenable` keeps the plain scrim.
nonisolated enum CodeAttachmentDisplayState: Equatable, Sendable {
    case inFlight
    case complete
    case failed
    case unopenable
    case displayOnly
}

/// The tile geometry every attachment surface draws with. Sizes come from
/// `CodeAttachmentLayout` (the measurer's source of truth); the 14 pt
/// continuous corner is CLOSURE.md §1 (E) but has no counterpart there yet.
nonisolated enum CodeAttachmentTileMetrics {
    static let cornerRadius: CGFloat = 14
    static let square = CGSize(width: CodeAttachmentLayout.squareSide,
                               height: CodeAttachmentLayout.squareSide)
    static let wide = CGSize(width: CodeAttachmentLayout.wideWidth,
                             height: CodeAttachmentLayout.squareSide)
    /// A file has no pixel size, so the official card is the square 140 pt
    /// tile (verified from the device screenshots: the single-file card is
    /// 140x140, not the image `large` box).
    static let largeFile = CGSize(width: CodeAttachmentLayout.squareSide,
                                  height: CodeAttachmentLayout.squareSide)
}

/// The official `AttachmentTileLayout` row shapes
/// (`attachment-tiles-arrangement.md` §1, E). Three items is the only count
/// with three shapes: the wide row sits on the side the official predicate
/// selects, and when neither the first nor the last item is wide the grid
/// falls through to two squares plus one trailing square (a leading Color
/// filler aligns it with the right edge).
///
/// The predicate body (`0x101895bf4`) is still U. This client reads the same
/// `pixelSize` the tile draws with and treats "landscape" (`width > height`)
/// as the wide hit; a file with no pixel size is never wide. That matches the
/// evidence's acceptance rule ("no pixelSize → 2+1") and keeps the three
/// official branches representable.
nonisolated enum CodeAttachmentGridPlan {
    nonisolated enum TileSize: Sendable {
        case square
        case wide
        case large
    }

    nonisolated struct Placement: Identifiable, Equatable, Sendable {
        let index: Int
        let size: TileSize
        /// `items.dropFirst(4).count` on the fourth tile, nil elsewhere
        /// (CLOSURE.md §1: `N = 总数 - 4`).
        let overflow: Int?

        var id: Int { index }

        /// The official `GridRow` is `(Color?) + AttachmentTile`: a leading
        /// filler pushes the 2+1 fallback's single square to the trailing
        /// edge, matching the user row's right alignment (the `edge` field is
        /// E; the filler side is I). Filler placements carry index -1.
        var isFiller: Bool { index < 0 }
    }

    /// The [I] reading of the unresolved three-item predicate: a landscape
    /// pixel size selects the wide row; a missing/non-positive size does not.
    /// Kept here so the gate can pin the predicate without a hosted view.
    static func isWide(pixelSize: CGSize?) -> Bool {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return false
        }
        return pixelSize.width > pixelSize.height
    }

    static func rows(count: Int,
                     wideFirst: Bool = false,
                     wideLast: Bool = false) -> [[Placement]] {
        switch count {
        case ..<1:
            return []
        case 1:
            return [[Placement(index: 0, size: .large, overflow: nil)]]
        case 2:
            return [[square(0), square(1)]]
        case 3:
            if wideFirst {
                return [[wide(0)], [square(1), square(2)]]
            }
            if wideLast {
                return [[square(0), square(1)], [wide(2)]]
            }
            return [[square(0), square(1)], [filler, square(2)]]
        case 4:
            return [[square(0), square(1)], [square(2), square(3)]]
        default:
            return [[square(0), square(1)],
                    [square(2), Placement(index: 3, size: .square, overflow: count - 4)]]
        }
    }

    private static func square(_ index: Int) -> Placement {
        Placement(index: index, size: .square, overflow: nil)
    }

    private static func wide(_ index: Int) -> Placement {
        Placement(index: index, size: .wide, overflow: nil)
    }

    private static var filler: Placement {
        Placement(index: -1, size: .square, overflow: nil)
    }
}

/// The shared official tile grid: `Grid(alignment: .center)` with 8 pt
/// spacing, pinned to the trailing edge of the row content (CLOSURE.md §1/§4).
struct CodeAttachmentGrid<Content: View>: View {
    let rows: [[CodeAttachmentGridPlan.Placement]]
    let content: (CodeAttachmentGridPlan.Placement) -> Content

    /// The memberwise initializer would not carry the builder attribute into
    /// the closure parameter, so the `if` inside a tile closure is only legal
    /// through this explicit builder parameter.
    init(rows: [[CodeAttachmentGridPlan.Placement]],
         @ViewBuilder content: @escaping (CodeAttachmentGridPlan.Placement) -> Content) {
        self.rows = rows
        self.content = content
    }

    var body: some View {
        Grid(alignment: .center,
             horizontalSpacing: CodeAttachmentLayout.tileSpacing,
             verticalSpacing: CodeAttachmentLayout.tileSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { placement in
                        content(placement)
                            // The wide tile occupies the two square columns, so
                            // its row is 288 pt wide, not 288 + 140
                            // (CLOSURE.md §1).
                            .gridCellColumns(placement.size == .wide ? 2 : 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One message's image attachments, in the official grid shape.
struct CodeAttachmentTiles: View {
    let files: [ChatMessageAttachment]
    var state: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }

    var body: some View {
        let rows = CodeAttachmentGridPlan.rows(count: files.count,
                                               wideFirst: isWide(files.first),
                                               wideLast: isWide(files.last))
        CodeAttachmentGrid(rows: rows) { placement in
            if placement.isFiller {
                Color.clear
            } else if files.indices.contains(placement.index) {
                CodeAttachmentImageTile(
                    file: files[placement.index],
                    placement: placement,
                    state: state(files[placement.index].content),
                    onAttachment: onAttachment,
                    loadThumbnail: loadThumbnail)
            }
        }
    }

    /// The official three-item predicate is U (`0x101895bf4`); "landscape"
    /// is the natural reading of the wide row. A missing size is not wide,
    /// which sends three files (and three size-less images) to the 2+1
    /// branch the evidence records.
    private func isWide(_ file: ChatMessageAttachment?) -> Bool {
        guard let file else { return false }
        let size = file.previewPixelSize ?? file.content.serverPixelSize
        return CodeAttachmentGridPlan.isWide(pixelSize: size)
    }
}

/// One image tile: the decoded thumbnail cropped to the tile box, the state
/// overlay, and the `+N` count on the fourth tile when the grid overflows.
private struct CodeAttachmentImageTile: View {
    let file: ChatMessageAttachment
    let placement: CodeAttachmentGridPlan.Placement
    let state: CodeAttachmentDisplayState
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let loadThumbnail: (V2AttachmentContent) async throws -> Data?

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var retry = 0
    /// The request whose bytes produced `image`. A hosted cell can be
    /// reconfigured for a different message at the same placement index, so
    /// the tile must reload when the file key changes instead of keeping the
    /// previous row's image (`image != nil` alone cannot tell them apart).
    @State private var loadedRequest: Request?
    @Environment(\.displayScale) private var displayScale

    private var tileSize: CGSize {
        switch placement.size {
        case .square:
            return CodeAttachmentTileMetrics.square
        case .wide:
            return CodeAttachmentTileMetrics.wide
        case .large:
            // The large slot is a 200 pt box with the image's aspect clamped
            // to 2/3-3/2; a missing size reads as 4:3 (CLOSURE.md §1). The
            // measurer uses the same function, so the box cannot change after
            // the first frame.
            let height = CodeAttachmentLayout.largeImageHeight(pixelSize: sourcePixelSize)
            let aspect = layoutAspectRatio
            return CGSize(width: height * aspect, height: height)
        }
    }

    /// A locally decoded preview size wins over the server's metadata: it is
    /// the exact size of the bytes this tile draws (CLOSURE.md §1, task §3.4).
    private var sourcePixelSize: CGSize? {
        file.previewPixelSize ?? file.content.serverPixelSize
    }

    private var layoutAspectRatio: CGFloat {
        guard let size = sourcePixelSize, size.width > 0, size.height > 0 else {
            return CodeAttachmentLayout.defaultImageAspect
        }
        return min(max(size.width / size.height,
                       CodeAttachmentLayout.minimumImageAspect),
                   CodeAttachmentLayout.maximumImageAspect)
    }

    private var accessibilityLabel: Text {
        // Keep the file name as the label even when the tile failed. The
        // card's `upload_failed` key is E, but the tile-overlay's own key is
        // U (`attachment-badge-failure-deep.md` §3.3 note); the failure goes
        // into the value so the only identifying text is not discarded.
        Text(verbatim: file.content.name ?? String(localized: "图片附件"))
    }

    private var accessibilityValue: Text {
        state == .failed
            ? Text(verbatim: String(localized: "upload_failed"))
            : Text(verbatim: "")
    }

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                // [I] The official loading placeholder is not in CLOSURE.md;
                // the tinted fill only keeps the tile visible before decode.
                Color(.secondarySystemFill)
                if let image {
                    Image(uiImage: image)
                        // CLOSURE.md §1 / CORRECTIONS #80: resizable
                        // stretchy + aspectRatio + Rectangle crop, centered,
                        // contentMode fill.
                        .resizable(resizingMode: .stretch)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileSize.width, height: tileSize.height)
                        .clipped()
                }
                // The official tile chooses one overlay: a grid that
                // overflows uses `TileCountOverlay` (which carries its own
                // status child), not the state overlay plus a separate +N.
                if let overflow = placement.overflow {
                    CodeAttachmentCountOverlay(count: overflow, state: state)
                } else {
                    CodeAttachmentStateOverlay(state: state)
                }
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: CodeAttachmentTileMetrics.cornerRadius,
                                        style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CodeAttachmentTileMetrics.cornerRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .task(id: request) { await load() }
    }

    private var request: Request {
        // `previewVersion` lets a preview that lands in the cache after a
        // failed load re-run the task by itself.
        Request(key: file.content.cacheKey,
                retry: retry,
                previewVersion: file.previewVersion,
                maxPixelSize: ChatImageThumbnail.maximumPixelSize(
                    for: tileSize, displayScale: displayScale))
    }

    private func handleTap() {
        if loadFailed && image == nil {
            loadFailed = false
            retry += 1
        } else {
            onAttachment(file.content, image)
        }
    }

    private func load() async {
        let current = request
        guard loadedRequest != current else { return }
        if loadedRequest?.key != current.key {
            image = nil
            loadFailed = false
        }
        do {
            let sourceData: Data
            if let previewData = file.previewData {
                sourceData = previewData
            } else {
                guard let data = try await loadThumbnail(file.content) else {
                    loadFailed = true
                    loadedRequest = current
                    return
                }
                sourceData = data
            }
            let maxPixelSize = current.maxPixelSize
            let data = await Task.detached(priority: .utility) {
                ChatImageThumbnail.make(data: sourceData, maxPixelSize: maxPixelSize) ?? sourceData
            }.value
            guard !Task.isCancelled else { return }
            let decoded = UIImage(data: data)
            image = decoded
            loadFailed = decoded == nil
            loadedRequest = current
        } catch {
            if !Task.isCancelled {
                loadFailed = true
                loadedRequest = current
            }
        }
    }

    private struct Request: Equatable {
        let key: String
        let retry: Int
        let previewVersion: Int
        let maxPixelSize: Int
    }
}

/// The `+N` overlay (`TileCountOverlay`). Its body is a VStack of a status
/// child and the count text with 4 pt spacing
/// (`attachment-tiles-overlay.md` §一屏: `VStack<TupleView<
/// _ConditionalContent<ProgressView…, Anthropicon…>, Text>>`, spacing 4.0).
/// The count text is white, 20 pt / 500 / 28 pt line height in Anthropic
/// Sans, always signed through `IntegerFormatStyle`, and the overlay has no
/// scrim of its own (CLOSURE.md §1, CORRECTIONS #78).
///
/// The non-in-flight status child is U; this client keeps the ring for
/// `.inFlight`, the warning glyph for `.failed`, and leaves the other states
/// text-only instead of inventing an icon.
struct CodeAttachmentCountOverlay: View {
    let count: Int
    var state: CodeAttachmentDisplayState = .complete

    @ScaledMetric(relativeTo: .title3) private var fontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var lineHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 4) {
            status
            Text(verbatim: Self.text(count))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: fontSize, weight: 500)))
                .foregroundStyle(.white)
                .frame(height: lineHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .inFlight:
            CodeAttachmentUploadRing()
        case .failed:
            AnthropiconView(name: "anthropicon.warning", size: .large)
                .foregroundStyle(.white)
        case .complete, .displayOnly, .unopenable:
            EmptyView()
        }
    }

    /// `+N`, not `N`: the official number style always displays the sign
    /// (CLOSURE.md §1: E).
    static func text(_ count: Int) -> String {
        var style = IntegerFormatStyle<Int>.number
        style = style.sign(strategy: .always(includingZero: true))
        return count.formatted(style)
    }
}

/// The official state scrim. `inFlight`, `failed` and `unopenable` paint
/// `Color.black.opacity(0.5)`; `failed` adds the warning glyph; `complete` and
/// `displayOnly` draw nothing (CLOSURE.md §1, CORRECTIONS #85).
struct CodeAttachmentStateOverlay: View {
    let state: CodeAttachmentDisplayState

    var body: some View {
        switch state {
        case .complete, .displayOnly:
            EmptyView()
        case .inFlight:
            ZStack {
                scrim
                CodeAttachmentUploadRing()
            }
        case .failed:
            ZStack {
                scrim
                AnthropiconView(name: "anthropicon.warning", size: .large)
                    .foregroundStyle(.white)
            }
        case .unopenable:
            scrim
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.5)
    }
}

/// The in-flight indicator: a 24 pt ring, 3 pt stroke, white on a 0.3 white
/// track (CLOSURE.md §1: 上传态).
private struct CodeAttachmentUploadRing: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                           value: spinning)
        }
        .frame(width: 24, height: 24)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}
