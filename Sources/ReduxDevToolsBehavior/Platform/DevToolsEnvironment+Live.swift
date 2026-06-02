#if canImport(Darwin)
import BonjourService
import FP
import Foundation
import WebSocketClient

extension DevToolsEnvironment {
    /// Creates a live `DevToolsEnvironment` backed by `URLSession` WebSocket
    /// and the Bonjour service browser from `NetworkTools`.
    ///
    /// This is the environment to use in production (or debug) builds:
    ///
    /// ```swift
    /// extension AppEnvironment {
    ///     static let live = AppEnvironment(
    ///         // ...
    ///         devTools: .live()
    ///     )
    /// }
    /// ```
    ///
    /// ## Bonjour service type
    ///
    /// The default service type is `"_reduxdevtools._tcp."`. If you run a custom
    /// remotedev-server that advertises a different type, pass it as `bonjourServiceType`.
    ///
    /// - Parameters:
    ///   - urlSession: The `URLSession` used to open WebSocket connections.
    ///   - bonjourServiceType: Bonjour service type to browse for when
    ///     ``DevToolsAction/startBrowsing`` is dispatched.
    /// - Parameters:
    ///   - urlSession:          The `URLSession` used to open WebSocket connections.
    ///   - bonjourServiceType:  Bonjour service type to browse for.
    ///   - maxHistorySize:      Maximum number of state JSON strings to retain on the device.
    ///                          Older entries are evicted when the limit is reached. Default 200.
    ///                          The canonical full history is stored in the devtools panel on the Mac.
    public static func live(
        urlSession: URLSession = .shared,
        bonjourServiceType: String = "_reduxdevtools._tcp.",
        maxHistorySize: Int = 200
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
                    .map { result in
                        result.map(DiscoveredServiceEvent.from(browseEvent:))
                              .mapError { $0 }
                    }
            },

            resolveService: { service in
                bonjourResolve(BonjourServiceInfo(
                    name: service.name,
                    type: service.type,
                    domain: service.domain
                ))
                .map { result in
                    result.map(ResolvedService.from(resolved:))
                }
            }
        )
    }
}

// MARK: - Socket.io handshake

/// Performs the Engine.io v4 + Socket.io v4 handshake on an already-open WebSocket.
///
/// Returns the same `WebSocketConnection` on success so callers can continue
/// using it for application-level messages.
private func performSocketIOHandshake(
    connection: WebSocketConnection
) async -> Result<WebSocketConnection, Error> {
    // Wait for the Engine.io OPEN packet
    guard case .success(.text(let openFrame)) = await connection.receive.first() else {
        return .failure(DevToolsConnectionError.handshakeFailed("no OPEN packet"))
    }
    guard case .open = SocketIO.parse(openFrame) else {
        return .failure(DevToolsConnectionError.handshakeFailed("expected OPEN, got: \(openFrame)"))
    }

    // Send Socket.io CONNECT for the default namespace
    _ = await connection.send(.text(SocketIO.connect)).run()

    // Wait for the Socket.io CONNECT ACK
    guard case .success(.text(let ackFrame)) = await connection.receive.first() else {
        return .failure(DevToolsConnectionError.handshakeFailed("no CONNECT ACK"))
    }
    guard case .connected = SocketIO.parse(ackFrame) else {
        return .failure(DevToolsConnectionError.handshakeFailed("expected CONNECT ACK, got: \(ackFrame)"))
    }

    return .success(connection)
}

// MARK: - DeferredStream.first() helper

private extension DeferredStream {
    /// Returns the first element by creating a short-lived iterator.
    func first() async -> Element? {
        var iterator = makeAsyncIterator()
        return try? await iterator.next()
    }
}

// MARK: - Type conversions

private extension DiscoveredServiceEvent {
    static func from(browseEvent event: BonjourBrowseEvent) -> DiscoveredServiceEvent {
        switch event {
        case let .found(info):               return .found(.init(info))
        case let .removed(info):             return .removed(.init(info))
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
            name: resolved.name,
            type: resolved.type,
            domain: resolved.domain,
            host: resolved.host,
            port: resolved.port,
            ips: resolved.ips,
            txt: resolved.txt
        )
    }
}

// MARK: - DeferredTask.flatMap

private extension DeferredTask {
    func flatMap<NewSuccess: Sendable>(
        _ transform: @escaping @Sendable (Success) async -> NewSuccess
    ) -> DeferredTask<NewSuccess> {
        DeferredTask<NewSuccess> { await transform(self.run()) }
    }
}

private extension DeferredTask {
    func map<T: Sendable>(_ transform: @escaping @Sendable (Success) -> T) -> DeferredTask<T> {
        DeferredTask<T> { transform(await self.run()) }
    }
}

private extension DeferredStream {
    func map<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T) -> DeferredStream<T> {
        DeferredStream<T> {
            AsyncStream<T> { continuation in
                let task = Task {
                    for await element in self {
                        continuation.yield(transform(element))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

// MARK: - Error

public enum DevToolsConnectionError: Error {
    case invalidURL(host: String, port: UInt16)
    case handshakeFailed(String)
}
#endif
