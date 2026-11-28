import Foundation
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// App-side Phone Bridge: keeps an outbound WebSocket to the AA Server and
/// dials iCTRL on loopback for every `open` frame. The Server never sees
/// iCTRL's plaintext; this client forwards raw bytes only.
@MainActor
@Observable
final class PhoneBridgeClient {
    enum Status: Equatable {
        case off
        case connecting
        case connected
        case error(String)
    }

    enum IctrlStatus: Equatable {
        case unknown
        case checking
        case available
        case unavailable
    }

    static let bridgeVersion = "1"

    private(set) var status: Status = .off
    private(set) var ictrlStatus: IctrlStatus = .unknown
    private(set) var currentComputerName: String?
    private(set) var lastError: String?
    private(set) var lastActivityAt: Date?
    private(set) var latencyMilliseconds: Int?
    private(set) var isEnabled: Bool
    private(set) var isFatalError = false

    @ObservationIgnored private let realtime: V2RealtimeAPI
    @ObservationIgnored private let enabledKey: String
    @ObservationIgnored private let deviceIdKey: String
    @ObservationIgnored private let clientId = "ios-phone-\(UUID().uuidString)"
    @ObservationIgnored private let deviceId: String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var socket: (any WebSocketConnection)?
    @ObservationIgnored private var tunnels: [String: BridgeTunnel] = [:]
    @ObservationIgnored private var seqByBridge: [String: Int] = [:]
    @ObservationIgnored private var pingStartedAt: Date?
    @ObservationIgnored private var reconnectDelay: UInt64 = 1
    @ObservationIgnored private var sendQueue: [Data] = []
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var sendGeneration = 0
    @ObservationIgnored private var runGeneration = 0

