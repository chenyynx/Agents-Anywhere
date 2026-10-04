import Foundation

/// Only explicit protocol translation keys are looked up. Agent/user prose,
/// model names, paths and opaque action/selection IDs remain unchanged.
enum RuntimeLocalizedCopy {
    static func text(_ fallback: String, metadata: JSONValue, field: String = "labelKey", locale: Locale = .current, bundle: Bundle = .main) -> String {
        guard let key = metadata["i18n"]?[field]?.stringValue else { return fallback }
        let translated = String(localized: String.LocalizationValue(key), bundle: bundle, locale: locale)
        return translated == key ? fallback : translated
    }

    /// Runtime errors whose Connector copy is product copy, not a log line.
    ///
    /// A `message` on the wire is written once, in English, by the Connector.
    /// That is the right default: most errors are diagnostic and are shown
    /// verbatim. It is the wrong default for the codes below, where the
    /// English sentence names the wrong cause — "Scheduled work did not
    /// report a result within 600 seconds" reads as *the model was slow*,
    /// while the truth is *the CLI process was terminated and every task
    /// running inside it ended*. A user told the false cause rescues nothing
    /// and retries nothing, so the false cause is the defect, not the wording.
    ///
    /// Entries are looked up by CODE, never matched on message text: the
    /// Connector owns the code's stability, and matching prose would break
    /// silently the first time that prose is edited.
    ///
    /// Unknown codes return nil so the caller keeps today's behaviour — the
    /// Connector's own message — rather than degrading to an empty string or
    /// a raw payload. That fallback is the contract with every future code
    /// this table has not been taught yet, and it is pinned by test.
    private static let runtimeErrorCopyKeys: [String: String] = [
        "claude_process_retired": "runtime.error.claudeProcessRetired",
    ]

    /// The catalog key this build would use for `code`, as the raw string, or
    /// nil when the code has no entry.
    ///
    /// Split out from `runtimeErrorText` so the SELECTION half — which code
    /// maps to which copy — is a pure function that tests can pin without a
    /// bundle. The catalog binding is verified by `ios/scripts/
    /// check-localization.py` and by the app build, not from a unit test.
    /// Keys stay raw `String`s because `String.LocalizationValue` cannot be
    /// converted back to a string (no such initializer); the catalog value is
    /// built at the lookup site instead.
    static func runtimeErrorCopyKey(for code: String?) -> String? {
        guard let code else { return nil }
        return runtimeErrorCopyKeys[code]
    }

    /// The localized sentence for `code`, or nil when this build has no copy
    /// for it.
    ///
    /// `params` is carried through rather than interpolated today: pp's
    /// finalized sentence is fixed, so an entry that consumes parameters must
    /// degrade to its parameterless form rather than print a hole. Callers
    /// pass the payload regardless, which keeps the signature honest for the
    /// first entry that does interpolate.
    static func runtimeErrorText(code: String?, params: JSONValue?, locale: Locale = .current, bundle: Bundle = .main) -> String? {
        guard let key = runtimeErrorCopyKey(for: code) else { return nil }
        let translated = String(localized: String.LocalizationValue(key), bundle: bundle, locale: locale)
        // An untranslated catalog hands the key back. That is not copy.
        guard translated != key else { return nil }
        return translated
    }
}

extension V2DeviceRuntimeStatus {
    var displayName: String {
        switch self {
        case .stopped: String(localized: "dashboard.device.runtimeStatus.stopped")
        case .discovering: String(localized: "dashboard.device.runtimeStatus.discovering")
        case .available: String(localized: "dashboard.device.runtimeStatus.available")
        case .unavailable: String(localized: "dashboard.device.runtimeStatus.unavailable")
        case .validating: String(localized: "dashboard.device.runtimeStatus.validating")
        case .starting: String(localized: "dashboard.device.runtimeStatus.starting")
        case .running: String(localized: "dashboard.device.runtimeStatus.running")
        case .stopping: String(localized: "dashboard.device.runtimeStatus.stopping")
        case .error: String(localized: "dashboard.device.runtimeStatus.error")
        case .unknown: String(localized: "dashboard.device.runtimeStatus.unknown")
        }
    }
}

extension V2RuntimeStatus {
    var displayName: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .waiting: String(localized: "Waiting")
        case .waitingApproval: String(localized: "Waiting for approval")
        case .pending: String(localized: "Pending")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping…")
        case .blocked: String(localized: "Blocked")
        case .error: String(localized: "Error")
        case .disconnected: String(localized: "Disconnected")
        case .unknown: String(localized: "Unknown")
        }
    }
}
