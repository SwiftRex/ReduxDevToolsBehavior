import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency
import WebSocketClient

/// Namespace for the Redux DevTools behaviors and their composition API.
public enum DevToolsBehavior {

    // MARK: - Primary API

    /// Creates the fully-composed devtools behavior and lifts it into your app types.
    ///
    /// Combines ``socketBehavior`` (connection lifecycle + command routing) with
    /// ``timeMachineBehavior(extractDevToolsAction:restoreStateAction:)`` (action recording
    /// + state restoration) and lifts both into `AppAction`, `AppState`, `AppEnvironment`.
    ///
    /// ## Minimum setup (monitoring only)
    ///
    /// ```swift
    /// DevToolsBehavior.behaviors(
    ///     action: AppAction.prism.devTools,
    ///     state: \AppState.devTools,
    ///     environment: \AppEnvironment.devTools
    /// )
    /// ```
    ///
    /// ## With time travel
    ///
    /// ```swift
    /// DevToolsBehavior.behaviors(
    ///     action: AppAction.prism.devTools,
    ///     state: \AppState.devTools,
    ///     environment: \AppEnvironment.devTools,
    ///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
    ///     restoreStateAction: { .restoreState($0) }
    /// )
    /// ```
    ///
    /// Requires `environment.decodeState` to be set — use `.live(for: AppState.self)` when
    /// `AppState: Codable`, or set `decodeState` manually in `.live(decodeState:)`.
    ///
    /// - Parameters:
    ///   - action:                Prism from `AppAction` to `DevToolsAction`.
    ///   - state:                 KeyPath from `AppState` to `DevToolsState`.
    ///   - environment:           KeyPath from `AppEnvironment` to `DevToolsEnvironment`.
    ///   - extractDevToolsAction: Returns the `DevToolsAction` inside an `AppAction`, or
    ///                            `nil` for regular actions. Required for time travel.
    ///   - restoreStateAction:    Builds the `AppAction` that replaces the live state with
    ///                            a restored snapshot. Required for time travel.
    public static func behaviors<AppAction: Sendable, AppState: Sendable, AppEnvironment: Sendable>(
        action actionPrism: Prism<AppAction, DevToolsAction>,
        state statePath: WritableKeyPath<AppState, DevToolsState>,
        environment envPath: KeyPath<AppEnvironment, DevToolsEnvironment>,
        extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil },
        restoreStateAction: (@Sendable (AppState) -> AppAction)? = nil
    ) -> Behavior<AppAction, AppState, AppEnvironment> {
        Behavior.combine(
            socketBehavior.lift(
                action: actionPrism,
                state: statePath,
                environment: { $0[keyPath: envPath] }
            ),
            timeMachineBehavior(
                extractDevToolsAction: extractDevToolsAction,
                restoreStateAction: restoreStateAction
            )
            .liftEnvironment { $0[keyPath: envPath] }
        )
    }

    // MARK: - Component behaviors (advanced composition)

    /// The time-machine behavior: records every action, stores state JSON, and
    /// restores state on jump / toggle / import commands.
    ///
    /// Typed `Behavior<AppAction, AppState, DevToolsEnvironment>`. Lift the environment
    /// axis before combining with your app behavior:
    ///
    /// ```swift
    /// DevToolsBehavior.timeMachineBehavior(
    ///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
    ///     restoreStateAction: { .restoreState($0) }
    /// )
    /// .liftEnvironment(\AppEnvironment.devTools)
    /// ```
    ///
    /// Prefer ``behaviors(action:state:environment:extractDevToolsAction:restoreStateAction:)``
    /// unless you need to compose the two behaviors separately.
    public static func timeMachineBehavior<AppAction: Sendable, AppState: Sendable>(
        extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil },
        restoreStateAction: (@Sendable (AppState) -> AppAction)? = nil
    ) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
        Behavior { action, _ in

            // Intercept devtools commands before regular recording
            if let dtAction = extractDevToolsAction(action) {
                return handleDevToolsCommand(dtAction, restoreStateAction: restoreStateAction)
            }

            // Regular app action — record and forward to the devtools panel
            return .produce { ctx in
                Effect.task {
                    let env = ctx.environment
                    let mgr = env.connectionManager
                    guard await mgr.shouldRecord, await mgr.isConnected else { return nil }

                    // Encode action (phase 3 — safe, action is a value type captured above)
                    let actionJSON = env.encodeAction(action)

                    // Post-mutation state (@MainActor hop)
                    let stateAfter = await ctx.stateAfter
                    let stateJSON  = env.encodeState(stateAfter.map { $0 as Any })

                    // Store JSON in the ring buffer (reuses already-computed stateJSON)
                    await mgr.storeStateJSON(stateJSON)

                    // INIT once per connection
                    let instanceId   = env.instanceId
                    let instanceName = env.instanceName ?? instanceId
                    if await mgr.checkAndMarkInitSent() {
                        _ = await mgr.send(SocketIO.emit("log",
                            RemoteDevOutbound.`init`(
                                state: stateJSON,
                                instanceId: instanceId,
                                name: instanceName
                            ).toJSON()
                        ))
                    }

                    // ACTION every cycle
                    _ = await mgr.send(SocketIO.emit("log",
                        RemoteDevOutbound.action(
                            action: actionJSON,
                            state: stateJSON,
                            instanceId: instanceId
                        ).toJSON()
                    ))

                    return nil
                }
            }
        }
    }

    /// The socket-lifecycle behavior: connection, browsing, and devtools command routing.
    ///
    /// Typed `Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment>`. Lift with
    /// all three axes before combining with your app behavior.
    ///
    /// Prefer ``behaviors(action:state:environment:extractDevToolsAction:restoreStateAction:)``
    /// unless you need to compose the two behaviors separately.
    public static let socketBehavior: Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment> =
        Behavior { action, _ in
            switch action {

            case let .connect(host, port):
                return .reduce { $0.connectionStatus = .connecting }
                    .produce { ctx in
                        Effect<DevToolsAction>.deferredStream(
                            connectionStream(host: host, port: port, env: ctx.environment),
                            { $0 },
                            scheduling: .replacing(id: "devtools-connection")
                        )
                    }

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

            case let ._serviceFound(svc):
                return .reduce { state in
                    if !state.discoveredServices.contains(svc) {
                        state.discoveredServices.append(svc)
                    }
                }

            case let ._serviceRemoved(svc):
                return .reduce { $0.discoveredServices.removeAll { $0 == svc } }

            case let ._received(command):
                return socketCommandConsequence(command)

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
                    Effect.fireAndForget { await ctx.environment.connectionManager.commitStateJSONs() }
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
                    state.stateHistory       = lifted.computedStateJSONs
                    state.actionHistory      = Array(repeating: "{}", count: lifted.computedStateJSONs.count)
                    state.skippedActionIds   = lifted.skippedActionIds
                    state.currentActionIndex = lifted.currentStateIndex
                    state.isPaused           = lifted.isPaused
                    state.isLocked           = lifted.isLocked
                }
                .produce { ctx in
                    Effect.fireAndForget {
                        await ctx.environment.connectionManager.setSkippedActionIds(lifted.skippedActionIds)
                        await ctx.environment.connectionManager.setPaused(lifted.isPaused)
                        await ctx.environment.connectionManager.setLocked(lifted.isLocked)
                    }
                }

            case .pause:
                return .reduce { $0.isPaused = true }
                    .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(true) } }

            case .resume:
                return .reduce { $0.isPaused = false }
                    .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(false) } }

            case .lockChanges:
                return .reduce { $0.isLocked = true }
                    .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(true) } }

            case .unlockChanges:
                return .reduce { $0.isLocked = false }
                    .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(false) } }

            case .dispatchAction:
                // Handled by timeMachineBehavior which knows the concrete AppAction type.
                // socketBehavior has no state mutation or side effect to perform here.
                return .doNothing
            }
        }

    /// Deprecated alias for ``socketBehavior``.
    @available(*, deprecated, renamed: "DevToolsBehavior.socketBehavior")
    public static var behavior: Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment> {
        socketBehavior
    }
}

