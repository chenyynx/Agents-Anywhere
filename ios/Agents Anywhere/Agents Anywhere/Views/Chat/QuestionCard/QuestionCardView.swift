import SwiftUI
import UIKit

/// The official `ClaudeCoreUI.QuestionCard` for a pending `input_request`
/// notice. Values come from `QuestionCardMetrics` (CANONICAL/25-question-card.md,
/// R32 closing table).
///
/// Placement: the interaction dock above the composer — the official Code
/// page's list-footer form (pp picked it 2026-11-20: same surface the blocking
/// interaction notices already use). The answered state is a separate
/// timeline card built from the question row (`QuestionAnsweredCardView`).
///
/// Behaviours:
/// - one question per page through the caret buttons (horizontal swipe was
///   removed: it fought the card's own vertical scroller, pp 2026-11-22);
/// - "下一页" requires the current question answered; "跳过" is always
///   available and leaves the question out of the submitted answers;
/// - the last page's primary button submits; skipping the last question also
///   submits (with the answers collected so far);
/// - the X cancels the whole request through the notice's `cancel` action
///   (pp: no confirmation dialog);
/// - dictation/mic and the ranked-options list belong to the official Chat
///   variant only — AA follows the Code variant, so neither is drawn.
struct QuestionCardView: View {
    let item: SessionNoticeModel
    let chat: SessionChatModel
    /// The tallest the card may draw: the host's space above the keyboard.
    /// The card hugs its content while it fits and turns into a vertical
    /// scroller at this cap (pp 2026-11-22: with the keyboard up the custom
    /// answer field and the buttons sat behind it).
    var maximumHeight: CGFloat = .infinity

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageIndex = 0
    /// The scrolling content's raw height (above the pinned footer) and the
    /// footer's own height. The card draws at
    /// `min(scrollHeight + footerHeight, maximumHeight)`.
    @State private var scrollHeight: CGFloat = 0
    /// Seeded with one button row's height so the very first layout already
    /// reserves the footer; the measurement replaces it in the same pass.
    @State private var footerHeight: CGFloat = 56
    /// The question whose custom-answer field owns the keyboard, if any.
    /// Scrolling follows it so what you type stays above the keyboard.
    @State private var focusedQuestionID: String?

    /// Scroll anchors for the card's own scroll view.
    private static let topAnchorID = "question-card.top"
    private static let inputAnchorID = "question-card.input"

    // MARK: - Derived state

    private var questions: [NoticeInputQuestion] { item.form?.questions ?? [] }
    private var submitAction: V2RuntimeNoticeAction? {
        item.notice.actions.first { $0.id == item.form?.actionID }
    }
    private var cancelAction: V2RuntimeNoticeAction? {
        item.notice.actions.first { $0.id == "cancel" }
    }
    private var isSubmitting: Bool { submitAction.map(item.isSending) ?? false }
    /// True while the notice cannot take a response (expired, another writer,
    /// IME composing, or an offline runtime).
    private var responding: Bool {
        chat.isWorking || !item.canRespond(fresh: chat.session.runtime.isFresh)
    }
    private var currentQuestion: NoticeInputQuestion? {
        questions.indices.contains(pageIndex) ? questions[pageIndex] : nil
    }
    /// A single-question card has no paging row, so the header/question is the
    /// first row and shares its band with the floating X.
    private var avoidsDismiss: Bool { questions.count == 1 && cancelAction != nil }
    private var isLastPage: Bool { pageIndex >= questions.count - 1 }
    /// "Next" needs this question answered; "Submit" needs every non-skipped
    /// question answered (the notice payload builder is the single judge).
    private var primaryEnabled: Bool {
        if isLastPage {
            return submitAction.map(item.hasValidInput(for:)) ?? false
        }
        return currentQuestion.map(item.hasAnswer) ?? false
    }

    // MARK: - Body

