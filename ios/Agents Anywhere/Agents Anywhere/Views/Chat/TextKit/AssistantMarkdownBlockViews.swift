#if canImport(UIKit)
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
        case .text(let attributed):
            let view = AssistantMarkdownBlockTextView()
            view.attributedText = attributed
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
            spacing: list.innerSpacing, displayScale: displayScale)
        super.init(frame: .zero)
        backgroundColor = .clear

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = list.innerSpacing
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
        stack.spacing = quote.innerSpacing
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
        for block in quote.blocks {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: contentWidth, displayScale: displayScale)
            stack.addArrangedSubview(made.view)
            made.view.heightAnchor.constraint(equalToConstant: made.height).isActive = true
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

/// The table card: a horizontally scrolling grid with fixed column widths and
/// per-row heights. Cells use the same TextKit views as running text; the
/// header row is tinted and semibold, and every seam uses the product's single
/// hairline colour.
final class AssistantTableBlockView: UIView {
    private let table: AssistantTableBlock
    private let displayScale: CGFloat
    private let scrollView = UIScrollView()
    private let card = UIView()
    private var cells: [[UIView]] = []
    private var textViews: [[AssistantMarkdownBlockTextView]] = []
    private var separators: [[UIView]] = []

    init(table: AssistantTableBlock, width: CGFloat, displayScale: CGFloat) {
        self.table = table
        self.displayScale = displayScale
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

        card.backgroundColor = .clear
        card.layer.cornerRadius = table.cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        scrollView.addSubview(card)

        for row in table.rows.indices {
            var rowCells: [UIView] = []
            var rowTextViews: [AssistantMarkdownBlockTextView] = []
            var rowSeparators: [UIView] = []
            for column in table.rows[row].indices {
                let cell = UIView()
                cell.backgroundColor = row == 0
                    ? ChatTextUIColors.tableHeaderFill : .clear
                card.addSubview(cell)

                let textView = AssistantMarkdownBlockTextView()
                textView.attributedText = table.rows[row][column]
                textView.backgroundColor = .clear
                cell.addSubview(textView)

                let separator = UIView()
                separator.backgroundColor = ChatTextUIColors.tableLine
                separator.isHidden = row == table.rows.count - 1
                cell.addSubview(separator)

                rowCells.append(cell)
                rowTextViews.append(textView)
                rowSeparators.append(separator)
            }
            cells.append(rowCells)
            textViews.append(rowTextViews)
            separators.append(rowSeparators)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : displayScale
        let line = 1 / scale
        scrollView.frame = bounds
        card.frame = CGRect(x: 0, y: 0,
                            width: table.totalWidth, height: table.totalHeight)
        scrollView.contentSize = card.frame.size

        var y: CGFloat = 0
        for (row, height) in table.rowHeights.enumerated() {
            var x: CGFloat = 0
            for (column, width) in table.columnWidths.enumerated() {
                guard cells.indices.contains(row),
                      cells[row].indices.contains(column) else { break }
                cells[row][column].frame = CGRect(x: x, y: y, width: width, height: height)
                let textView = textViews[row][column]
                textView.frame = CGRect(
                    x: table.cellPaddingHorizontal,
                    y: table.cellPaddingVertical,
                    width: max(0, width - table.cellPaddingHorizontal * 2),
                    height: max(0, height - table.cellPaddingVertical * 2))
                let separator = separators[row][column]
                separator.frame = CGRect(
                    x: 0, y: height - line, width: width, height: line)
                x += width
            }
            y += height
        }

        card.layer.borderWidth = line
        card.layer.borderColor = ChatTextUIColors.tableLine
            .resolvedColor(with: traitCollection).cgColor
    }
}
#endif
