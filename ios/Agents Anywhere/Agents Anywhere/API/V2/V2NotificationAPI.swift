import Foundation

/// Reads the server-decided notification records directly.
///
/// The dashboard websocket is the live channel; this read lets the client
/// poll while it holds the background keep-alive, so a turn that ends during
/// a stalled push still surfaces. The server owns the decision either way.
nonisolated struct V2NotificationAPI {
    let transport: any HTTPTransport

    /// `wait > 0` asks the server to hold the request until a record appears
    /// or the wait expires (long polling). The shared session's 30 s request
    /// timeout leaves room for the server's 25 s cap.
    func notifications(wait: Int = 0) async throws -> V2DashboardNotificationsResponse {
        let query = wait > 0
            ? [URLQueryItem(name: "wait", value: String(wait))]
            : []
        let request = HTTPRequest<EmptyRequestBody, V2DashboardNotificationsResponse>(
            method: .get,
            path: "/dashboard/notifications",
            queryItems: query
        )
        return try await transport.send(request)
    }
}
