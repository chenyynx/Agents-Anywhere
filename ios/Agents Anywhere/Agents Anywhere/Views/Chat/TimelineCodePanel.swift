import SwiftUI
import UIKit

// The code / diff panel the turn review sheet shows for a tool call's patch.
// It is the last piece of the retired Chat row views that still has a caller
// (2026-11-16): the marker and fold leaves that used to sit beside it were
// deleted when the standalone fallback moved to Code components.

struct TimelineCodePanel: View {
    let label: String
    let code: String
    var isDiff = false
    @State private var copied = false
    @State private var memo = PanelMemo()
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 19
    /// Diff parsing and line counting repeat only when the code changes, not
    /// when the copy feedback or a neighbouring row invalidates this body.
    private final class PanelMemo {
        var code: String?
        var displayCode = ""
        var lineCount = 0
        var diffLines: [TimelineDiff.Line] = []
    }
    private func prepared() -> PanelMemo {
        if memo.code != code {
            memo.code = code
            memo.displayCode = String(code.prefix(200_000))
            memo.lineCount = memo.displayCode.utf8.reduce(1) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            memo.diffLines = isDiff ? TimelineDiff(memo.displayCode).lines : []
        }
        return memo
    }
    var body: some View {
        let panel = prepared()
        let displayCode = panel.displayCode
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(.caption, design: .monospaced))
                Spacer()
                Button {
                    UIPasteboard.general.string = code; copied = true
                } label: { AppSymbol(copied ? "checkmark" : "document.on.document").frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制 \(label)"))
                .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
            }.padding(.leading, 12).foregroundStyle(.secondary).background(.quaternary.opacity(0.3))
            ScrollView([.horizontal, .vertical]) {
                if isDiff {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(panel.diffLines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.sign).frame(width: 10)
                                Text(line.oldLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                Text(line.newLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                                ChatSelectableText(text: line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.caption, design: .monospaced)).monospacedDigit()
                            .padding(.horizontal, 12).frame(minHeight: rowHeight)
                            .foregroundStyle(diffColor(line.kind)).background(diffColor(line.kind).opacity(line.kind == .add || line.kind == .delete ? 0.09 : 0))
                        }
                    }.padding(.vertical, 8).fixedSize(horizontal: true, vertical: false)
                } else {
                    ChatSelectableText(text: displayCode).font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: min(320, max(76, CGFloat(panel.lineCount) * rowHeight + 24)))
            if displayCode.count < code.count { ToolTruncatedNote() }
        }.background(Color(uiColor: .secondarySystemBackground))
    }
    private func diffColor(_ kind: TimelineDiff.Line.Kind) -> Color {
        switch kind { case .add: .green; case .delete: .red; case .hunk, .file, .annotation: .secondary; case .context: .primary }
    }
}
