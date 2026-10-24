#if canImport(UIKit)
import SwiftUI
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
        case .image(let image):
            let view = AssistantImageBlockView(
                image: image,
                size: image.reservedSize(columnWidth: width),
                height: height)
            return (view, height)
        case .math(let math):
            let view = AssistantMathBlockView(
                math: math, columnWidth: width, height: height)
            return (view, height)
        case .divider:
            return (AssistantDividerBlockView(), height)
        }
    }
}

/// Textual's default thematic break: a hairline in `DynamicColor.grid`
/// (210/210/215 light, 66/66/69 dark) vertically centred in a 1pt frame.
final class AssistantDividerBlockView: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : 1
        let line = 1 / scale
        let color = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 66 / 255, green: 66 / 255, blue: 69 / 255, alpha: 1)
                : UIColor(red: 210 / 255, green: 210 / 255, blue: 215 / 255, alpha: 1)
        }
        color.resolvedColor(with: traitCollection).setFill()
        UIRectFill(CGRect(x: 0, y: (bounds.height - line) / 2,
                          width: bounds.width, height: line))
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            setNeedsDisplay()
        }
    }
}

/// One Markdown image. The legacy attachment view is hosted at its reserved
/// footprint, so a slow/failed load never changes the block height. Interaction
/// (preview, file open, retry) stays inside that view.
final class AssistantImageBlockView: UIView {
    private let host: UIHostingController<AnyView>

    init(image: AssistantImageBlock, size: CGSize, height: CGFloat) {
        // The live color scheme arrives through the hosted view's own
        // environment; the stored copy only provides the defaults the legacy
        // loader used.
        let attachment = ChatMarkdownImageAttachment(
            url: image.url,
            description: image.description,
            colors: ColorEnvironmentValues())
        host = UIHostingController(rootView: AnyView(attachment.body))
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            // The legacy attachment is `min(420, column) × (0.75×width | 68)`.
            // Pinning the hosted view keeps a wide column from stretching it.
            host.view.widthAnchor.constraint(equalToConstant: size.width),
            // `height` is the layout's own rounded number, so the cell's
            // required height and this view can never disagree.
            host.view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if DEBUG
    var debugHostSize: CGSize { host.view.bounds.size }
    #endif
}

/// One display formula, centered like Textual's `MathBlock`.
final class AssistantMathBlockView: UIView {
    private let host: UIHostingController<TextualMathView>

