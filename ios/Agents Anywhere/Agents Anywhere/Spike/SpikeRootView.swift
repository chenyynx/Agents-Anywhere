import Observation
import SwiftUI

// MARK: - Model

/// Throwaway state for the 6b container spike. Not part of the product.
@MainActor
@Observable
final class SpikeModel {
    struct Item: Identifiable, Equatable {
        let id: String
        var text: String
        var revision: Int
    }

    enum ScrollTarget { case top, bottomAnimated, bottomInstant }

    private(set) var items: [Item] = []
    /// Bumped whenever the item list or a revision changes.
    private(set) var generation = 0

    // MARK: Counters shown on the HUD
    private(set) var targetOffsetCalls = 0
    private(set) var prepareForUpdatesCalls = 0
    private(set) var finalizeUpdatesCalls = 0
    private(set) var invalidationContextCalls = 0
    private(set) var shouldInvalidateCalls = 0
    private(set) var didEndScrollingAnimationCalls = 0
    private(set) var contentHeight: CGFloat = 0
    private(set) var dragStartHeight: CGFloat = 0
    private(set) var dragMaxDelta: CGFloat = 0
    private(set) var lastOwed: CGFloat = 0
    private(set) var lastProposedOffset: CGFloat = 0
    private(set) var lastReturnedOffset: CGFloat = 0
    private(set) var anchorBeforeY: CGFloat = 0
    private(set) var anchorAfterY: CGFloat = 0
    private(set) var reconfigureCount = 0
    private(set) var streamTicks = 0
    private(set) var lastEvent = "-"

    private(set) var scrollCommand: (id: Int, target: ScrollTarget)?
    private var scrollCommandID = 0
    private var prependCounter = 0
    private var appendCounter = 0
    var streamingItemID: String?

    init() {
        reset()
    }

    func reset() {
        items = (1...1000).map { index in
            Item(id: "item-\(index)", text: Self.text(for: index, lines: index % 7 + 1), revision: 0)
        }
        generation &+= 1
        streamingItemID = items.last?.id
        lastEvent = "reset 1000"
    }

    func prepend() {
        prependCounter += 1
        let new = (1...100).map { offset in
            Item(id: "pre-\(prependCounter)-\(offset)",
                 text: Self.text(for: offset, lines: offset % 5 + 1), revision: 0)
        }
        items.insert(contentsOf: new, at: 0)
        generation &+= 1
        lastEvent = "prepend 100"
    }

    func append() {
        appendCounter += 1
        let new = (1...100).map { offset in
            Item(id: "post-\(appendCounter)-\(offset)",
                 text: Self.text(for: offset, lines: offset % 5 + 1), revision: 0)
        }
        items.append(contentsOf: new)
        generation &+= 1
        lastEvent = "append 100"
    }

    func growStreamingItem() {
        guard let id = streamingItemID, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text += "\nstream \(streamTicks)"
        items[index].revision += 1
        streamTicks += 1
        generation &+= 1
    }

    func requestScroll(_ target: ScrollTarget) {
        scrollCommandID &+= 1
        scrollCommand = (scrollCommandID, target)
        lastEvent = "scroll \(target)"
    }

    // MARK: Controller callbacks

    func recordContentHeight(_ value: CGFloat) { contentHeight = value }
    func recordTarget(proposed: CGFloat, returned: CGFloat) {
        targetOffsetCalls += 1
        lastProposedOffset = proposed
        lastReturnedOffset = returned
    }
    func recordPrepareForUpdates() { prepareForUpdatesCalls += 1 }
    func recordFinalizeUpdates() { finalizeUpdatesCalls += 1 }
    func recordInvalidationContext(delta: CGFloat) {
        invalidationContextCalls += 1
        _ = delta
    }
    func recordShouldInvalidate() { shouldInvalidateCalls += 1 }
    func recordDidEndScrollingAnimation() { didEndScrollingAnimationCalls += 1 }
    func recordReconfigure(_ count: Int) { reconfigureCount += count }
    func recordDragStart(_ height: CGFloat) { dragStartHeight = height; dragMaxDelta = 0 }
    func recordDragDelta(_ delta: CGFloat) { dragMaxDelta = max(dragMaxDelta, abs(delta)) }
    func recordOwed(before: CGFloat, after: CGFloat, owed: CGFloat) {
        anchorBeforeY = before
        anchorAfterY = after
        lastOwed = owed
    }

    static func text(for index: Int, lines: Int) -> String {
        let body = (0..<lines).map { line in
            "Row \(index) · line \(line + 1) · " + String(repeating: "lorem ipsum ", count: (index % 4) + 1)
        }
        return body.joined(separator: "\n")
    }
}

// MARK: - Root

struct SpikeRootView: View {
    @State private var model = SpikeModel()
    @State private var streamingTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SpikeHUD(model: model)
            SpikeTimelineView(model: model)
                .frame(maxHeight: .infinity)
            controls
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onDisappear { streamingTask?.cancel() }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                button("顶部插入100") { model.prepend() }
                button("底部追加100") { model.append() }
                button(model.streamingItemID == nil ? "开始流式" : "流式进行中") {
                    toggleStreaming()
                }
                button("回顶") { model.requestScroll(.top) }
                button("回底(动画)") { model.requestScroll(.bottomAnimated) }
                button("回底(瞬时)") { model.requestScroll(.bottomInstant) }
                button("重置") { model.reset() }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 56)
        .background(.bar)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func toggleStreaming() {
        if streamingTask != nil {
            streamingTask?.cancel()
            streamingTask = nil
            return
        }
        streamingTask = Task { @MainActor in
            while !Task.isCancelled {
                model.growStreamingItem()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}

// MARK: - HUD

private struct SpikeHUD: View {
    let model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("6b spike · 1000 行 · \(model.lastEvent)")
                .font(.caption.weight(.semibold))
            Text("targetOffset=\(model.targetOffsetCalls)  prepareUpdates=\(model.prepareForUpdatesCalls)  finalize=\(model.finalizeUpdatesCalls)")
            Text("invalidationCtx=\(model.invalidationContextCalls)  shouldInvalidate=\(model.shouldInvalidateCalls)  reconfigure=\(model.reconfigureCount)")
            Text("didEndScrollAnim=\(model.didEndScrollingAnimationCalls)  streamTicks=\(model.streamTicks)")
            Text("contentH=\(Int(model.contentHeight))  dragStart=\(Int(model.dragStartHeight))  dragMaxΔ=\(Int(model.dragMaxDelta))")
            Text("owed=\(Int(model.lastOwed))  proposed=\(Int(model.lastProposedOffset))  returned=\(Int(model.lastReturnedOffset))")
            Text("anchorY \(Int(model.anchorBeforeY)) → \(Int(model.anchorAfterY))")
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
