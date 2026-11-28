import Foundation
import Testing
@testable import ClientCore

nonisolated private final class CloseState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isClosed: Bool { lock.withLock { value } }
    func close() { lock.withLock { value = true } }
}

@MainActor private final class TestSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    nonisolated private let closed = CloseState()
    var isClosed: Bool { closed.isClosed }
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func messages() -> AsyncThrowingStream<Data, Error> { stream }
    nonisolated func send(_ data: Data) async throws {}
    nonisolated func close() { closed.close(); continuation.finish() }
}

@MainActor private final class TestSocketTransport: WebSocketTransport {
    let connection = TestSocketConnection()
    var url: URL?
    func connect(url: URL) -> any WebSocketConnection { self.url = url; return connection }
}

@Suite @MainActor struct RealtimeTests {
    @Test func ticketURLKeepaliveAndCancellation() async throws {
        let socket = TestSocketTransport()
        let api = V2RealtimeAPI(serverURL: URL(string: "https://example.test/api/v2?old=yes")!, transport: TestHTTPTransport(), webSocketTransport: socket)
        let stream = try api.sessionEvents(sessionId: "session", ticket: "ticket + &?")
        #expect(socket.url?.scheme == "wss")
        #expect(socket.url?.path == "/api/v2/sessions/session/ws")
        #expect(URLComponents(url: socket.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "ticket", value: "ticket + &?")])
        var received = 0
        let consume = Task { for try await _ in stream { received += 1 } }
        socket.connection.continuation.yield(Data(#"{"type":"keepalive"}"#.utf8))
        socket.connection.continuation.yield(try fixtureData("event"))
        try await eventually { received == 1 }
        consume.cancel(); _ = await consume.result
        try await eventually { socket.connection.isClosed }
    }

    @Test func phoneBridgeConnectionUsesPhonePath() throws {
        let socket = TestSocketTransport()
        let api = V2RealtimeAPI(
            serverURL: URL(string: "https://example.test/api/v2?old=yes")!,
            transport: TestHTTPTransport(),
            webSocketTransport: socket
        )
        _ = try api.phoneBridgeConnection(ticket: "ticket + &?")
        #expect(socket.url?.scheme == "wss")
        #expect(socket.url?.path == "/api/v2/phone/ws")
        #expect(
            URLComponents(url: socket.url!, resolvingAgainstBaseURL: false)?
                .queryItems == [URLQueryItem(name: "ticket", value: "ticket + &?")]
        )
    }

    @Test func phoneFrameParserCoversTheWireContract() throws {
        func parse(_ json: String) -> PhoneBridgeFrame? {
            PhoneBridgeFrame.parse(Data(json.utf8))
        }

        #expect(parse(#"{"type":"registered","deviceId":"d1"}"#) == .registered)
        #expect(
            parse(#"{"type":"open","bridgeId":"pb_12345678","port":8200,"connectorName":"Mac"}"#)
                == .open(bridgeId: "pb_12345678", port: 8200, connectorName: "Mac")
        )
        let payload = Data("hello".utf8)
        #expect(
            parse(#"{"type":"data","bridgeId":"pb_12345678","data":"aGVsbG8="}"#)
                == .data(bridgeId: "pb_12345678", payload: payload)
        )
        #expect(
            parse(#"{"type":"close","bridgeId":"pb_12345678","reason":"eof"}"#)
                == .close(bridgeId: "pb_12345678")
        )
        #expect(
            parse(#"{"type":"error","code":"port_refused","message":"no"}"#)
                == .error(code: "port_refused", message: "no")
        )
        #expect(
            parse(#"{"type":"error","code":"server_unavailable","message":"worker"}"#)
                == .error(code: "server_unavailable", message: "worker")
        )
        #expect(parse(#"{"type":"ping"}"#) == .ping)
        #expect(parse(#"{"type":"pong"}"#) == .pong)
        #expect(parse(#"{"type":"open","bridgeId":"pb_12345678","port":70000}"#) == nil)
        #expect(parse(#"{"type":"data","bridgeId":"pb_12345678","data":"%%%"}"#) == nil)
        #expect(parse(#"not-json"#) == nil)
    }

    @Test func phoneScopeIsExclusive() {
        let scope = V2WebSocketTicketScope(scope: .phone)
        #expect(scope.phone)
        #expect(!scope.dashboard)
        #expect(scope.sessionId == nil)
    }

    @Test func silentConnectionTimesOutEvenWhenPathIsOnline() async throws {
        let socket = TestSocketTransport()
        let api = V2RealtimeAPI(serverURL: URL(string: "https://example.test")!, transport: TestHTTPTransport(), webSocketTransport: socket,
                                heartbeatTimeout: .milliseconds(20), heartbeatCheckInterval: .milliseconds(5))
        let stream = try api.dashboardSnapshots(ticket: "ticket")
        do { for try await _ in stream {}; Issue.record("Expected silent socket timeout") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(socket.connection.isClosed)
    }

    @Test func overflowForcesRecoveryInsteadOfSilentlyDroppingEvents() async throws {
        let socket = TestSocketTransport()
        let api = V2RealtimeAPI(serverURL: URL(string: "https://example.test")!, transport: TestHTTPTransport(), webSocketTransport: socket)
        let stream = try api.sessionEvents(sessionId: "session", ticket: "ticket")
        let data = try fixtureData("event")
        for _ in 0..<2050 { socket.connection.continuation.yield(data) }
        try await eventually { socket.connection.isClosed }
        var received = 0
        do { for try await _ in stream { received += 1 }; Issue.record("Expected stream overflow") }
        catch { #expect(error is HTTPError) }
        #expect(received == 2048)
    }
}
