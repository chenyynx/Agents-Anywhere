import Foundation

nonisolated protocol WebSocketConnection: AnyObject, Sendable {
    func messages() -> AsyncThrowingStream<Data, Error>
    nonisolated func send(_ data: Data) async throws
    nonisolated func close()
}

nonisolated protocol WebSocketTransport {
    func connect(url: URL) -> any WebSocketConnection
}

nonisolated struct URLSessionWebSocketTransport: WebSocketTransport {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func connect(url: URL) -> any WebSocketConnection {
        URLSessionWebSocketConnection(task: urlSession.webSocketTask(with: url))
    }
}

nonisolated final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    /// Receives socket frames until the server closes or the consumer cancels.
    func messages() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2048)) { continuation in
            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case let .data(bytes):
                            data = bytes
                        case let .string(text):
                            data = Data(text.utf8)
                        @unknown default:
                            continue
                        }
                        if case .dropped = continuation.yield(data) { throw HTTPError.streamOverflow }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [task] _ in
                receiveTask.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// The bridge protocols are JSON text frames; sending `.data` would make
    /// Starlette's `receive_json` reject the frame before handlers see it.
    nonisolated func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        try await task.send(.string(text))
    }

    nonisolated func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
