#if canImport(UIKit)
import Textual
import UIKit

/// Builds the UIKit view for one block and returns the height it was laid out
/// at. Callers install the height as a required constraint, so the view, the
/// cell's content fitting and `TimelineListLayout` all read one number.
@MainActor
enum AssistantMarkdownBlockViewFactory {
    static func make(_ block: AssistantMarkdownBlock,
                     width: CGFloat,
                     displayScale: CGFloat) -> (view: UIView, height: CGFloat) {
        let height = AssistantMarkdownTextLayout.height(
            of: block, width: width, displayScale: displayScale)
        switch block {
        case .text(let text):
            let view = AssistantMarkdownBlockTextView()
            view.attributedText = text.attributed
            return (view, height)
        case .list(let list):
            return (AssistantListBlockView(list: list, width: width,
                                           displayScale: displayScale), height)
        case .quote(let quote):
            return (AssistantQuoteBlockView(quote: quote, width: width,
                                            displayScale: displayScale), height)
        case .code(let code):
            return (AssistantCodeBlockView(codeBlock: code, width: width,
                                           displayScale: displayScale), height)
        case .table(let table):
            return (AssistantTableBlockView(table: table, width: width,
                                            displayScale: displayScale), height)
        }
    }
}

/// One list block. Items are rows in a vertical stack; the marker lives in the
/// item's leading indent, and the item's blocks use the remaining width. This
/// is the same shape as Textual's `BlockVStack` of list items.
final class AssistantListBlockView: UIView {
    private let list: AssistantListBlock
    private let stack = UIStackView()
    private var rowHeights: [NSLayoutConstraint] = []

    init(list: AssistantListBlock, width: CGFloat, displayScale: CGFloat) {
        self.list = list
        super.init(frame: .zero)
        backgroundColor = .clear
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = list.itemSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])

        for item in list.items {
            let row = AssistantListItemRowView(item: item, list: list,
                                               width: width, displayScale: displayScale)
            stack.addArrangedSubview(row)
            let height = row.contentHeight
            let constraint = row.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            rowHeights.append(constraint)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One row: marker in the indent column, content stack in the text column.
final class AssistantListItemRowView: UIView {
    let contentHeight: CGFloat

    private let list: AssistantListBlock
    private let marker: AssistantListBlock.Marker
    private let contentIndent: CGFloat
    private let bullet = UIView()
    private let orderedLabel = UILabel()

    init(item: AssistantListBlock.Item,
         list: AssistantListBlock,
         width: CGFloat,
         displayScale: CGFloat) {
        self.list = list
        self.marker = item.marker
        self.contentIndent = list.contentIndent(for: item.marker)
        let contentWidth = max(0, width - contentIndent)
        self.contentHeight = AssistantMarkdownTextLayout.stackHeight(
            of: item.blocks, width: contentWidth,
            uniformSpacing: list.itemSpacing, displayScale: displayScale)
        super.init(frame: .zero)
        backgroundColor = .clear

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = list.itemSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentIndent),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        for block in item.blocks {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: contentWidth, displayScale: displayScale)
            stack.addArrangedSubview(made.view)
            made.view.heightAnchor.constraint(equalToConstant: made.height).isActive = true
        }

        switch item.marker {
        case .bullet:
            bullet.backgroundColor = list.markerColor
            bullet.layer.cornerRadius = list.bulletSize / 2
            bullet.isUserInteractionEnabled = false
            addSubview(bullet)
        case .ordered(let ordinal):
            orderedLabel.font = UIFont.monospacedDigitSystemFont(
                ofSize: list.bodySize, weight: .regular)
            orderedLabel.textColor = list.markerColor
            orderedLabel.textAlignment = .right
            orderedLabel.text = "\(ordinal)."
            addSubview(orderedLabel)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Textual aligns the marker's centre with the first text line's centre
        // (`HStack(alignment: .firstTextCenter)`). Line spacing only sits
        // between lines, so the first line is one font line box tall.
        let firstLineHeight = UIFont.systemFont(ofSize: list.bodySize).lineHeight
        let centerY = firstLineHeight / 2
        switch marker {
        case .bullet:
            bullet.frame = CGRect(
                x: list.bulletCenterX - list.bulletSize / 2,
                y: centerY - list.bulletSize / 2,
                width: list.bulletSize,
                height: list.bulletSize)
        case .ordered:
            let markerWidth = contentIndent - list.markerGap
            orderedLabel.frame = CGRect(
                x: 0,
                y: centerY - firstLineHeight / 2,
                width: markerWidth,
                height: firstLineHeight)
        }
    }
}

