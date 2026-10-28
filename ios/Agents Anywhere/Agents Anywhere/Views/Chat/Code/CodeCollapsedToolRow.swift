import SwiftUI
import UIKit

// The Code page's collapsed row, shared by tool calls and thinking blocks.
//
// Official structure (1023 static analysis, R28 §1 / §U 收口三):
// `Button(CollapsedStepsRow)` with `.buttonStyle(TapTargetButtonStyle)`; the
// row is always collapsed and a tap opens the detail, never an in-place
// expansion. Body = a single HStack (alignment `.center`, no explicit
// spacing): the leading `ConditionalContent<IconFrame, WorkingMarkSlot…>`
// slot, the label, `TimelineStatusGlyph`, an optional `DiffIndicator`, the
// caret when `hasDetails`, then a spacer.
//
// 1023 construction evidence for the two rules this row once guessed wrong:
// both row builds — the tool packer `0x1033b901c` and the summary direct path
// `0x1033b8b20` — pass a concrete non-nil icon into the row init
// (`0x101e3dbd8`), so a settled row keeps its category icon; the slot only
// swaps to the working mark while a mark is seated. And `TimelineStatusGlyph`
// is a fixed tuple element of the row body (not behind a row-level
// condition); its body is `ConditionalContent<FailureGlyph, Image>` whose
// non-failure branch is `Image(systemName: "checkmark")` with
// `.fontWeight(.semibold)` and `accentSecondary100`.
//
// The only outer padding is `.padding(.vertical, 6)`; the official view
// carries no `minHeight` and no background/corner radius, so the row's height
// is the natural content height: 24 + 12 = 36 pt with an icon/caret, 21 + 12 =
// 33 pt for pure text.
//
// Every visible constant is from R28 (`visual-spec.md` §1–§4, §U 收口二/三)
// or the 1023 construction points above.

/// One run of the collapsed row's label. The official label is an
/// `AttributedString` with at most two runs (verb / target) or a per-category
/// summary; the view maps these semantic runs to fonts and token colours.
nonisolated struct CodeToolLabelRun: Equatable {
    nonisolated enum Role: Equatable {
        /// `text300` — the verb run. 1023 label colours: the summary's
        /// non-target runs (verb / category phrase / separator) use `text300`
        /// (`0x100b4e334`); AA previously painted the verb `text400`.
        case primary
        /// `text300` — multi-category summary phrases and separators
        /// (`0x100b4e334`, R28 §U 收口二 二-B).
        case secondary
        /// `text100` — the summary's target run (path / command / query).
        case target
        /// `danger00` — a failed call, or a `whole` failed category when
        /// `differentiateWithoutColor` is off.
        case failure
    }

    nonisolated enum Face: Equatable {
        case sans
        case mono
    }

    let text: String
    let role: Role
    let face: Face
}

/// The official `FailureExtent` (`swift_types.csv`, dump 20352).
nonisolated enum CodeFailureExtent: Hashable {
    case failed
    case partial
}

extension CodeToolLabelRun {
    /// Renders the semantic runs with the official fonts and tokens. Shared
    /// by the collapsed row and the group-detail list so the verb (`text300`)
    /// and target (`text100`) can never drift between them.
    static func styledText(_ runs: [CodeToolLabelRun],
                           scheme: ColorScheme) -> Text {
        var text = Text("")
        for run in runs {
            let font: Font = run.face == .mono
                ? .custom(CodePageTheme.monoFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowTextStyle)
                : .custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowBodyTextStyle)
            text = text
                + Text(run.text)
                    .font(font)
                    .foregroundStyle(color(for: run.role, scheme: scheme))
        }
        return text
    }

    private static func color(for role: Role, scheme: ColorScheme) -> Color {
        switch role {
        case .primary:
            return CodePageTheme.text300Color.resolved(for: scheme)
        case .secondary:
            return CodePageTheme.text300Color.resolved(for: scheme)
        case .target:
            return CodePageTheme.text100Color.resolved(for: scheme)
        case .failure:
            return CodePageTheme.danger00Color.resolved(for: scheme)
        }
    }
}

