import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

/// Creates a behavior that forwards every dispatched `AppAction` and resulting
/// `AppState` to the remotedev-server, and optionally handles time-travel and
/// toggle commands by decoding stored JSON back to `AppState`.
///
/// ## Memory model
///
/// State history is stored as **JSON strings** in the `DevToolsConnectionManager`
/// ring buffer — not as live `AppState` objects. This keeps the iOS memory footprint
/// small: a 200-entry ring buffer of 10 KB JSON snapshots uses ~2 MB, regardless of
/// how large the live `AppState` graph is.
///
/// The canonical full history lives in the devtools panel on the Mac, which has
/// abundant RAM. When the devtools panel requests time travel it sends back only an
/// index; the app looks up the stored JSON at that index and decodes it.
///
/// ## Phase 1 (monitoring only)
///
/// ```swift
/// makeDevToolsRecorder(instanceId: "my-app")
///     .liftEnvironment(\AppEnvironment.devTools)
/// ```
///
/// ## Phase 2 (time travel + toggle + import)
///
/// When `AppState: Decodable`, use the ``makeDevToolsRecorder(_:instanceName:extractDevToolsAction:restoreStateAction:serialize:)-Decodable``
/// overload — `deserializeState` is wired automatically via `JSONDecoder`:
///
/// ```swift
/// // AppAction + AppState both Codable — zero-config encoding AND decoding
/// makeDevToolsRecorder(
///     instanceId: Bundle.main.bundleIdentifier ?? "app",
///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
///     restoreStateAction: { .restoreState($0) }
///     // deserializeState is automatic — JSONDecoder used because AppState: Decodable
/// )
/// .liftEnvironment(\AppEnvironment.devTools)
/// ```
///
/// When `AppState` is NOT `Decodable`, supply `deserializeState` explicitly:
///
/// ```swift
/// makeDevToolsRecorder(
///     instanceId: Bundle.main.bundleIdentifier ?? "app",
///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
///     restoreStateAction: { .restoreState($0) },
///     deserializeState: { json in myCustomDecode(json) }
/// )
/// .liftEnvironment(\AppEnvironment.devTools)
/// ```
///
/// - Parameters:
///   - instanceId:            Unique key shown in the devtools instance list.
///   - instanceName:          Human-readable label; defaults to `instanceId`.
///   - extractDevToolsAction: Returns the `DevToolsAction` inside an `AppAction`,
///                            or `nil` for regular actions. Needed for time travel.
///   - restoreStateAction:    Given a decoded `AppState`, returns the `AppAction`
///                            that replaces the live state. Needed for time travel.
///   - deserializeState:      Decodes a JSON string back to `AppState`. Needed for
///                            `JUMP_TO_ACTION`, `TOGGLE_ACTION`, and `IMPORT_STATE`.
///   - serialize:             Maps `(AppAction, AppState?)` → `(actionJSON, stateJSON)`.
///                            Defaults to ``MirrorJSON`` reflection (no `Encodable` needed).
public func makeDevToolsRecorder<AppAction: Sendable, AppState: Sendable>(
    instanceId: String,
    instanceName: String? = nil,
    extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil },
    restoreStateAction: (@Sendable (AppState) -> AppAction)? = nil,
    deserializeState: (@Sendable (String) -> AppState?)? = nil,
    serialize: @escaping @Sendable (AppAction, AppState?) -> (action: String, state: String)
        = { action, state in
            (MirrorJSON.encode(action), state.map { MirrorJSON.encode($0 as Any) } ?? "{}")
        }
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    let name = instanceName ?? instanceId

    return Behavior { action, _ in

        // Intercept devtools commands before regular recording
        if let dtAction = extractDevToolsAction(action) {
            return handleDevToolsCommand(
                dtAction,
                restoreStateAction: restoreStateAction,
                deserializeState: deserializeState
            )
        }

        // Regular app action — capture serialized form now (phase 1, @MainActor)
        let actionJSON = serialize(action, nil).action

        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                guard await mgr.shouldRecord, await mgr.isConnected else { return nil }

                // Post-mutation state (@MainActor hop)
                let stateAfter = await ctx.stateAfter
                let (_, stateJSON) = serialize(action, stateAfter)

                // Store JSON in the ring buffer — zero extra serialization cost since
                // we already computed stateJSON for the wire message.
                await mgr.storeStateJSON(stateJSON)

                // INIT once per connection
                if await mgr.checkAndMarkInitSent() {
                    _ = await mgr.send(SocketIO.emit("log",
                        RemoteDevOutbound.`init`(state: stateJSON, instanceId: instanceId, name: name).toJSON()
                    ))
                }

                // ACTION every cycle
                _ = await mgr.send(SocketIO.emit("log",
                    RemoteDevOutbound.action(action: actionJSON, state: stateJSON, instanceId: instanceId).toJSON()
                ))

                return nil
            }
        }
    }
}

