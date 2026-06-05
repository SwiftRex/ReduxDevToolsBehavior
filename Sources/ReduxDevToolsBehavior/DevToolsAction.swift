import Foundation

/// Actions handled by ``DevToolsBehavior`` and optionally intercepted by ``makeDevToolsRecorder``.
///
/// Add a `devTools` case to your `AppAction` and use `AppAction.prism.devTools`
/// when lifting the behavior into your app:
///
/// ```swift
/// enum AppAction {
///     // ...your cases...
///     #if DEBUG
///     case devTools(DevToolsAction)
///     #endif
/// }
/// ```
///
/// Dispatch user-facing cases from your UI or launch code:
///
/// ```swift
/// store.dispatch(.devTools(.connect(host: "192.168.1.100", port: 8000)))
/// store.dispatch(.devTools(.startBrowsing))
/// ```
///
/// Cases prefixed with `_` are dispatched by behavior effects and should not
/// be dispatched by application code directly.
/// A `Codable`, `Sendable` wrapper for `Error` values in `DevToolsAction`.
/// `Error` is not itself `Codable`; this preserves the message across encode/decode.
public struct CodableError: Error, Codable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ error: Error) { description = error.localizedDescription }
    public init(_ message: String) { description = message }
}

public enum DevToolsAction: Sendable {

    // MARK: - Startup

    /// Reads ``DevToolsEnvironment/connectionMode`` from the environment and starts the
    /// appropriate connection flow.
    ///
    /// Dispatch this **once** at app launch, after the store is ready:
    ///
    /// ```swift
    /// // @main / App body / SceneDelegate, after store is created:
    /// store.dispatch(.devTools(.activate))
    /// ```
    ///
    /// - `.manual` → no-op; use ``connect(host:port:)`` or ``startBrowsing`` explicitly.
    /// - `.connectOnLaunch(host:port:)` → dispatches ``connect(host:port:)`` immediately.
    /// - `.browseOnLaunch(serviceType:)` → dispatches ``startBrowsing``.
    /// - `.advertise*` → no-op until Phase 3 native devtools is implemented.
    case activate

    // MARK: - User-initiated

    /// Connect to a remotedev-server at the given host and port.
    case connect(host: String, port: UInt16)

    /// Resolves `service` to a concrete host and port, then connects.
    ///
    /// Convenience for Mode 3 (`browseOnLaunch`): after the user picks a service from
    /// ``DevToolsState/discoveredServices``, dispatch this instead of manually calling
    /// ``DevToolsEnvironment/resolveService`` and then ``connect(host:port:)``.
    ///
    /// ```swift
    /// // User taps a row in the discovered services list:
    /// store.dispatch(.devTools(.connectToService(selectedService)))
    /// ```
    case connectToService(DiscoveredService)

    /// Browse the local network for remotedev-servers via Bonjour.
    case startBrowsing

    /// Stop Bonjour browsing without connecting.
    case stopBrowsing

    /// Close the current connection.
    case disconnect

    // MARK: - Internal events (dispatched by behavior effects)

    /// The WebSocket connection was established; SocketCluster handshake is in progress.
    case _connected(host: String, port: UInt16)

    /// The SocketCluster handshake completed — the server assigned `socketId` and
    /// the client subscribed to its personal channel. The connection is now fully ready.
    case _handshakeAck(socketId: String)

    /// The connection attempt failed.
    case _connectionFailed(CodableError)

    /// An established connection was lost.
    case _connectionLost(CodableError?)

    /// A Bonjour service was discovered.
    case _serviceFound(DiscoveredService)

    /// A previously discovered service is no longer available.
    case _serviceRemoved(DiscoveredService)

    /// A remotedev command was received from the devtools panel.
    case _received(RemoteDevCommand)

    /// Internal: carries a decoded `AppState` snapshot (as `any Sendable`) to be applied
    /// by the time machine behavior via a pure `.reduce { state = payload as! AppState }`.
    /// Dispatched from the time travel effect — never from user code, never over the wire.
    case _triggerRestore(any Sendable)

