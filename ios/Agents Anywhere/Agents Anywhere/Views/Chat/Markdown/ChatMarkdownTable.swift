import SwiftUI
import Textual

struct ChatMarkdownTable: View {
    let rows: [[AttributedString]]
    let columns: [PresentationIntent.TableColumn]

    var body: some View {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal) {
            // Reference tables size each column to its content and scroll
            // sideways; the cap only exists so one runaway cell cannot make
            // the row unreachable, not to force uniform widths.
            TableGridLayout(columns: columnCount,
                            minWidth: ChatMetrics.tableCellPadHorizontal * 2,
                            maxWidth: ChatMetrics.tableContentWidthCap) {
                ForEach(rows.indices, id: \.self) { row in
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(rows[row].indices.contains(column) ? rows[row][column] : AttributedString(),
                             row: row, column: column, columnCount: columnCount)
                    }
                }
            }
            // One hairline colour for the header underline, every body row seam
            // *and* the card outline, so the border reads as the same rule the
            // table is drawn with rather than a second, heavier frame.
            .clipShape(.rect(cornerRadius: ChatMetrics.tableRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatMetrics.tableRadius, style: .continuous)
                    .stroke(ChatPalette.tableLine.color, lineWidth: 1 / UIScreen.main.scale)
                    .allowsHitTesting(false)
            )
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ content: AttributedString, row: Int, column: Int, columnCount: Int) -> some View {
        InlineText(String(content.hashValue), parser: ParsedMarkdownText(content: content))
            .textual.textSelection(.enabled)
            .modifier(StreamingGlyphReveal())
            .font(.system(size: ChatMetrics.tableCellSize))
            .fontWeight(row == 0 ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ChatMetrics.tableCellPadHorizontal)
            .padding(.vertical, ChatMetrics.tableCellPadVertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment(column), vertical: .top))
            .background(row == 0 ? ChatPalette.tableHeaderFill.color : .clear)
            // One line colour everywhere; no vertical seams in the borderless
            // style, so columns are separated by spacing alone.
            .overlay(alignment: .bottom) {
                if row < rows.count - 1 {
                    Rectangle().fill(ChatPalette.tableLine.color)
                        .frame(height: 1 / UIScreen.main.scale)
                        .allowsHitTesting(false)
                }
            }
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard columns.indices.contains(column) else { return .leading }
        return switch columns[column].alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}

/// Grid measured its rows under a different width than it placed them with
/// inside the horizontal scroll view, so wrapped cells overflowed into the
/// next row and the table was cut short. This layout sizes each column once
/// (ideal width, capped so long cells wrap), gives every row its tallest
/// cell's height and places cells with exactly that size.
private struct TableGridLayout: Layout {
    let columns: Int
    let minWidth: CGFloat
    let maxWidth: CGFloat

    struct Metrics {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Metrics? { nil }

    func updateCache(_ cache: inout Metrics?, subviews: Subviews) { cache = nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) -> CGSize {
        let metrics = measure(subviews, cache: &cache)
        return CGSize(width: metrics.widths.reduce(0, +), height: metrics.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) {
        let metrics = measure(subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in metrics.heights.enumerated() {
            var x = bounds.minX
            for (column, width) in metrics.widths.enumerated() {
                let index = row * columns + column
                guard subviews.indices.contains(index) else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: width, height: height))
                x += width
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews, cache: inout Metrics?) -> Metrics {
        if let cache { return cache }
        let rowCount = (subviews.count + columns - 1) / columns
        var metrics = Metrics(widths: Array(repeating: minWidth, count: columns))
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            metrics.widths[index % columns] = min(max(metrics.widths[index % columns], ideal), maxWidth)
        }
        metrics.heights = (0..<rowCount).map { row in
            (0..<columns).reduce(0) { tallest, column in
                let index = row * columns + column
                guard subviews.indices.contains(index) else { return tallest }
                let width = metrics.widths[column]
                return max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
            }
        }
        cache = metrics
        return metrics
    }
}

struct ParsedMarkdownText: MarkupParser {
    let content: AttributedString
    func attributedString(for input: String) throws -> AttributedString { content }
}