/// The official `CollapsedStepsRow` for the Code page.
///
/// Field list follows R28 §1.1 exactly. Two fields are hooks, not guessed
/// values:
/// - `workingMark`: a seated mark replaces the leading icon
///   (`ConditionalContent<IconFrame, WorkingMarkSlot…>`); only the 20×20
///   content box and the 30 fps cadence are decoded (D2/D3), so the slot
///   renders a frame-less skeleton instead of the retired 1019 artwork. AA
///   passes nil because no decoded predicate maps a live pose to the mark yet.
/// - `TimelineStatusGlyph` is a fixed element of the official row body. Its
///   non-failure branch is `Image(systemName: "checkmark")` semibold in
///   `accentSecondary100`; the `FailureGlyph` branch (failed / partial) is
///   UNKNOWN artwork (D6) and stays empty until asset/colour/frame are read.
struct CodeCollapsedStepsRow: View {
    var icon: String?
    var iconSize: AnthropiconSize = .large
    /// The pre-styled label. The caller owns the per-run fonts/colours, which
    /// keeps the failure rules in one place (`CodeToolLabels`).
    var text: Text
    var status: CodeToolStatus
    var failureExtent: CodeFailureExtent?
    var hasDetails: Bool
    var diffIndicator: CodeDiffStat?
    var workingMark: WorkingMarkBody?
    var isTextHidden: Bool = false
    /// D10 (R28 §U 收口二 二-E): the official `ToolRowCompanions` container
    /// draws settled rows first and `AttachmentTiles` second, and skips the
    /// settled `ForEach` when its count is 0. AA's segment model carries no
    /// settled/image data, so this row only reserves the flag; the U parts
    /// (empty attachment condition, VStack spacing) stay unimplemented.
    var includesImages: Bool = false
    var voiceControlName: String?
    var spokenLabel: String?
    var isRunning: Bool
    var action: () -> Void

    /// [E] R28 §2.1 — row text unscaled line height 21, relative `.body`.
    @ScaledMetric(relativeTo: CodePageTheme.toolRowBodyTextStyle)
    private var textLineHeight = CodePageTheme.toolRowTextLineHeight

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                leadingSlot

                if !isTextHidden {
                    text
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The official row has no minHeight; the line box is
                        // the 21 pt unscaled line height (V3). With an icon
                        // or caret the 24 pt slot wins, giving 36 pt.
                        .frame(minHeight: textLineHeight, alignment: .leading)
                        .layoutPriority(1)
                        .modifier(CodeCollapsedRowShimmer(active: isRunning))
                }

                CodeTimelineStatusGlyph(status: status,
                                        failureExtent: failureExtent)

                if let diffIndicator, diffIndicator.hasCounts {
                    CodeDiffIndicator(stat: diffIndicator)
                }

                if hasDetails {
                    CodeRowCaret()
                }

                // Official body ends in a `Spacer`, so the row's tap target
                // fills the transcript width while the content stays leading.
                Spacer(minLength: 0)
            }
            .padding(.vertical, CodePageTheme.toolRowButtonPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // D8 UNKNOWN (R28 §U 收口二 二-C): the official row has no direct
        // `.accessibilityLabel`/`.accessibilityValue` call; the Button's
        // automatic label from its visible text is the evidenced behaviour.
        // The optional `spokenLabel`/`voiceControlName` fields exist in the
        // official model, so apply them only when a caller supplies the
        // (not-yet-decoded) strings. Do not synthesise a spoken sentence.
        .modifier(CodeCollapsedRowAccessibility(spokenLabel: spokenLabel,
                                                voiceControlName: voiceControlName))
    }

    /// 1023 `TimelineStatusGlyph` branch. The row body always carries the
    /// glyph (fixed tuple element); the view itself chooses between the
    /// `FailureGlyph` branch and the `checkmark` branch.
    ///
    /// - `.failed` / any non-nil extent → `FailureGlyph` (D6 hook: its
    ///   artwork, colour and frame are UNKNOWN — R28 §U 收口三 — so nothing
    ///   is drawn yet).
    /// - `.complete` → `checkmark`. The glyph's `ConditionalContent` branch
    ///   predicate itself was not located; the checkmark builder is the
    ///   candidate and the non-failure branch is the only decoded one (R28
    ///   §U 收口三; still U at the predicate level).
    /// - `.running` → nothing. The running row's exact construction
    ///   (status/icon/workingMark) is not decoded — R28 §U 收口三 — so no
    ///   unproven mark is drawn; this is a hook, not a visual claim.
    static func statusGlyphKind(status: CodeToolStatus,
                                failureExtent: CodeFailureExtent?) -> CodeStatusGlyphKind {
        if status == .failed || failureExtent != nil { return .failure }
        if status == .complete { return .checkmark }
        return .none
    }

    /// [E] R28 §1.2 — `IconFrame` regular 24×24; the glyph inside keeps its
    /// official artwork extent (`AnthropiconAssets`), i.e. medium for the
    /// thinking row and large for tool category icons.
    @ViewBuilder
    private var leadingSlot: some View {
        if let workingMark {
            // The official first slot is `ConditionalContent<IconFrame,
            // WorkingMarkSlot + ZStack<WorkingMarkView>>`: a seated mark
            // replaces the category icon. D2/D3: only the 20×20 content box
            // and the 30 fps player are decoded; the sheet/frame sequence is
            // UNKNOWN, so the skeleton draws no frames yet (do not reuse the
            // retired 1019 mark, R28 §6).
            CodeWorkingMarkSkeleton(mark: workingMark)
        } else if let icon {
            AnthropiconView(name: icon, size: iconSize)
                .foregroundStyle(CodePageTheme.text500Color
                    .resolved(for: colorScheme))
                .frame(width: CodePageTheme.toolRowIconFrameSize,
                       height: CodePageTheme.toolRowIconFrameSize)
        }
    }

}

