import Core
import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

// MARK: - DevTools command handling

/// Handles a `DevToolsAction` intercepted by `timeMachineBehavior` before regular recording.
///
/// Serialization is done via `ctx.environment.jsonDecoder` — no captured closures.
/// `AppState` and `AppAction` are decoded with `String.jsonDecode(as:using:)`, which
/// uses the `_JSONDecodable` protocol dispatch and returns `nil` when the type is not
/// `Decodable` at runtime (time travel / Dispatcher tab silently no-ops).
func handleDevToolsCommand<AppAction: Sendable, AppState: Sendable>(
    _ command: DevToolsAction,
    wrapDevToolsAction: (@Sendable (DevToolsAction) -> AppAction)?,
    pendingRestore: PendingRestore<AppState>
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {

    switch command {

    case let .jumpToAction(index), let .jumpToState(index):
        return .produce { ctx in
            Effect.task {
                guard let json = await ctx.environment.connectionManager.stateJSON(at: index),
                      let state = json.jsonDecode(as: AppState.self, using: ctx.environment.decoderFactory),
                      let wrap  = wrapDevToolsAction
                else { return nil }
                pendingRestore.set(state)
                return wrap(._triggerRestore)
            }
        }

    case let .toggleAction(id):
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let isNowSkipped = await mgr.toggleSkipped(id)
                let targetIndex  = isNowSkipped ? max(0, id - 1) : id
                let base         = await mgr.historyBaseIndex
                let idx          = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? base
                guard let json = await mgr.stateJSON(at: idx),
                      let state = json.jsonDecode(as: AppState.self, using: ctx.environment.decoderFactory),
                      let wrap  = wrapDevToolsAction
                else { return nil }
                pendingRestore.set(state)
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
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                await mgr.setSkippedActionIds(lifted.skippedActionIds)
                let base = await mgr.historyBaseIndex
                let idx  = await mgr.latestNonSkippedIndex(upTo: lifted.currentStateIndex) ?? base
                guard let json = await mgr.stateJSON(at: idx),
                      let state = json.jsonDecode(as: AppState.self, using: ctx.environment.decoderFactory),
                      let wrap  = wrapDevToolsAction
                else { return nil }
                pendingRestore.set(state)
                return wrap(._triggerRestore)
            }
        }

    case let .dispatchAction(actionJSON: json):
        return .produce { ctx in
            Effect.task { json.jsonDecode(as: AppAction.self, using: ctx.environment.decoderFactory) }
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

/// - Important: Deprecated. Use ``DevToolsBehavior/behaviors(action:state:environment:)`` instead.
@available(*, deprecated, message: "Use DevToolsBehavior.behaviors(action:state:environment:) — serialization is now handled via DevToolsEnvironment.jsonEncoder/jsonDecoder.")
public func makeDevToolsRecorder<AppAction: Sendable, AppState: Sendable>(
    instanceId: String,
    instanceName: String? = nil,
    extractDevToolsAction: @escaping @Sendable (AppAction) -> DevToolsAction? = { _ in nil }
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    DevToolsBehavior.timeMachineBehavior(extractDevToolsAction: extractDevToolsAction)
}
