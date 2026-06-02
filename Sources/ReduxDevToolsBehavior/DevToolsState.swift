import Foundation

/// State managed by ``DevToolsBehavior``.
///
/// Embed this in your app state and lift the behavior to it:
///
/// ```swift
/// struct AppState {
///     // ...your state...
///     #if DEBUG
///     var devTools: DevToolsState = .initial
///     #endif
/// }
/// ```
public struct DevToolsState: Sendable {

    // MARK: - Connection

    public enum ConnectionStatus: Sendable, Equatable {
        case disconnected
        case connecting
        case connected(host: String, port: UInt16)
    }

    public var connectionStatus: ConnectionStatus

    // MARK: - Browsing

    /// Services found via Bonjour that are not yet connected to.
    public var discoveredServices: [DiscoveredService]

    public var isBrowsing: Bool

    // MARK: - Recording

    /// Serialized state snapshots (JSON strings), one per dispatched action.
    /// Index 0 = initial state; index N = state after the Nth action.
    /// Used by the devtools panel for time travel.
    public var stateHistory: [String]

    /// Serialized action descriptions (JSON strings), one per dispatched action.
    /// Parallel array to `stateHistory`.
    public var actionHistory: [String]

    // MARK: - Defaults

    public static let initial = DevToolsState(
        connectionStatus: .disconnected,
        discoveredServices: [],
        isBrowsing: false,
        stateHistory: [],
        actionHistory: []
    )

    public init(
        connectionStatus: ConnectionStatus,
        discoveredServices: [DiscoveredService],
        isBrowsing: Bool,
        stateHistory: [String],
        actionHistory: [String]
    ) {
        self.connectionStatus = connectionStatus
        self.discoveredServices = discoveredServices
        self.isBrowsing = isBrowsing
        self.stateHistory = stateHistory
        self.actionHistory = actionHistory
    }
}

// MARK: - Convenience

extension DevToolsState {
    var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }
}