/// One quote block: a thin rule on the leading edge and the quoted blocks
/// inset by the product's 12pt padding. Nested quotes recurse through the same
/// factory and gain their own rule.
final class AssistantQuoteBlockView: UIView {
    private let quote: AssistantQuoteBlock
    private let bar = UIView()

    init(quote: AssistantQuoteBlock, width: CGFloat, displayScale: CGFloat) {
        self.quote = quote
        super.init(frame: .zero)
        backgroundColor = .clear

        bar.backgroundColor = ChatTextUIColors.quoteBar
        bar.layer.cornerRadius = quote.barWidth / 2
        bar.isUserInteractionEnabled = false
        addSubview(bar)

        let contentWidth = max(0, width - quote.inset)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: quote.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        for (index, block) in quote.blocks.enumerated() {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: contentWidth, displayScale: displayScale)
            stack.addArrangedSubview(made.view)
            made.view.heightAnchor.constraint(equalToConstant: made.height).isActive = true
            if index > 0 {
                stack.setCustomSpacing(
                    AssistantMarkdownTextLayout.spacing(
                        after: quote.blocks[index - 1], before: block),
                    after: stack.arrangedSubviews[index - 1])
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 0, width: quote.barWidth, height: bounds.height)
    }
}

/// The fenced-code card: a 36pt language header, a hairline divider, and a
/// horizontally scrolling code body. Long lines never wrap, so the block's
/// height is the code's intrinsic line stack plus the card chrome.
final class AssistantCodeBlockView: UIView {
    private let codeBlock: AssistantCodeBlock
    private let displayScale: CGFloat
    private let textSize: CGSize
    private let header = UIView()
    private let languageLabel = UILabel()
    private let divider = UIView()
    private let scrollView = UIScrollView()
    private let codeView = AssistantMarkdownBlockTextView()
    private let copyIcon = UIImageView()
    private let expandIcon = UIImageView()
    private var highlightTask: Task<Void, Never>?

    init(codeBlock: AssistantCodeBlock, width: CGFloat, displayScale: CGFloat) {
        self.codeBlock = codeBlock
        self.displayScale = displayScale
        self.textSize = AssistantMarkdownTextLayout.intrinsicSize(
            of: codeBlock.code, displayScale: displayScale)
        super.init(frame: .zero)
        backgroundColor = ChatTextUIColors.codeCardFill
        layer.cornerRadius = codeBlock.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        header.backgroundColor = .clear
        addSubview(header)

        divider.backgroundColor = ChatTextUIColors.codeHeaderDivider
        addSubview(divider)

        languageLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        languageLabel.textColor = ChatTextUIColors.codeHeaderLabel
        languageLabel.lineBreakMode = .byTruncatingTail
        languageLabel.text = (codeBlock.language?.isEmpty == false
            ? codeBlock.language! : "code").lowercased()
        header.addSubview(languageLabel)

        configureIcon(copyIcon, symbol: "document.on.document")
        configureIcon(expandIcon, symbol: "arrow.up.left.and.arrow.down.right")
        header.addSubview(copyIcon)
        header.addSubview(expandIcon)

        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        codeView.attributedText = codeBlock.code
        codeView.backgroundColor = .clear
        codeView.textContainer.widthTracksTextView = false
        scrollView.addSubview(codeView)
        startHighlighting()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The legacy renderer gets syntax colours from Textual's view layer. The
    /// TextKit path has no `StructuredText` view, so it asks the same Prism
    /// tokenizer for the token stream and applies the same AA palette.
    private func startHighlighting() {
        guard let language = codeBlock.language, !language.isEmpty else { return }
        let plain = codeBlock.code
        let source = plain.string
        highlightTask = Task { @MainActor [weak self] in
            let tokens = await SyntaxHighlighting.tokenize(
                code: source, language: language)
            guard let self, !Task.isCancelled,
                  tokens.map(\.content).joined() == source else { return }
            self.codeView.attributedText = Self.highlighted(
                tokens: tokens, base: plain)
        }
    }

    private static func highlighted(tokens: [SyntaxHighlightToken],
                                    base: NSAttributedString) -> NSAttributedString {
        guard base.length > 0,
              let baseAttributes = base.attributes(
                at: 0, effectiveRange: nil) as? [NSAttributedString.Key: Any] else {
            return base
        }
        let baseFont = baseAttributes[.font] as? UIFont
        let result = NSMutableAttributedString()
        for token in tokens {
            var attributes = baseAttributes
            if let color = color(for: token.type) {
                attributes[.foregroundColor] = color
            }
            if token.type == .keyword || token.type == .literal
                || token.type == .boolean, let baseFont {
                attributes[.font] = UIFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize, weight: .semibold)
            }
            result.append(NSAttributedString(
                string: token.content, attributes: attributes))
        }
        return result
    }

