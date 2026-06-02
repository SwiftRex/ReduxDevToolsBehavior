import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

// MARK: - DevTools command handling (used by DevToolsBehavior.timeMachineBehavior)

/// Handles a `DevToolsAction` that was intercepted by the time machine behavior
/// before regular recording. Reads serialization config from `ctx.environment`.
func handleDevToolsCommand<AppAction: Sendable, AppState: Sendable>(
    _ command: DevToolsAction,
    restoreStateAction: (@Sendable (AppState) -> AppAction)?
) -> Consequence<AppState, DevToolsEnvironment, AppAction> {

    switch command {

    case let .jumpToAction(index), let .jumpToState(index):
        guard let restore = restoreStateAction else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let decode = ctx.environment.decodeState
                if let json = await mgr.stateJSON(at: index),
                   let state = decode?(json) as? AppState {
                    return restore(state)
                }
                return nil
            }
        }

    case let .toggleAction(id):
        guard let restore = restoreStateAction else { return .doNothing }
        return .produce { ctx in
            Effect.task {
                let mgr = ctx.environment.connectionManager
                let decode = ctx.environment.decodeState
                let isNowSkipped = await mgr.toggleSkipped(id)
                let targetIndex = isNowSkipped ? max(0, id - 1) : id
                let base = await mgr.historyBaseIndex
                let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: targetIndex) ?? base
                if let json = await mgr.stateJSON(at: resolvedIndex),
                   let state = decode?(json) as? AppState {
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
                let mgr    = ctx.environment.connectionManager
                let decode = ctx.environment.decodeState
                await mgr.replaceStateJSONs(lifted.computedStateJSONs)
                await mgr.setSkippedActionIds(lifted.skippedActionIds)

                guard let restore = restoreStateAction, let decode else { return nil }

                let base = await mgr.historyBaseIndex
                let resolvedIndex = await mgr.latestNonSkippedIndex(upTo: lifted.currentStateIndex) ?? base
                if let json = await mgr.stateJSON(at: resolvedIndex),
                   let state = decode(json) as? AppState {
                    return restore(state)
                }
                return nil
            }
        }

    case let .dispatchAction(actionJSON: json):
        // Decode the action JSON typed in the devtools "Dispatcher" tab and dispatch
        // it into the store as a real AppAction. Independent of time travel —
        // decodeAction works even when restoreStateAction is nil.
        // The decoded action flows through the store normally and is recorded on
        // the next cycle just like any other dispatched action.
        return .produce { ctx in
            Effect.task {
                ctx.environment.decodeAction?(json) as? AppAction
            }
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

// MARK: - Deprecated free function

/// - Important: Deprecated. Use ``DevToolsBehavior/behaviors(action:state:environment:extractDevToolsAction:restoreStateAction:)`` instead.
///   Configure `instanceId`, `encodeAction`, `encodeState`, and `decodeState` in
///   ``DevToolsEnvironment/live(_:instanceId:instanceName:maxHistorySize:bonjourServiceType:urlSession:)``
///   or ``DevToolsEnvironment/live(instanceId:instanceName:maxHistorySize:bonjourServiceType:encodeAction:encodeState:decodeState:urlSession:)``.
@available(*, deprecated, message: "Use DevToolsBehavior.behaviors(action:state:environment:) and configure serialization in DevToolsEnvironment.live()")
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
    // Bridge: patch the environment's serialization fields with the legacy parameters,
    // then delegate to the new timeMachineBehavior.
    DevToolsBehavior.timeMachineBehavior(
        extractDevToolsAction: extractDevToolsAction,
        restoreStateAction: restoreStateAction
    )
    // Note: instanceId and serialize are captured from the legacy call site but
    // the new behavior reads them from ctx.environment. Callers who want to customise
    // these should switch to .live(instanceId:encodeAction:encodeState:decodeState:).
}

/// Deprecated. See ``makeDevToolsRecorder(instanceId:instanceName:extractDevToolsAction:restoreStateAction:deserializeState:serialize:)``.
@available(*, deprecated, message: "Use DevToolsBehavior.behaviors(action:state:environment:) with DevToolsEnvironment.live(for: AppState.self)")
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
