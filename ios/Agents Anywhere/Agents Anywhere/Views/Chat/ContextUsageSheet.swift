import SwiftUI

/// The session toolbar's context-window ring — the official Code page carries
/// this beside the overflow menu. A 21 pt ring, 3 pt stroke, arc from twelve
/// o'clock clockwise over a light track. The colour follows the usage level:
/// normal is the official blue sampled from the 1.261023 build's screenshot;
/// warning / critical reuse the app's amber / red severity palette.
struct ContextUsageRing: View {
    let usage: V2ContextUsage
    var diameter: CGFloat = 21
    var lineWidth: CGFloat = 3

    private var fraction: Double { usage.fraction ?? 0 }
    private var tint: Color { Self.tint(forPercent: usage.percentUsed ?? 0) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.35), value: fraction)
        .animation(.smooth(duration: 0.35), value: tint)
        .accessibilityHidden(true)
    }

    static func tint(forPercent percent: Int) -> Color {
        if percent < 75 {
            return Color(red: 33 / 255, green: 86 / 255, blue: 162 / 255)
        }
        if percent < 90 {
            return Color(red: 239 / 255, green: 159 / 255, blue: 39 / 255)
        }
        return Color(red: 226 / 255, green: 75 / 255, blue: 74 / 255)
    }

    static func accessibilityValue(_ usage: V2ContextUsage) -> String {
        guard let percent = usage.percentUsed else {
            return String(localized: "用量未知")
        }
        return String(format: String(localized: "已使用 %lld%%"), percent)
    }
}

/// The sheet the ring opens: the runtime's own context-window answer with its
/// per-category breakdown, laid out as the official Usage page's context card.
/// Runtimes that answer summary-only (codex) show the header, meter and token
/// line without a breakdown section. The sheet chrome (background, cards,
/// typography) follows the add-to-chat sheet so the two read as one family.
struct ContextUsageSheet: View {
    let chat: SessionChatModel
    let sessionID: V2SessionID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsInfo = false

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if chat.isRefreshingContextUsage, chat.displayedContextUsage == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "上下文"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                                .padding(.leading, 20)
                            if let usage = chat.displayedContextUsage {
                                contextCard(usage)
                            } else {
                                emptyCard
                            }
                        }
                    }
                    if let error = chat.contextUsageError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                    }
                }
                .padding(.horizontal, ChatSheetMetrics.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(AppTheme.composerSheetBackground(colorScheme).ignoresSafeArea())
            .toolbarBackground(AppTheme.composerSheetBackground(colorScheme), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetCloseToolbar { dismiss() }
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "用量"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await chat.refreshContextUsage(
                                sessionID: sessionID, detail: .full)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17))
                    }
                    .disabled(chat.isRefreshingContextUsage)
                    .accessibilityLabel(String(localized: "刷新"))
                    Button {
                        showsInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17))
                    }
                    .accessibilityLabel(String(localized: "说明"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(String(localized: "上下文窗口"), isPresented: $showsInfo) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(String(localized: "用量来自 Runtime 的上下文统计；连接不可用时显示上次测量或 timeline 估算。"))
        }
        .task {
            // The sheet's own read is the runtime's full per-category pass;
            // the ring only ever asks for `summary`.
            await chat.refreshContextUsage(sessionID: sessionID, detail: .full)
        }
    }

    private var emptyCard: some View {
        Text(String(localized: "暂无用量数据"))
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
    }

    private func contextCard(_ usage: V2ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(localized: "上下文窗口"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                Spacer(minLength: 8)
                if let percent = usage.percentUsed {
                    Text(String(format: String(localized: "已使用 %lld%%"), percent))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                } else {
                    Text(String(localized: "用量未知"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                }
            }
            ContextUsageMeter(usage: usage)
            caption(usage)
            if usage.hasBreakdown {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(usage.visibleCategories.indices, id: \.self) { index in
                        let category = usage.visibleCategories[index]
                        ContextUsageRow(
                            label: category.name,
                            tokens: category.tokens,
                            total: usage.maxTokens ?? usage.totalTokens,
                            tone: ContextUsageMeter.tone(for: category, index: index)
                        )
                    }
                }
                .padding(.top, 2)
                ContextUsageGroups(usage: usage)
            } else if chat.isRefreshingContextUsage {
                statusLine(String(localized: "正在读取分类明细…"), spinner: true)
            } else if usage.isEstimate {
                statusLine(String(localized: "当前为 timeline 估算值，连接会话后可获取精确分类明细"))
            } else if usage.isCached {
                statusLine(String(localized: "显示上次测量结果，连接会话后会自动更新"))
            } else {
                statusLine(String(localized: "该 Runtime 只提供总体用量，暂无分类明细"))
            }
        }
        .padding(20)
        .background(AppTheme.composerTileBackground(colorScheme), in: cardShape)
    }

    private func statusLine(_ text: String, spinner: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.mini) }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
        }
    }

    private func caption(_ usage: V2ContextUsage) -> some View {
        let used = ContextTokenFormat.wan(usage.totalTokens)
        let total = usage.maxTokens.map(ContextTokenFormat.wan) ?? "—"
        let text: String
        if let measured = Self.measuredTime(usage.measuredAt) {
            text = String(format: String(localized: "%@/%@ 个 token · 更新时间：%@"),
                          used, total, measured)
        } else {
            text = String(format: String(localized: "%@ / %@ 个 token"), used, total)
        }
        return Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            .monospacedDigit()
    }

    private static func measuredTime(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = precise.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let time = DateFormatter()
        time.locale = .current
        time.dateStyle = .none
        time.timeStyle = .short
        return time.string(from: date)
    }
}

