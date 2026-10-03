import Foundation

/// The line under the session title: "Agent · 设备". One source shared by the
/// chat header and the SubAgent panel's subtitle (§3.3) so the two always read
/// the same values.
enum SessionHeaderSubtitle {
    static func text(metadata: V2SessionMeta?, deviceName: String?, fallbackRuntimeName: String?) -> String {
        // The exact chain the header used before it moved here: the configured
        // instance name, then the runtime id, then the fallback, then "Agent".
        let configured = metadata?.runtimeName ?? metadata?.runtime
        let runtime = configured ?? fallbackRuntimeName
        let name = runtime ?? String(localized: "Agent")
        let device = deviceName ?? metadata?.connectorId
        return [name, device].compactMap { $0 }.joined(separator: " · ")
    }
}
