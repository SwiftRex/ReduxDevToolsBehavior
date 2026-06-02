import Foundation
import WebSocketClient

/// Thread-safe holder for the live WebSocket connection to the remotedev-server.
///
/// The manager lives inside ``DevToolsEnvironment`` as a shared reference so that
/// both the ``DevToolsBehavior`` (which opens/closes the connection) and
/// ``makeDevToolsRecorder`` (which sends per-action messages) can access the
/// same connection without passing it through store state.
///
/// All methods are `async` and isolated to the actor, providing data-race safety.
public actor DevToolsConnectionManager {
    private var connection: WebSocketConnection?

    /// Sets (or clears) the live connection. Resets the INIT-sent flag.
    func setConnection(_ connection: WebSocketConnection?) {
        self.connection?.close()
        self.connection = connection
        hasSentInit = false
    }

    /// Sends a text frame if a connection is open; silently succeeds if not connected.
    func send(_ text: String) async -> Result<Void, Error> {
        guard let connection else { return .success(()) }
        return await connection.send(.text(text)).run()
    }

    /// Whether a connection is currently open.
    var isConnected: Bool { connection != nil }

    /// Closes the current connection, clears the reference, and resets the init flag.
    func close() {
        connection?.close()
        connection = nil
        hasSentInit = false
    }

    // MARK: - INIT tracking

    /// Tracks whether the INIT message has been sent for the current connection.
    /// Reset to `false` whenever a new connection is established or the connection closes.
    private var hasSentInit = false

    /// Returns `true` the first time it is called after a connection is established,
    /// then `false` on all subsequent calls — used by ``makeDevToolsRecorder`` to
    /// send the INIT message exactly once per connection.
    func checkAndMarkInitSent() -> Bool {
        if hasSentInit { return false }
        hasSentInit = true
        return true
    }
}
