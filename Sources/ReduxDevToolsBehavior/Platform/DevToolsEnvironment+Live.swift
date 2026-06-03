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
        connectionMode: ConnectionMode = .manual,
        instanceId: String = Bundle.main.bundleIdentifier ?? "app",
        instanceName: String? = nil,
        maxHistorySize: Int = 200,
        bonjourServiceType: String = "_reduxdevtools._tcp.",
        urlSession: URLSession = .shared
    ) -> DevToolsEnvironment {
        let manager = DevToolsConnectionManager(maxHistorySize: maxHistorySize)

        return DevToolsEnvironment(
            connectionManager: manager,

            openConnection: { host, port in
                guard let url = URL(string: "ws://\(host):\(port)/socketcluster/") else {
                    return DeferredTask<Result<WebSocketConnection, Error>> {
                        .failure(DevToolsConnectionError.invalidURL(host: host, port: port))
                    }
                }
                return urlSession.webSocketConnection(with: url).map(Result<WebSocketConnection, Error>.success)
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

            instanceId:     instanceId,
            instanceName:   instanceName,
            connectionMode: connectionMode
        )
    }
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
