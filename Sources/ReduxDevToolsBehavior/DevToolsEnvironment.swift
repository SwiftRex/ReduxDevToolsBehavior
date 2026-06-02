import FP
import Foundation
import WebSocketClient

/// The dependencies needed by ``DevToolsBehavior`` and ``makeDevToolsRecorder``.
///
/// `DevToolsEnvironment` is a struct of closures — all platform-specific types
/// (`URLSessionWebSocketTask`, `NWBrowser`, etc.) are hidden inside the closure
/// captures. The interface uses only primitives, ``DeferredTask``, ``DeferredStream``,
/// and the platform-agnostic ``DiscoveredService`` / ``ResolvedService`` types.
///
/// ## Wiring into your app environment
///
/// ```swift
/// struct AppEnvironment {
///     // ...your deps...
///     #if DEBUG
///     var devTools: DevToolsEnvironment
///     #endif
/// }
///
/// extension AppEnvironment {
///     static let live = AppEnvironment(
///         // ...
///         devTools: .live()   // uses URLSession + Bonjour
///     )
/// }
/// ```
///
/// ## Using the live environment
///
/// ```swift
/// DevToolsEnvironment.live(instanceId: "MyApp", instanceName: "My App")
/// ```
public struct DevToolsEnvironment: Sendable {
    // MARK: - Connection

    /// Shared actor that holds the live connection. Both ``DevToolsBehavior``
    /// (opens/closes) and ``makeDevToolsRecorder`` (sends per-action) reference
    /// the same manager.
    public let connectionManager: DevToolsConnectionManager

    /// Opens a WebSocket to `host:port` and performs the Socket.io v4 handshake.
    /// Returns when the connection is confirmed (Socket.io CONNECT ACK received).
    ///
    /// On success the returned `WebSocketConnection` is ready for `send`/`receive`.
    public var openConnection: @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>

    // MARK: - Discovery

    /// Browses the local network for Bonjour services of the given type.
    ///
    /// ```swift
    /// environment.browseServices("_reduxdevtools._tcp.")
    /// ```
    public var browseServices: @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>

    /// Resolves a discovered service to its concrete host, port, and IP addresses.
    public var resolveService: @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>

    public init(
        connectionManager: DevToolsConnectionManager,
        openConnection: @escaping @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>,
        browseServices: @escaping @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>,
        resolveService: @escaping @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>
    ) {
        self.connectionManager = connectionManager
        self.openConnection = openConnection
        self.browseServices = browseServices
        self.resolveService = resolveService
    }
}

// MARK: - Discovery event

/// Events from ``DevToolsEnvironment/browseServices``.
public enum DiscoveredServiceEvent: Sendable {
    case found(DiscoveredService)
    case removed(DiscoveredService)
    case updated(from: DiscoveredService, to: DiscoveredService)
}
