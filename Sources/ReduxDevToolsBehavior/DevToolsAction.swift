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

public enum DevToolsAction: Sendable, Codable {

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
