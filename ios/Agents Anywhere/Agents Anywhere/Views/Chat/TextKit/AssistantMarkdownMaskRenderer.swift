#if canImport(UIKit)
import QuartzCore
import UIKit

/// TextKit 2 line geometry + CALayer mask for the official Chat-style reveal.
///
/// The mask and the height come from the same `NSTextLayoutManager` that lays
/// out the text view, so this path has no cross-engine measurement. The cell
/// still installs an explicit height constraint from the same layout manager;
/// the mask only controls which characters are visible.
@MainActor
enum AssistantMarkdownMaskRenderer {
    /// Per-line rectangles for the given UTF-16 range, in the text view's
    /// coordinate space.
    static func lineRects(for range: NSRange, in textView: UITextView) -> [CGRect] {
        guard range.length > 0,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location,
                                           offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              end.compare(start) != .orderedSame else { return [] }
        let textRange = NSTextRange(location: start, end: end)
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
            _, frame, _, _ in
            rects.append(frame.offsetBy(dx: textView.textContainerInset.left,
                                        dy: textView.textContainerInset.top))
            return true
        }
        return rects
    }

    /// New shape layer for one reveal run. The caller adds it to the text
    /// view's existing mask container; the layer fades 0 → 1 over 0.6 s with
    /// ease-out and stays visible afterwards.
    static func makeRunLayer(rects: [CGRect],
                             in textView: UITextView,
                             fadeDuration: CFTimeInterval = 0.6) -> CAShapeLayer? {
        guard !rects.isEmpty else { return nil }
        let shape = CAShapeLayer()
        shape.frame = textView.bounds
        let path = CGMutablePath()
        path.addRects(rects)
        shape.path = path
        shape.fillColor = UIColor.black.cgColor

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        shape.add(fade, forKey: "reveal")
        return shape
    }

    /// Install a mask container for the text view and append one run layer.
    /// Existing layers stay (official behavior: normal reveal only adds).
    @discardableResult
    static func appendRun(rects: [CGRect],
                          to textView: UITextView,
                          mask: CALayer,
                          fadeDuration: CFTimeInterval = 0.6) -> CAShapeLayer? {
        guard let layer = makeRunLayer(rects: rects, in: textView,
                                       fadeDuration: fadeDuration) else { return nil }
        if textView.layer.mask !== mask {
            mask.frame = textView.bounds
            textView.layer.mask = mask
        }
        mask.addSublayer(layer)
        return layer
    }

    static func makeMaskContainer(for textView: UITextView) -> CALayer {
        let mask = CALayer()
        mask.frame = textView.bounds
        return mask
    }
}
#endif
