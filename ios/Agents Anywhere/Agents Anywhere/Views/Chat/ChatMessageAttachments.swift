import SwiftUI
import UIKit

struct ChatMessageAttachments: View {
    let files: [ChatMessageAttachment]
    let onOpen: (V2AttachmentContent) -> Void
    let loadThumbnail: (V2AttachmentContent) async throws -> Data?
    var alignment: HorizontalAlignment = .trailing
    var isOutgoing = false

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            if isOutgoing {
                ForEach(outgoingGroups) { group in
                    switch group {
                    case let .images(images):
                        if images.count == 1, let file = images.first {
                            ChatMessageImage(file: file, onOpen: onOpen, loadThumbnail: loadThumbnail, layout: .outgoing)
                        } else {
                            ChatMessageImageGrid(files: images, onOpen: onOpen, loadThumbnail: loadThumbnail)
                        }
                    case let .file(file):
                        ChatMessageFileAttachment(file: file.content, onOpen: onOpen)
                    }
                }
            } else {
                ForEach(files) { file in
                    if file.content.isImage {
                        ChatMessageImage(file: file, onOpen: onOpen, loadThumbnail: loadThumbnail, layout: .received)
                    } else {
                        ChatMessageFileAttachment(file: file.content, onOpen: onOpen)
                    }
                }
            }
        }
    }

    private var outgoingGroups: [AttachmentGroup] {
        var groups: [AttachmentGroup] = []
        var imageRun: [ChatMessageAttachment] = []
        for file in files {
            if file.content.isImage {
                imageRun.append(file)
            } else {
                if !imageRun.isEmpty { groups.append(.images(imageRun)); imageRun = [] }
                groups.append(.file(file))
            }
        }
        if !imageRun.isEmpty { groups.append(.images(imageRun)) }
        return groups
    }

    private enum AttachmentGroup: Identifiable {
        case images([ChatMessageAttachment])
        case file(ChatMessageAttachment)

        var id: String {
            switch self {
            case let .images(files): "images:\(files.map(\.id).joined(separator: "|"))"
            case let .file(file): "file:\(file.id)"
            }
        }
    }
}

private struct ChatMessageFileAttachment: View {
    let file: V2AttachmentContent
    let onOpen: (V2AttachmentContent) -> Void

