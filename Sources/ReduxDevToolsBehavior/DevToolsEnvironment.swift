import FP
import Foundation
import WebSocketClient

/// The dependencies needed by ``DevToolsBehavior``.
///
/// `DevToolsEnvironment` is a struct of closures. All platform-specific types
/// (`URLSessionWebSocketTask`, `NWBrowser`, etc.) are hidden inside the closure
/// captures; the interface uses only primitives, ``DeferredTask``, ``DeferredStream``,
/// and the platform-agnostic service-discovery types.
///
/// Serialization configuration (`instanceId`, `encodeAction`, `encodeState`,
/// `decodeState`) also lives here so it is configured once at startup rather than
/// repeated at every call site.
///
/// ## Wiring
///
/// ```swift
/// struct AppEnvironment: Sendable {
///     var feature: FeatureEnvironment
///     #if DEBUG
///     var devTools: DevToolsEnvironment = .live()   // zero-config for non-Codable
///     // or, when AppState: Codable:
///     // var devTools: DevToolsEnvironment = .live(for: AppState.self)
///     #endif
/// }
///
/// let appBehavior = Behavior.combine(
///     featureBehavior.lift(...),
///     #if DEBUG
///     DevToolsBehavior.behaviors(
///         action: AppAction.prism.devTools,
///         state: \AppState.devTools,
///         environment: \AppEnvironment.devTools
///     ),
///     #endif
/// )
/// ```
public struct DevToolsEnvironment: Sendable {

    // MARK: - Connection

    /// Shared actor that holds the live connection.
    public let connectionManager: DevToolsConnectionManager

    /// Opens a WebSocket to `host:port` and performs the Socket.io v4 handshake.
    public var openConnection: @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>

    // MARK: - Discovery

    /// Browses the local network for Bonjour services of the given type.
    public var browseServices: @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>

    /// Resolves a discovered service to its concrete host, port, and IP addresses.
    public var resolveService: @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>

    // MARK: - Instance identity

    /// Unique key shown in the devtools instance list.
    /// Defaults to `Bundle.main.bundleIdentifier` in `.live()`.
    public var instanceId: String

    /// Human-readable label in the devtools panel sidebar.
    /// `nil` falls back to `instanceId`.
    public var instanceName: String?

    // MARK: - Serialization

    /// Serializes any `AppAction` value to a JSON string for the wire.
    ///
    /// Receives the action as `Any` because the environment is not generic over
    /// `AppAction`. The default is ``MirrorJSON/encode(_:)``, which uses
    /// `JSONEncoder` automatically for `Encodable` types.
    public var encodeAction: @Sendable (Any) -> String

    /// Serializes any `AppState?` value to a JSON string for the wire.
    ///
    /// `nil` input → `"{}"`. The default is ``MirrorJSON``, which uses
    /// `JSONEncoder` automatically for `Encodable` types.
    public var encodeState: @Sendable (Any?) -> String

    /// Decodes a JSON string back to `AppState` (type-erased as `Any`).
    ///
    /// Required for time travel (`JUMP_TO_ACTION`, `TOGGLE_ACTION`) and
    /// `IMPORT_STATE`. `nil` disables state restoration.
    ///
    /// When `AppState: Decodable` use `.live(for: AppState.self)` to wire
    /// this automatically via `JSONDecoder`.
    public var decodeState: (@Sendable (String) -> Any?)?

    /// Decodes a JSON string from the Redux DevTools "Dispatcher" tab back to
    /// `AppAction` (type-erased as `Any`).
    ///
    /// Required for dispatching actions from the devtools panel. `nil` (default)
    /// silently discards `ACTION` commands from the devtools.
    ///
    /// When `AppAction: Decodable` use `.live(for: AppState.self, action: AppAction.self)`
    /// to wire this automatically via `JSONDecoder`.
    public var decodeAction: (@Sendable (String) -> Any?)?

    // MARK: - Init

    public init(
        connectionManager: DevToolsConnectionManager,
        openConnection: @escaping @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>,
        browseServices: @escaping @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>,
        resolveService: @escaping @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>,
        instanceId: String,
        instanceName: String? = nil,
        encodeAction: @escaping @Sendable (Any) -> String = MirrorJSON.encode,
        encodeState: @escaping @Sendable (Any?) -> String = { state in
            state.map(MirrorJSON.encode) ?? "{}"
        },
        decodeState: (@Sendable (String) -> Any?)? = nil,
        decodeAction: (@Sendable (String) -> Any?)? = nil
    ) {
        self.connectionManager = connectionManager
        self.openConnection    = openConnection
        self.browseServices    = browseServices
        self.resolveService    = resolveService
        self.instanceId        = instanceId
        self.instanceName      = instanceName
        self.encodeAction      = encodeAction
        self.encodeState       = encodeState
        self.decodeState       = decodeState
        self.decodeAction      = decodeAction
    }
}

// MARK: - Discovery event

/// Events from ``DevToolsEnvironment/browseServices``.
public enum DiscoveredServiceEvent: Sendable {
    case found(DiscoveredService)
    case removed(DiscoveredService)
    case updated(from: DiscoveredService, to: DiscoveredService)
}
