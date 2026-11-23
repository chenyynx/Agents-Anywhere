import Foundation

/// Reads the server-decided notification records directly.
///
/// The dashboard websocket is the live channel; this read lets the client
/// poll while it holds the background keep-alive, so a turn that ends during
/// a stalled push still surfaces. The server owns the decision either way.
nonisolated struct V2NotificationAPI {
    let transport: any HTTPTransport

    /// `wait > 0` asks the server to hold the request until a record the
    /// client does not already hold appears, or the wait expires (long
    /// polling). Without `known`, any unread record answers immediately — the
    /// server cannot tell it apart from a new one. The shared session's 30 s
    /// request timeout leaves room for the server's 25 s cap.
    func notifications(
        wait: Int = 0,
        known: [String] = []
    ) async throws -> V2DashboardNotificationsResponse {
        var query: [URLQueryItem] = []
        if wait > 0 {
            query.append(URLQueryItem(name: "wait", value: String(wait)))
        }
        if !known.isEmpty {
            query.append(URLQueryItem(name: "known", value: known.joined(separator: ",")))
        }
        let request = HTTPRequest<EmptyRequestBody, V2DashboardNotificationsResponse>(
            method: .get,
            path: "/dashboard/notifications",
            queryItems: query
        )
        return try await transport.send(request)
    }
}