/// The collapsed row's caret: `anthropicon.caretRight` (`0x100bbfb60`) at
/// `Icon.Size.medium` (20 x 20 pt icon box, artwork aspect-fitted) inside a
/// 24 pt tall frame (`0x101e3eaa0`). No rotation; ink is `text400`
/// (`0x101e3ead0` → `0x100b50c28`).
///
/// The group-detail list row shares this view (same descriptor, same
/// `Icon.Size.medium`, gated by `hasDetails`). Its colour token getter is
/// `0x100b4ac5c`, which is not decoded to a name/colour (U, R28 §U 收口三);
/// the `text400` ink above is the collapsed row's value used as the stand-in.
/// Do not treat it as the group row's verified colour, and do not invent a
/// second one.
struct CodeRowCaret: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("anthropicon.caretRight")
            .resizable()
            .scaledToFit()
            .frame(width: CodePageTheme.toolRowCaretSlotSize,
                   height: CodePageTheme.toolRowCaretSlotSize)
            .foregroundStyle(CodePageTheme.text400Color
                .resolved(for: colorScheme))
            .frame(height: CodePageTheme.toolRowCaretFrameHeight)
            .accessibilityHidden(true)
    }
}

/// D2/D3 skeleton for the 1023 `WorkingMarkView` (R28 §U 收口二 二-F).
///
/// Evidenced: the content box is 20×20 pt, the player ticks at 30 fps
/// (1/30 s), and its key thresholds are 1.5 s / 0.5 s
/// (`0x101f070c0`/`0x101f07128`). The `WorkingMarkSheet` frame counts and the
/// per-pose opening/looping/closing/grow sequences are not decoded, so this
/// view reserves the official slot and cadence but draws no artwork; the
/// 1.5/0.5 thresholds have no segment mapping to apply yet. The pose is
/// passed through unchanged for the future sheet lookup.
private struct CodeWorkingMarkSkeleton: View {
    /// The pose is reserved for the future sheet lookup; it must not be named
    /// `body` because that collides with the `View.body` requirement.
    let mark: WorkingMarkBody

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / CodePageTheme.workingMarkFrameRate)) { _ in
            Color.clear
                .frame(width: CodePageTheme.workingMarkSize,
                       height: CodePageTheme.workingMarkSize)
        }
        .frame(width: CodePageTheme.workingMarkSize,
               height: CodePageTheme.workingMarkSize)
        .accessibilityHidden(true)
    }
}

/// The row's optional accessibility fields. The official row is a `Button`,
/// so its automatic label already reads the visible text; only the model's
/// `spokenLabel`/`voiceControlName` override that, and their strings are
/// UNKNOWN (D8). Keeping the branch empty by default avoids inventing a
/// spoken sentence while still wiring the fields.
private struct CodeCollapsedRowAccessibility: ViewModifier {
    let spokenLabel: String?
    let voiceControlName: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let spokenLabel {
            content
                .accessibilityLabel(Text(spokenLabel))
                .accessibilityInputLabels(voiceControlName.map { [Text($0)] } ?? [])
        } else if let voiceControlName {
            content.accessibilityInputLabels([Text(voiceControlName)])
        } else {
            content
        }
    }
}

