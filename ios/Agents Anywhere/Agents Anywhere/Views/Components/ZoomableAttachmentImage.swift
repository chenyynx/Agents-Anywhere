import SwiftUI
import UIKit

/// Shared zoom/pan surface for full-screen image viewing: the markdown
/// preview and the attachment image viewer both render through it, so both
/// get the same pinch-to-zoom, panning and bounce behavior.
///
/// UIKit owns pinch-to-zoom, panning and bounce. Bounds changes preserve the
/// current zoom relative to the fitted image instead of adding SwiftUI gestures.
struct ZoomableAttachmentImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ImageScrollView { ImageScrollView(image: image) }
    func updateUIView(_ view: ImageScrollView, context: Context) {}

    final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
        private let imageView: UIImageView
        private var fittedBounds = CGSize.zero

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init(frame: .zero)
            delegate = self
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            bouncesZoom = true
            imageView.frame = CGRect(origin: .zero, size: image.size)
            addSubview(imageView)
            contentSize = image.size
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != fittedBounds, bounds.width > 0, bounds.height > 0,
               let size = imageView.image?.size, size.width > 0, size.height > 0 {
                let relativeZoom = fittedBounds == .zero ? 1 : zoomScale / minimumZoomScale
                fittedBounds = bounds.size
                let fit = min(bounds.width / size.width, bounds.height / size.height)
                minimumZoomScale = fit
                maximumZoomScale = fit * 6
                setZoomScale(min(maximumZoomScale, fit * relativeZoom), animated: false)
            }
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        private func centerImage() {
            imageView.center = CGPoint(x: max(bounds.width, contentSize.width) / 2,
                y: max(bounds.height, contentSize.height) / 2)
        }
    }
}