    init(realtime: V2RealtimeAPI, storageScope: String) {
        self.realtime = realtime
        enabledKey = "phoneBridge.enabled.\(storageScope)"
        deviceIdKey = "phoneBridge.deviceId.\(storageScope)"
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        if let stored = UserDefaults.standard.string(forKey: deviceIdKey),
           !stored.isEmpty {
            deviceId = stored
        } else {
            let id = "iphone-\(UUID().uuidString.lowercased())"
            UserDefaults.standard.set(id, forKey: deviceIdKey)
            deviceId = id
        }
        probeIctrl()
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled, task == nil else { return }
        lastError = nil
        isFatalError = false
        pingStartedAt = nil
        setStatus(.connecting)
        runGeneration += 1
        let generation = runGeneration
        task = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    func stop() {
        runGeneration += 1
        task?.cancel()
        task = nil
        probeTask?.cancel()
        probeTask = nil
        closeTunnels()
        socket?.close()
        socket = nil
        resetSendQueue()
        isFatalError = false
        currentComputerName = nil
        pingStartedAt = nil
        latencyMilliseconds = nil
        setStatus(.off)
    }

    func probeIctrl() {
        probeTask?.cancel()
        ictrlStatus = .checking
        probeTask = Task { [weak self] in
            var request = URLRequest(
                url: URL(string: "http://127.0.0.1:8200/schema")!
            )
            request.timeoutInterval = 2
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 200,
                   !data.isEmpty {
                    self?.ictrlStatus = .available
                } else {
                    self?.ictrlStatus = .unavailable
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.ictrlStatus = .unavailable
            }
        }
    }

    /// Sends one ping; the pong latency lands in `latencyMilliseconds`.
    func testConnection() {
        guard status == .connected, socket != nil else { return }
        pingStartedAt = Date()
        latencyMilliseconds = nil
        send(["type": "ping"])
    }

    // MARK: - Socket loop

    private func run(generation: Int) async {
        guard generation == runGeneration else { return }
        var fatal = false
        reconnectDelay = 1
        while !Task.isCancelled && isEnabled && generation == runGeneration {
            resetSendQueue()
            do {
                let ticket = try await realtime.ticket(
                    clientId: clientId,
                    scope: .phone
                )
                let connection = try realtime.phoneBridgeConnection(
                    ticket: ticket.ticket
                )
                guard generation == runGeneration else {
                    connection.close()
                    return
                }
                socket = connection
                lastActivityAt = Date()
                setStatus(.connecting)
                try await connection.send(helloData())
                let heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard let self, !Task.isCancelled else { return }
                        if let last = self.lastActivityAt,
                           Date().timeIntervalSince(last) > 45 {
                            self.socket?.close()
                            return
                        }
                        self.send(["type": "ping"])
                    }
                }
                defer { heartbeat.cancel() }
                for try await data in connection.messages() {
                    if Task.isCancelled { break }
                    lastActivityAt = Date()
                    handle(data)
                }
                if Task.isCancelled { break }
                throw URLError(.networkConnectionLost)
            } catch {
                if Task.isCancelled { break }
                if isPermanent(error) || isFatalError {
                    lastError = isFatalError
                        ? (lastError ?? "phone bridge unavailable")
                        : error.localizedDescription
                    isFatalError = true
                    setStatus(.error(lastError ?? "phone bridge unavailable"))
                    fatal = true
                    break
                }
                if generation != runGeneration { return }
                closeTunnels()
                socket = nil
                resetSendQueue()
                pingStartedAt = nil
                currentComputerName = nil
                lastError = error.localizedDescription
                setStatus(.error(error.localizedDescription))
                try? await Task.sleep(for: .seconds(Int(reconnectDelay)))
                guard generation == runGeneration else { return }
                reconnectDelay = min(reconnectDelay * 2, 5)
                continue
            }
        }
        guard generation == runGeneration else { return }
        closeTunnels()
        socket = nil
        currentComputerName = nil
        task = nil
        if !Task.isCancelled && !fatal {
            setStatus(.off)
        }
    }

    private func handle(_ data: Data) {
        guard let frame = PhoneBridgeFrame.parse(data) else { return }
        switch frame {
        case .registered:
            lastError = nil
            isFatalError = false
            reconnectDelay = 1
            pingStartedAt = nil
            setStatus(.connected)
        case let .open(bridgeId, port, connectorName):
            openTunnel(bridgeId: bridgeId, port: port)
            if let connectorName, !connectorName.isEmpty {
                currentComputerName = connectorName
            }
        case let .data(bridgeId, payload):
            tunnels[bridgeId]?.send(payload)
        case let .close(bridgeId):
            closeTunnel(bridgeId)
        case .ping:
            send(["type": "pong"])
        case let .error(code, message):
            // A bridge-level error does not tear down the phone socket; a
            // server_unavailable error is fatal for this run.
            lastError = message
            if code == "server_unavailable" {
                isFatalError = true
                setStatus(.error(message))
            }
        case .pong:
            if let started = pingStartedAt {
                latencyMilliseconds = max(
                    0,
                    Int(Date().timeIntervalSince(started) * 1000)
                )
                pingStartedAt = nil
            }
        }
    }

    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private func helloData() -> Data {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let payload: [String: Any] = [
            "type": "hello",
            "deviceId": deviceId,
            "name": deviceName,
            "appVersion": version,
            "bridgeVersion": Self.bridgeVersion,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func send(_ object: [String: Any]) {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        sendQueue.append(data)
        guard sendTask == nil else { return }
        let generation = sendGeneration
        sendTask = Task { [weak self] in
            await self?.drainSendQueue(generation: generation)
        }
    }

    /// One writer task keeps frame order: concurrent `URLSessionWebSocketTask`
    /// sends are not a documented ordering guarantee, and a reordered `data`
    /// frame would corrupt the iCTRL HTTP stream.
    private func drainSendQueue(generation: Int) async {
        while generation == sendGeneration, !sendQueue.isEmpty {
            let data = sendQueue.removeFirst()
            guard let socket else { break }
            do {
                try await socket.send(data)
            } catch {
                break
            }
            guard generation == sendGeneration else { return }
        }
        if generation == sendGeneration {
            sendTask = nil
        }
    }

    private func resetSendQueue() {
        sendGeneration += 1
        sendTask?.cancel()
        sendTask = nil
        sendQueue.removeAll()
    }

    private func openTunnel(bridgeId: String, port: UInt16) {
        closeTunnel(bridgeId)
        // The Server allowlists 8200; the phone enforces the same boundary so
        // a compromised/malicious Server cannot turn the device into a generic
        // loopback port proxy.
        guard port == 8200 else {
            send([
                "type": "error",
                "bridgeId": bridgeId,
                "code": "port_refused",
                "message": "only 8200 is allowed",
            ])
            return
        }
        guard let tunnel = BridgeTunnel(bridgeId: bridgeId, port: port) else {
            send([
                "type": "error",
                "bridgeId": bridgeId,
                "code": "port_refused",
                "message": "invalid local port",
            ])
            return
        }
        seqByBridge[bridgeId] = 0
        tunnel.onReady = { [weak self] in
            self?.send([
                "type": "ready",
                "bridgeId": bridgeId,
                "port": Int(port),
            ])
        }
        tunnel.onData = { [weak self] payload in
            self?.sendTunnelData(bridgeId: bridgeId, payload: payload)
        }
        tunnel.onClose = { [weak self] in
            guard let self else { return }
            self.send([
                "type": "close",
                "bridgeId": bridgeId,
                "reason": "eof",
            ])
            self.finishTunnel(bridgeId)
        }
        tunnel.onFailure = { [weak self] code in
            guard let self else { return }
            let message = code == "port_refused"
                ? "could not reach iCTRL on 127.0.0.1:8200"
                : "the iCTRL connection failed"
            self.send([
                "type": "error",
                "bridgeId": bridgeId,
                "code": code,
                "message": message,
            ])
            self.finishTunnel(bridgeId)
        }
        tunnels[bridgeId] = tunnel
        tunnel.start()
    }

    private func sendTunnelData(bridgeId: String, payload: Data) {
        let next = (seqByBridge[bridgeId] ?? 0) + 1
        seqByBridge[bridgeId] = next
        send([
            "type": "data",
            "bridgeId": bridgeId,
            "seq": next,
            "data": payload.base64EncodedString(),
        ])
    }

    private func finishTunnel(_ bridgeId: String) {
        tunnels.removeValue(forKey: bridgeId)
        seqByBridge.removeValue(forKey: bridgeId)
        if tunnels.isEmpty {
            currentComputerName = nil
        }
    }

    private func closeTunnel(_ bridgeId: String) {
        tunnels.removeValue(forKey: bridgeId)?.cancel()
        seqByBridge.removeValue(forKey: bridgeId)
        if tunnels.isEmpty {
            currentComputerName = nil
        }
    }

    private func closeTunnels() {
        for tunnel in tunnels.values {
            tunnel.cancel()
        }
        tunnels.removeAll()
        seqByBridge.removeAll()
    }

    private func isPermanent(_ error: Error) -> Bool {
        guard let http = error as? HTTPError, let code = http.statusCode else {
            return false
        }
        return code == 401 || code == 403 || code == 404 || code == 422
    }

    private func setStatus(_ next: Status) {
        guard next != status else { return }
        status = next
        switch next {
        case .connected:
            ClientDiagnosticsLog.shared.record(
                kind: "phone.bridge.connect",
                detail: ["device": deviceId],
                dedupe: false
            )
        case let .error(message):
            ClientDiagnosticsLog.shared.record(
                kind: "phone.bridge.error",
                detail: ["device": deviceId, "error": message],
                dedupe: true
            )
        case .off, .connecting:
            break
        }
    }
}

/// Decoded server→phone frames. Pure so the package tests can pin the wire
/// contract without a socket or a Network.framework tunnel.
nonisolated enum PhoneBridgeFrame: Equatable {
    case registered
    case open(bridgeId: String, port: UInt16, connectorName: String?)
    case data(bridgeId: String, payload: Data)
    case close(bridgeId: String)
    case error(code: String, message: String)
    case ping
    case pong

    static func parse(_ data: Data) -> PhoneBridgeFrame? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        switch type {
        case "registered":
            return .registered
        case "open":
            guard
                let bridgeId = object["bridgeId"] as? String,
                let port = object["port"] as? Int,
                let nwPort = UInt16(exactly: port)
            else { return nil }
            return .open(
                bridgeId: bridgeId,
                port: nwPort,
                connectorName: object["connectorName"] as? String
            )
        case "data":
            guard
                let bridgeId = object["bridgeId"] as? String,
                let encoded = object["data"] as? String,
                let payload = Data(base64Encoded: encoded)
            else { return nil }
            return .data(bridgeId: bridgeId, payload: payload)
        case "close":
            guard let bridgeId = object["bridgeId"] as? String else { return nil }
            return .close(bridgeId: bridgeId)
        case "error":
            return .error(
                code: object["code"] as? String ?? "phone_error",
                message: object["message"] as? String ?? "phone bridge error"
            )
        case "ping":
            return .ping
        case "pong":
            return .pong
        default:
            return nil
        }
    }
}

