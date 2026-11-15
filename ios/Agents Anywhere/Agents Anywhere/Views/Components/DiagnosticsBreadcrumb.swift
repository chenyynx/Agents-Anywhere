import SwiftUI

/// Records page and sheet appearance for the diagnostics trail.
///
/// The state trail explains what the data did; a breadcrumb explains where the
/// reader was when it did. Names are stable, lowercase keys (no localized text,
/// no content), and the volume is two lines per screen visit — it stays in the
/// standard level.
struct DiagnosticsBreadcrumb: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                ClientDiagnosticsLog.shared.record(
                    kind: "ui.screen",
                    detail: ["name": name, "action": "enter"],
                    dedupe: false)
            }
            .onDisappear {
                ClientDiagnosticsLog.shared.record(
                    kind: "ui.screen",
                    detail: ["name": name, "action": "leave"],
                    dedupe: false)
            }
    }
}

extension View {
    func diagnosticsBreadcrumb(_ name: String) -> some View {
        modifier(DiagnosticsBreadcrumb(name: name))
    }
}
