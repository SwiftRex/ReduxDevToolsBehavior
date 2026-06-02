import FP
import Foundation
import WebSocketClient

/// The infrastructure dependencies needed by ``DevToolsBehavior``.
///
/// `DevToolsEnvironment` owns **networking** (WebSocket, Bonjour) and
/// **deployment identity** (`instanceId`, `instanceName`). It does **not** own
/// serialization — encoding and decoding are the responsibility of
/// ``DevToolsBehavior/timeMachineBehavior(extractDevToolsAction:restoreStateAction:encodeAction:encodeState:deserializeState:deserializeAction:)``
/// and its Codable overloads, which know the concrete `AppAction` and `AppState`
/// types at compile time and can therefore make type-safe decisions.
///
/// ## Wiring
///
/// ```swift
/// struct AppEnvironment: Sendable {
///     var feature: FeatureEnvironment
///     #if DEBUG
///     var devTools: DevToolsEnvironment = .live()
///     #endif
/// }
///
/// let appBehavior = Behavior.combine(
///     featureBehavior.lift(...),
///     #if DEBUG
///     // Non-Codable: MirrorJSON encoding, no time travel
///     DevToolsBehavior.behaviors(
///         action: AppAction.prism.devTools,
///         state: \AppState.devTools,
///         environment: \AppEnvironment.devTools
///     ),
///     // AppState: Codable: JSONEncoder + JSONDecoder wired automatically
///     // DevToolsBehavior.behaviors<_, AppState: Codable, _>(
///     //     action: ..., state: ..., environment: ...,
///     //     restoreStateAction: { .restoreState($0) }
///     // ),
///     #endif
/// )
/// ```
public struct DevToolsEnvironment: Sendable {

    // MARK: - Connection

    /// Shared actor that holds the live connection. Both ``DevToolsBehavior/socketBehavior``
    /// (opens/closes) and ``DevToolsBehavior/timeMachineBehavior(extractDevToolsAction:restoreStateAction:encodeAction:encodeState:deserializeState:deserializeAction:)``
    /// (sends per-action messages) reference the same manager.
    public let connectionManager: DevToolsConnectionManager

    /// Opens a WebSocket to `host:port` and performs the Socket.io v4 handshake.
    public var openConnection: @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>

    // MARK: - Discovery

    /// Browses the local network for Bonjour services of the given type.
    public var browseServices: @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>

    /// Resolves a discovered service to its concrete host, port, and IP addresses.
    public var resolveService: @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>

    // MARK: - Instance identity

    /// Unique key shown in the devtools instance list. Defaults to the bundle identifier.
    public var instanceId: String

    /// Human-readable label in the devtools panel sidebar. `nil` falls back to `instanceId`.
    public var instanceName: String?

    // MARK: - Init

    public init(
        connectionManager: DevToolsConnectionManager,
        openConnection: @escaping @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>,
        browseServices: @escaping @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>,
        resolveService: @escaping @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>,
        instanceId: String,
        instanceName: String? = nil
    ) {
        self.connectionManager = connectionManager
        self.openConnection    = openConnection
        self.browseServices    = browseServices
        self.resolveService    = resolveService
        self.instanceId        = instanceId
        self.instanceName      = instanceName
    }
}

// MARK: - Discovery event

/// Events from ``DevToolsEnvironment/browseServices``.
public enum DiscoveredServiceEvent: Sendable {
    case found(DiscoveredService)
    case removed(DiscoveredService)
    case updated(from: DiscoveredService, to: DiscoveredService)
}
