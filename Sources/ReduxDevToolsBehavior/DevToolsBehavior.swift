import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency
import WebSocketClient

/// The Redux DevTools connection behavior.
///
/// `DevToolsBehavior` manages the connection lifecycle and routes all commands
/// received from the devtools panel back into the store as ``DevToolsAction`` values.
/// Time travel, toggle, import, pause, and lock are all handled here.
///
/// Pair with ``makeDevToolsRecorder`` to forward app actions and store snapshots.
/// See the README for full wiring instructions.
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
                            {
                                switch $0 {
                                case let .success(.found(svc)):   return ._serviceFound(svc)
                                case let .success(.removed(svc)): return ._serviceRemoved(svc)
                                case .success(.updated):          return ._serviceRemoved(.init(name: "", type: "", domain: ""))
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
                return .reduce {
                    $0.connectionStatus = .disconnected
                    $0.isPaused = false
                    $0.isLocked = false
                }
                .produce { ctx in
                    Effect<DevToolsAction>.fireAndForget {
                        await ctx.environment.connectionManager.close()
                    }
                    <> .cancelInFlight(id: "devtools-connection")
                }

            // MARK: - Internal: lifecycle

            case let ._connected(host, port):
                return .reduce { $0.connectionStatus = .connected(host: host, port: port) }

            case ._connectionFailed:
                return .reduce { $0.connectionStatus = .disconnected }

            case ._connectionLost:
                return .reduce {
                    $0.connectionStatus = .disconnected
                    $0.isPaused = false
                    $0.isLocked = false
                }

            // MARK: - Internal: discovery

            case let ._serviceFound(svc):
                return .reduce { state in
                    if !state.discoveredServices.contains(svc) {
                        state.discoveredServices.append(svc)
                    }
                }

            case let ._serviceRemoved(svc):
                return .reduce { $0.discoveredServices.removeAll { $0 == svc } }

            // MARK: - Internal: route received command

            case let ._received(command):
                return commandConsequence(command)

            // MARK: - Time travel (surfaced to app; recorder handles restoration)

            case let .jumpToAction(index):
                return .reduce { $0.currentActionIndex = index }

            case let .jumpToState(index):
                return .reduce { $0.currentActionIndex = index }

            case let .toggleAction(id):
                return .reduce { state in
                    if state.skippedActionIds.contains(id) {
                        state.skippedActionIds.remove(id)
                    } else {
                        state.skippedActionIds.insert(id)
                    }
                }

            // MARK: - History management

            case .reset:
                return .reduce {
                    $0.stateHistory = []
                    $0.actionHistory = []
                    $0.skippedActionIds = []
                    $0.currentActionIndex = nil
                }
                .produce { ctx in
                    Effect.fireAndForget { await ctx.environment.connectionManager.resetStateJSONs() }
                }

            case .commit:
                return .reduce { state in
                    if let ls = state.stateHistory.last, let la = state.actionHistory.last {
                        state.stateHistory  = [ls]
                        state.actionHistory = [la]
                        state.skippedActionIds = []
                        state.currentActionIndex = nil
                    }
                }
                .produce { ctx in
                    Effect.fireAndForget {
                        await ctx.environment.connectionManager.commitStateJSONs()
                    }
                }

            case .rollback:
                return .reduce { state in
                    if state.stateHistory.count > 1 {
                        state.stateHistory.removeLast()
                        state.actionHistory.removeLast()
                        state.currentActionIndex = nil
                    }
                }

            case let .importState(lifted):
                return .reduce { state in
                    state.stateHistory  = lifted.computedStateJSONs
                    state.actionHistory = Array(repeating: "{}", count: lifted.computedStateJSONs.count)
                    state.skippedActionIds  = lifted.skippedActionIds
                    state.currentActionIndex = lifted.currentStateIndex
                    state.isPaused = lifted.isPaused
                    state.isLocked = lifted.isLocked
                }
                .produce { ctx in
                    Effect.fireAndForget {
                        await ctx.environment.connectionManager.setSkippedActionIds(lifted.skippedActionIds)
                        await ctx.environment.connectionManager.setPaused(lifted.isPaused)
                        await ctx.environment.connectionManager.setLocked(lifted.isLocked)
                    }
                }

            // MARK: - Recording control

            case .pause:
                return .reduce { $0.isPaused = true }
                    .produce { ctx in
                        Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(true) }
                    }

            case .resume:
                return .reduce { $0.isPaused = false }
                    .produce { ctx in
                        Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(false) }
                    }

            case .lockChanges:
                return .reduce { $0.isLocked = true }
                    .produce { ctx in
                        Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(true) }
                    }

            case .unlockChanges:
                return .reduce { $0.isLocked = false }
                    .produce { ctx in
                        Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(false) }
                    }
            }
        }
}

// MARK: - Command → DevToolsAction

private func commandConsequence(_ command: RemoteDevCommand)
    -> Consequence<DevToolsState, DevToolsEnvironment, DevToolsAction> {
    switch command {
    case let .jumpToAction(index):     return .produce { _ in .just(.jumpToAction(index)) }
    case let .jumpToState(index):      return .produce { _ in .just(.jumpToState(index)) }
    case let .toggleAction(id):        return .produce { _ in .just(.toggleAction(id)) }
    case .reset:                       return .produce { _ in .just(.reset) }
    case .commit:                      return .produce { _ in .just(.commit) }
    case .rollback:                    return .produce { _ in .just(.rollback) }
    case let .pauseRecording(paused):  return .produce { _ in .just(paused ? .pause : .resume) }
    case let .lockChanges(locked):     return .produce { _ in .just(locked ? .lockChanges : .unlockChanges) }
    case let .importState(json):
        if let lifted = ImportedLiftedState.from(json: json) {
            return .produce { _ in .just(.importState(lifted)) }
        }
        return .doNothing
    case .unknown:
        return .doNothing
    }
}

// MARK: - Connection stream

/// Returns a `DeferredStream<DevToolsAction>` that opens the WebSocket,
/// performs the Socket.io handshake, yields `._connected`, then drives
/// the receive loop until the server closes the connection.
private func connectionStream(
    host: String,
    port: UInt16,
    env: DevToolsEnvironment
) -> DeferredStream<DevToolsAction> {
    DeferredStream {
        AsyncStream { continuation in
            let task = Task {
                let result = await env.openConnection(host, port).run()
                guard !Task.isCancelled else { return }

                switch result {
                case let .failure(error):
                    continuation.yield(._connectionFailed(error))
                    continuation.finish()

                case let .success(connection):
                    await env.connectionManager.setConnection(connection)
                    continuation.yield(._connected(host: host, port: port))

                    for await messageResult in connection.receive {
                        guard !Task.isCancelled else { break }
                        switch messageResult {
                        case let .success(.text(text)):
                            if let action = parseIncoming(text: text, connection: connection) {
                                continuation.yield(action)
                            }
                        case .success(.data):
                            break
                        case let .failure(error):
                            continuation.yield(._connectionLost(error))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(._connectionLost(nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Incoming message parser

private func parseIncoming(text: String, connection: WebSocketConnection) -> DevToolsAction? {
    switch SocketIO.parse(text) {
    case .ping:
        Task { _ = await connection.send(.text(SocketIO.pong)).run() }
        return nil
    case let .event(name, payload) where name == "dispatch":
        return ._received(RemoteDevCommand.from(payloadJSON: payload))
    default:
        return nil
    }
}
