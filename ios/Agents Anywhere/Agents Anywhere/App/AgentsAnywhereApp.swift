import SwiftUI

@main
struct AgentsAnywhereApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearanceValue = AppAppearance.system.rawValue

    init() {
        AppFontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(TimelineAutoRunModel.launchArgument) {
                    // C3 simulator gate; never reachable from the product UI.
                    TimelineAutoRunRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitSpikeModel.launchArgument) {
                    // C5/M1 TextKit 2 measurement spike; never reachable from the product UI.
                    TextKitSpikeRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitM3AutoRunModel.launchArgument) {
                    // C5/M3 assistant-body gate; never reachable from the product UI.
                    TextKitM3AutoRunRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitVisualParityAutoRunModel.launchArgument) {
                    // C5 visual-parity capture; never reachable from the product UI.
                    TextKitVisualParityRootView()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environment(appState)
                .background {
                    #if targetEnvironment(macCatalyst)
                    MacCatalystWindowTitle(appState: appState)
                    #endif
                }
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { appState.setAppInBackground(true) }
                    else if phase == .active { appState.setAppInBackground(false) }
                }
        }
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceValue) ?? .system
    }
}