    init(math: AssistantMathBlock, columnWidth: CGFloat, height: CGFloat) {
        host = UIHostingController(rootView: TextualMathView(
            latex: math.latex, isBlock: true, fontSize: math.fontSize))
        super.init(frame: .zero)
        backgroundColor = .clear
        let metrics = math.metrics(columnWidth: columnWidth)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.widthAnchor.constraint(
                equalToConstant: max(0, min(metrics.size.width, columnWidth))),
            host.view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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

        bar.backgroundColor = quote.barColor ?? ChatTextUIColors.quoteBar
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
    private var copyResetWorkItem: DispatchWorkItem?

    init(codeBlock: AssistantCodeBlock, width: CGFloat, displayScale: CGFloat) {
        self.codeBlock = codeBlock
        self.displayScale = displayScale
        self.textSize = AssistantMarkdownTextLayout.intrinsicSize(
            of: codeBlock.code, displayScale: displayScale)
        super.init(frame: .zero)
        backgroundColor = codeBlock.fillColor ?? ChatTextUIColors.codeCardFill
        layer.cornerRadius = codeBlock.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        header.backgroundColor = .clear
        addSubview(header)

        divider.backgroundColor = codeBlock.borderColor
            ?? ChatTextUIColors.codeHeaderDivider
        addSubview(divider)

        if let titleFontName = codeBlock.titleFontName {
            // [E] `codeCard.title.typography` (code-title-r10 §1): 13 pt,
            // weight 400, lineHeight 20.8, `.caption` relative, JetBrains
            // Mono. The official 44 pt header centres the 20.8 pt line box.
            // SwiftUI's `.caption` is UIKit's `.caption1`; `UIFont.TextStyle`
            // has no `.caption` member.
            let size = UIFontMetrics(forTextStyle: .caption1)
                .scaledValue(for: codeBlock.titleFontSize)
            languageLabel.font = MarkdownFontFactory.font(
                name: titleFontName, size: size,
                weight: codeBlock.titleWeightValue)
        } else {
            languageLabel.font = UIFont.monospacedSystemFont(
                ofSize: codeBlock.titleFontSize, weight: codeBlock.titleWeight)
        }
        languageLabel.textColor = codeBlock.titleColor
            ?? ChatTextUIColors.codeHeaderLabel
        languageLabel.lineBreakMode = .byTruncatingTail
        // [E] The title is the fence info string **as written** (no
        // lowercasing); a fence with no language shows the localised "Code"
        // (R19 code-card-highlighting.md).
        languageLabel.text = codeBlock.language?.isEmpty == false
            ? codeBlock.language
            : String(localized: "代码")
        header.addSubview(languageLabel)

        configureIcon(copyIcon, symbol: "document.on.document")
        configureIcon(expandIcon, symbol: "arrow.up.left.and.arrow.down.right")
        // The header copy control must be tappable. It used to be a decorative
        // image (`isUserInteractionEnabled = false`) with no gesture, so the
        // Code card had no working copy affordance.
        copyIcon.isUserInteractionEnabled = true
        copyIcon.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(copyCode)))
        copyIcon.isAccessibilityElement = true
        copyIcon.accessibilityTraits = .button
        copyIcon.accessibilityLabel = String(localized: "复制代码")
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
        let result = NSMutableAttributedString()
        for token in tokens {
            var attributes = baseAttributes
            if let color = color(for: token.type) {
                attributes[.foregroundColor] = color
            }
            // [E] The official tokenizer adds only a foreground colour per
            // token: no bold/italic font modifiers at all
            // (R19 code-card-highlighting.md).
            result.append(NSAttributedString(
                string: token.content, attributes: attributes))
        }
        return result
    }

    /// The official highlight.js theme mapping (R19 code-card-highlighting.md,
    /// switch table `0x104230070`). A token that is not listed keeps the base
    /// `#383A42` / `#ABB2BF`.
    private static func color(
        for type: StructuredText.HighlighterTheme.TokenType
    ) -> UIColor? {
        switch type {
        case .variable, .number:
            return CodePageTheme.uiColor(CodePageTheme.syntaxOrange)
        case .string, .regex, .attributeName, .attributeValue, .inserted:
            return CodePageTheme.uiColor(CodePageTheme.syntaxGreen)
        case .comment, .blockComment, .docComment:
            return CodePageTheme.uiColor(CodePageTheme.syntaxComment)
        case .keyword:
            return CodePageTheme.uiColor(CodePageTheme.syntaxKeyword)
        case .literal, .boolean:
            return CodePageTheme.uiColor(CodePageTheme.syntaxCyan)
        case .className, .builtin:
            return CodePageTheme.uiColor(CodePageTheme.syntaxYellow)
        case .function, .functionName, .functionDefinition,
             .symbol, .url, .selector:
            // Official hljs scopes `title.function`/`symbol`/`link` are blue.
            return CodePageTheme.uiColor(CodePageTheme.syntaxBlue)
        case .tag, .deleted:
            return CodePageTheme.uiColor(CodePageTheme.syntaxRed)
        case .property, .char, .punctuation, .operator:
            // Official `property`/`char`/punctuation keep the default ink.
            return nil
        default:
            return nil
        }
    }

    private func configureIcon(_ view: UIImageView, symbol: String) {
        view.image = iconImage(symbol: symbol, fallback: symbol)
        view.tintColor = ChatTextUIColors.codeHeaderIcon
        // The 24 pt frame is the official control; the artwork inside it is
        // smaller (see `iconGlyphSize`), so it is centred rather than stretched.
        view.contentMode = .center
        view.isUserInteractionEnabled = false
    }

