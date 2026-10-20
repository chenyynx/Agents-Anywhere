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
#endif
