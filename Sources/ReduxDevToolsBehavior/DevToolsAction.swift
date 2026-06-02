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
public enum DevToolsAction: Sendable {

    // MARK: - User-initiated

    /// Connect to a remotedev-server at the given host and port.
    case connect(host: String, port: UInt16)

    /// Browse the local network for remotedev-servers via Bonjour.
    case startBrowsing

    /// Stop Bonjour browsing without connecting.
    case stopBrowsing

    /// Close the current connection.
    case disconnect

    // MARK: - Internal events (dispatched by behavior effects)

    /// The WebSocket + Socket.io handshake completed successfully.
    case _connected(host: String, port: UInt16)

    /// The connection attempt failed.
    case _connectionFailed(Error)

    /// An established connection was lost.
    case _connectionLost(Error?)

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