    /// Official `AnimatingHapticButton` copy control: writes the fenced code
    /// and fires the `.selection` feedback (`EVIDENCE/round19/motion.md` §P2).
    @objc private func copyCode() {
        guard codeBlock.code.length > 0 else { return }
        UIPasteboard.general.string = codeBlock.code.string
        UISelectionFeedbackGenerator().selectionChanged()

        // [E] The official control swaps `anthropicon.copy` for
        // `anthropicon.check`; the assets are not extracted yet, so the SF
        // glyphs stand in. The reset duration is UNKNOWN; AA keeps the 2 s
        // confirmation its Chat card already uses ([I]).
        copyIcon.image = iconImage(symbol: "check", fallback: "checkmark")
        copyResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyIcon.image = self.iconImage(
                symbol: "document.on.document", fallback: "document.on.document")
        }
        copyResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// The official code-card controls are two 24 pt Anthropicons whose
    /// artwork is smaller than the control: at `.large`,
    /// `DATA/anthropicon-map.tsv` records copy 19×19 and expand 18×18. The card
    /// draws the stand-in glyph at that optical size and keeps the 24 pt frame.
    private static let iconGlyphSize: CGFloat = 19

    private func iconImage(symbol: String, fallback: String) -> UIImage? {
        // The legacy card uses AppSymbol's Lucide assets, not SF Symbols.
        if let asset = AppSymbolAssets.names[symbol].flatMap({ UIImage(named: $0) }) {
            return Self.scaledTemplate(asset, side: Self.iconGlyphSize)
        }
        return UIImage(systemName: fallback,
                       withConfiguration: UIImage.SymbolConfiguration(
                           pointSize: Self.iconGlyphSize))?
            .withRenderingMode(.alwaysTemplate)
    }

    /// Rasterises a vector/template asset at the requested optical size so a
    /// `.center` image view cannot stretch it back to the 24 pt control.
    private static func scaledTemplate(_ image: UIImage, side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let size = CGSize(width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ratio = min(size.width / max(1, image.size.width),
                            size.height / max(1, image.size.height))
            let drawSize = CGSize(width: image.size.width * ratio,
                                  height: image.size.height * ratio)
            image.draw(in: CGRect(x: (size.width - drawSize.width) / 2,
                                  y: (size.height - drawSize.height) / 2,
                                  width: drawSize.width,
                                  height: drawSize.height))
        }
        return rendered.withRenderingMode(.alwaysTemplate)
    }

    deinit { copyResetWorkItem?.cancel() }

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