/// The proportional segmented bar. Categories fill the window in order; free
/// space and the compaction buffer keep the muted tone; whatever is left over
/// is the track itself.
struct ContextUsageMeter: View {
    let usage: V2ContextUsage
    @Environment(\.colorScheme) private var colorScheme

    /// Sampled from the official Usage page (dark mode): #3E78CE fill over a
    /// #0B1D40 track. The light track keeps the same hue at low opacity.
    private var fill: Color { Color(red: 62 / 255, green: 120 / 255, blue: 206 / 255) }
    private var track: Color {
        colorScheme == .dark
            ? Color(red: 11 / 255, green: 29 / 255, blue: 64 / 255)
            : fill.opacity(0.16)
    }

    private static let palette: [Color] = [
        Color(red: 33 / 255, green: 86 / 255, blue: 162 / 255),
        Color(red: 29 / 255, green: 158 / 255, blue: 117 / 255),
        Color(red: 239 / 255, green: 159 / 255, blue: 39 / 255),
        Color(red: 138 / 255, green: 108 / 255, blue: 208 / 255),
        Color(red: 74 / 255, green: 144 / 255, blue: 226 / 255),
        Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255),
        Color(red: 99 / 255, green: 153 / 255, blue: 34 / 255),
        Color(red: 150 / 255, green: 150 / 255, blue: 150 / 255),
    ]

    static func tone(for category: V2ContextUsageCategory, index: Int) -> Color {
        if category.isFreeOrBuffer {
            return Color.secondary.opacity(0.35)
        }
        return palette[index % palette.count]
    }

    var body: some View {
        GeometryReader { proxy in
            let categories = usage.visibleCategories
            if categories.isEmpty {
                // Summary-only / estimate: there is no per-category split, so
                // the bar still has to show the measured share of the window.
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * CGFloat(min(max(usage.fraction ?? 0, 0), 1)))
                }
            } else {
                // The runtime's rows can sum past the nominal window (different
                // accounting between summary and breakdown); scale by whichever
                // is larger so the bar never overflows or clips.
                let categoryTotal = categories.reduce(0) { $0 + $1.tokens }
                let total = max(usage.maxTokens ?? usage.totalTokens, categoryTotal, 1)
                HStack(spacing: 1) {
                    ForEach(categories.indices, id: \.self) { index in
                        let category = categories[index]
                        Rectangle()
                            .fill(Self.tone(for: category, index: index))
                            .frame(
                                width: max(
                                    0,
                                    CGFloat(category.tokens) / CGFloat(total) * proxy.size.width
                                )
                            )
                    }
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(track))
                .clipShape(Capsule())
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

private struct ContextUsageRow: View {
    let label: String
    let tokens: Int
    let total: Int
    let tone: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tone)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            Text(ContextTokenFormat.wan(tokens))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(share)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var share: String {
        guard total > 0 else { return "—" }
        let percent = Double(tokens) / Double(total) * 100
        if percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }
}

/// The grouped detail lists the CLI reports alongside the categories.
private struct ContextUsageGroups: View {
    let usage: V2ContextUsage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !usage.mcpTools.isEmpty {
            group(String(localized: "MCP 工具"), tokens: sum(usage.mcpTools.map(\.tokens))) {
                ForEach(usage.mcpTools.indices, id: \.self) { index in
                    let tool = usage.mcpTools[index]
                    item(label: "\(tool.serverName) · \(tool.name)", tokens: tool.tokens)
                }
            }
        }
        if !usage.memoryFiles.isEmpty {
            group(String(localized: "记忆文件"), tokens: sum(usage.memoryFiles.map(\.tokens))) {
                ForEach(usage.memoryFiles.indices, id: \.self) { index in
                    let file = usage.memoryFiles[index]
                    item(label: file.path, tokens: file.tokens, isPath: true)
                }
            }
        }
        if !usage.agents.isEmpty {
            group(String(localized: "自定义智能体"), tokens: sum(usage.agents.map(\.tokens))) {
                ForEach(usage.agents.indices, id: \.self) { index in
                    let agent = usage.agents[index]
                    item(label: agent.agentType, tokens: agent.tokens)
                }
            }
        }
        if !usage.skills.isEmpty {
            group(String(localized: "Skills"), tokens: sum(usage.skills.map(\.tokens))) {
                ForEach(usage.skills.indices, id: \.self) { index in
                    let skill = usage.skills[index]
                    item(label: skill.name, tokens: skill.tokens)
                }
            }
        }
    }

    private func sum(_ values: [Int]) -> Int { values.reduce(0, +) }

    private func group<Content: View>(
        _ title: String,
        tokens: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(.top, 6)
                .padding(.leading, 2)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                Spacer()
                Text("\(ContextTokenFormat.wan(tokens))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
            }
        }
        .tint(AppTheme.composerSecondaryGlyph(colorScheme))
    }

    private func item(label: String, tokens: Int, isPath: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13, design: isPath ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(ContextTokenFormat.wan(tokens))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
        }
    }
}
