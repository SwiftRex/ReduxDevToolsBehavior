import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency
import WebSocketClient

/// The Redux DevTools connection behavior.
///
/// `DevToolsBehavior` manages the lifecycle of the connection to a
/// `remotedev-server` and routes commands received from the devtools panel
/// (time travel, reset, commit, etc.) back into the store as `DevToolsAction`.
///
/// It does **not** observe app actions — pair it with ``makeDevToolsRecorder``
/// to forward every dispatched action and state snapshot to the devtools.
///
/// ## Wiring
///
/// ```swift
/// // AppAction
/// enum AppAction {
///     case yourFeatureAction(FeatureAction)
///     #if DEBUG
///     case devTools(DevToolsAction)
///     #endif
/// }
///
/// // AppState
/// struct AppState {
///     var yourState: FeatureState
///     #if DEBUG
///     var devTools: DevToolsState = .initial
///     #endif
/// }
///
/// // AppEnvironment
/// struct AppEnvironment {
///     var feature: FeatureEnvironment
///     #if DEBUG
///     var devTools: DevToolsEnvironment = .live()
///     #endif
/// }
///
/// // Combine behaviors
/// let appBehavior = Behavior.combine(
///     featureBehavior.lift(
///         action: AppAction.prism.yourFeatureAction,
///         state: \AppState.yourState,
///         environment: \AppEnvironment.feature
///     ),
///     #if DEBUG
///     DevToolsBehavior.behavior.lift(
///         action: AppAction.prism.devTools,
///         state: \AppState.devTools,
///         environment: \AppEnvironment.devTools
///     ),
///     makeDevToolsRecorder(instanceId: Bundle.main.bundleIdentifier ?? "app")
///         .liftEnvironment(\AppEnvironment.devTools),
///     #endif
/// )
///
/// // Connect (e.g. from a debug settings screen or on launch)
/// store.dispatch(.devTools(.connect(host: "192.168.1.100", port: 8000)))
///
/// // Or browse the local network for a remotedev-server:
/// store.dispatch(.devTools(.startBrowsing))
/// ```
public enum DevToolsBehavior {
    public static let behavior: Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment> =
        Behavior { action, _ in
            switch action {

            // MARK: - Connect

            case let .connect(host, port):
                return .reduce { $0.connectionStatus = .connecting }
                    .produce { ctx in
                        Effect<DevToolsAction>.deferredStream(
                            connectionStream(host: host, port: port, env: ctx.environment),
                            { $0 },
                            scheduling: .replacing(id: "devtools-connection")
                        )
                    }

            // MARK: - Browse

            case .startBrowsing:
                return .reduce { $0.isBrowsing = true }
                    .produce { ctx in
                        Effect<DevToolsAction>.deferredStream(
                            ctx.environment.browseServices("_reduxdevtools._tcp."),
                            { result -> DevToolsAction in
                                switch result {
                                case let .success(.found(svc)):   return ._serviceFound(svc)
                                case let .success(.removed(svc)): return ._serviceRemoved(svc)
                                case .success(.updated):          return ._serviceRemoved(.init(name: "", type: "", domain: ""))  // placeholder
                                case let .failure(error):         return ._connectionFailed(error)
                                }
                            },
                            scheduling: .replacing(id: "devtools-browse")
                        )
                    }

            case .stopBrowsing:
                return .reduce { $0.isBrowsing = false }
                    .produce { _ in .cancelInFlight(id: "devtools-browse") }

            // MARK: - Disconnect

            case .disconnect:
                return .reduce { $0.connectionStatus = .disconnected }
                    .produce { ctx in
                        Effect<DevToolsAction>.fireAndForget {
                            await ctx.environment.connectionManager.close()
                        }
                        <> .cancelInFlight(id: "devtools-connection")
                    }

            // MARK: - Internal: lifecycle events

            case let ._connected(host, port):
                return .reduce { $0.connectionStatus = .connected(host: host, port: port) }

            case ._connectionFailed:
                return .reduce { $0.connectionStatus = .disconnected }

            case ._connectionLost:
                return .reduce { $0.connectionStatus = .disconnected }

            // MARK: - Internal: discovery

            case let ._serviceFound(svc):
                return .reduce { state in
                    if !state.discoveredServices.contains(svc) {
                        state.discoveredServices.append(svc)
                    }
                }

            case let ._serviceRemoved(svc):
                return .reduce { $0.discoveredServices.removeAll { $0 == svc } }

            // MARK: - Internal: received command from devtools

            case let ._received(command):
                switch command {
                case let .jumpToAction(index):  return .just(.jumpToAction(index))
                case let .toggleAction(id):     return .just(.toggleAction(id))
                case .reset:                    return .just(.reset)
                case .commit:                   return .just(.commit)
                case .rollback:                 return .just(.rollback)
                case .importState, .unknown:    return .doNothing
                }

            // MARK: - Commands (surfaced to the app)

            case .jumpToAction, .toggleAction:
                // The app's reducer handles these — DevToolsBehavior does not modify AppState
                return .doNothing

            case .reset:
                return .reduce { $0.stateHistory = []; $0.actionHistory = [] }

            case .commit:
                return .reduce { state in
                    if let ls = state.stateHistory.last, let la = state.actionHistory.last {
                        state.stateHistory  = [ls]
                        state.actionHistory = [la]
                    }
                }

            case .rollback:
                return .reduce { state in
                    if state.stateHistory.count > 1 {
                        state.stateHistory.removeLast()
                        state.actionHistory.removeLast()
                    }
                }
            }
        }
}

