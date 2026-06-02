#if canImport(Darwin)
import BonjourService
import FP
import Foundation
import WebSocketClient

extension DevToolsEnvironment {

    // MARK: - Standard live environment

    /// Creates a live `DevToolsEnvironment` backed by `URLSession` WebSocket
    /// and `NetworkTools` Bonjour discovery.
    ///
    /// All parameters have sensible defaults so the minimum viable call is just `.live()`.
    ///
    /// ```swift
    /// // Zero-config — MirrorJSON for both encode and decode (no time travel)
    /// devTools: .live()
    ///
    /// // With custom instance name
    /// devTools: .live(instanceId: "com.myapp", instanceName: "My App")
    ///
    /// // With custom JSON encoding (e.g. snake_case keys)
    /// let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
    /// devTools: .live(
    ///     encodeState: { state in
    ///         (state.flatMap { (try? encoder.encode($0 as! Encodable)) }).flatMap {
    ///             String(data: $0, encoding: .utf8)
    ///         } ?? MirrorJSON.encode(state as Any)
    ///     }
    /// )
    ///
    /// // Limit history to 50 entries on memory-constrained devices
    /// devTools: .live(maxHistorySize: 50)
    /// ```
    ///
    /// - Parameters:
    ///   - instanceId:         Identifier shown in the devtools instance list.
    ///                         Defaults to `Bundle.main.bundleIdentifier ?? "app"`.
    ///   - instanceName:       Human-readable label. Defaults to `instanceId`.
    ///   - maxHistorySize:     Max state JSON entries retained on the device (ring buffer).
    ///                         The canonical full history lives in the devtools panel on Mac.
    ///                         Default 200.
    ///   - bonjourServiceType: Bonjour service type to browse for. Default `"_reduxdevtools._tcp."`.
    ///   - encodeAction:       Serializes `AppAction` (as `Any`) to JSON. Default: ``MirrorJSON``,
    ///                         which uses `JSONEncoder` automatically for `Encodable` types.
    ///   - encodeState:        Serializes `AppState?` (as `Any?`) to JSON. Same default.
    ///   - decodeState:        Decodes a JSON string back to `AppState` (as `Any`).
    ///                         `nil` (default) disables time travel. Use `.live(for:)` to wire
    ///                         `JSONDecoder` automatically when `AppState: Decodable`.
    ///   - urlSession:         Session for WebSocket connections. Default `.shared`.
    public static func live(
        instanceId: String = Bundle.main.bundleIdentifier ?? "app",
        instanceName: String? = nil,
        maxHistorySize: Int = 200,
        bonjourServiceType: String = "_reduxdevtools._tcp.",
        encodeAction: @escaping @Sendable (Any) -> String = MirrorJSON.encode,
        encodeState: @escaping @Sendable (Any?) -> String = { state in
            state.map(MirrorJSON.encode) ?? "{}"
        },
        decodeState: (@Sendable (String) -> Any?)? = nil,
        urlSession: URLSession = .shared
    ) -> DevToolsEnvironment {
        let manager = DevToolsConnectionManager(maxHistorySize: maxHistorySize)

        return DevToolsEnvironment(
            connectionManager: manager,

            openConnection: { host, port in
                guard let url = URL(string: "ws://\(host):\(port)") else {
                    return DeferredTask<Result<WebSocketConnection, Error>> {
                        .failure(DevToolsConnectionError.invalidURL(host: host, port: port))
                    }
                }
                return urlSession
                    .webSocketConnection(with: url)
                    .flatMap { connection in
                        DeferredTask { await performSocketIOHandshake(connection: connection) }
                    }
            },

            browseServices: { serviceType in
                bonjourBrowserStream(serviceType: serviceType)
                    .map { $0.map(DiscoveredServiceEvent.from(browseEvent:)) }
            },

            resolveService: { service in
                bonjourResolve(BonjourServiceInfo(
                    name: service.name, type: service.type, domain: service.domain
                ))
                .map { $0.map(ResolvedService.from(resolved:)) }
            },

            instanceId:    instanceId,
            instanceName:  instanceName,
            encodeAction:  encodeAction,
            encodeState:   encodeState,
            decodeState:   decodeState
        )
    }

    // MARK: - Codable overload

