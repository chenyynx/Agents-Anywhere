import UIKit

/// Minimal application delegate: only installs the notification-centre
/// delegate early.
///
/// `UNUserNotificationCenter` must have its delegate in place before
/// `didFinishLaunching` returns. A delegate installed later (for example from
/// a SwiftUI `.onAppear`) is too late for a cold launch: iOS does not deliver
/// the tapped notification to `didReceive` at all, and the app falls through
/// to the saved selection instead of the tapped session. OpenMinis carries the
/// same fix as `T-notification-tap-vs-launch-session`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationService.shared.activate()
        return true
    }
}