/// Which branch of the official `TimelineStatusGlyph`
/// (`ConditionalContent<FailureGlyph, Image>`) a row takes.
///
/// The branch predicate is not located (U, R28 §U 收口三); the non-failure
/// `Image` construction is E, so `.checkmark` is the evidenced candidate.
nonisolated enum CodeStatusGlyphKind: Equatable {
    /// `Image(systemName: "checkmark")`, `.fontWeight(.semibold)`,
    /// `accentSecondary100` — E from the 1023 non-failure branch.
    case checkmark
    /// `FailureGlyph` — artwork, colour and frame still UNKNOWN (D6; R28
    /// §U 收口三).
    case failure
    /// Running: the official construction for that state is not decoded
    /// (R28 §U 收口三).
    case none
}

/// The official `TimelineStatusGlyph` (`R28 §4.3` + 1023 row construction).
///
/// The view is always present in the row body; this wrapper renders the
/// decoded non-failure branch (`checkmark` ink) and keeps the `FailureGlyph`
/// branch as the empty D6 hook.
///
/// Still UNKNOWN (D6, re-closed as U by R28 §U 收口三): the `FailureGlyph`
/// artwork for `.failed`/`.partial`, its foreground token and its frame size.
/// Do not substitute a warning symbol or `danger00`. The checkmark's font size
/// is likewise undecoded; the image renders at its natural semibold size with
/// no explicit frame.
struct CodeTimelineStatusGlyph: View {
    let status: CodeToolStatus
    let failureExtent: CodeFailureExtent?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch CodeCollapsedStepsRow.statusGlyphKind(status: status,
                                                     failureExtent: failureExtent) {
        case .checkmark:
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .foregroundStyle(CodePageTheme.accentSecondary100Color
                    .resolved(for: colorScheme))
        case .failure:
            // TODO(D6): FailureGlyph(extent:size:) — asset/glyph, colour and
            // frame size are UNKNOWN; `0x101e913c0` is the Thumbnail body and
            // must not be used here.
            EmptyView()
        case .none:
            EmptyView()
        }
    }
}

/// The official tool row wrapper: maps a segment's label plan to the shared
/// collapsed row. It never expands and never navigates itself; the caller
/// owns the detail sheet.
struct CodeCollapsedToolRow: View {
    let label: CodeToolRowLabel
    let icon: String?
    let iconSize: AnthropiconSize
    /// The seated working-mark pose; nil keeps the category icon. The pose
    /// comes from the official predicate (`CodeWorkingMarkPose`), not from a
    /// visual guess.
    let workingMark: WorkingMarkBody?
    let status: CodeToolStatus
    let failureExtent: CodeFailureExtent?
    let hasDetails: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The official `failureInWords` switch: a `whole` failed category is
    /// written out instead of painted red (R28 §2.4, task rule 6).
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    init(label: CodeToolRowLabel,
         icon: String? = nil,
         iconSize: AnthropiconSize = .large,
         workingMark: WorkingMarkBody? = nil,
         status: CodeToolStatus = .complete,
         failureExtent: CodeFailureExtent? = nil,
         hasDetails: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.iconSize = iconSize
        self.workingMark = workingMark
        self.status = status
        self.failureExtent = failureExtent
        self.hasDetails = hasDetails
        self.action = action
    }

    var body: some View {
        let runs = CodeToolLabels.runs(
            for: label, differentiateWithoutColor: differentiateWithoutColor)
        CodeCollapsedStepsRow(
            icon: icon,
            iconSize: iconSize,
            text: CodeToolLabelRun.styledText(runs, scheme: colorScheme),
            status: status,
            failureExtent: failureExtent,
            hasDetails: hasDetails,
            diffIndicator: label.diff,
            workingMark: workingMark,
            isTextHidden: false,
            includesImages: false,
            voiceControlName: nil,
            spokenLabel: nil,
            isRunning: label.isRunning,
            action: action)
    }

}

