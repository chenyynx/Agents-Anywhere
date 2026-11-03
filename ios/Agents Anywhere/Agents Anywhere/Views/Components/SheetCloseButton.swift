import SwiftUI

struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        // iOS 26 的系统 close role 会按工具栏默认字号画一颗偏大的 X
        // （b917 实测约 16 pt）。官方 sheet 的 X 更小，所以这里显式给
        // 13 pt 的 xmark，并用 glass 样式自己画圆钮——不再依赖系统
        // close 的默认 label。
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
    }
}

/// Sheet dismissal always uses the same leading X. Native navigation continues
/// to own the separate Back action on pushed pages.
struct SheetCloseToolbar: ToolbarContent {
    var disabled = false
    let action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            SheetCloseButton(action: action).disabled(disabled)
        }
        // The button draws its own glass circle; hide the shared toolbar
        // capsule so the close control is one circle, not a capsule + circle.
        .sharedBackgroundVisibility(.hidden)
    }
}

struct SheetEditorToolbar: ToolbarContent {
    var saveTitle = String(localized: "Save")
    var isWorking = false
    var saveDisabled = false
    let onCancel: () -> Void
    let onSave: () -> Void
    var body: some ToolbarContent {
        SheetCloseToolbar(disabled: isWorking, action: onCancel)
        SheetSaveToolbar(saveTitle: saveTitle, isWorking: isWorking, saveDisabled: saveDisabled, onSave: onSave)
    }
}

/// Pushed editors keep the system Back button and interactive pop gesture.
struct SheetSaveToolbar: ToolbarContent {
    var saveTitle = String(localized: "Save")
    var isWorking = false
    var saveDisabled = false
    let onSave: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm, action: onSave) {
                Text(saveTitle).opacity(isWorking ? 0 : 1)
                    .overlay { if isWorking { ProgressView().controlSize(.small) } }
            }
            .disabled(isWorking || saveDisabled).keyboardShortcut("s", modifiers: .command)
        }
    }
}

extension View {
    func confirmDiscardChanges(_ isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        confirmationDialog(String(localized: "Discard unsaved changes?"), isPresented: isPresented, titleVisibility: .visible) {
            Button(String(localized: "Discard changes"), role: .destructive, action: onDiscard)
            Button(String(localized: "Keep editing"), role: .cancel) {}
        }
    }
}
