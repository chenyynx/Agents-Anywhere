import Foundation

/// Reads the server-decided notification records directly.
///
/// The dashboard websocket is the live channel; this read lets the client
/// poll while it holds the background keep-alive, so a turn that ends during
/// a stalled push still surfaces. The server owns the decision either way.
nonisolated struct V2NotificationAPI {
    let transport: any HTTPTransport

    func notifications() async throws -> [V2DashboardNotification] {
        let request = HTTPRequest<EmptyRequestBody, V2DashboardNotificationsResponse>(
            method: .get,
            path: "/dashboard/notifications"
        )
        return try await transport.send(request).notifications
    }
}
