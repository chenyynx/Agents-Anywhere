import SwiftUI
import UIKit

/// Full-screen reader for one fenced code block.
///
/// Shape follows moonveil's `CodeBlockFullScreenView`: a large sheet with the
/// fence language as the title, an X on the leading edge and copy on the
/// trailing edge. The body is a UIKit text view rather than SwiftUI `Text`
/// because it must (a) wrap long lines at the viewport width, (b) scroll
/// vertically on its own, and (c) render exactly the attributed string Textual
/// already highlighted — SwiftUI cannot take a pre-built attributed value here.
struct ChatCodeFullScreenView: View {
    let code: String
    var language: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var cardBackground: Color {
        colorScheme == .dark ? ChatPalette.codeCardFill.color : .white
    }

    var body: some View {
        NavigationStack {
            ChatCodeFullScreenText(code: code, language: language)
                .background(cardBackground)
                .toolbarBackground(cardBackground, for: .navigationBar)
                .navigationTitle((language?.isEmpty == false ? language! : String(localized: "代码")).lowercased())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            AppSymbol("xmark", size: 15)
                        }
                        .accessibilityLabel(String(localized: "关闭"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            AppSymbol(copied ? "checkmark" : "document.on.document", size: 17)
                        }
                        .accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制代码"))
                    }
                }
        }
        .presentationBackground(cardBackground)
        .presentationDetents([.large])
    }
}

/// UIKit owns the layout end to end: the text view wraps at its
/// constraint-pinned width and scrolls itself, with no SwiftUI sizing
/// negotiation in the chain.
private struct ChatCodeFullScreenText: UIViewControllerRepresentable {
    let code: String
    let language: String?

    func makeUIViewController(context: Context) -> ChatCodeFullScreenController {
        let controller = ChatCodeFullScreenController()
        controller.apply(code: code, language: language)
        return controller
    }

    func updateUIViewController(_ controller: ChatCodeFullScreenController, context: Context) {
        controller.apply(code: code, language: language)
    }
}

final class ChatCodeFullScreenController: UIViewController {
    private let textView = UITextView()
    private var lastApplyKey: String?

    private static let monoFont: UIFont = {
        .monospacedSystemFont(ofSize: 14, weight: .regular)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = Self.monoFont
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    /// Re-applies content when the code, language or appearance changes; a
    /// light/dark flip must re-resolve the dynamic token colours while open.
    func apply(code: String, language: String?) {
        let key = "\(code.count)|\(language ?? "-")|\(traitCollection.userInterfaceStyle.rawValue)"
        guard key != lastApplyKey else { return }
        lastApplyKey = key

        let ink = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xF0 / 255, green: 0xEF / 255, blue: 0xEC / 255, alpha: 1)
                : UIColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0B / 255, alpha: 1)
        }
        let style = NSMutableParagraphStyle()
        // Force wrapping over the whole string so a long line can never run
        // past the text view's width.
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4

        let attributed = NSMutableAttributedString(string: code, attributes: [
            .font: Self.monoFont,
            .foregroundColor: ink,
            .paragraphStyle: style,
        ])
        textView.attributedText = attributed
    }
}
