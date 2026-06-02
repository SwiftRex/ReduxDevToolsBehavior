import Foundation

/// Actions handled by ``DevToolsBehavior``.
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
/// Then connect from your app's launch or settings screen:
///
/// ```swift
/// store.dispatch(.devTools(.connect(host: "192.168.1.100", port: 8000)))
/// ```
///
/// Or let the behavior browse for a remotedev-server automatically:
///
/// ```swift
/// store.dispatch(.devTools(.startBrowsing))
/// ```
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

    /// The devtools panel requested time-travel to the action at `index`.
    case jumpToAction(Int)

    /// The devtools panel toggled (skipped/re-enabled) the action at `index`.
    case toggleAction(Int)

    /// The devtools panel requested a reset to the initial state.
    case reset

    /// The devtools panel committed the current state as the new baseline.
    case commit

    /// The devtools panel rolled back to the previous commit.
    case rollback
}