    /// Creates a live environment with `JSONEncoder`/`JSONDecoder` wired automatically
    /// for `AppState: Codable`.
    ///
    /// Pass `AppState.self` so the compiler can infer the concrete type for encoding
    /// and decoding:
    ///
    /// ```swift
    /// // AppState: Codable — full time travel, zero manual config
    /// devTools: .live(for: AppState.self)
    ///
    /// // With custom instanceId
    /// devTools: .live(for: AppState.self, instanceId: "com.myapp")
    /// ```
    ///
    /// This overload sets:
    /// - `encodeState`: uses `JSONEncoder`; falls back to ``MirrorJSON`` on failure.
    /// - `decodeState`: uses `JSONDecoder`.
    /// - `encodeAction`: ``MirrorJSON`` (uses `JSONEncoder` automatically for `Encodable` actions).
    ///
    /// - Parameters:
    ///   - stateType:          The concrete `AppState` type. Pass `AppState.self`.
    ///   - instanceId:         Identifier shown in devtools. Default: bundle identifier.
    ///   - instanceName:       Human-readable label. Default: `instanceId`.
    ///   - maxHistorySize:     Ring buffer cap. Default 200.
    ///   - bonjourServiceType: Bonjour service type. Default `"_reduxdevtools._tcp."`.
    ///   - urlSession:         Session for WebSocket connections. Default `.shared`.
    public static func live<S: Codable & Sendable>(
        for stateType: S.Type,
        instanceId: String = Bundle.main.bundleIdentifier ?? "app",
        instanceName: String? = nil,
        maxHistorySize: Int = 200,
        bonjourServiceType: String = "_reduxdevtools._tcp.",
        urlSession: URLSession = .shared
    ) -> DevToolsEnvironment {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        return live(
            instanceId: instanceId,
            instanceName: instanceName,
            maxHistorySize: maxHistorySize,
            bonjourServiceType: bonjourServiceType,
            encodeAction: MirrorJSON.encode,
            encodeState: { state in
                if let s = state as? S,
                   let data = try? encoder.encode(s),
                   let str  = String(data: data, encoding: .utf8) { return str }
                return state.map(MirrorJSON.encode) ?? "{}"
            },
            decodeState: { json in
                json.data(using: .utf8).flatMap { try? decoder.decode(S.self, from: $0) }
            },
            urlSession: urlSession
        )
    }
}

// MARK: - Socket.io handshake

private func performSocketIOHandshake(
    connection: WebSocketConnection
) async -> Result<WebSocketConnection, Error> {
    guard case .success(.text(let openFrame)) = await connection.receive.first() else {
        return .failure(DevToolsConnectionError.handshakeFailed("no OPEN packet"))
    }
    guard case .open = SocketIO.parse(openFrame) else {
        return .failure(DevToolsConnectionError.handshakeFailed("expected OPEN, got: \(openFrame)"))
    }

    _ = await connection.send(.text(SocketIO.connect)).run()

    guard case .success(.text(let ackFrame)) = await connection.receive.first() else {
        return .failure(DevToolsConnectionError.handshakeFailed("no CONNECT ACK"))
    }
    guard case .connected = SocketIO.parse(ackFrame) else {
        return .failure(DevToolsConnectionError.handshakeFailed("expected CONNECT ACK, got: \(ackFrame)"))
    }

    return .success(connection)
}

// MARK: - Helpers

private extension DeferredStream {
    func first() async -> Element? {
        var iterator = makeAsyncIterator()
        return try? await iterator.next()
    }
}

private extension DiscoveredServiceEvent {
    static func from(browseEvent event: BonjourBrowseEvent) -> DiscoveredServiceEvent {
        switch event {
        case let .found(info):                 return .found(.init(info))
        case let .removed(info):               return .removed(.init(info))
        case let .updated(from: old, to: new): return .updated(from: .init(old), to: .init(new))
        }
    }
}

private extension DiscoveredService {
    init(_ info: BonjourServiceInfo) {
        self.init(name: info.name, type: info.type, domain: info.domain, txt: info.txt)
    }
}

private extension ResolvedService {
    static func from(resolved: ResolvedServiceInfo) -> ResolvedService {
        ResolvedService(
            name: resolved.name, type: resolved.type, domain: resolved.domain,
            host: resolved.host, port: resolved.port, ips: resolved.ips, txt: resolved.txt
        )
    }
}

private extension DeferredTask {
    func flatMap<T: Sendable>(_ transform: @escaping @Sendable (Success) async -> T) -> DeferredTask<T> {
        DeferredTask<T> { await transform(self.run()) }
    }

    func map<T: Sendable>(_ transform: @escaping @Sendable (Success) -> T) -> DeferredTask<T> {
        DeferredTask<T> { transform(await self.run()) }
    }
}

private extension DeferredStream {
    func map<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T) -> DeferredStream<T> {
        DeferredStream<T> {
            AsyncStream<T> { continuation in
                let task = Task {
                    for await element in self { continuation.yield(transform(element)) }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

public enum DevToolsConnectionError: Error {
    case invalidURL(host: String, port: UInt16)
    case handshakeFailed(String)
}
#endif
