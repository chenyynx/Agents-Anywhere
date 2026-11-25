import SwiftUI

/// Root for a tab whose feature ships in a later project. It keeps the shell
/// chrome (toolbar + drawer menu) identical to the working tabs so the tab bar
/// can be judged on its own.
struct PlaceholderTabPage: View {
    let title: String
    let icon: String
    let onMenu: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea()
            VStack(spacing: 10) {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(String(localized: "Coming in a later build"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
        .modifier(ChatPageToolbar(title: title, onMenu: onMenu))
    }
}
