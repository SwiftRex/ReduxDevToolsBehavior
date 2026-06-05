import Foundation

/// State managed by ``DevToolsBehavior``.
///
/// Embed this in your app state under `#if DEBUG`:
///
/// ```swift
/// struct AppState: Sendable {
///     var counter: CounterState
///     #if DEBUG
///     var devTools: DevToolsState = .initial
///     #endif
/// }
/// ```
public struct DevToolsState: Sendable, Codable {

    // MARK: - Connection

    public enum ConnectionStatus: Sendable, Equatable, Codable {
        case disconnected
        case connecting
        /// WebSocket open; SocketCluster handshake in progress.
        case handshaking(host: String, port: UInt16)
        /// SocketCluster handshake complete; ready to send and receive.
        case connected(host: String, port: UInt16)
    }

    public var connectionStatus: ConnectionStatus

    // MARK: - Browsing

    /// Services found via Bonjour that are not yet connected to.
    public var discoveredServices: [DiscoveredService]

    public var isBrowsing: Bool

    /// The SocketCluster socket ID assigned by the server after a successful handshake.
    /// `nil` while disconnected or still handshaking.
    public var socketId: String?

    // MARK: - Recording

    /// Serialized state snapshots (JSON strings), one per dispatched action.
    /// Index 0 = initial state; index N = state after the Nth action.
    /// Sent to the devtools panel for display and import/export.
    public var stateHistory: [String]

    /// Serialized action descriptions (JSON strings), one per dispatched action.
    /// Parallel to `stateHistory`.
    public var actionHistory: [String]

    // MARK: - Time travel

    /// Actions that have been toggled (skipped) by the devtools panel.
    /// Skipped actions are excluded when computing the current state.
    public var skippedActionIds: Set<Int>

    /// The action index currently displayed in the devtools panel, or `nil` when live.
    public var currentActionIndex: Int?

    // MARK: - Recording control

    /// `true` while the devtools panel has paused recording. New app actions
    /// are silently dropped when paused — no INIT / ACTION messages are sent.
    public var isPaused: Bool

    /// `true` while the devtools panel has locked state changes. The behavior
    /// surfaces `.lockChanges` / `.unlockChanges` so the app's reducer can
    /// refuse or accept dispatches accordingly.
    public var isLocked: Bool

    /// `true` while time travel is active (after jumpToAction/toggleAction/importState,
    /// before the next reset/commit/rollback). Actions dispatched as reactive side-effects
    /// of the restored state are suppressed from recording while this is `true`.
    public var isTimeTraveling: Bool

    // MARK: - Defaults

    public static let initial = DevToolsState(
        connectionStatus: .disconnected,
        discoveredServices: [],
        isBrowsing: false,
        socketId: nil,
        stateHistory: [],
        actionHistory: [],
        skippedActionIds: [],
        currentActionIndex: nil,
        isPaused: false,
        isLocked: false,
        isTimeTraveling: false
    )

    public init(
        connectionStatus: ConnectionStatus,
        discoveredServices: [DiscoveredService],
        isBrowsing: Bool,
        socketId: String? = nil,
        stateHistory: [String],
        actionHistory: [String],
        skippedActionIds: Set<Int>,
        currentActionIndex: Int?,
        isPaused: Bool,
        isLocked: Bool,
        isTimeTraveling: Bool = false
    ) {
        self.connectionStatus = connectionStatus
        self.discoveredServices = discoveredServices
        self.isBrowsing = isBrowsing
        self.socketId = socketId
        self.stateHistory = stateHistory
        self.actionHistory = actionHistory
        self.skippedActionIds = skippedActionIds
        self.currentActionIndex = currentActionIndex
        self.isPaused = isPaused
        self.isLocked = isLocked
        self.isTimeTraveling = isTimeTraveling
    }
}

// MARK: - Convenience

extension DevToolsState {
    public var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }
}
