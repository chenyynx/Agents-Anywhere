import ImageIO
import PencilKit
import SwiftUI
import UIKit

/// Markup editor for an image that is already staged in the composer.
///
/// Official shape (Claude 1.261023.20): a staged image is `EditableImage.staged`;
/// `AttachmentGalleryModel.onEditRequested` opens `ImageEditorModel`, whose
/// `ImageEditor` hosts a PencilKit `MarkupCanvasView` / `PKToolPicker` with
/// undo/redo and an async save. Saving returns fresh image data (`onSave:
/// (Data, UTType) async`), and the staged attachment is replaced.
///
/// AA keeps the same interaction but without the gallery hop the official app
/// uses for sent images: tapping a composer image tile opens this editor
/// directly, and saving replaces that attachment in the draft.
struct ComposerImageEditor: View {
    let attachment: ChatAttachment
    let onSave: (ChatAttachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isAnimated = false
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var isSaving = false
    @State private var showsDiscard = false
    @State private var showsSaveError = false
    @State private var canvasHandle = MarkupCanvasHandle()

    private static let maximumPreviewPixelSize = 960
    /// Cap the flattened bitmap so a 48 MP original cannot allocate a ~200 MB
    /// RGBA buffer just to save a doodle.
    private static let maximumFlattenPixelSize: CGFloat = 4096

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            floatingTopBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if isSaving {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(24)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .task(id: attachment.id) { await load() }
        .confirmationDialog(String(localized: "放弃标记？"), isPresented: $showsDiscard,
                            titleVisibility: .visible) {
            Button(String(localized: "放弃"), role: .destructive) { dismiss() }
            Button(String(localized: "继续编辑"), role: .cancel) {}
        }
        .alert(String(localized: "无法保存标记"), isPresented: $showsSaveError) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(String(localized: "请重试。"))
        }
    }

    /// Floating controls over the image, with no navigation-bar band: the
    /// official editor keeps the canvas edge-to-edge and the tools on glass.
    /// No live title: a screenshot being edited can already contain the app's
    /// own "标记" header, and a second title makes it read as two layers.
    private var floatingTopBar: some View {
        HStack(spacing: 8) {
            floatingButton(action: requestDismiss) {
                AppSymbol("xmark", size: 20)
            }
            .accessibilityLabel(String(localized: "关闭"))
            Spacer(minLength: 8)
            floatingButton(action: { canvasHandle.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .medium))
            }
            .disabled(!canUndo)
            .opacity(canUndo ? 1 : 0.45)
            .accessibilityLabel(String(localized: "撤销"))
            floatingButton(action: { canvasHandle.redo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .medium))
            }
            .disabled(!canRedo)
            .opacity(canRedo ? 1 : 0.45)
            .accessibilityLabel(String(localized: "重做"))
            floatingButton(action: save) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
            }
            .disabled(image == nil || isAnimated || isSaving)
            .opacity((image == nil || isAnimated || isSaving) ? 0.45 : 1)
            .accessibilityLabel(String(localized: "保存"))
        }
    }

    private func floatingButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            if isAnimated {
                unavailable(String(localized: "动画图片暂不支持编辑"))
            } else {
                GeometryReader { proxy in
                    let fitted = Self.fittedSize(image.size, in: proxy.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .allowsHitTesting(false)
                        MarkupCanvas(drawing: $drawing,
                                     canUndo: $canUndo,
                                     canRedo: $canRedo,
                                     handle: canvasHandle)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .onAppear { canvasSize = fitted }
                    .onChange(of: fitted) { _, size in canvasSize = size }
                }
            }
        } else if failed {
            unavailable(String(localized: "无法打开这张图片"))
        } else {
            ProgressView().tint(.white)
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28))
            Text(message).font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private func requestDismiss() {
        if drawing.strokes.isEmpty {
            dismiss()
        } else {
            showsDiscard = true
        }
    }

    private func save() {
        guard let image, !isSaving, canvasSize.width > 0, canvasSize.height > 0 else { return }
        isSaving = true
        let drawing = drawing
        let size = canvasSize
        let source = attachment
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Self.flatten(image: image, drawing: drawing, canvasSize: size)
            }.value
            isSaving = false
            guard let result else {
                showsSaveError = true
                return
            }
            onSave(ChatAttachment(
                id: source.id,
                name: Self.pngName(for: source.name),
                data: result.data,
                mediaType: "image/png",
                previewData: result.preview,
                pixelSize: result.pixelSize))
            dismiss()
        }
    }

    private func load() async {
        let data = attachment.data
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, Bool) in
            guard let image = UIImage(data: data) else { return (nil, false) }
            let animated = Self.isAnimated(data)
            return (image.preparingForDisplay() ?? image, animated)
        }.value
        image = loaded.0
        isAnimated = loaded.1
        failed = loaded.0 == nil
    }

    // MARK: - Rendering

    private static func pngName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base.isEmpty ? "image" : base).png"
    }

    private nonisolated static func fittedSize(_ imageSize: CGSize, in available: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private nonisolated static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Draws the original image and the vector canvas into one bitmap at the
    /// image's own pixel size. The canvas' point size is the display size; the
    /// scale factor carries its strokes up to the original resolution.
    private nonisolated static func flatten(
        image: UIImage,
        drawing: PKDrawing,
        canvasSize: CGSize
    ) -> (data: Data, preview: Data?, pixelSize: CGSize)? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let outputScale = min(1, maximumFlattenPixelSize / max(pixelWidth, pixelHeight))
        let target = CGSize(width: (pixelWidth * outputScale).rounded(),
                            height: (pixelHeight * outputScale).rounded())
        guard target.width > 0, target.height > 0 else { return nil }

        let drawingScale = target.width / canvasSize.width
        let drawingImage = drawing.image(
            from: CGRect(origin: .zero, size: canvasSize), scale: drawingScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
            drawingImage.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = flattened.pngData() else { return nil }
        let preview = ChatImageThumbnail.make(data: data, maxPixelSize: maximumPreviewPixelSize)
        return (data, preview, target)
    }
}

/// Small handle so the SwiftUI toolbar can drive the canvas' own undo manager.
@MainActor
final class MarkupCanvasHandle {
    weak var canvas: PKCanvasView?

    func undo() { canvas?.undoManager?.undo() }
    func redo() { canvas?.undoManager?.redo() }
}

private struct MarkupCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var canUndo: Bool
    @Binding var canRedo: Bool
    let handle: MarkupCanvasHandle

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.tool = PKInkingTool(.pen, color: .red, width: 4)
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        handle.canvas = canvas
        context.coordinator.presentToolPickerIfNeeded(on: canvas)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: MarkupCanvas
        private var toolPicker: PKToolPicker?

        init(_ parent: MarkupCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            refreshUndoState(canvasView)
        }

        func presentToolPickerIfNeeded(on canvas: PKCanvasView) {
            guard toolPicker == nil, canvas.window != nil else { return }
            let picker = PKToolPicker()
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
            toolPicker = picker
            DispatchQueue.main.async { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.refreshUndoState(canvas)
            }
        }

        func refreshUndoState(_ canvas: PKCanvasView) {
            let undo = canvas.undoManager?.canUndo ?? false
            let redo = canvas.undoManager?.canRedo ?? false
            if parent.canUndo != undo { parent.canUndo = undo }
            if parent.canRedo != redo { parent.canRedo = redo }
        }
    }
}
