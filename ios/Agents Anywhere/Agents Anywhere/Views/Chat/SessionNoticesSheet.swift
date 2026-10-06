import SwiftUI

struct SessionNoticesSheet: View {
    let model: SessionChatModel
    var initialNoticeID: String? = nil
    @Environment(\.dismiss) private var dismiss
    /// Handle for the pending auto-dismiss, so repopulated content can cancel it.
    @State private var autoDismissTask: Task<Void, Never>?
    /// A brief settle window before closing on an emptied list: status pushes
    /// can blink the list empty between the submitted and resolved revisions.
    private static let emptyDismissDelay: Duration = .milliseconds(350)

    private var isEmpty: Bool { model.session.notices.visibleNotices.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.session.notices.visibleNotices) { item in
                            SessionInteractionContent(item: item, chat: model).id(item.id)
                        }
                    }.padding(16)
                }
                .onAppear { if let initialNoticeID { proxy.scrollTo(initialNoticeID, anchor: .top) } }
            }
            .navigationTitle(String(localized: "交互与通知"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.compact)
        // Only a *change* in emptiness closes the sheet: opening it empty or
        // with content never arms the timer, and content arriving during the
        // settle window cancels the pending close. The re-read after the delay
        // is a live check against the store, not the value captured at change.
        .onChange(of: isEmpty) { _, nowEmpty in
            autoDismissTask?.cancel()
            autoDismissTask = nil
            guard nowEmpty else { return }
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.emptyDismissDelay)
                guard !Task.isCancelled, isEmpty else { return }
                dismiss()
            }
        }
        .onDisappear { autoDismissTask?.cancel() }
    }
}