    /// Internal: clears the `isTimeTraveling` flag after the first reactive side-effect
    /// following a state restore has been suppressed. Recording resumes normally from
    /// the next action onwards.
    case _endTimeTraveling

    // MARK: - Commands surfaced from received messages

    /// Time-travel: restore the state produced by action at `index`.
    case jumpToAction(Int)

    /// Time-travel: jump directly to the pre-computed state at `index`.
    case jumpToState(Int)

    /// Toggle (skip / re-enable) the action at `id` and restore the nearest valid state.
    case toggleAction(Int)

    /// Reset the store to its initial state and clear all history.
    case reset

    /// Commit the current state as the new baseline and clear the history.
    case commit

    /// Roll back to the state before the last committed checkpoint.
    case rollback

    /// Import a full devtools lifted-state snapshot (replaces history).
    case importState(ImportedLiftedState)

    // MARK: - Action dispatch from devtools

    /// An action was dispatched from the Redux DevTools "Dispatcher" tab.
    ///
    /// `actionJSON` is the raw JSON string the developer typed in the panel.
    /// The time machine behavior decodes it via ``DevToolsEnvironment/decodeAction``
    /// and dispatches the result back into the store as an `AppAction`.
    ///
    /// Requires `DevToolsEnvironment.decodeAction` to be set — either automatically
    /// via `.live(for: AppState.self, action: AppAction.self)` when `AppAction: Decodable`,
    /// or manually via `.live(decodeAction:)`.
    case dispatchAction(actionJSON: String)

    // MARK: - Recording control

    /// Pause recording — new actions will not be forwarded to the devtools panel.
    case pause

    /// Resume recording after a ``pause``.
    case resume

    /// Lock state changes — the devtools panel will not be able to modify the store.
    case lockChanges

    /// Unlock state changes.
    case unlockChanges
}

// MARK: - Codable
// Explicit implementation required because _triggerRestore carries `any Sendable`
// which is not Codable. That case is internal and never encoded/decoded.

