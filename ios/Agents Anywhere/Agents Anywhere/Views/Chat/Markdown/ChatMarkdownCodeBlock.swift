import SwiftUI
import Textual
import UIKit

/// A fenced code block drawn as a card.
///
/// Card chrome follows moonveil's `CodeBlockAttachment` one-to-one: 23pt
/// corners, a 1pt outline, a 36pt header strip with a lowercased monospace
/// label over a hairline, a 14pt gutter, no scroll indicators, and a copy
/// button that confirms with a haptic.
///
/// The *content* pipeline is unchanged: Textual parses, highlights and selects;
/// this view only wraps the result.
struct ChatMarkdownCodeBlock<Code: View>: View {
    let code: String
    let language: String?
    @ViewBuilder let highlightedCode: () -> Code
    @State private var copyCount = 0
    @State private var copied = false
    @State private var showsFullScreen = false

    private static var headerHeight: CGFloat { 36 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(ChatPalette.codeHeaderDivider.color)
                .frame(height: 1 / UIScreen.main.scale)
            ScrollView(.horizontal) {
                highlightedCode()
                    .textual.textSelectionScope()
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(ChatPalette.codeCardFill.color)
        .clipShape(.rect(cornerRadius: ChatMetrics.codeRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatMetrics.codeRadius, style: .continuous)
                .stroke(ChatPalette.codeCardBorder.color, lineWidth: 1 / UIScreen.main.scale)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $showsFullScreen) {
            ChatCodeFullScreenView(code: code, language: language)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(verbatim: displayLanguage)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatPalette.codeHeaderLabel.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            headerButton(
                copied ? "checkmark" : "document.on.document",
                label: copied ? String(localized: "已复制") : String(localized: "复制代码"),
                tint: copied ? .green : ChatPalette.codeHeaderIcon.color
            ) {
                UIPasteboard.general.string = code
                copied = true
                copyCount += 1
                // Copy feedback is haptic as well as visual, matching the card
                // this chrome comes from.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .accessibilityIdentifier("markdown.copyCode")
            .task(id: copyCount) {
                guard copyCount > 0 else { return }
                do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
            }
            headerButton("arrow.up.left.and.arrow.down.right", label: String(localized: "全屏查看")) {
                showsFullScreen = true
            }
            .accessibilityIdentifier("markdown.expandCode")
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
    }

    private var displayLanguage: String {
        (language?.isEmpty == false ? language! : "code").lowercased()
    }

    private func headerButton(
        _ symbol: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let ink = tint ?? ChatPalette.codeHeaderIcon.color
        return Button(action: action) {
            AppSymbol(symbol, size: 15)
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
