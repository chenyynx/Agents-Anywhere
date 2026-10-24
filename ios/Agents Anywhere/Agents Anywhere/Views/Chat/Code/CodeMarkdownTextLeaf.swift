#if canImport(UIKit)
import SwiftUI
import UIKit

/// The Code page's Markdown text block, built the way the official page builds
/// it: a `UIViewRepresentable` whose synchronous `sizeThatFits` measures the
/// same TextKit document that draws it.
///
/// Official evidence: the Code row is a `UIHostingConfiguration` and SwiftUI
/// asks `MarkdownTextLeafRepresentable` for its size through the
/// `UIViewRepresentable` size witness; the leaf consults its TextKit
/// measurement (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md:149`,
/// `CANONICAL/05-layout-scroll.md:102`). Because the measurement is synchronous,
/// the first fit already sees the real body — the official cell never corrects
/// a settled row.
///
/// The document parser and block views are the ones the Chat page and
/// `CodeMessageHeightMeasurer` already use. That makes the height the first fit
/// reports equal to the height the layout stores, so no later correction (the
/// 3 pt / 1900 pt family) is produced.
struct CodeMarkdownTextLeaf: UIViewRepresentable {
    let text: String
    /// The adapter's typography snapshot. Production always passes it; the
    /// fallback keeps previews and gates honest when they build the row
    /// directly.
    var typography: TimelineTypographySnapshot?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(text: String, typography: TimelineTypographySnapshot?) {
        self.text = text
        self.typography = typography
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var document: AssistantMarkdownDocument?
        var documentKey = ""
    }

    private var snapshot: TimelineTypographySnapshot {
        if let typography { return typography }
        return TimelineChatContentAdapter.typography(
            dynamicType: String(describing: dynamicTypeSize),
            layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
            boldText: legibilityWeight == .bold)
    }

    private func document(in coordinator: Coordinator) -> AssistantMarkdownDocument? {
        let metrics = snapshot
        let key = "\(metrics.revision):\(text)"
        if coordinator.documentKey == key { return coordinator.document }
        let parsed = AssistantMarkdownDocumentParser.make(
            text: text, resolvesFileReferences: true, typography: metrics,
            codeStyle: CodePageTheme.codeCardStyle)
        coordinator.document = parsed
        coordinator.documentKey = key
        return parsed
    }

    func makeUIView(context: Context) -> CodeMarkdownTextStackView {
        let view = CodeMarkdownTextStackView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: CodeMarkdownTextStackView, context: Context) {
        let document = document(in: context.coordinator)
        uiView.install(document: document,
                       key: context.coordinator.documentKey,
                       displayScale: max(displayScale, 1))
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: CodeMarkdownTextStackView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        guard let document = document(in: context.coordinator) else {
            return CGSize(width: width, height: 0)
        }
        let height = ceil(AssistantMarkdownTextLayout.measure(
            document, width: width, displayScale: max(displayScale, 1)))
        return CGSize(width: width, height: height)
    }
}

/// The UIKit content of one `CodeMarkdownTextLeaf`: the document's blocks in a
/// vertical stack, each at the height `AssistantMarkdownTextLayout` measured.
/// The heights are constraints, exactly like `AssistantMarkdownCell`, so the
/// rendered layout and the value returned by `sizeThatFits` are the same
/// arithmetic.
final class CodeMarkdownTextStackView: UIView {
    private let stack = UIStackView()
    private var heightConstraints: [NSLayoutConstraint] = []
    private var document: AssistantMarkdownDocument?
    private var documentKey = ""
    private var displayScale: CGFloat = 2
    private var builtWidth: CGFloat = -1
    private var builtKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        isOpaque = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        // The stack's height is the document measurement; the representable's
        // frame is that number too. Keep the pin below required so a subpixel
        // difference cannot break the layout.
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The latest document. Building happens on the next layout pass, when the
    /// representable has its real width.
    func install(document: AssistantMarkdownDocument?, key: String, displayScale: CGFloat) {
        self.document = document
        self.documentKey = key
        self.displayScale = displayScale
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        guard abs(width - builtWidth) > 0.5 || documentKey != builtKey else { return }
        builtWidth = width
        builtKey = documentKey
        rebuild(width: width)
    }

    private func rebuild(width: CGFloat) {
        for constraint in heightConstraints { constraint.isActive = false }
        heightConstraints.removeAll()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let document else { return }
        for block in document.blocks {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: width, displayScale: displayScale)
            stack.addArrangedSubview(made.view)
            let constraint = made.view.heightAnchor.constraint(equalToConstant: made.height)
            constraint.isActive = true
            heightConstraints.append(constraint)
        }
        // Textual collapses adjacent block margins (max, not sum); the
        // measurement path uses the same rule, so the stack must too.
        for index in 1..<max(1, document.blocks.count) {
            guard stack.arrangedSubviews.indices.contains(index - 1) else { break }
            stack.setCustomSpacing(
                AssistantMarkdownTextLayout.topLevelSpacing(after: index - 1, in: document),
                after: stack.arrangedSubviews[index - 1])
        }
    }
}
#endif