/// One loopback TCP connection to iCTRL. The Server bridge is one TCP stream,
/// so every accepted local connection gets its own tunnel.
@MainActor
private final class BridgeTunnel {
    let bridgeId: String
    let port: UInt16
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.agentsanywhere.phonebridge.tunnel")
    private var closed = false
    private var ready = false

    init?(bridgeId: String, port: UInt16) {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return nil }
        self.bridgeId = bridgeId
        self.port = port
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpoint,
            using: .tcp
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in
                    self.ready = true
                    self.onReady?()
                }
            case .failed:
                Task { @MainActor in
                    self.finish(failure: self.ready ? "connection_failed" : "port_refused")
                }
            case .cancelled:
                Task { @MainActor in self.finish() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ payload: Data) {
        guard !closed else { return }
        connection.send(
            content: payload,
            completion: .contentProcessed { _ in }
        )
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.onData?(data) }
            }
            if error != nil {
                Task { @MainActor in
                    self.finish(
                        failure: self.ready ? "connection_failed" : "port_refused"
                    )
                }
                return
            }
            if isComplete {
                Task { @MainActor in self.finish() }
                return
            }
            Task { @MainActor in self.receive() }
        }
    }

    private func finish(failure: String? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        if let failure {
            onFailure?(failure)
        } else {
            onClose?()
        }
        onFailure = nil
        onClose = nil
        onData = nil
        onReady = nil
    }
}
