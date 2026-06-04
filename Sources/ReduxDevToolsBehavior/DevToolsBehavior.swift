import Core
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
    /// Base overload — no Codable constraints. MirrorJSON for encoding, no time travel.
    /// Override individual closures for custom serialization or time travel.
    public static func behaviors<AppAction: Sendable, AppState: Sendable, AppEnvironment: Sendable>(
        action actionPrism: Prism<AppAction, DevToolsAction>,
        state statePath: WritableKeyPath<AppState, DevToolsState>,
        environment envPath: KeyPath<AppEnvironment, DevToolsEnvironment>,
        extractDevToolsAction: (@Sendable (AppAction) -> DevToolsAction?)? = nil
    ) -> Behavior<AppAction, AppState, AppEnvironment> {
        let extract: @Sendable (AppAction) -> DevToolsAction? = extractDevToolsAction ?? { actionPrism.preview($0) }
        return lift(
            actionPrism, statePath, envPath,
            timeMachine: makeTimeMachine(
                extractDevToolsAction: extract,
                wrapDevToolsAction: actionPrism.review
            )
        )
    }

    // MARK: - Component behaviors (advanced composition)

    /// The time-machine behavior: records every action, stores state JSON, and
    /// restores state on jump / toggle / import commands.
    ///
    /// Typed `Behavior<AppAction, AppState, DevToolsEnvironment>`. Lift the environment
    /// axis before combining with your app behavior.
    ///
    /// ## Serialization defaults
    ///
    /// | Closure | Default | When to override |
    /// |---|---|---|
    /// | `encodeAction` | ``MirrorJSON`` (auto-uses `JSONEncoder` for `Encodable`) | custom format |
    /// | `encodeState`  | ``MirrorJSON`` | custom format |
    /// | `deserializeState`  | `nil` — time travel disabled | provide when `AppState` is not `Decodable` |
    /// | `deserializeAction` | `nil` — Dispatcher tab disabled | provide when `AppAction` is not `Decodable` |
    ///
    /// For `AppState: Codable`, prefer the Codable overload which auto-wires
    /// `JSONEncoder`/`JSONDecoder` without any parameters.
    ///
    /// ## Base overload (no Codable constraints)
    ///
    /// ```swift
    /// DevToolsBehavior.timeMachineBehavior(
    ///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
    ///     restoreStateAction: { .restoreState($0) },
    ///     deserializeState: { json in myDecode(json) }   // required for time travel
    /// )
    /// ```
    /// Serialization is provided by `DevToolsEnvironment.jsonEncoder` / `jsonDecoder`.
    /// Time travel and the Dispatcher tab activate automatically when `AppState`/`AppAction`
    /// are `Decodable` at runtime — no additional parameters required.
    public static func timeMachineBehavior<AppAction: Sendable, AppState: Sendable>(
        extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil }
    ) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
        makeTimeMachine(extractDevToolsAction: extractDevToolsAction, wrapDevToolsAction: nil)
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

            case .activate:
                // Read connectionMode from the environment and dispatch the appropriate action.
                return .produce { ctx in
                    switch ctx.environment.connectionMode {
                    case .manual:
                        return .empty
                    case let .connectOnLaunch(host, port):
                        return .just(.connect(host: host, port: port))
                    case .browseOnLaunch, .autoConnect:
                        // Both modes start browsing. .autoConnect also auto-connects
                        // on the first ._serviceFound (handled in that case below).
                        return .just(.startBrowsing)
                    }
                }

            case let .connectToService(service):
                // Resolve the Bonjour service to a concrete host:port, then connect.
                return .produce { ctx in
                    Effect.task {
                        switch await ctx.environment.resolveService(service).run() {
                        case let .success(resolved):
                            guard let host = resolved.preferredHost, let port = resolved.port else {
                                return ._connectionFailed(CodableError(DevToolsError.couldNotResolveService(service)))
                            }
                            return .connect(host: host, port: port)
                        case let .failure(error):
                            return ._connectionFailed(CodableError(error))
                        }
                    }
                }

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
                            ctx.environment.browseServices(ctx.environment.browsingServiceType),
                            {
                                switch $0 {
                                case let .success(.found(svc)):   return ._serviceFound(svc)
                                case let .success(.removed(svc)): return ._serviceRemoved(svc)
                                case .success(.updated):          return ._serviceRemoved(.init(name: "", type: "", domain: ""))
                                case let .failure(error):         return ._connectionFailed(CodableError(error))
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
                    $0.socketId = nil
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
                return .reduce { $0.connectionStatus = .handshaking(host: host, port: port) }
                    .produce { ctx in
                        // In .autoConnect mode, stop browsing once connected —
                        // no point continuing to scan the network.
                        guard case .autoConnect = ctx.environment.connectionMode else { return .empty }
                        return .just(.stopBrowsing)
                    }

            case let ._handshakeAck(socketId):
                return .reduce { state in
                    if case .handshaking(let host, let port) = state.connectionStatus {
                        state.connectionStatus = .connected(host: host, port: port)
                    }
                    state.socketId = socketId
                }

            case ._connectionFailed:
                return .reduce {
                    $0.connectionStatus = .disconnected
                    $0.socketId = nil
                }

            case ._connectionLost:
                return .reduce {
                    $0.connectionStatus = .disconnected
                    $0.socketId = nil
                    $0.isPaused = false
                    $0.isLocked = false
                }

            case let ._serviceFound(svc):
                return .reduce { state in
                    if !state.discoveredServices.contains(svc) {
                        state.discoveredServices.append(svc)
                    }
                }
                .produce { ctx in
                    // In .autoConnect mode, connect to the first server found
                    // (but only if still disconnected — ignore subsequent discoveries).
                    guard case .autoConnect = ctx.environment.connectionMode else { return .empty }
                    return Effect.task {
                        let status = await ctx.stateAfter?.connectionStatus
                        guard case .disconnected = status else { return nil }
                        return .connectToService(svc)
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
                return .doNothing

            case ._triggerRestore:
                // Handled by timeMachineBehavior which owns the PendingRestore box.
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

/// Thread-safe typed box for two-phase time travel restore.
/// The produce effect decodes a JSON string into AppState and stores it here;
/// the subsequent reduce reads it synchronously — no deserialization in reduce.
final class PendingRestore<S: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: S?
    func set(_ s: S)    { lock.withLock { state = s } }
    func consume() -> S? { lock.withLock { defer { state = nil }; return state } }
}

// MARK: - Private factories

/// Shared implementation of all `timeMachineBehavior` overloads.
/// All closures are fully typed — no `Any`, no casts.
private func makeTimeMachine<AppAction: Sendable, AppState: Sendable>(
    extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction?,
    wrapDevToolsAction: (@Sendable (DevToolsAction) -> AppAction)?
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    // Typed box for the two-phase time travel restore.
    // Phase 1 (produce): decode JSON → store AppState here.
    // Phase 2 (reduce):  consume typed state → assign to store, no JSON involved.
    let pendingRestore = PendingRestore<AppState>()

    return Behavior<AppAction, AppState, DevToolsEnvironment> { action, _ in

        if let dtAction = extractDevToolsAction(action) {
            // On connect: send INIT with current state immediately.
            if case ._handshakeAck = dtAction {
                return .produce { ctx in
                    Effect.task {
                        let mgr = ctx.environment.connectionManager
                        guard await mgr.isConnected else { return nil }
                        let stateJSON    = ctx.environment.encodeAny.run(await ctx.stateAfter as Any).value ?? "{}"
                        let instanceId   = ctx.environment.instanceId
                        let instanceName = ctx.environment.instanceName ?? instanceId
                        _ = await mgr.checkAndMarkInitSent()
                        _ = await mgr.send(SocketCluster.transmit(
                            event: "log-noid",
                            jsonPayload: RemoteDevOutbound.`init`(state: stateJSON, instanceId: instanceId, name: instanceName).toJSON(describeAction: ctx.environment.describeAction)
                        ))
                        return nil
                    }
                }
            }

            // Phase 2: consume the decoded state from the box and apply it.
            if case ._triggerRestore = dtAction {
                return .reduce { state in
                    if let restored = pendingRestore.consume() { state = restored }
                }
            }

            return handleDevToolsCommand(
                dtAction,
                wrapDevToolsAction: wrapDevToolsAction,
                pendingRestore: pendingRestore
            )
        }

        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                guard await mgr.shouldRecord, await mgr.isConnected else { return nil }

                let stateAfter = await ctx.stateAfter
                let stateJSON  = ctx.environment.encodeAny.run(stateAfter as Any).value ?? "{}"

                await mgr.storeStateJSON(stateJSON)

                let instanceId   = ctx.environment.instanceId
                let instanceName = ctx.environment.instanceName ?? instanceId
                if await mgr.checkAndMarkInitSent() {
                    _ = await mgr.send(SocketCluster.transmit(
                        event: "log-noid",
                        jsonPayload: RemoteDevOutbound.`init`(state: stateJSON, instanceId: instanceId, name: instanceName).toJSON(describeAction: ctx.environment.describeAction)
                    ))
                }
                _ = await mgr.send(SocketCluster.transmit(
                    event: "log-noid",
                    jsonPayload: RemoteDevOutbound.action(originalAction: action, state: stateJSON, instanceId: instanceId).toJSON(describeAction: ctx.environment.describeAction)
                ))
                return nil
            }
        }
    }
}

/// Lifts the socket + time-machine pair into the app's action/state/environment.
private func lift<AppAction: Sendable, AppState: Sendable, AppEnvironment: Sendable>(
    _ actionPrism: Prism<AppAction, DevToolsAction>,
    _ statePath: WritableKeyPath<AppState, DevToolsState>,
    _ envPath: KeyPath<AppEnvironment, DevToolsEnvironment>,
    timeMachine: Behavior<AppAction, AppState, DevToolsEnvironment>
) -> Behavior<AppAction, AppState, AppEnvironment> {
    Behavior.combine(
        DevToolsBehavior.socketBehavior.lift(
            action: actionPrism,
            state: statePath,
            environment: { $0[keyPath: envPath] }
        ),
        timeMachine.liftEnvironment { $0[keyPath: envPath] }
    )
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
                    continuation.yield(._connectionFailed(CodableError(error)))
                    continuation.finish()

                case let .success(connection):
                    // Send SocketCluster handshake directly — the manager has no connection
                    // yet, so the recorder cannot fire prematurely.
                    _ = await connection.send(.text(SocketCluster.handshake(cid: 1))).run()

                    // Single iterator for the entire connection lifetime — creating a second
                    // iterator would cancel the underlying URLSessionWebSocketTask.
                    for await messageResult in connection.receive {
                        guard !Task.isCancelled else { break }
                        switch messageResult {
                        case let .success(.text(text)):
                            switch SocketCluster.parse(text) {
                            case .ping:
                                Task { _ = await connection.send(.text(SocketCluster.pong)).run() }
                            case .handshakeAck(let socketId, _):
                                _ = await connection.send(.text(SocketCluster.subscribe(channel: "sc-\(socketId)", cid: 2))).run()
                                await env.connectionManager.setConnection(connection)
                                continuation.yield(._connected(host: host, port: port))
                                continuation.yield(._handshakeAck(socketId: socketId))
                            case let .publish(channel, payload) where channel.hasPrefix("sc-"):
                                if let action = parseDispatch(payload) { continuation.yield(action) }
                            default:
                                break
                            }
                        case .success(.data): break
                        case let .failure(error):
                            continuation.yield(._connectionLost(CodableError(error)))
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

private func parseDispatch(_ payload: String) -> DevToolsAction? {
    guard let data = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type_ = obj["type"] as? String
    else { return nil }

    switch type_ {
    case "DISPATCH":
        guard let action = obj["action"],
              let actionData = try? JSONSerialization.data(withJSONObject: action),
              let actionJSON = String(data: actionData, encoding: .utf8)
        else { return nil }
        return ._received(RemoteDevCommand.from(payloadJSON: actionJSON))
    default:
        return nil
    }
}