    private static func color(
        for type: StructuredText.HighlighterTheme.TokenType
    ) -> UIColor? {
        switch type {
        case .property, .variable:
            return ChatTextUIColors.synKey
        case .string, .char, .regex:
            return ChatTextUIColors.synString
        case .comment, .blockComment, .docComment:
            return ChatTextUIColors.synComment
        case .punctuation, .symbol:
            return ChatTextUIColors.synPunct
        case .keyword, .literal, .boolean:
            return ChatTextUIColors.synKeyword
        case .number:
            return ChatTextUIColors.synNumber
        case .className:
            return ChatTextUIColors.synType
        case .function, .functionName:
            return ChatTextUIColors.synFunction
        default:
            return nil
        }
    }

    private func configureIcon(_ view: UIImageView, symbol: String) {
        view.image = UIImage(systemName: symbol)
        view.tintColor = ChatTextUIColors.codeHeaderIcon
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : displayScale
        let dividerHeight = 1 / scale
        let width = bounds.width
        let bodyY = codeBlock.headerHeight + dividerHeight
        let bodyHeight = max(0, bounds.height - bodyY)

        header.frame = CGRect(x: 0, y: 0, width: width,
                              height: codeBlock.headerHeight)
        divider.frame = CGRect(x: 0, y: codeBlock.headerHeight,
                               width: width, height: dividerHeight)
        scrollView.frame = CGRect(x: 0, y: bodyY, width: width, height: bodyHeight)

        // Match `ChatMarkdownCodeBlock`: two 44pt header buttons inset 14pt.
        let iconSize: CGFloat = 15
        let iconY = (codeBlock.headerHeight - iconSize) / 2
        expandIcon.frame = CGRect(x: width - 14 - 22 - iconSize / 2,
                                  y: iconY, width: iconSize, height: iconSize)
        copyIcon.frame = CGRect(x: width - 14 - 44 - 22 - iconSize / 2,
                                y: iconY, width: iconSize, height: iconSize)
        let labelWidth = max(0, width - 14 - 88 - 8 - 14)
        languageLabel.frame = CGRect(x: 14, y: 0,
                                     width: labelWidth,
                                     height: codeBlock.headerHeight)

        let textWidth = max(1, textSize.width + 1)
        codeView.frame = CGRect(x: codeBlock.contentPadding,
                                y: codeBlock.contentPadding,
                                width: textWidth,
                                height: textSize.height)
        codeView.textContainer.size = CGSize(
            width: textWidth, height: .greatestFiniteMagnitude)
        let contentWidth = max(width,
            codeBlock.contentPadding * 2 + textWidth)
        scrollView.contentSize = CGSize(width: contentWidth, height: bodyHeight)

        layer.borderWidth = 1 / scale
        layer.borderColor = ChatTextUIColors.codeCardBorder
            .resolvedColor(with: traitCollection).cgColor
    }
}

/// The table surface: one view draws the whole table, the shape the official
/// chat transcript uses (`MarkdownTableView` with a single text surface and no
/// per-cell UIView). Cells are paragraphs in that surface; here they are drawn
/// directly, with accessibility elements standing in for the old labels.
final class AssistantTableBlockView: UIView {
    private let table: AssistantTableBlock
    private let displayScale: CGFloat
    private let scrollView = UIScrollView()
    private let surface: AssistantTableSurfaceView

    init(table: AssistantTableBlock, width: CGFloat, displayScale: CGFloat) {
        self.table = table
        self.displayScale = displayScale
        self.surface = AssistantTableSurfaceView(table: table, displayScale: displayScale)
        super.init(frame: .zero)
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        surface.frame = CGRect(origin: .zero,
                               size: CGSize(width: table.totalWidth,
                                            height: table.totalHeight))
        scrollView.contentSize = surface.frame.size
    }