extension DevToolsAction: Codable {
    private enum CK: String, CodingKey {
        case type, host, port, socketId, error, service, index, id
        case json, status, lifted, actionJSON
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case .activate:              try c.encode("activate",        forKey: .type)
        case .startBrowsing:         try c.encode("startBrowsing",   forKey: .type)
        case .stopBrowsing:          try c.encode("stopBrowsing",    forKey: .type)
        case .disconnect:            try c.encode("disconnect",      forKey: .type)
        case .reset:                 try c.encode("reset",           forKey: .type)
        case .commit:                try c.encode("commit",          forKey: .type)
        case .rollback:              try c.encode("rollback",        forKey: .type)
        case .pause:                 try c.encode("pause",           forKey: .type)
        case .resume:                try c.encode("resume",          forKey: .type)
        case .lockChanges:           try c.encode("lockChanges",     forKey: .type)
        case .unlockChanges:         try c.encode("unlockChanges",   forKey: .type)
        case ._endTimeTraveling:    try c.encode("_endTimeTraveling",  forKey: .type)
        case ._triggerRestore:
            // Payload is any Sendable — not encodable. Encode type only; decoded
            // back as a no-op (payload cannot be reconstructed from JSON).
            try c.encode("_triggerRestore",                          forKey: .type)
        case let .connect(host, port):
            try c.encode("connect",    forKey: .type)
            try c.encode(host,         forKey: .host)
            try c.encode(port,         forKey: .port)
        case let .connectToService(svc):
            try c.encode("connectToService", forKey: .type)
            try c.encode(svc,                forKey: .service)
        case let ._connected(host, port):
            try c.encode("_connected", forKey: .type)
            try c.encode(host,         forKey: .host)
            try c.encode(port,         forKey: .port)
        case let ._handshakeAck(socketId):
            try c.encode("_handshakeAck",  forKey: .type)
            try c.encode(socketId,         forKey: .socketId)
        case let ._connectionFailed(err):
            try c.encode("_connectionFailed", forKey: .type)
            try c.encode(err.description,     forKey: .error)
        case let ._connectionLost(err):
            try c.encode("_connectionLost",   forKey: .type)
            try c.encodeIfPresent(err?.description, forKey: .error)
        case let ._serviceFound(svc):
            try c.encode("_serviceFound",  forKey: .type)
            try c.encode(svc,              forKey: .service)
        case let ._serviceRemoved(svc):
            try c.encode("_serviceRemoved", forKey: .type)
            try c.encode(svc,               forKey: .service)
        case let ._received(cmd):
            try c.encode("_received",  forKey: .type)
            try c.encode(cmd,          forKey: .json)
        case let .jumpToAction(i):
            try c.encode("jumpToAction", forKey: .type)
            try c.encode(i,              forKey: .index)
        case let .jumpToState(i):
            try c.encode("jumpToState",  forKey: .type)
            try c.encode(i,              forKey: .index)
        case let .toggleAction(i):
            try c.encode("toggleAction", forKey: .type)
            try c.encode(i,              forKey: .id)
        case let .importState(lifted):
            try c.encode("importState",  forKey: .type)
            try c.encode(lifted,         forKey: .lifted)
        case let .dispatchAction(actionJSON):
            try c.encode("dispatchAction", forKey: .type)
            try c.encode(actionJSON,       forKey: .actionJSON)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        switch try c.decode(String.self, forKey: .type) {
        case "activate":            self = .activate
        case "startBrowsing":       self = .startBrowsing
        case "stopBrowsing":        self = .stopBrowsing
        case "disconnect":          self = .disconnect
        case "reset":               self = .reset
        case "commit":              self = .commit
        case "rollback":            self = .rollback
        case "pause":               self = .pause
        case "resume":              self = .resume
        case "lockChanges":         self = .lockChanges
        case "unlockChanges":       self = .unlockChanges
        case "_endTimeTraveling":   self = ._endTimeTraveling
        case "_triggerRestore":
            // Payload is runtime-only — provide an inert placeholder value.
            self = ._triggerRestore(())
        case "connect":
            self = .connect(host: try c.decode(String.self, forKey: .host),
                            port: try c.decode(UInt16.self, forKey: .port))
        case "connectToService":
            self = .connectToService(try c.decode(DiscoveredService.self, forKey: .service))
        case "_connected":
            self = ._connected(host: try c.decode(String.self, forKey: .host),
                               port: try c.decode(UInt16.self, forKey: .port))
        case "_handshakeAck":
            self = ._handshakeAck(socketId: try c.decode(String.self, forKey: .socketId))
        case "_connectionFailed":
            self = ._connectionFailed(CodableError(try c.decode(String.self, forKey: .error)))
        case "_connectionLost":
            self = ._connectionLost(try c.decodeIfPresent(String.self, forKey: .error).map(CodableError.init))
        case "_serviceFound":
            self = ._serviceFound(try c.decode(DiscoveredService.self, forKey: .service))
        case "_serviceRemoved":
            self = ._serviceRemoved(try c.decode(DiscoveredService.self, forKey: .service))
        case "_received":
            self = ._received(try c.decode(RemoteDevCommand.self, forKey: .json))
        case "jumpToAction":
            self = .jumpToAction(try c.decode(Int.self, forKey: .index))
        case "jumpToState":
            self = .jumpToState(try c.decode(Int.self, forKey: .index))
        case "toggleAction":
            self = .toggleAction(try c.decode(Int.self, forKey: .id))
        case "importState":
            self = .importState(try c.decode(ImportedLiftedState.self, forKey: .lifted))
        case "dispatchAction":
            self = .dispatchAction(actionJSON: try c.decode(String.self, forKey: .actionJSON))
        default:
            self = .activate
        }
    }
}
