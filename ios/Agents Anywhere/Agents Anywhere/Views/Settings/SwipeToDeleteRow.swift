import SwiftUI

/// Right-swipe delete for a settings row.
///
/// The settings screen is a `ScrollView` of custom cards, not a `List`, so
/// `swipeActions` is unavailable. Dragging a row to the right slides it over a
/// red action at the leading edge; past the midpoint it stays open and the
/// action deletes. Only one row is open at a time — the parent owns `openID`.
///
/// The row's own background uses the card colour so the action never shows
/// through, with the section card's corner radius on the first and last rows
/// (a square background there would paint over the card's rounded corner).
struct SwipeToDeleteRow<Content: View>: View {
    let id: String
    @Binding var openID: String?
    /// First/last row of the card: their background follows the card corners.
    let isFirst: Bool
    let isLast: Bool
    let onDelete: () -> Void
    private let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragX: CGFloat = 0
    @State private var isHorizontalDrag = false

    init(id: String,
         openID: Binding<String?>,
         isFirst: Bool = false,
         isLast: Bool = false,
         onDelete: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self._openID = openID
        self.isFirst = isFirst
        self.isLast = isLast
        self.onDelete = onDelete
        self.content = content
    }

    private static var actionWidth: CGFloat { 84 }

    private var isOpen: Bool { openID == id }

    private var offset: CGFloat {
        let base = isOpen ? Self.actionWidth : 0
        return max(0, min(Self.actionWidth, base + dragX))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Dismisses the open row when the reader taps the revealed area.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isOpen else { return }
                    withAnimation(.easeOut(duration: 0.18)) { openID = nil }
                }

            rowContent
        }
        .simultaneousGesture(swipe)
        .clipped()
        // The gesture is invisible to VoiceOver; the action keeps the same
        // delete reachable without it.
        .accessibilityAction(named: Text(String(localized: "删除"))) { onDelete() }
        .onChange(of: openID) { _, newValue in
            if newValue != id { dragX = 0 }
        }
    }

    /// The row slides right over the action, which rides in its leading
    /// overlay so it inherits the row's height. When closed the action sits
    /// outside the row's bounds: clipped away and not hit-testable.
    private var rowContent: some View {
        content()
            .background(cardBackground)
            // While open the row must not navigate; the action and the clear
            // background own the tap.
            .allowsHitTesting(!isOpen)
            .overlay(alignment: .leading) {
                actionButton
                    .offset(x: -Self.actionWidth)
                    .allowsHitTesting(offset > 0)
            }
            .offset(x: offset)
    }

    private var actionButton: some View {
        Button(role: .destructive) {
            onDelete()
            withAnimation(.easeOut(duration: 0.18)) { openID = nil }
        } label: {
            VStack(spacing: 4) {
                AppSymbol("trash", size: 17)
                Text(String(localized: "删除"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .frame(width: Self.actionWidth)
            .frame(maxHeight: .infinity)
            .background(Color.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(offset > 0 ? 1 : 0)
    }

    private var cardBackground: some View {
        let radius = SettingsStyle.cardRadius
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: isFirst ? radius : 0,
                bottomLeading: isLast ? radius : 0,
                bottomTrailing: isLast ? radius : 0,
                topTrailing: isFirst ? radius : 0),
            style: .continuous)
            .fill(SettingsStyle.card(colorScheme))
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                if !isHorizontalDrag {
                    guard horizontal else { return }
                    isHorizontalDrag = true
                }
                guard horizontal else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                guard isHorizontalDrag else { return }
                isHorizontalDrag = false
                let projected = offset + (value.predictedEndTranslation.width - value.translation.width)
                let shouldOpen = projected > Self.actionWidth * 0.5
                withAnimation(.easeOut(duration: 0.18)) {
                    openID = shouldOpen ? id : nil
                    dragX = 0
                }
            }
    }
}
