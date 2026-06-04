import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

// MARK: - DevTools command handling

/// Handles a `DevToolsAction` intercepted by `timeMachineBehavior` before regular recording.
///
/// All serialization closures are typed — no `Any` conversions, no runtime casts.
func handleDevToolsCommand<AppAction: Sendable, AppState: Sendable>(
    _ command: DevToolsAction,
    wrapDevToolsAction: (@Sendable (DevToolsAction) -> AppAction)?,
    pendingRestore: PendingRestore<AppState>,
    deserializeState: (@Sendable (String) -> AppState?)?,
    deserializeAction: (@Sendable (String) -> AppAction?)?
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {

    switch command {

    case let .jumpToAction(index), let .jumpToState(index):
        guard let decode = deserializeState else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                guard let json = await ctx.environment.connectionManager.stateJSON(at: index),
                      let state = decode(json) else { return nil }
                pendingRestore.set(state)                          // typed AppState, no JSON in reduce
                return wrapDevToolsAction?(._triggerRestore)
            }
        }

    case let .toggleAction(id):
        guard let decode = deserializeState else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let isNowSkipped = await mgr.toggleSkipped(id)
                let targetIndex  = isNowSkipped ? max(0, id - 1) : id
                let base         = await mgr.historyBaseIndex
                let idx          = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? base
                guard let json = await mgr.stateJSON(at: idx),
                      let state = decode(json) else { return nil }
                pendingRestore.set(state)
                guard let wrap = wrapDevToolsAction else { return nil }
                return wrap(._triggerRestore)
            }
        }

    case .reset:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.resetStateJSONs() }
        }

    case .commit:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.commitStateJSONs() }
        }

    case .rollback:
        return .produce { ctx in
            Effect.fireAndForget { await ctx.environment.connectionManager.rollbackStateJSON() }
        }

    case let .importState(lifted):
        guard let decode = deserializeState else {
            return .produce { ctx in
                Effect.fireAndForget {
                    let mgr = ctx.environment.connectionManager
                    await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                    await mgr.setSkippedActionIds(lifted.skippedActionIds)
                }
            }
        }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                await mgr.setSkippedActionIds(lifted.skippedActionIds)
                let base = await mgr.historyBaseIndex
                let idx  = await mgr.latestNonSkippedIndex(upTo: lifted.currentStateIndex) ?? base
                guard let json = await mgr.stateJSON(at: idx),
                      let state = decode(json) else { return nil }
                pendingRestore.set(state)
                guard let wrap = wrapDevToolsAction else { return nil }
                return wrap(._triggerRestore)
            }
        }

    case let .dispatchAction(actionJSON: json):
        guard let decode = deserializeAction else { return .doNothing }
        return .produce { _ in Effect.task { decode(json) } }

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

// MARK: - Deprecated free functions

/// - Important: Deprecated. Use ``DevToolsBehavior/behaviors(action:state:environment:extractDevToolsAction:restoreStateAction:encodeAction:encodeState:deserializeState:deserializeAction:)`` instead.
@available(*, deprecated, message: "Use DevToolsBehavior.behaviors(action:state:environment:) — serialization is now configured there, not in the environment.")
public func makeDevToolsRecorder<AppAction: Sendable, AppState: Sendable>(
    instanceId: String,
    instanceName: String? = nil,
    extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil },
    deserializeState: (@Sendable (String) -> AppState?)? = nil,
    encodeState: (@Sendable (AppState?) -> String)? = nil
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    DevToolsBehavior.timeMachineBehavior(
        extractDevToolsAction: extractDevToolsAction,
        encodeState: encodeState,
        deserializeState: deserializeState
    )
}
