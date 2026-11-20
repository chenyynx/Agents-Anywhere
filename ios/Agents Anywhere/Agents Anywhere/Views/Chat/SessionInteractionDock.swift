import SwiftUI

struct SessionInteractionDock: View {
    let chat: SessionChatModel
    let onShowAll: (String) -> Void
    @State private var selectedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var metrics = SessionInteractionMetrics()

    private var items: [SessionNoticeModel] { chat.session.notices.notices.filter { $0.blocks(chat.session.id) } }
    /// Questionnaires render the official `QuestionCard`; every other blocking
    /// interaction keeps the compact notice card.
    private var questionItems: [SessionNoticeModel] { items.filter { $0.form != nil } }
    private var compactItems: [SessionNoticeModel] { items.filter { $0.form == nil } }
    private var selectedIndex: Int { compactItems.firstIndex { $0.id == selectedID } ?? 0 }
    // Reserve the same peeking space for one or several cards, so resolving a
    // queued item does not resize the entire dock. Status text never measures it.
    private let peek: CGFloat = 12
    private var pageHeight: CGFloat {
        metrics.compactHeight
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(questionItems) { item in
                    QuestionCardView(item: item, chat: chat)
                        .padding(.horizontal, QuestionCardMetrics.screenMargin)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(item.id)
                }
                if !compactItems.isEmpty {
                    compactCarousel
                }
            }
            // The question card stands in for the composer, so nothing else
            // keeps it off the keyboard: without this the card's bottom edge
            // sat flush on the keyboard's candidate bar (pp 2026-11-20).
            .padding(.bottom, questionItems.isEmpty ? 0 : QuestionCardMetrics.cardBottomMargin)
        }
    }

    /// The pre-question dock: a vertical paging carousel of compact notice
    /// cards (blocking approvals and other interactions).
    private var compactCarousel: some View {
        let motionReduced = reduceMotion
        return ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(Array(compactItems.enumerated()), id: \.element.id) { index, item in
                    SessionInteractionCard(item: item, chat: chat,
                        page: compactItems.count > 1 ? "\(index + 1)/\(compactItems.count)" : nil,
                        height: pageHeight, onExpand: { onShowAll(item.id) })
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            content.scaleEffect(motionReduced ? 1 : 1 - min(abs(phase.value), 1) * 0.04)
                                .opacity(1 - min(abs(phase.value), 1) * 0.3)
                        }
                        .accessibilityAction(named: String(localized: "下一项")) { step(1) }
                        .accessibilityAction(named: String(localized: "上一项")) { step(-1) }
                        .id(item.id)
                }
            }.scrollTargetLayout()
        }
        .contentMargins(.vertical, peek, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $selectedID, anchor: .center)
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        .frame(height: pageHeight + peek * 2).clipped()
        .onChange(of: compactItems.map(\.id), initial: true) { old, next in
            if let selectedID, next.contains(selectedID) { return }
            let index = old.firstIndex(of: selectedID ?? "") ?? 0
            selectedID = next.isEmpty ? nil : next[min(index, next.count - 1)]
        }
        .padding(.horizontal, 24)
    }

    private func step(_ delta: Int) {
        let index = selectedIndex + delta
        guard compactItems.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selectedID = compactItems[index].id }
    }
}
