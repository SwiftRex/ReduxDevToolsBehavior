import Core
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

    // MARK: - Serialization

    /// Produces typed `DataEncoder<T>` converters for `Encodable` state/action types.
    /// Defaults to `JSONEncoder` in the live environment.
    public var encoderFactory: any DataEncoderFactory & Sendable

    /// Produces typed `DataDecoder<T>` converters for `Decodable` state/action types.
    /// Defaults to `JSONDecoder` in the live environment.
    public var decoderFactory: any DataDecoderFactory & Sendable

    /// Encodes any value (including non-`Encodable` types) to a JSON string.
    /// Defaults to `MirrorJSON` backed by the live `encoderFactory` in the live environment.
    /// Swap this out to customise how non-`Encodable` state is displayed in the devtools panel.
    public var encodeAny: Convert<Any, String, Never>

    /// Produces the Redux DevTools action description: `(typePath, payloadJSON)`.
    /// `typePath` is the `.namespace(.action)` string shown in the action list.
    /// `payloadJSON` is the leaf associated value encoded as JSON.
    /// Defaults to `MirrorJSON`-based type-name traversal in the live environment.
    public var describeAction: Convert<Any, (typePath: String, payloadJSON: String), Never>

    // MARK: - Instance identity

    /// Unique key shown in the devtools instance list. Defaults to the bundle identifier.
    public var instanceId: String

    /// Human-readable label in the devtools panel sidebar. `nil` falls back to `instanceId`.
    public var instanceName: String?

    // MARK: - Connection mode

    /// Controls how the connection is established when ``DevToolsAction/activate``
    /// is dispatched. Defaults to ``ConnectionMode/manual``.
    public var connectionMode: ConnectionMode

    /// The Bonjour service type used by ``DevToolsAction/startBrowsing``.
    ///
    /// Derived from `connectionMode` when it carries a service type; otherwise
    /// falls back to `"_reduxdevtools._tcp."`.
    public var browsingServiceType: String {
        switch connectionMode {
        case let .browseOnLaunch(type): return type
        case let .autoConnect(type):    return type
        default:                        return "_reduxdevtools._tcp."
        }
    }

    // MARK: - Init

    public init(
        connectionManager: DevToolsConnectionManager,
        openConnection: @escaping @Sendable (String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>,
        browseServices: @escaping @Sendable (String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>,
        resolveService: @escaping @Sendable (DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>,
        encoderFactory: any DataEncoderFactory & Sendable,
        decoderFactory: any DataDecoderFactory & Sendable,
        encodeAny: Convert<Any, String, Never>,
        describeAction: Convert<Any, (typePath: String, payloadJSON: String), Never>,
        instanceId: String,
        instanceName: String? = nil,
        connectionMode: ConnectionMode = .manual
    ) {
        self.connectionManager = connectionManager
        self.openConnection    = openConnection
        self.browseServices    = browseServices
        self.resolveService    = resolveService
        // @unchecked because JSONEncoder/JSONDecoder are not formally Sendable pre-Swift 6
        // but are safe to share across actors (they have no mutable shared state).
        self.encoderFactory    = encoderFactory
        self.decoderFactory    = decoderFactory
        self.encodeAny         = encodeAny
        self.describeAction    = describeAction
        self.instanceId        = instanceId
        self.instanceName      = instanceName
        self.connectionMode    = connectionMode
    }
}

// MARK: - Discovery event

/// Events from ``DevToolsEnvironment/browseServices``.
public enum DiscoveredServiceEvent: Sendable {
    case found(DiscoveredService)
    case removed(DiscoveredService)
    case updated(from: DiscoveredService, to: DiscoveredService)
}

// MARK: - Errors

/// Errors originating from the devtools behavior.
public enum DevToolsError: Error, Codable {
    /// ``DevToolsAction/connectToService(_:)`` was dispatched but the service
    /// could not be resolved to a host and port.
    case couldNotResolveService(DiscoveredService)
}
