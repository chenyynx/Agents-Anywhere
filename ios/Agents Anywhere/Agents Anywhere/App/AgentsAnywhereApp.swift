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
                } else if ProcessInfo.processInfo.arguments.contains(TextKitM4BaselineAutoRun.launchArgument) {
                    // C5/M4 streaming baseline probe; never reachable from the product UI.
                    TextKitM4BaselineRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitM4AutoRunModel.launchArgument) {
                    // C5/M4 streaming gate; never reachable from the product UI.
                    TextKitM4AutoRunRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitMaskSpikeAutoRun.launchArgument) {
                    // C5/M4.2 TextKit mask spike; never reachable from the product UI.
                    TextKitMaskSpikeRootView()
                } else if ProcessInfo.processInfo.arguments.contains(TextKitM4_3AutoRunModel.launchArgument) {
                    // C5/M4.3 image/formula/footer gate; never reachable from the product UI.
                    TextKitM4_3AutoRunRootView()
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