/// The official shimmer: `KeyframeAnimator(initialValue: 0.0, repeating:
/// true)` over a `LinearKeyframe(1.0, duration: 2.0, .linear)` (R28 U-C.3,
/// closed). The gradient geometry follows the previously decoded ShimmerView
/// (two tiled copies, 0.2 edge opacity); only its alpha profile is used.
///
/// D5 UNKNOWN: the official static scan found no `accessibilityReduceMotion`
/// read in `ShimmerOverlay`/`WorkingMark`; whether the animation stops under
/// Reduce Motion is unverified. Do not add a gating branch until measured.
private struct CodeCollapsedRowShimmer: ViewModifier {
    let active: Bool

    private static let period: Double = 2.0
    private static let edgeOpacity: Double = 0.2

    func body(content: Content) -> some View {
        if active {
            content.mask {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let gradient = LinearGradient(stops: [
                        .init(color: .white.opacity(Self.edgeOpacity), location: 0),
                        .init(color: .white, location: 0.5),
                        .init(color: .white.opacity(Self.edgeOpacity), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { progress in
                        ZStack {
                            gradient
                                .frame(width: width)
                                .offset(x: (progress - 1) * width)
                            gradient
                                .frame(width: width)
                                .offset(x: progress * width)
                        }
                    } keyframes: { _ in
                        LinearKeyframe(1.0, duration: Self.period, timingCurve: .linear)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// The official `DiffIndicator`: `+N` and `−N` share one 4.5 pt rounded pill,
/// each half carrying its own fill and ink (R28 U-B.2).
struct CodeDiffIndicator: View {
    let stat: CodeDiffStat

    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var horizontalPadding = CodePageTheme.diffIndicatorHorizontalPadding

    /// [E] R28 U-B.2 — each half is 18 pt tall and the glyph is
    /// 11 pt / 550 / 16 (ScaledMetric base values).
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var halfHeight = CodePageTheme.diffIndicatorHeight

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var fontSize = CodePageTheme.diffIndicatorFontSize

    /// [E] R28 U-B.2 — the glyph's unscaled line height is 16 pt.
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var textLineHeight = CodePageTheme.diffIndicatorLineHeight

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var cornerRadius = CodePageTheme.diffIndicatorCornerRadius

    var body: some View {
        HStack(spacing: 0) {
            if stat.added > 0 {
                half(text: "+\(stat.added)",
                     fill: CodePageTheme.diffIndicatorAddFill,
                     ink: CodePageTheme.diffIndicatorAddText)
            }
            if stat.removed > 0 {
                half(text: "−\(stat.removed)",
                     fill: CodePageTheme.diffIndicatorRemoveFill,
                     ink: CodePageTheme.diffIndicatorRemoveText)
            }
        }
        // [E] 11 pt / weight 550 in the official mono face.
        .font(Font(MarkdownFontFactory.font(
            name: CodePageTheme.monoFontName,
            size: fontSize,
            weight: CodePageTheme.diffIndicatorFontWeight)))
        .lineLimit(1)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // D8 UNKNOWN (R28 §U 收口二 二-C): the official `DiffIndicator` has
        // an `accessibilityLabel: Text` field whose text is not decoded.
        // Hiding it avoids inventing a spoken "+N −N" sentence; revisit with
        // the VoiceOver Inspector.
        .accessibilityHidden(true)
    }

    private func half(text: String,
                      fill: CodePageTheme.SchemeColor,
                      ink: CodePageTheme.SchemeColor) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(ink.resolved(for: colorScheme))
            .frame(minHeight: textLineHeight)
            .padding(.horizontal, horizontalPadding)
            .frame(height: halfHeight)
            .background(fill.resolved(for: colorScheme))
    }
}

#Preview("Collapsed tool row — settled") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Read",
                                                 target: "Package.swift",
                                                 isRunning: false)) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — running") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Ran",
                                                 target: "npm test",
                                                 isRunning: true),
                         icon: "anthropicon.commandLinePrompt",
                         status: .running) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — diff") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Edited",
                                                 target: "validate-email.ts",
                                                 diff: CodeDiffStat(added: 1, removed: 1),
                                                 isRunning: false),
                         icon: "anthropicon.edit") {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — failed") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Ran",
                                                 target: "npm test",
                                                 isRunning: false,
                                                 failed: 1,
                                                 total: 1),
                         icon: "anthropicon.commandLinePrompt",
                         status: .failed,
                         failureExtent: .failed) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}
