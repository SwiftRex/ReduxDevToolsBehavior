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
    restoreStateAction: (@Sendable (AppState) -> AppAction)?,
    deserializeState:  (@Sendable (String) -> AppState?)?,
    deserializeAction: (@Sendable (String) -> AppAction?)?
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {

    switch command {

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

    case let .toggleAction(id):
        guard let restore = restoreStateAction, let decode = deserializeState else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let isNowSkipped = await mgr.toggleSkipped(id)
                let targetIndex  = isNowSkipped ? max(0, id - 1) : id
                let base         = await mgr.historyBaseIndex
                let idx          = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? base
                if let json = await mgr.stateJSON(at: idx), let state = decode(json) {
                    return restore(state)
                }
                return nil
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
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                await mgr.setSkippedActionIds(lifted.skippedActionIds)

                guard let restore = restoreStateAction, let decode = deserializeState else { return nil }

                let base = await mgr.historyBaseIndex
                let idx  = await mgr.latestNonSkippedIndex(upTo: lifted.currentStateIndex) ?? base
                if let json = await mgr.stateJSON(at: idx), let state = decode(json) {
                    return restore(state)
                }
                return nil
            }
        }

    case let .dispatchAction(actionJSON: json):
        // Decode the action JSON typed in the devtools "Dispatcher" tab and dispatch
        // it as a real AppAction. Independent of time travel — works even when
        // restoreStateAction is nil. The decoded action is recorded on the next cycle.
        guard let decode = deserializeAction else { return .doNothing }
        return .produce { _ in
            Effect.task { decode(json) }
        }

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
    restoreStateAction: (@Sendable (AppState) -> AppAction)? = nil,
    deserializeState: (@Sendable (String) -> AppState?)? = nil,
    serialize: @escaping @Sendable (AppAction, AppState?) -> (action: String, state: String)
        = { action, state in
            (MirrorJSON.encode(action), state.map { MirrorJSON.encode($0 as Any) } ?? "{}")
        }
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    DevToolsBehavior.timeMachineBehavior(
        extractDevToolsAction: extractDevToolsAction,
        restoreStateAction: restoreStateAction,
        encodeAction: { serialize($0, nil).action },
        encodeState:  { state in serialize(AppAction?.none as! AppAction, state).state },
        deserializeState: deserializeState
    )
}
