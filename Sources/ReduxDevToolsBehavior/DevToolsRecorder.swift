import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

/// Creates a behavior that forwards every dispatched `AppAction` and the resulting
/// `AppState` to the connected remotedev-server, and optionally handles time-travel
/// and toggle commands by restoring stored state snapshots.
///
/// ## Phase 1 (zero-config monitoring)
///
/// ```swift
/// makeDevToolsRecorder(instanceId: "my-app")
///     .liftEnvironment(\AppEnvironment.devTools)
/// ```
///
/// Actions and states are serialized with ``MirrorJSON`` — no `Encodable` required.
///
/// ## Phase 2 (time travel + toggle)
///
/// Supply `extractDevToolsAction` and `restoreStateAction` to enable in-process
/// state restoration. When the devtools panel requests a jump, toggle, or import,
/// the recorder retrieves the stored `AppState` snapshot and dispatches
/// `restoreStateAction(snapshot)` back into the store:
///
/// ```swift
/// makeDevToolsRecorder(
///     instanceId: Bundle.main.bundleIdentifier ?? "app",
///     instanceName: "My App",
///     extractDevToolsAction: { appAction in
///         if case .devTools(let dt) = appAction { return dt }
///         return nil
///     },
///     restoreStateAction: { .devTools(.restoreState($0)) },
///     serialize: { action, state in
///         let encoder = JSONEncoder()
///         let actionJSON = (try? encoder.encode(action as! Encodable))
///             .flatMap { String(data: $0, encoding: .utf8) } ?? MirrorJSON.encode(action)
///         let stateJSON = state.flatMap { s in
///             (try? encoder.encode(s)).flatMap { String(data: $0, encoding: .utf8) }
///         } ?? "{}"
///         return (actionJSON, stateJSON)
///     }
/// )
/// ```
///
/// And in your `AppAction` and `AppState`:
///
/// ```swift
/// enum AppAction {
///     // ...
///     #if DEBUG
///     case devTools(DevToolsAction)
///     case restoreState(AppState)   // for time travel
///     #endif
/// }
///
/// // In your Behavior / Reducer:
/// case .restoreState(let snapshot):
///     state = snapshot
/// ```
///
/// ## IMPORT_STATE
///
/// When the devtools panel imports a full lifted state, the recorder can restore
/// the `currentStateIndex` snapshot if you provide `deserializeState`:
///
/// ```swift
/// makeDevToolsRecorder(
///     instanceId: "my-app",
///     deserializeState: { json in
///         json.data(using: .utf8).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
///     },
///     restoreStateAction: { .restoreState($0) }
/// )
/// ```
///
/// - Parameters:
///   - instanceId: Unique identifier shown in the devtools instance list.
///   - instanceName: Human-readable label; defaults to `instanceId`.
///   - extractDevToolsAction: Extracts a `DevToolsAction` from your `AppAction`, or
///     returns `nil` for regular app actions. Required for time travel and toggle.
///   - restoreStateAction: Given a stored `AppState` snapshot, returns the `AppAction`
///     that should be dispatched to replace the live state. Required for time travel.
///   - deserializeState: Decodes a JSON string back to `AppState`. Required only for
///     `IMPORT_STATE` — the snapshot is stored from the live state otherwise.
///   - serialize: Maps `(AppAction, AppState?)` to `(actionJSON, stateJSON)`.
///     Defaults to ``MirrorJSON`` reflection.
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
        let manager = // captured in the closure below
            Void()  // placeholder — see produce

        // Check if this is a devtools command intercepted by the recorder
        if let dtAction = extractDevToolsAction(action) {
            return handleDevToolsCommand(
                dtAction,
                restoreStateAction: restoreStateAction,
                deserializeState: deserializeState,
                instanceId: instanceId,
                name: name,
                serialize: serialize
            )
        }

        // Regular app action: serialize in phase 1 (@MainActor, before mutation)
        let actionJSON = serialize(action, nil).action

        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                guard await mgr.shouldRecord else { return nil }
                guard await mgr.isConnected  else { return nil }

                // Read post-mutation state (@MainActor hop)
                let stateAfter = await ctx.stateAfter

                // Store actual AppState snapshot for in-process time travel
                if let state = stateAfter {
                    await mgr.storeSnapshot(state)
                }

                // Serialize state
                let (_, stateJSON) = serialize(action, stateAfter)

                // Send INIT once per connection
                if await mgr.checkAndMarkInitSent() {
                    let initMsg = RemoteDevOutbound.`init`(
                        state: stateJSON,
                        instanceId: instanceId,
                        name: name
                    )
                    _ = await mgr.send(SocketIO.emit("log", initMsg.toJSON()))
                }

                // Send ACTION for this cycle
                let actionMsg = RemoteDevOutbound.action(
                    action: actionJSON,
                    state: stateJSON,
                    instanceId: instanceId
                )
                _ = await mgr.send(SocketIO.emit("log", actionMsg.toJSON()))

                return nil
            }
        }
    }
}

// MARK: - DevTools command handling

private func handleDevToolsCommand<AppAction: Sendable, AppState: Sendable>(
    _ command: DevToolsAction,
    restoreStateAction: (@Sendable (AppState) -> AppAction)?,
    deserializeState: (@Sendable (String) -> AppState?)?,
    instanceId: String,
    name: String,
    serialize: @escaping @Sendable (AppAction, AppState?) -> (action: String, state: String)
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {
    guard let restore = restoreStateAction else { return .doNothing }

    switch command {

    // MARK: Jump to action / state

    case let .jumpToAction(index), let .jumpToState(index):
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                if let snapshot: AppState = await mgr.snapshot(at: index) {
                    return restore(snapshot)
                }
                return nil
            }
        }

    // MARK: Toggle action

    case let .toggleAction(id):
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let isNowSkipped = await mgr.toggleSkipped(id)

                // Restore the nearest valid snapshot:
                // - If newly skipped: jump to state before this action (id - 1)
                // - If newly un-skipped: jump back to state AT this action (id)
                let targetIndex = isNowSkipped ? max(0, id - 1) : id

                // Find nearest non-skipped index at or before the target
                let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? 0

                if let snapshot: AppState = await mgr.snapshot(at: resolvedIndex) {
                    return restore(snapshot)
                }
                return nil
            }
        }

    // MARK: Reset

    case .reset:
        return .produce { ctx in
            Effect.task {
                await ctx.environment.connectionManager.resetSnapshots()
                return nil
            }
        }

    // MARK: Commit

    case .commit:
        // commitSnapshots() handles the type-erased "keep only last" internally
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.commitSnapshots() }
        }

    // MARK: Import state

    case let .importState(lifted):
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager

                // Restore snapshots from deserialized states (requires deserializeState)
                if let decode = deserializeState {
                    let restored = lifted.computedStateJSONs.compactMap { decode($0) }
                    await mgr.replaceSnapshots(restored)
                    await mgr.setSkippedActionIds(lifted.skippedActionIds)

                    // Jump to currentStateIndex
                    let target = lifted.currentStateIndex
                    let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: target) ?? 0
                    if let snapshot: AppState = await mgr.snapshot(at: resolvedIndex) {
                        return restore(snapshot)
                    }
                } else {
                    // No deserializer — can only update the skip set
                    await mgr.setSkippedActionIds(lifted.skippedActionIds)
                }
                return nil
            }
        }

    // MARK: Pause / Resume / Lock / Unlock (sync with manager)

    case .pause:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(true) }
        }

    case .resume:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.setPaused(false) }
        }

    case .lockChanges:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(true) }
        }

    case .unlockChanges:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.setLocked(false) }
        }

    default:
        return .doNothing
    }
}