        // [E] R19 code-card-highlighting.md: header horizontal padding 16,
        // HStack spacing 16, two 24 pt Anthropicon controls (copy → expand),
        // trailing inset 16.
        let iconSize: CGFloat = 24
        let iconY = (codeBlock.headerHeight - iconSize) / 2
        let trailingInset: CGFloat = 16
        let actionsSpacing: CGFloat = 16
        expandIcon.frame = CGRect(x: width - trailingInset - iconSize,
                                  y: iconY, width: iconSize, height: iconSize)
        copyIcon.frame = CGRect(x: expandIcon.frame.minX - actionsSpacing - iconSize,
                                y: iconY, width: iconSize, height: iconSize)
        let labelWidth = max(0, copyIcon.frame.minX - actionsSpacing - 16)
        languageLabel.frame = CGRect(x: 16, y: 0,
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
        layer.borderColor = (codeBlock.borderColor ?? ChatTextUIColors.codeCardBorder)
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

/// Draws the official inline-code chips behind their runs.
///
/// Evidence: `EVIDENCE/round19/typography-inline.md` §3 — radius 6.4,
/// horizontal padding 4/side, fill grey 0.043 @5% (light) / white @7.5%
/// (dark), stroke (0.118,0.118,0.114)@15% (light) /
/// (0.882,0.878,0.851)@15% (dark), width 1/displayScale. The vertical extent
/// comes from the run font's typographic bounds; the official vertical
/// padding has no constant (§3, §10 #4), so the chip uses the minimal
/// symmetric inset carried by the style (0 pt).
///
/// The chip is decoration only: none of these attributes changes the
/// attributed string's line layout, so a chipped run keeps exactly the height
/// `AssistantMarkdownTextLayout.height(of:)` measures.
@MainActor
enum AssistantInlineCodeChipRenderer {
    static func containsChip(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        var found = false
        attributed.enumerateAttribute(
            .assistantInlineCodeChip,
            in: NSRange(location: 0, length: attributed.length),
            options: []) { value, _, stop in
            if (value as? NSNumber)?.boolValue == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Text-view path: reuse the view's own TextKit 2 layout, so the chip
    /// rectangles are the exact fragments the glyphs were drawn in.
    static func drawChips(in attributed: NSAttributedString,
                          layoutManager: NSTextLayoutManager,
                          origin: CGPoint,
                          traitCollection: UITraitCollection) {
        guard attributed.length > 0,
              let content = layoutManager.textContentManager else { return }
        // The draw pass must see every fragment the text itself will draw; the
        // view may still be waiting for a layout invalidation.
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : 1
        let lineWidth = 1 / max(scale, 1)
        for range in chipRanges(in: attributed) {
            guard let font = attributed.attribute(
                    .font, at: range.location, effectiveRange: nil) as? UIFont,
                  let start = content.location(
                    content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  end.compare(start) != .orderedSame else { continue }
            // The initializer is failable in the iOS 26 SDK; the annotation
            // keeps the non-failable SDKs compiling too.
            let textRange: NSTextRange? = NSTextRange(location: start, end: end)
            guard let textRange else { continue }

            let style = chipStyle(in: attributed, at: range.location,
                                  traitCollection: traitCollection)
            layoutManager.enumerateTextSegments(
                in: textRange, type: .standard, options: []
            ) { _, frame, _, _ in
                drawChip(frame: frame.offsetBy(dx: origin.x, dy: origin.y),
                         font: font, style: style, lineWidth: lineWidth)
                return true
            }
        }
    }

    /// Table path: cells are drawn with `NSAttributedString.draw`, i.e. the
    /// TextKit 1 line machinery, so the chip rectangles come from the same
    /// `NSLayoutManager` line fragments. Mixing a TextKit 2 layout here could
    /// put a chip on a different line than the text when a cell wraps.
    static func drawChips(in attributed: NSAttributedString,
                          width: CGFloat,
                          origin: CGPoint,
                          traitCollection: UITraitCollection) {
        guard attributed.length > 0, width > 0 else { return }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale : 1
        let lineWidth = 1 / max(scale, 1)
        for range in chipRanges(in: attributed) {
            guard let font = attributed.attribute(
                    .font, at: range.location, effectiveRange: nil) as? UIFont else {
                continue
            }
            let style = chipStyle(in: attributed, at: range.location,
                                  traitCollection: traitCollection)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { frame, _ in
                drawChip(frame: frame.offsetBy(dx: origin.x, dy: origin.y),
                         font: font, style: style, lineWidth: lineWidth)
            }
        }
    }

    private struct ChipStyle {
        let fill: UIColor
        let stroke: UIColor
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
    }

    private static func chipStyle(in attributed: NSAttributedString,
                                  at location: Int,
                                  traitCollection: UITraitCollection) -> ChipStyle {
        func number(_ key: NSAttributedString.Key, fallback: CGFloat) -> CGFloat {
            guard let value = attributed.attribute(
                    key, at: location, effectiveRange: nil) as? NSNumber else {
                return fallback
            }
            return CGFloat(value.doubleValue)
        }
        let fill = (attributed.attribute(
            .assistantInlineCodeChipFill, at: location,
            effectiveRange: nil) as? UIColor)
            ?? CodePageTheme.inlineCodeChipFillUIColor
        let stroke = (attributed.attribute(
            .assistantInlineCodeChipStroke, at: location,
            effectiveRange: nil) as? UIColor)
            ?? CodePageTheme.inlineCodeChipStrokeUIColor
        return ChipStyle(
            fill: fill.resolvedColor(with: traitCollection),
            stroke: stroke.resolvedColor(with: traitCollection),
            cornerRadius: number(.assistantInlineCodeChipCornerRadius,
                                 fallback: CodePageTheme.inlineCodeChipCornerRadius),
            horizontalPadding: number(.assistantInlineCodeChipHorizontalPadding,
                                      fallback: CodePageTheme.inlineCodeChipHorizontalPadding),
            verticalPadding: number(.assistantInlineCodeChipVerticalPadding,
                                    fallback: CodePageTheme.inlineCodeChipVerticalPadding))
    }

    /// Maximal runs carrying the chip marker. Adjacent runs with different
    /// colours/weights merge, so a bold inline-code run does not show a seam.
    private static func chipRanges(in attributed: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attributed.enumerateAttribute(
            .assistantInlineCodeChip,
            in: NSRange(location: 0, length: attributed.length),
            options: []) { value, range, _ in
            guard (value as? NSNumber)?.boolValue == true else { return }
            if let last = ranges.last,
               last.location + last.length == range.location {
                ranges[ranges.count - 1].length += range.length
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func drawChip(frame: CGRect,
                                 font: UIFont,
                                 style: ChipStyle,
                                 lineWidth: CGFloat) {
        guard frame.width > 0, frame.height > 0 else { return }
        let glyphHeight = max(1, font.ascender - font.descender)
        let height = min(frame.height, glyphHeight + style.verticalPadding * 2)
        let rect = CGRect(
            x: frame.minX - style.horizontalPadding,
            y: frame.midY - height / 2,
            width: frame.width + style.horizontalPadding * 2,
            height: height)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(style.cornerRadius, rect.height / 2)
        style.fill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        let inset = lineWidth / 2
        let strokeRect = rect.insetBy(dx: inset, dy: inset)
        guard strokeRect.width > 0, strokeRect.height > 0 else { return }
        style.stroke.setStroke()
        let path = UIBezierPath(roundedRect: strokeRect,
                                cornerRadius: max(0, radius - inset))
        path.lineWidth = lineWidth
        path.stroke()
    }
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

        // [E] R19 `typography-inline.md` §5 — header fill white / #1A1A19,
        // row seams and the outer border grey 0.043 @10% / white @10%, all
        // hairlines. No zebra fill and no vertical column rules (EVIDENCE-
        // negative in the official draw pass).
        let headerFill = (table.headerFillColor
            ?? ChatTextUIColors.tableHeaderFill)
            .resolvedColor(with: traitCollection)
        let lineColor = (table.borderColor ?? ChatTextUIColors.tableLine)
            .resolvedColor(with: traitCollection)

        headerFill.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: bounds.width,
                          height: table.rowHeights[0]))

        lineColor.setFill()
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
                let text = textRect(row: row, column: column)
                UIGraphicsGetCurrentContext()?.saveGState()
                UIRectClip(cell)
                // Inline-code runs in a cell carry the same chip marker as the
                // body; paint their chips behind the text before `draw`.
                if AssistantInlineCodeChipRenderer.containsChip(string) {
                    AssistantInlineCodeChipRenderer.drawChips(
                        in: string, width: text.width, origin: text.origin,
                        traitCollection: traitCollection)
                }
                string.draw(with: text,
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil)
                UIGraphicsGetCurrentContext()?.restoreGState()
            }
        }

        let border = UIBezierPath(
            roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
            cornerRadius: max(0, radius - line / 2))
        border.lineWidth = line
        lineColor.setStroke()
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
