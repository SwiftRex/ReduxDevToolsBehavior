import Foundation
import WebSocketClient

/// Thread-safe holder for the live WebSocket connection, a bounded ring buffer of
/// serialized state JSON strings, and recording control flags.
///
/// Lives inside ``DevToolsEnvironment`` as a shared reference so that
/// ``DevToolsBehavior`` (opens/closes the connection) and ``makeDevToolsRecorder``
/// (sends per-action messages and stores JSON history) can coordinate without
/// passing references through store state.
///
/// ## Memory model
///
/// State history is stored as JSON **strings** (not typed `AppState` objects), bounded
/// by `maxHistorySize`. This keeps the iOS memory footprint small — the canonical
/// full history lives in the devtools panel on the Mac, which has abundant RAM.
///
/// New entries are appended at the end. When the buffer is full the oldest entry is
/// evicted from the front and `historyBaseIndex` advances, preserving the logical
/// action indices that the devtools panel uses.
///
/// Time travel requires `deserializeState` in ``makeDevToolsRecorder`` to decode a
/// JSON string back to `AppState`. Without it the ring buffer is still maintained
/// (for display in the app) but `JUMP_TO_ACTION` / `TOGGLE_ACTION` cannot restore state.
public actor DevToolsConnectionManager {

    // MARK: - Init

    /// Creates a manager with a given maximum state-JSON history size.
    ///
    /// - Parameter maxHistorySize: Maximum number of state JSON strings to retain on
    ///   the device. Older entries are evicted when the limit is reached. Default 200.
    public init(maxHistorySize: Int = 200) {
        self.maxHistorySize = maxHistorySize
    }

    // MARK: - Connection

    private var connection: WebSocketConnection?

    /// Sets (or clears) the live connection. Resets the INIT flag and
    /// clears the state JSON history so a new session starts fresh.
    /// Session-scoped instance ID: `baseInstanceId + "/" + socketId.prefix(8)`.
    /// Changes on every new connection so the devtools creates a fresh entry
    /// (avoiding stale `connectionId` from a previous session).
    private(set) var sessionInstanceId: String?

    func setConnection(_ connection: WebSocketConnection?) {
        self.connection?.close()
        self.connection = connection
        sessionInstanceId = nil
        hasSentInit = false
        stateJSONHistory = []
        historyBaseIndex = 0
        skippedActionIds = []
    }

    func setSessionInstanceId(_ id: String) { sessionInstanceId = id }

    /// Whether a connection is currently open.
    var isConnected: Bool { connection != nil }

    /// Closes the current connection and clears all session state.
    func close() {
        connection?.close()
        connection = nil
        hasSentInit = false
        stateJSONHistory = []
        historyBaseIndex = 0
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
    func checkAndMarkInitSent() -> Bool {
        if hasSentInit { return false }
        hasSentInit = true
        return true
    }

    /// Clears the INIT flag so the next action re-sends INIT to the devtools panel.
    /// Called on reset so the panel re-syncs with the current state.
    func resetInitSent() { hasSentInit = false }

    // MARK: - State JSON ring buffer

    /// At most `maxHistorySize` state JSON strings.
    /// `stateJSONHistory[0]` corresponds to logical index `historyBaseIndex`.
    private var stateJSONHistory: [String] = []

    /// Logical index of `stateJSONHistory[0]`. Advances as old entries are evicted.
    private(set) var historyBaseIndex: Int = 0

    private let maxHistorySize: Int

    /// Number of JSON strings currently stored.
    var stateJSONCount: Int { stateJSONHistory.count }

    /// Appends `json` to the ring buffer, evicting the oldest entry if full.
    func storeStateJSON(_ json: String) {
        if stateJSONHistory.count >= maxHistorySize {
            stateJSONHistory.removeFirst()
            historyBaseIndex += 1
        }
        stateJSONHistory.append(json)
    }

    /// Returns the state JSON at logical `index`, or `nil` if out of the buffered range.
    func stateJSON(at index: Int) -> String? {
        let arrayIndex = index - historyBaseIndex
        guard arrayIndex >= 0, arrayIndex < stateJSONHistory.count else { return nil }
        return stateJSONHistory[arrayIndex]
    }

    /// Replaces the entire ring buffer with `jsons` and resets the base index to 0.
    /// Used during `IMPORT_STATE`.
    func replaceStateJSONs(_ jsons: [String]) {
        stateJSONHistory = jsons
        historyBaseIndex = 0
    }

    /// Keeps only the last entry as the new baseline (logical index 0).
    /// Used during `COMMIT`.
    func commitStateJSONs() {
        let last = stateJSONHistory.last
        stateJSONHistory = last.map { [$0] } ?? []
        historyBaseIndex = 0
        skippedActionIds = []
    }

    /// Removes the last entry. Used during `ROLLBACK`.
    func rollbackStateJSON() {
        if !stateJSONHistory.isEmpty {
            stateJSONHistory.removeLast()
        }
    }

    /// Clears the ring buffer and the skipped-action set.
    func resetStateJSONs() {
        stateJSONHistory = []
        historyBaseIndex = 0
        skippedActionIds = []
    }

    // MARK: - Skip tracking (TOGGLE_ACTION)

    private var skippedActionIds: Set<Int> = []

    /// Toggles the skip state for `id`.
    /// - Returns: `true` if the action is now skipped; `false` if now active.
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

    func isSkipped(_ id: Int) -> Bool { skippedActionIds.contains(id) }

    /// Replaces the entire skipped-action set. Used during `IMPORT_STATE`.
    func setSkippedActionIds(_ ids: Set<Int>) { skippedActionIds = ids }

    /// Returns the latest logical index ≤ `maxIndex` that is not skipped and has
    /// a stored JSON string, or `nil` if no such index exists in the buffer.
    func latestNonSkippedIndex(upTo maxIndex: Int) -> Int? {
        let upperBound = min(maxIndex, historyBaseIndex + stateJSONHistory.count - 1)
        var i = upperBound
        while i >= historyBaseIndex {
            if !skippedActionIds.contains(i) { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Recording control (PAUSE_RECORDING / LOCK_CHANGES)

    private var isPaused = false
    private var isLocked = false

    var shouldRecord: Bool { !isPaused }
    var isChangeLocked: Bool { isLocked }

    func setPaused(_ paused: Bool) { isPaused = paused }
    func setLocked(_ locked: Bool) { isLocked = locked }
}