    var body: some View {
        Button { onOpen(file) } label: {
            HStack(spacing: 12) {
                AppSymbol(AppFileSymbol.name(for: file.name ?? ""), size: 24).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name ?? String(localized: "附件")).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                AppSymbol("arrow.up.right", size: 14).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: 320, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
                .contentShape(.rect(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var description: String {
        let ext = ((file.name ?? "") as NSString).pathExtension.uppercased()
        return [ext.isEmpty ? String(localized: "文件") : ext,
            file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ChatMessageImageGrid: View {
    let files: [ChatMessageAttachment]
    let onOpen: (V2AttachmentContent) -> Void
    let loadThumbnail: (V2AttachmentContent) async throws -> Data?

    private var columns: [GridItem] {
        let cellSize = ChatImageThumbnail.gridCellSize()
        return [GridItem(.fixed(cellSize), spacing: 4), GridItem(.fixed(cellSize), spacing: 4)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(files) { file in
                ChatMessageImage(file: file, onOpen: onOpen, loadThumbnail: loadThumbnail, layout: .square)
            }
        }
        .frame(maxWidth: ChatImageThumbnail.maximumBubbleWidth, alignment: .trailing)
    }
}

private enum ChatMessageImageLayout: Equatable {
    case outgoing
    case square
    case received
}

private struct ChatMessageImage: View {
    let file: ChatMessageAttachment
    let onOpen: (V2AttachmentContent) -> Void
    let loadThumbnail: (V2AttachmentContent) async throws -> Data?
    let layout: ChatMessageImageLayout
    @State private var image: UIImage?
    @State private var imagePixelSize: CGSize?
    @State private var visible = false
    @State private var failed = false
    @State private var retry = 0
    @Environment(\.displayScale) private var displayScale

    // Cached sender preview dimensions win, then the server's own metadata
    // (available before any decode), then the displayed image's size.
    private var sourcePixelSize: CGSize? { file.previewPixelSize ?? file.content.serverPixelSize ?? imagePixelSize }
    private var sourceAspectRatio: CGFloat? {
        guard let size = sourcePixelSize, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
    private var frameSize: CGSize {
        switch layout {
        case .outgoing:
            if let sourcePixelSize, let size = ChatImageThumbnail.bubbleSize(for: sourcePixelSize) { return size }
            return ChatImageThumbnail.bubbleSize(forAspectRatio: 0.75) ?? CGSize(width: 240, height: 320)
        case .square:
            let side = ChatImageThumbnail.gridCellSize()
            return CGSize(width: side, height: side)
        case .received:
            return CGSize(width: 320, height: 240)
        }
    }
    private var maximumPixelSize: Int {
        ChatImageThumbnail.maximumPixelSize(for: frameSize, displayScale: displayScale)
    }
    private var topAlignedCrop: Bool {
        guard layout == .outgoing, let sourceAspectRatio else { return false }
        return ChatImageThumbnail.shouldAlignTop(for: sourceAspectRatio)
    }
    private var bubbleShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private var request: Request {
        // `previewVersion` is part of the identity so a preview written to the
        // cache after a failed load re-runs this task by itself.
        Request(visible: visible, key: file.content.cacheKey, retry: retry, maxPixelSize: maximumPixelSize,
            layout: layout, previewVersion: file.previewVersion)
    }

    var body: some View {
        Button(action: handleTap) {
            if layout == .received {
                receivedPreview
            } else {
                outgoingPreview
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(file.content.name ?? String(localized: "图片附件"))
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(id: request) { await loadPreview(maxPixelSize: request.maxPixelSize) }
    }

    private var receivedPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.6))
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Label(String(localized: "轻点重试预览"), appSymbol: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit).frame(maxWidth: 320)
        .clipShape(.rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }

    private var outgoingPreview: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: frameSize.width, height: frameSize.height, alignment: topAlignedCrop ? .top : .center)
                    .clipped()
            } else {
                bubbleShape.fill(.quaternary.opacity(0.6))
                if failed {
                    Label(String(localized: "轻点重试预览"), appSymbol: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.circular)
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(bubbleShape)
        .contentShape(bubbleShape)
        .overlay { bubbleShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
    }

    private func handleTap() {
        if failed && image == nil { failed = false; retry += 1 }
        else { onOpen(file.content) }
    }

    private func loadPreview(maxPixelSize: Int) async {
        guard image == nil else { return }
        do {
            let sourceData: Data
            if let previewData = file.previewData {
                // A locally cached preview is available immediately, so it loads
                // without waiting for the scroll-visibility probe (the old
                // onAppear semantics); remote fetches still wait for visibility.
                sourceData = previewData
            } else {
                guard visible else { return }
                guard let data = try await loadThumbnail(file.content) else { failed = true; return }
                sourceData = data
            }
            let data = await Task.detached(priority: .utility) {
                ChatImageThumbnail.make(data: sourceData, maxPixelSize: maxPixelSize) ?? sourceData
            }.value
            guard !Task.isCancelled else { return }
            let decoded = UIImage(data: data)
            image = decoded
            imagePixelSize = ChatImageThumbnail.imageSize(data: data)
                ?? decoded.map { CGSize(width: $0.size.width, height: $0.size.height) }
            failed = decoded == nil
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private struct Request: Equatable {
        let visible: Bool
        let key: String
        let retry: Int
        let maxPixelSize: Int
        let layout: ChatMessageImageLayout
        let previewVersion: Int
    }
}

struct ChatComposerAttachment: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void
    @State private var image: UIImage?
    var body: some View {
        Group {
            if attachment.isImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { AppSymbol("photo").foregroundStyle(.secondary) }
                }.frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 12))
            } else {
                HStack(spacing: 8) {
                    AppSymbol(AppFileSymbol.name(for: attachment.name), size: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.name).font(.caption.weight(.medium)).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: 140, alignment: .leading)
                }.padding(.horizontal, 12).padding(.trailing, 20).frame(height: 72)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 12))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                AppSymbol("xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7)).font(.system(size: 19))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).offset(x: 9, y: -9).accessibilityLabel(String(localized: "移除 \(attachment.name)"))
        }
        .task(id: attachment.id) {
            if let data = attachment.previewData { image = UIImage(data: data) }
        }
        .accessibilityLabel(attachment.name)
    }
}