// MARK: - Decodable overload (auto-wires JSONDecoder)

/// Overload for when `AppState: Decodable`.
///
/// `deserializeState` is wired automatically using `JSONDecoder`, making time travel
/// and toggle zero-config when `AppState` is `Codable`. Encoding uses `JSONEncoder`
/// automatically too (via the `Encodable` fast-path in ``MirrorJSON``).
///
/// This is the overload to use when `AppState: Codable`:
///
/// ```swift
/// // AppState: Codable — fully automatic encode + decode
/// makeDevToolsRecorder(
///     instanceId: "my-app",
///     extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
///     restoreStateAction: { .restoreState($0) }
/// )
/// ```
///
/// When `AppState` does not conform to `Decodable`, the compiler falls back to
/// the base overload and `deserializeState` must be provided explicitly (or omitted
/// to disable time travel).
public func makeDevToolsRecorder<AppAction: Sendable, AppState: Decodable & Sendable>(
    instanceId: String,
    instanceName: String? = nil,
    extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil },
    restoreStateAction: (@Sendable (AppState) -> AppAction)? = nil,
    serialize: @escaping @Sendable (AppAction, AppState?) -> (action: String, state: String)
        = { action, state in
            (MirrorJSON.encode(action), state.map { MirrorJSON.encode($0 as Any) } ?? "{}")
        }
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    makeDevToolsRecorder(
        instanceId: instanceId,
        instanceName: instanceName,
        extractDevToolsAction: extractDevToolsAction,
        restoreStateAction: restoreStateAction,
        deserializeState: { json in
            json.data(using: .utf8).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
        },
        serialize: serialize
    )
}

// MARK: - DevTools command handling

private func handleDevToolsCommand<AppAction: Sendable, AppState: Sendable>(
    _ command: DevToolsAction,
    restoreStateAction: (@Sendable (AppState) -> AppAction)?,
    deserializeState: (@Sendable (String) -> AppState?)?
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {

    switch command {

    // MARK: Jump

    case let .jumpToAction(index), let .jumpToState(index):
        guard let restore = restoreStateAction, let decode = deserializeState else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                if let json = await mgr.stateJSON(at: index), let state = decode(json) {
                    return restore(state)
                }
                return nil
            }
        }

    // MARK: Toggle

    case let .toggleAction(id):
        guard let restore = restoreStateAction, let decode = deserializeState else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let isNowSkipped = await mgr.toggleSkipped(id)
                // Skip: jump to state just before this action.
                // Un-skip: jump back to state at this action.
                let targetIndex = isNowSkipped ? max(0, id - 1) : id
                let base = await mgr.historyBaseIndex
                let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? base
                if let json = await mgr.stateJSON(at: resolvedIndex), let state = decode(json) {
                    return restore(state)
                }
                return nil
            }
        }

    // MARK: Reset

    case .reset:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.resetStateJSONs() }
        }

    // MARK: Commit

    case .commit:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.commitStateJSONs() }
        }

    // MARK: Rollback

    case .rollback:
        // DevToolsBehavior already pops the last entry from DevToolsState.stateHistory.
        // Mirror that in the ring buffer.
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.rollbackStateJSON() }
        }

    // MARK: Import state

    case let .importState(lifted):
        // Always update the JSON ring buffer — regardless of whether we can decode.
        // Decoding + restoration only happens when deserializeState is provided.
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                await mgr.setSkippedActionIds(lifted.skippedActionIds)

                guard let restore = restoreStateAction, let decode = deserializeState else { return nil }

                let target = lifted.currentStateIndex
                let base = await mgr.historyBaseIndex
                let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: target) ?? base
                if let json = await mgr.stateJSON(at: resolvedIndex), let state = decode(json) {
                    return restore(state)
                }
                return nil
            }
        }

    // MARK: Recording control (sync manager with DevToolsBehavior's state changes)

    case .pause:
        return .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(true) } }
    case .resume:
        return .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(false) } }
    case .lockChanges:
        return .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(true) } }
    case .unlockChanges:
        return .produce { ctx in Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(false) } }

    default:
        return .doNothing
    }
}