    var body: some View {
        // One ScrollView for the question/options/answer field, with the
        // skip/next buttons pinned below it: scrolling to reach the input
        // must not take the actions away (pp 2026-11-22). Sizing is measured
        // rather than fitted by a `ViewThatFits` switch, which would rebuild
        // the editor and drop the keyboard the moment the cap changes.
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    scrollContent
                        // The card hugs its content: measure the raw height,
                        // then let the scroll view take it up to the cap. A
                        // zero-width pass would report a bogus wrapped height.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width > 0 ? proxy.size.height : 0
                        } action: { height in
                            guard height > 0, abs(height - scrollHeight) > 0.5 else { return }
                            scrollHeight = height
                        }
                        .id(Self.topAnchorID)
                }
                // The card's own scroll bar sits on its trailing edge (pp
                // 2026-11-22: 「要加卡片右侧的滚动条」).
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                .onChange(of: focusedQuestionID) { _, focused in
                    guard focused != nil else { return }
                    scrollCardToInput(scroller)
                }
                .onChange(of: maximumHeight) { _, _ in
                    guard focusedQuestionID != nil else { return }
                    scrollCardToInput(scroller)
                }
                .onChange(of: scrollHeight) { _, _ in
                    // The editor grows a line per keystroke; keep its caret
                    // in view while it owns the keyboard.
                    guard focusedQuestionID != nil else { return }
                    scrollCardToInput(scroller)
                }
                .onChange(of: pageIndex) { _, _ in
                    // A new page starts at the paging row, not at the
                    // previous page's scroll offset.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scroller.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
            footer
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width > 0 ? proxy.size.height : 0
                } action: { height in
                    guard height > 0, abs(height - footerHeight) > 0.5 else { return }
                    footerHeight = height
                }
        }
        .frame(height: cardHeight)
        // The X floats above the card's top-trailing corner (outside the
        // content padding), like the official floating dismiss button. It
        // stays put while the card scrolls.
        .overlay(alignment: .topTrailing) {
            if cancelAction != nil {
                dismissButton
                    .padding(QuestionCardMetrics.closeButtonInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only drawn subviews hit-test by default, so a drag that started on
        // a transparent gap inside the card (row spacing, padding, bare
        // areas next to the buttons) fell through to the collection view
        // behind and scrolled the transcript with it (pp 2026-11-20). The
        // whole rounded silhouette belongs to the card.
        .contentShape(RoundedRectangle(cornerRadius: QuestionCardMetrics.cornerRadius,
                                       style: .continuous))
        // A downward swipe anywhere on the card drops the keyboard: the card
        // consumes the drags that used to fall through to the transcript, so
        // it has to dismiss the keyboard itself (pp 2026-11-20). A capped
        // card that actually scrolls keeps those drags for its scroller.
        .gesture(QuestionCardSwipeDownGesture(isScrollable: isCardScrollable) {
            dismissKeyboard()
        })
        .glassEffect(.regular, in: .rect(cornerRadius: QuestionCardMetrics.cornerRadius))
        // The dock cell clips its bounds; clipping to the card's own shape
        // keeps the glass shadow from painting around it (same reason as
        // SessionInteractionCard).
        .clipShape(.rect(cornerRadius: QuestionCardMetrics.cornerRadius))
        // The official card floats on a soft shadow around its edge (pp
        // 2026-11-20). Clipping the glass first keeps this to one clean
        // silhouette shadow.
        .shadow(color: .black.opacity(QuestionCardMetrics.cardShadowOpacity),
                radius: QuestionCardMetrics.cardShadowRadius,
                y: QuestionCardMetrics.cardShadowY)
        .onChange(of: questions.map(\.id)) { _, _ in
            pageIndex = min(pageIndex, max(0, questions.count - 1))
        }
        // Low-frequency evidence for the device: whether the card had to
        // scroll and whether its field owns the keyboard. The cap changes on
        // every frame of a keyboard animation, so it is only sampled here.
        .onChange(of: isCardScrollable) { _, scrollable in
            recordCardGeometry(scrollable ? "scrollable" : "hugs")
        }
        .onChange(of: focusedQuestionID) { _, focused in
            recordCardGeometry(focused == nil ? "blurred" : "focused")
        }
    }

    private func recordCardGeometry(_ event: String) {
        ClientDiagnosticsLog.shared.record(
            kind: "question.card.geometry",
            sessionID: chat.session.id,
            detail: [
                "event": event,
                "scroll": String(Int(scrollHeight.rounded())),
                "footer": String(Int(footerHeight.rounded())),
                "cap": maximumHeight.isFinite ? String(Int(maximumHeight.rounded())) : "inf",
                "card": String(Int(cardHeight.rounded())),
            ])
    }

    /// The visible card height: the scrolling content plus the pinned footer
    /// while both fit the host's space, the cap from there on. The first
    /// layout measures both halves inside a zero-height frame before
    /// anything is drawn, so no zero-height frame reaches the screen.
    private var cardHeight: CGFloat {
        guard scrollHeight > 0 else { return 0 }
        return min(scrollHeight + footerHeight, maximumHeight)
    }

    private var isCardScrollable: Bool {
        scrollHeight + footerHeight > maximumHeight + 0.5
    }

    /// The scrolling half: paging row, question, options and the
    /// custom-answer field. The status line and the actions stay pinned in
    /// the footer.
    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Official flow: the paging row (multi-question only) is the
            // first row; the close button FLOATS at the top-trailing corner
            // and never consumes flow height (pp 2026-11-20). That is why a
            // single-question card's question starts at the very top.
            if questions.count > 1 {
                pagingRow
                    .padding(.leading, QuestionCardMetrics.pagingLeading)
            }
            // The official card's pager is the horizontal pager itself; the
            // page sizes to its content so every option and the
            // custom-answer field stay visible together.
            pager
        }
        .padding(.horizontal, QuestionCardMetrics.contentPaddingHorizontal)
        .padding(.top, QuestionCardMetrics.contentPadding)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The fixed half: status line and the skip/next actions. They never
    /// scroll away (pp 2026-11-22).
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            submitRow
        }
        .padding(.horizontal, QuestionCardMetrics.contentPaddingHorizontal)
        .padding(.top, 8)
        .padding(.bottom, QuestionCardMetrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keep the focused answer field's bottom at the scroll viewport's
    /// bottom, directly above the pinned footer. The keyboard's own animation
    /// moves the card; the card's scroll must not add a spring on top of it.
    private func scrollCardToInput(_ scroller: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scroller.scrollTo(Self.inputAnchorID, anchor: .bottom)
        }
    }

    // MARK: - Top row (paging + dismiss)

    private var pagingRow: some View {
        // Centre, not top: each caret carries a 44 pt tap target, so a
        // top-aligned HStack parked the 12 pt page label ~13 pt above the
        // glyph the eye reads (pp 2026-11-22: 「文字没和箭头在一排」).
        HStack(alignment: .center, spacing: QuestionCardMetrics.pagingSpacing) {
            pagingArrow(left: true)
            // Official copy: 「第1个，共3个」 (device, 2026-11-20).
            Text(String(localized: "第\(min(pageIndex + 1, questions.count))个，共\(questions.count)个"))
                .font(QuestionCardTheme.font(size: QuestionCardMetrics.pagingSize,
                                             weight: QuestionCardMetrics.pagingWeight))
                .lineSpacing(QuestionCardTheme.lineSpacing(
                    size: QuestionCardMetrics.pagingSize,
                    lineHeight: QuestionCardMetrics.pagingLineHeight))
                .foregroundStyle(secondary)
                .monospacedDigit()
            pagingArrow(left: false)
        }
    }

    private func pagingArrow(left: Bool) -> some View {
        let enabled = left ? pageIndex > 0 : pageIndex < questions.count - 1
        return Button {
            step(left ? -1 : 1)
        } label: {
            // The official left glyph is `anthropicon.caretLeft`; AA ships only
            // the right artwork, so the same caret is mirrored (see PR body).
            // Official paging arrows measure ~13 pt of artwork ink on device
            // (38 px @3x), the `.small` slot — not `.large`.
            AnthropiconView(name: "anthropicon.caretRight", size: .small)
                .scaleEffect(x: left ? -1 : 1, y: 1)
                .frame(width: QuestionCardMetrics.arrowGlyphSize,
                       height: QuestionCardMetrics.arrowGlyphSize)
        }
        .buttonStyle(QuestionPagingArrowStyle(enabled: enabled))
        .foregroundStyle(secondary)
        .disabled(!enabled)
        .frame(minWidth: QuestionCardMetrics.arrowTapTarget,
               minHeight: QuestionCardMetrics.arrowTapTarget)
        .accessibilityLabel(left ? String(localized: "上一题") : String(localized: "下一题"))
    }

    private var dismissButton: some View {
        Button {
            cancel()
        } label: {
            CloseXMark(color: QuestionCardTheme.color(QuestionCardMetrics.closeButtonInk, colorScheme))
                .frame(width: QuestionCardMetrics.closeButtonSize,
                       height: QuestionCardMetrics.closeButtonSize)
                // Official DismissXButton is a floating Liquid Glass circle
                // (pp 2026-11-20), same treatment as the other glass chrome.
                .glassEffect(.regular.interactive(), in: Circle())
                .shadow(color: .black.opacity(QuestionCardMetrics.closeButtonShadowOpacity),
                        radius: QuestionCardMetrics.closeButtonShadowRadius,
                        y: QuestionCardMetrics.closeButtonShadowY)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(responding || isSubmitting)
        .opacity(responding || isSubmitting ? QuestionCardMetrics.buttonDisabledOpacity : 1)
        .accessibilityLabel(String(localized: "取消提问"))
    }

    // MARK: - Pager

    /// One page at a time, sized by its own content: the official card hugs
    /// its content and top-aligns it. A ScrollView here measured heights
    /// unreliably and left a big blank band above the question (b1395), so the
    /// pager is a deterministic ZStack; paging goes through the carets.
    private var pager: some View {
        ZStack(alignment: .topLeading) {
            if let question = currentQuestion {
                page(question)
                    .id(question.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: pageIndex)
    }

    private func page(_ question: NoticeInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Swipe left/right here to change pages; the custom-answer field
            // stays outside so the gesture never fights the text editor.
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    if let header = question.header, !header.isEmpty {
                        typography(header,
                                   size: QuestionCardMetrics.titleSize,
                                   lineHeight: QuestionCardMetrics.titleLineHeight,
                                   weight: QuestionCardMetrics.titleWeight)
                            // R5: the card title is primary ink, not the
                            // secondary token used by descriptions/paging.
                            .foregroundStyle(.primary)
                    }
                    typography(question.prompt,
                               size: QuestionCardMetrics.questionSize,
                               lineHeight: QuestionCardMetrics.questionLineHeight,
                               weight: QuestionCardMetrics.questionWeight)
                        .foregroundStyle(.primary)
                }
                // Only a single-question card starts its text inside the
                // floating X's band; multi-question cards begin below the
                // paging row, so their questions may use the full width.
                .padding(.trailing, avoidsDismiss
                         ? QuestionCardMetrics.questionTrailingAvoidance : 0)
                choices(question)
            }
            .contentShape(Rectangle())
            customInput(question)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choices(_ question: NoticeInputQuestion) -> some View {
        VStack(spacing: 0) {
            ForEach(question.options) { option in
                optionRow(option, question: question)
                // The official list draws one hairline after *every* option,
                // including the last one before the custom-answer field.
                // Effective inset 24 pt from the card edge = the content
                // padding; the divider aligns with the question text
                // (R6 §1.4 device read).
                Rectangle()
                    .fill(QuestionCardTheme.color(QuestionCardMetrics.divider, colorScheme))
                    .frame(height: QuestionCardMetrics.dividerThicknessPixels / displayScale)
            }
        }
    }

    private func optionRow(_ option: NoticeInputQuestion.Option,
                           question: NoticeInputQuestion) -> some View {
        let selected = item.choices[question.id]?.contains(option.id) == true
        return Button {
            guard !responding else { return }
            item.select(option.id, question: question)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    typography(option.label,
                               size: QuestionCardMetrics.optionSize,
                               lineHeight: QuestionCardMetrics.optionLineHeight,
                               weight: QuestionCardMetrics.optionWeight)
                        .foregroundStyle(.primary)
                    if let detail = option.detail, !detail.isEmpty {
                        typography(detail,
                                   size: QuestionCardMetrics.optionDetailSize,
                                   lineHeight: QuestionCardMetrics.optionDetailLineHeight,
                                   weight: 400)
                            .foregroundStyle(detailInk)
                    }
                }
                Spacer(minLength: 0)
                // Selected: a check on the trailing side (pp 2026-11-20) —
                // no circle, no leading badge.
                if selected {
                    AppSymbol("checkmark", size: 16)
                        .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.selectedBadge,
                                                                 colorScheme))
                        .transition(.opacity)
                }
            }
            // The card's 24 pt content padding already places the row on the
            // official left edge; the vertical pad matches the official 67 pt
            // row pitch measured on pp's app.
            .padding(.vertical, QuestionCardMetrics.optionRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(responding)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func customInput(_ question: NoticeInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if question.allowCustom {
                NoticeTextInput(value: item.custom[question.id] ?? "",
                                placeholder: String(localized: "输入您的回答…"),
                                cornerRadius: QuestionCardMetrics.inputCornerRadius,
                                // The placeholder aligns with the options'
                                // left edge on device — no inner padding.
                                textPadding: 0,
                                showsBackground: false,
                                placeholderColor: detailInk,
                                onFocus: {
                                    item.setCustomSelected(true, question: question)
                                    // The capped card parks its bottom so
                                    // the focused field stays above the
                                    // keyboard.
                                    focusedQuestionID = question.id
                                },
                                onEditingEnded: { item.composingFields.remove($0) },
                                onChange: { text, marked, editorID in
                                    if text != (item.custom[question.id] ?? "") {
                                        item.setCustom(text, question: question)
                                    }
                                    if marked { item.composingFields.insert(editorID) }
                                    else { item.composingFields.remove(editorID) }
                                })
                    // The official card draws no visible field chrome: the
                    // placeholder sits straight on the card surface (device,
                    // 2026-11-20). Radius/padding stay for the text inset.
                    .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.inputForeground, colorScheme))
                    .id(Self.inputAnchorID)
            }
        }
    }

    // MARK: - Submit row

    /// Only the runtimes that advertise the semantics accept an omitted
    /// answer; everyone else keeps every question required (no skip button).
    private var allowsSkip: Bool { item.form?.allowSkip == true }

    @ViewBuilder private var submitRow: some View {
        if !questions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: QuestionCardMetrics.submitSpacing) {
                    if allowsSkip { skipButton }
                    primaryButton
                }
                VStack(spacing: QuestionCardMetrics.submitSpacing) {
                    if allowsSkip { skipButton }
                    primaryButton
                }
            }
            // Official buttons are two ~110 pt capsules pushed to the
            // trailing side of the content, not centred (device, 2026-11-20).
            .frame(maxWidth: QuestionCardMetrics.submitRowMaxWidth)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, QuestionCardMetrics.submitRowTrailingInset)
        }
    }

    private var skipButton: some View {
        cardButton(title: String(localized: "跳过"), style: .secondary,
                   loading: false, action: skip)
    }

    private var primaryButton: some View {
        cardButton(title: isLastPage ? String(localized: "提交") : String(localized: "下一页"),
                   style: .normal,
                   loading: isSubmitting,
                   disabled: !primaryEnabled,
                   showsArrow: !isLastPage,
                   action: advance)
    }

    private enum ButtonStyleRole { case normal, secondary }

    private func cardButton(title: String, style: ButtonStyleRole, loading: Bool,
                            disabled: Bool = false,
                            showsArrow: Bool = false,
                            action: @escaping () -> Void) -> some View {
        let isSecondary = style == .secondary
        let foreground = isSecondary
            ? QuestionCardTheme.color(QuestionCardMetrics.text10, colorScheme)
            : QuestionCardTheme.color(QuestionCardMetrics.bg10, colorScheme)
        return Button(action: action) {
            ZStack {
                if loading {
                    ProgressView().controlSize(.small).tint(foreground)
                } else {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(QuestionCardTheme.font(size: 13, weight: 500))
                        if showsArrow {
                            AnthropiconView(name: "anthropicon.caretRight", size: .small)
                                .frame(width: 13, height: 13)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background {
                if isSecondary {
                    Capsule().fill(Color.clear)
                } else {
                    Capsule().fill(QuestionCardTheme.color(QuestionCardMetrics.text10, colorScheme))
                }
            }
            .overlay {
                if isSecondary {
                    Capsule().strokeBorder(
                        QuestionCardTheme.color(QuestionCardMetrics.buttonBorder, colorScheme),
                        lineWidth: QuestionCardMetrics.buttonStrokePixels / displayScale)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(QuestionCardButtonStyle())
        .disabled(disabled || responding || isSubmitting)
        .opacity(disabled || responding || isSubmitting ? QuestionCardMetrics.buttonDisabledOpacity : 1)
    }

    @ViewBuilder private var statusLine: some View {
        if isSubmitting {
            statusText(String(localized: "正在提交回应…"))
        } else if item.submission == .accepted {
            statusText(String(localized: "回应已提交，等待 \(chat.agentName)"))
        } else if let error = item.responseError {
            statusText(error)
        } else if !chat.session.runtime.isFresh, let reason = chat.responseBlockingReason {
            // Real blockers (offline, unparsable, re-auth) keep their line;
            // the transient "confirming" refresh after returning from the
            // background does not (pp 2026-11-20).
            statusText(reason)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(QuestionCardTheme.font(size: 13, weight: 400))
            .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.secondary, colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Typography

    private func typography(_ text: String, size: CGFloat, lineHeight: CGFloat,
                            weight: CGFloat) -> some View {
        Text(text)
            .font(QuestionCardTheme.font(size: size, weight: weight))
            .lineSpacing(QuestionCardTheme.lineSpacing(size: size, lineHeight: lineHeight))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var secondary: Color {
        QuestionCardTheme.color(QuestionCardMetrics.secondary, colorScheme)
    }

    /// Option descriptions and the custom-answer placeholder share this ink.
    private var detailInk: Color {
        QuestionCardTheme.color(QuestionCardMetrics.optionDetailInk, colorScheme)
    }

    // MARK: - Actions

    private func step(_ delta: Int) {
        let next = pageIndex + delta
        guard questions.indices.contains(next) else { return }
        pageIndex = next
    }

    /// Same dismissal the transcript's empty-space tap uses: resign whichever
    /// editor owns the responder (the card's custom-answer field).
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func advance() {
        if isLastPage {
            submit()
        } else {
            step(1)
        }
    }

    private func skip() {
        guard allowsSkip, let question = currentQuestion else { return }
        item.skip(question)
        if isLastPage { submit() } else { step(1) }
    }

    private func submit() {
        guard let action = submitAction else { return }
        // Never let a submit tap vanish silently: if an earlier question lost
        // its answer, land on the first question that still needs one.
        if !item.hasValidInput(for: action),
           let index = questions.firstIndex(where: { !item.hasAnswer($0) }) {
            pageIndex = index
            return
        }
        // The card collapses with the tap; the keyboard goes down in the same
        // beat instead of a frame later when the editor disappears.
        dismissKeyboard()
        Task { await chat.respond(notice: item, action: action, dismissOnSend: true) }
    }

    private func cancel() {
        guard let action = cancelAction else { return }
        dismissKeyboard()
        Task { await chat.respond(notice: item, action: action, dismissOnSend: true) }
    }
}

/// The official close glyph: two round-capped strokes, 16 pt of ink with a
/// 1.5 pt stroke (measured on the official screenshot, pp 2026-11-20), in
/// near-black. The colour is baked into the shapes — the surrounding glass
/// vibrancy otherwise washes a foreground style down to light grey.
private struct CloseXMark: View {
    let color: Color
    private let span = QuestionCardMetrics.closeGlyphSpan
    private let stroke = QuestionCardMetrics.closeGlyphStroke

    var body: some View {
        ZStack {
            Capsule().fill(color).frame(width: span, height: stroke).rotationEffect(.degrees(45))
            Capsule().fill(color).frame(width: span, height: stroke).rotationEffect(.degrees(-45))
        }
        .frame(width: span, height: span)
        .accessibilityHidden(true)
    }
}

/// Passive downward-swipe recognizer for the whole card (the K2 composer
/// gesture's pattern): it observes the finger without cancelling touches, so
/// taps, option buttons and IME candidates keep working, and it ignores
/// drags that begin inside the custom-answer editor — those belong to text
/// selection.
private struct QuestionCardSwipeDownGesture: UIGestureRecognizerRepresentable {
    /// The capped card's scroller owns vertical drags; a card that fits keeps
    /// the swipe-to-dismiss-keyboard behaviour.
    let isScrollable: Bool
    let onSwipeDown: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isScrollable: isScrollable)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isScrollable = isScrollable
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer,
                                         context: Context) {
        guard recognizer.state == .ended else { return }
        let translation = context.converter.localTranslation
            ?? recognizer.translation(in: recognizer.view)
        guard translation.y > 40, abs(translation.y) > abs(translation.x) else { return }
        onSwipeDown()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isScrollable: Bool

        init(isScrollable: Bool) {
            self.isScrollable = isScrollable
        }

        /// This recognizer is passive; it must never make another recognizer
        /// (button taps, the IME, the text editor) fail.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view: UIView? = touch.view
            while let candidate = view, candidate !== recognizer.view {
                // The text editor owns its selection drags; a card that has
                // to scroll owns its vertical drags too (otherwise every
                // attempt to reach the input dismissed the keyboard).
                if candidate is UITextView { return false }
                if candidate is UIScrollView, isScrollable { return false }
                view = candidate.superview
            }
            return true
        }
    }
}

/// Official button press feedback: scale 0.98; disabled opacity is applied by
/// the call site.
private struct QuestionCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? QuestionCardMetrics.buttonPressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Official paging arrow: 0.5 opacity while pressed, 0.3 when disabled.
private struct QuestionPagingArrowStyle: ButtonStyle {
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled
                ? (configuration.isPressed ? QuestionCardMetrics.arrowPressedOpacity : 1)
                : QuestionCardMetrics.arrowDisabledOpacity)
    }
}