    #if DEBUG
    var debugCellElementCount: Int { surface.debugCellElementCount }
    var debugSurfaceSubviewCount: Int { surface.subviews.count }
    var debugCellLabelCount: Int {
        var count = 0
        func walk(_ view: UIView) {
            if view is UILabel { count += 1 }
            view.subviews.forEach(walk)
        }
        walk(self)
        return count
    }
    #endif
}

/// Draws the header fill, row seams, cell text and the outer border in one
/// pass. Height still comes from `AssistantMarkdownTextLayout.tableMetrics`
/// (TextKit 2); this view only renders the attributed strings at the geometry
/// that measurement already fixed.
private final class AssistantTableSurfaceView: UIView {
    private let table: AssistantTableBlock
    private let displayScale: CGFloat
    private let columnOrigins: [CGFloat]
    private let rowOrigins: [CGFloat]

    init(table: AssistantTableBlock, displayScale: CGFloat) {
        self.table = table
        self.displayScale = displayScale
        var x: CGFloat = 0
        self.columnOrigins = table.columnWidths.map { width in
            defer { x += width }
            return x
        }
        var y: CGFloat = 0
        self.rowOrigins = table.rowHeights.map { height in
            defer { y += height }
            return y
        }
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        accessibilityElements = makeAccessibilityElements()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func cellBounds(row: Int, column: Int) -> CGRect {
        guard table.rowHeights.indices.contains(row),
              table.columnWidths.indices.contains(column) else { return .zero }
        return CGRect(x: columnOrigins[column], y: rowOrigins[row],
                      width: table.columnWidths[column],
                      height: table.rowHeights[row])
    }

    private func textRect(row: Int, column: Int) -> CGRect {
        cellBounds(row: row, column: column)
            .insetBy(dx: table.cellPaddingHorizontal,
                     dy: table.cellPaddingVertical)
    }

    private func makeAccessibilityElements() -> [Any] {
        var elements: [Any] = []
        for row in table.rows.indices {
            for column in table.rows[row].indices {
                let text = table.rows[row][column].string
                guard !text.isEmpty else { continue }
                elements.append(AssistantTableCellAccessibilityElement(
                    container: self, row: row, column: column,
                    label: text, frame: cellBounds(row: row, column: column)))
            }
        }
        return elements
    }

    #if DEBUG
    var debugCellElementCount: Int { accessibilityElements?.count ?? 0 }
    #endif

    override func draw(_ rect: CGRect) {
        guard !table.rowHeights.isEmpty, !table.columnWidths.isEmpty else { return }
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : displayScale
        let line = 1 / max(scale, 1)
        let radius = table.cornerRadius
        let clipPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius)

        clipPath.addClip()

        ChatTextUIColors.tableHeaderFill
            .resolvedColor(with: traitCollection).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: bounds.width,
                          height: table.rowHeights[0]))

        ChatTextUIColors.tableLine
            .resolvedColor(with: traitCollection).setFill()
        for row in 1..<table.rowHeights.count {
            // Centre the hairline on the row boundary, the official shape
            // (`rowTop[i] - lineWidth / 2`).
            let y = rowOrigins[row] - line / 2
            UIRectFill(CGRect(x: 0, y: y, width: bounds.width, height: line))
        }

        for row in table.rows.indices {
            for column in table.rows[row].indices {
                let string = table.rows[row][column]
                guard string.length > 0 else { continue }
                let cell = cellBounds(row: row, column: column)
                guard cell.intersects(rect) else { continue }
                UIGraphicsGetCurrentContext()?.saveGState()
                UIRectClip(cell)
                string.draw(with: textRect(row: row, column: column),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil)
                UIGraphicsGetCurrentContext()?.restoreGState()
            }
        }

        let border = UIBezierPath(
            roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
            cornerRadius: max(0, radius - line / 2))
        border.lineWidth = line
        ChatTextUIColors.tableLine
            .resolvedColor(with: traitCollection).setStroke()
        border.stroke()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            setNeedsDisplay()
        }
    }
}

private final class AssistantTableCellAccessibilityElement: UIAccessibilityElement {
    let row: Int
    let column: Int

    init(container: UIView, row: Int, column: Int, label: String, frame: CGRect) {
        self.row = row
        self.column = column
        super.init(accessibilityContainer: container)
        accessibilityLabel = label
        accessibilityTraits = .staticText
        accessibilityFrameInContainerSpace = frame
    }
}
#endif