// MARK: - Private consequence helper

private extension Consequence {
    static func just(_ action: Action) -> Self {
        .produce { _ in .just(action) }
    }
}

// MARK: - Connection stream

/// Returns a `DeferredStream<DevToolsAction>` that, when iterated:
/// 1. Opens the WebSocket and performs the Socket.io v4 handshake.
/// 2. Emits `._connected` once the handshake completes.
/// 3. Continuously emits parsed `DevToolsAction` values from incoming messages.
/// 4. Emits `._connectionLost` and finishes when the connection closes.
///
/// Uses `Task { for await ... }` internally — this is acceptable at the behavior
/// layer because the Task is started by the Store's Effect runtime (the "shell"),
/// not eagerly at construction time.
private func connectionStream(
    host: String,
    port: UInt16,
    env: DevToolsEnvironment
) -> DeferredStream<DevToolsAction> {
    DeferredStream {
        AsyncStream { continuation in
            let task = Task {
                // Step 1: open the WebSocket connection
                let connResult = await env.openConnection(host, port).run()
                guard !Task.isCancelled else { return }

                switch connResult {
                case let .failure(error):
                    continuation.yield(._connectionFailed(error))
                    continuation.finish()
                    return

                case let .success(connection):
                    // Store in manager so DevToolsRecorder can send messages
                    await env.connectionManager.setConnection(connection)
                    continuation.yield(._connected(host: host, port: port))

                    // Step 2: iterate the receive stream
                    for await messageResult in connection.receive {
                        guard !Task.isCancelled else { break }
                        switch messageResult {
                        case let .success(.text(text)):
                            // Handle Socket.io pings inline; surface devtools commands
                            if let action = parseIncoming(text: text, connection: connection) {
                                continuation.yield(action)
                            }
                        case .success(.data):
                            break  // binary frames are not used by remotedev-server
                        case let .failure(error):
                            continuation.yield(._connectionLost(error))
                            continuation.finish()
                            return
                        }
                    }
                    // Receive stream finished normally (server closed connection)
                    continuation.yield(._connectionLost(nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Incoming message parser

/// Parses an incoming Socket.io text frame and returns an action if applicable.
/// Responds to PING frames inline (sends PONG), returns `nil` for non-action packets.
private func parseIncoming(text: String, connection: WebSocketConnection) -> DevToolsAction? {
    switch SocketIO.parse(text) {
    case .ping:
        // Engine.io requires a synchronous-ish PONG; fire-and-forget is fine
        Task { _ = await connection.send(.text(SocketIO.pong)).run() }
        return nil
    case let .event(name, payload) where name == "dispatch":
        return ._received(RemoteDevCommand.from(payloadJSON: payload))
    default:
        return nil
    }
}