// MARK: - Private helpers

private func socketCommandConsequence(
    _ command: RemoteDevCommand
) -> Consequence<DevToolsState, DevToolsEnvironment, DevToolsAction> {
    switch command {
    case let .jumpToAction(index):           return .produce { _ in .just(.jumpToAction(index)) }
    case let .jumpToState(index):            return .produce { _ in .just(.jumpToState(index)) }
    case let .toggleAction(id):              return .produce { _ in .just(.toggleAction(id)) }
    case .reset:                             return .produce { _ in .just(.reset) }
    case .commit:                            return .produce { _ in .just(.commit) }
    case .rollback:                          return .produce { _ in .just(.rollback) }
    case let .pauseRecording(paused):        return .produce { _ in .just(paused ? .pause : .resume) }
    case let .lockChanges(locked):           return .produce { _ in .just(locked ? .lockChanges : .unlockChanges) }
    case let .dispatchFromDevTools(json):    return .produce { _ in .just(.dispatchAction(actionJSON: json)) }
    case let .importState(json):
        if let lifted = ImportedLiftedState.from(json: json) {
            return .produce { _ in .just(.importState(lifted)) }
        }
        return .doNothing
    case .unknown:
        return .doNothing
    }
}

private extension Consequence {
    static func just(_ action: Action) -> Self {
        .produce { _ in .just(action) }
    }
}

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
                        case .success(.data): break
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
