import SwiftUI

/// The queue itself: the waiting messages stacked bottom-up in the dock,
/// between the interaction dock and the composer. It is empty — not hidden —
/// when the queue is empty, so it never leaves a phantom gap above the input
/// bar. Additions, removals and the wire-to-echo hand-off animate gently; the
/// list scrolls with the composer rather than the timeline, so its height never
/// touches the timeline's tail contract.
struct SendQueueDock: View {
    let model: SessionChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = model.session.sendQueue.items
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { item in
                    QueuedMessageRow(item: item, model: model)
                        .id(item.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, ChatControlMetrics.collapsedHorizontalInset)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .frame(maxWidth: ChatControlMetrics.maximumContentWidth)
            .frame(maxWidth: .infinity)
            // The animation value is the roster together with each row's state,
            // so a removal (echo arrives) slides the rows below it up while a
            // style-only flip stays owned by the row's own transition.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: roster)
        }
    }

    private var roster: String {
        model.session.sendQueue.items.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }
}
