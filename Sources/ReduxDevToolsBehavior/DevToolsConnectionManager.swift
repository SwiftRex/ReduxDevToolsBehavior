import Foundation
import WebSocketClient

/// Thread-safe holder for the live WebSocket connection, type-erased state snapshots,
/// and recording control flags.
///
/// Lives inside ``DevToolsEnvironment`` as a shared reference so that
/// ``DevToolsBehavior`` (opens/closes the connection) and ``makeDevToolsRecorder``
/// (sends per-action messages and stores snapshots) can coordinate without
/// passing references through store state.
public actor DevToolsConnectionManager {

    // MARK: - Connection

    private var connection: WebSocketConnection?

    /// Sets (or clears) the live connection. Resets the INIT-sent flag and
    /// clears the snapshot history so a new session starts fresh.
    func setConnection(_ connection: WebSocketConnection?) {
        self.connection?.close()
        self.connection = connection
        hasSentInit = false
        snapshots = []
        skippedActionIds = []
    }

    /// Whether a connection is currently open.
    var isConnected: Bool { connection != nil }

    /// Closes the current connection and clears all session state.
    func close() {
        connection?.close()
        connection = nil
        hasSentInit = false
        snapshots = []
        skippedActionIds = []
    }

    /// Sends a text frame if a connection is open; silently succeeds if not connected.
    func send(_ text: String) async -> Result<Void, Error> {
        guard let connection else { return .success(()) }
        return await connection.send(.text(text)).run()
    }

    // MARK: - INIT tracking

    private var hasSentInit = false

    /// Returns `true` the first time it is called after a connection is established.
    /// Used by ``makeDevToolsRecorder`` to send the INIT message exactly once.
    func checkAndMarkInitSent() -> Bool {
        if hasSentInit { return false }
        hasSentInit = true
        return true
    }

    // MARK: - State snapshots (for in-process time travel)

    /// Type-erased `AppState` values, one per dispatched action.
    /// Index 0 = initial state; index N = state after the Nth action.
    private var snapshots: [Any] = []

    /// Appends `state` to the snapshot history.
    func storeSnapshot<S: Sendable>(_ state: S) {
        snapshots.append(state)
    }

    /// Returns the snapshot at `index` cast to `S`, or `nil` if out of range or wrong type.
    func snapshot<S: Sendable>(at index: Int) -> S? {
        guard index >= 0, index < snapshots.count else { return nil }
        return snapshots[index] as? S
    }

    /// Replaces the entire snapshot history with the given array.
    /// Used during `IMPORT_STATE` when the devtools panel provides pre-serialized snapshots
    /// and a `deserializeState` closure is available.
    func replaceSnapshots<S: Sendable>(_ states: [S]) {
        snapshots = states
    }

    /// The number of stored snapshots.
    var snapshotCount: Int { snapshots.count }

    /// Clears the snapshot history and skipped-action set.
    func resetSnapshots() {
        snapshots = []
        skippedActionIds = []
    }

    /// Keeps only the last snapshot as the new index-0 baseline.
    /// Used during COMMIT to set the current state as the new initial state.
    func commitSnapshots() {
        let last = snapshots.last
        snapshots = last.map { [$0] } ?? []
        skippedActionIds = []
    }

    // MARK: - Skip tracking (TOGGLE_ACTION)

    private var skippedActionIds: Set<Int> = []

    /// Toggles the skip state for `id`.
    /// - Returns: `true` if the action is now skipped; `false` if it is now active.
    @discardableResult
    func toggleSkipped(_ id: Int) -> Bool {
        if skippedActionIds.contains(id) {
            skippedActionIds.remove(id)
            return false
        } else {
            skippedActionIds.insert(id)
            return true
        }
    }

    /// Returns `true` if action `id` is currently marked as skipped.
    func isSkipped(_ id: Int) -> Bool { skippedActionIds.contains(id) }

    /// Replaces the entire skipped-action set (used during `IMPORT_STATE`).
    func setSkippedActionIds(_ ids: Set<Int>) { skippedActionIds = ids }

    /// Returns the latest snapshot index ≤ `upTo` that is not in `skippedActionIds`,
    /// or `nil` if no such index exists.
    func latestNonSkippedIndex(upTo maxIndex: Int) -> Int? {
        var i = min(maxIndex, snapshots.count - 1)
        while i >= 0 {
            if !skippedActionIds.contains(i) { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Recording control (PAUSE_RECORDING / LOCK_CHANGES)

    private var isPaused: Bool = false
    private var isLocked: Bool = false

    /// Whether new actions should be recorded and forwarded to the devtools panel.
    var shouldRecord: Bool { !isPaused }

    /// Whether the devtools panel has locked state changes.
    var isChangeLocked: Bool { isLocked }

    func setPaused(_ paused: Bool)   { isPaused = paused }
    func setLocked(_ locked: Bool)   { isLocked = locked }
}
