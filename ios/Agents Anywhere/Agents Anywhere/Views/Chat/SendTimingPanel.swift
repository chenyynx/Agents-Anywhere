import Foundation
import SwiftUI
import UIKit

/// Diagnostic-only overlay for the `ios-send-timing-probe` build: the newest
/// send's on-device timings for the current session, with 复制全部 / 清空.
/// Everything outside the card lets touches through to the chat below.
/// Delete this file with the branch.
struct SendTimingPanel: View {
    let sessionId: V2SessionID
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var didCopy = false

    private var record: SendTimingProbe.Record? { SendTimingProbe.shared.latest(for: sessionId) }

    var body: some View {
        ZStack(alignment: .top) {
            // The overlay spans the chat page: only the card itself may claim a
            // touch, so the empty area never blocks the timeline.
            Color.clear.allowsHitTesting(false)
            card
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
            if isExpanded { actions }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.secondaryControlStroke(colorScheme), lineWidth: 1))
    }

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let record {
                HStack(spacing: 6) {
                    Text("SEND #\(String(record.id.prefix(8)))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.primaryText(colorScheme))
                    Text(record.preview.isEmpty ? "(空)" : record.preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(record.isFinished ? "完成" : "进行中")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText(colorScheme))
                }
                line([("点→发", ms(record.httpStart, record.tapWall)),
                      ("存盘", ms(record.flushEnd, record.flushStart)),
                      ("POST", ms(record.httpEnd, record.httpStart))])
                line([("点→圈停", ms(record.echoAt, record.tapWall)),
                      ("返→停", ms(record.echoAt, record.httpEnd)),
                      ("pending", ms(record.pendingAt, record.tapWall))])
                line([("运行", ms(record.stateRunningAt, record.tapWall)),
                      ("首出", ms(record.firstActivityAt, record.tapWall)),
                      ("文本", ms(record.firstAssistantTextAt, record.tapWall)),
                      ("结束", ms(record.turnEndAt, record.tapWall))])
            } else {
                Text("send-timing: 本会话暂无记录 (send a message)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText(colorScheme))
            }
            Text(isExpanded ? "tap to collapse · 点卡片收起" : "tap to expand · 点卡片展开")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText(colorScheme))
        }
    }

    private func line(_ fields: [(title: String, value: String)]) -> some View {
        HStack(spacing: 10) {
            ForEach(fields.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    Text(fields[index].title).foregroundStyle(AppTheme.secondaryText(colorScheme))
                    Text(fields[index].value).foregroundStyle(AppTheme.primaryText(colorScheme))
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { copyAll() } label: {
                Text(didCopy ? "已复制" : "复制全部")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryControlForeground(colorScheme))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(AppTheme.primaryControlBackground(colorScheme), in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                SendTimingProbe.shared.clear()
            } label: {
                Text("清空")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryText(colorScheme))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .overlay(Capsule().stroke(AppTheme.secondaryControlStroke(colorScheme), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = SendTimingProbe.shared.copyText()
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func ms(_ end: Date?, _ start: Date?) -> String {
        guard let end, let start else { return "-" }
        return String(Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
