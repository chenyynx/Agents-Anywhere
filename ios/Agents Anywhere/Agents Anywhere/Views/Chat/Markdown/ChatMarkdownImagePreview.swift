import SwiftUI
import Textual
import UIKit

struct ChatMarkdownImagePreview: View {
    let attachment: AnyAttachment
    let title: String
    @State private var image: UIImage?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableAttachmentImage(image: image).id(ObjectIdentifier(image))
                } else if loaded {
                    attachment.body.padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title.isEmpty ? String(localized: "查看图片") : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.expanded)
        .task(id: attachment) {
            let data = await Task.detached(priority: .userInitiated) { attachment.pngData() }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
            loaded = true
        }
    }
}

// The zoom/pan surface moved to Views/Components/ZoomableAttachmentImage.swift
// so the attachment image viewer shares the exact same component.
