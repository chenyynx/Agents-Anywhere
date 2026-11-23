import CoreLocation

/// Coarse-location keep-alive (Poki's `BackgroundKeeper` location half,
/// adapted). The ladder's level 3: entered only when silent audio cannot hold
/// the process (it failed to start or another app's audio interrupted it).
///
/// Three-kilometre accuracy plus the largest possible distance filter: the
/// point of the subscription is the background execution, never a location.
/// Nothing here reads, stores or sends a coordinate. With Always
/// authorization iOS shows no location indicator for this accuracy; with
/// When-In-Use, `CLBackgroundActivitySession` carries the updates into the
/// background and the indicator is visible.
@MainActor
final class CoarseLocationKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var activity: CLBackgroundActivitySession?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isOn = false
    /// Authorization changed (granted/denied); the coordinator re-evaluates.
    var onChange: (@MainActor () -> Void)?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var always: Bool { authorization == .authorizedAlways }

    /// iOS asks for While-Using first and offers the Always upgrade on the
    /// second request; the caller decides when one is worth asking.
    func requestPermission() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestAlwaysAuthorization()
        }
    }

    func start() {
        guard allowed else {
            requestPermission()
            return
        }
        guard !isOn else { return }
        isOn = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = !always
        if !always, activity == nil {
            activity = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.location.start",
            detail: ["authorization": Self.label(authorization)],
            dedupe: false)
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        manager.stopUpdatingLocation()
        activity?.invalidate()
        activity = nil
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.location.stop",
            dedupe: false)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = status
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.location.authorization",
                detail: ["status": Self.label(status)],
                dedupe: false)
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    var authorizationLabel: String { Self.label(authorization) }

    private static func label(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedWhenInUse: "whenInUse"
        case .authorizedAlways: "always"
        @unknown default: "unknown"
        }
    }
}
