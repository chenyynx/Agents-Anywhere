import SwiftUI

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
/// - one question per page, swipe or the caret buttons (official animation);
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
    /// Whole-card cap; the question body scrolls inside it.
    var maximumHeight: CGFloat = 480

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageID: String?
    @State private var pageIndex = 0

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
        VStack(alignment: .leading, spacing: 12) {
            topRow
            // One vertical scroll owns the whole pager: the horizontal
            // pager's height is its tallest page, and anything past the card
            // cap scrolls here. Putting a vertical ScrollView *inside* each
            // page collapsed the pager to a sliver on device (b1384).
            ScrollView(.vertical) {
                pager
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            statusLine
            submitRow
        }
        .padding(.horizontal, QuestionCardMetrics.contentPaddingHorizontal)
        .padding(.vertical, QuestionCardMetrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maximumHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: QuestionCardMetrics.cornerRadius))
        // The dock cell clips its bounds; clipping to the card's own shape
        // keeps the glass shadow from painting around it (same reason as
        // SessionInteractionCard).
        .clipShape(.rect(cornerRadius: QuestionCardMetrics.cornerRadius))
        .onAppear {
            if pageID == nil { pageID = questions.first?.id }
        }
        .onChange(of: questions.map(\.id)) { _, ids in
            if let pageID, ids.contains(pageID) { return }
            pageIndex = 0
            pageID = ids.first
        }
    }

    // MARK: - Top row (paging + dismiss)

    private var topRow: some View {
        HStack(spacing: QuestionCardMetrics.pagingSpacing) {
            if questions.count > 1 {
                pagingRow
            }
            Spacer(minLength: 0)
            if cancelAction != nil {
                dismissButton
            }
        }
        .padding(.leading, QuestionCardMetrics.pagingLeading)
    }

    private var pagingRow: some View {
        HStack(spacing: QuestionCardMetrics.pagingSpacing) {
            pagingArrow(left: true)
            Text(verbatim: "\(min(pageIndex + 1, questions.count))/\(questions.count)")
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
            AnthropiconView(name: "anthropicon.caretRight", size: .large)
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
            AppSymbol("xmark", size: 13)
                .frame(width: QuestionCardMetrics.closeButtonSize,
                       height: QuestionCardMetrics.closeButtonSize)
                .background(.regularMaterial, in: Circle())
                .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.closeButtonInk, colorScheme))
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

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: QuestionCardMetrics.pagingSpacing) {
                ForEach(questions) { question in
                    page(question)
                        .containerRelativeFrame(.horizontal, count: 1,
                                                spacing: QuestionCardMetrics.pagingSpacing)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .blur(radius: abs(phase.value) * QuestionCardMetrics.pageTransitionBlurRadius,
                                      opaque: false)
                                .opacity(1 - min(abs(phase.value), 1))
                                .scaleEffect(1 - min(abs(phase.value), 1) * (1 - QuestionCardMetrics.pageTransitionScale))
                        }
                        .id(question.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .scrollIndicators(.hidden)
        .onChange(of: pageID) { _, id in
            guard let id, let index = questions.firstIndex(where: { $0.id == id }) else { return }
            pageIndex = index
        }
    }

    private func page(_ question: NoticeInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let header = question.header, !header.isEmpty {
                typography(header,
                           size: QuestionCardMetrics.titleSize,
                           lineHeight: QuestionCardMetrics.titleLineHeight,
                           weight: QuestionCardMetrics.titleWeight)
                    // R5: the card title is primary ink, not the secondary
                    // token used by descriptions and the paging row.
                    .foregroundStyle(.primary)
            }
            typography(question.prompt,
                       size: QuestionCardMetrics.questionSize,
                       lineHeight: QuestionCardMetrics.questionLineHeight,
                       weight: QuestionCardMetrics.questionWeight)
                .foregroundStyle(.primary)
            choices(question)
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
                selectionBadge(selected: selected)
                VStack(alignment: .leading, spacing: 4) {
                    typography(option.label,
                               size: QuestionCardMetrics.optionSize,
                               lineHeight: QuestionCardMetrics.optionLineHeight,
                               weight: QuestionCardMetrics.optionWeight)
                        .foregroundStyle(.primary)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(QuestionCardTheme.font(size: 13, weight: 400))
                            .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.secondary, colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // The card's 24 pt content padding already places the badge on
            // the official left edge; only the row's vertical padding is
            // added here.
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(responding)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func selectionBadge(selected: Bool) -> some View {
        ZStack {
            if selected {
                Circle().fill(QuestionCardTheme.color(QuestionCardMetrics.selectedBadge, colorScheme))
                AnthropiconView(name: "anthropicon.check", size: .medium)
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(
                    QuestionCardTheme.color(QuestionCardMetrics.unselectedRing, colorScheme),
                    lineWidth: QuestionCardMetrics.selectionBadgeStrokeWidth)
            }
        }
        .frame(width: QuestionCardMetrics.selectionBadgeMinSize,
               height: QuestionCardMetrics.selectionBadgeMinSize)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
    }

    private func customInput(_ question: NoticeInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isSkipped(question) {
                Text(String(localized: "已跳过"))
                    .font(QuestionCardTheme.font(size: 13, weight: 400))
                    .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.secondary, colorScheme))
            }
            if question.allowCustom {
                NoticeTextInput(value: item.custom[question.id] ?? "",
                                placeholder: String(localized: "其他回答"),
                                cornerRadius: QuestionCardMetrics.inputCornerRadius,
                                textPadding: QuestionCardMetrics.inputPadding,
                                showsBackground: false,
                                onFocus: { item.setCustomSelected(true, question: question) },
                                onEditingEnded: { item.composingFields.remove($0) },
                                onChange: { text, marked, editorID in
                                    if text != (item.custom[question.id] ?? "") {
                                        item.setCustom(text, question: question)
                                    }
                                    if marked { item.composingFields.insert(editorID) }
                                    else { item.composingFields.remove(editorID) }
                                })
                    .foregroundStyle(QuestionCardTheme.color(QuestionCardMetrics.inputForeground, colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: QuestionCardMetrics.inputCornerRadius,
                                         style: .continuous)
                            .strokeBorder(QuestionCardTheme.color(QuestionCardMetrics.divider, colorScheme),
                                          lineWidth: 1 / displayScale)
                    }
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
                   action: advance)
    }

    private enum ButtonStyleRole { case normal, secondary }

    private func cardButton(title: String, style: ButtonStyleRole, loading: Bool,
                            disabled: Bool = false,
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
                    Text(title)
                        .font(QuestionCardTheme.font(size: 15, weight: 500))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
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
        } else if !chat.session.runtime.isFresh, let reason = chat.responseUnavailableReason {
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

    // MARK: - Actions

    private func step(_ delta: Int) {
        let next = pageIndex + delta
        guard questions.indices.contains(next) else { return }
        if reduceMotion {
            pageID = questions[next].id
        } else {
            withAnimation(.smooth(duration: 0.25)) { pageID = questions[next].id }
        }
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
            let target = questions[index].id
            if reduceMotion { pageID = target }
            else { withAnimation(.smooth(duration: 0.25)) { pageID = target } }
            return
        }
        Task { await chat.respond(notice: item, action: action) }
    }

    private func cancel() {
        guard let action = cancelAction else { return }
        Task { await chat.respond(notice: item, action: action) }
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
