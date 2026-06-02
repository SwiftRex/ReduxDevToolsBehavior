import FP
import Foundation
import SwiftRex
import SwiftRexConcurrency

/// Creates a behavior that forwards every dispatched `AppAction` and the resulting
/// `AppState` to the connected remotedev-server.
///
/// This is the "observation" half of the Redux DevTools integration. Pair it with
/// ``DevToolsBehavior`` which handles the connection lifecycle and commands.
///
/// ## Type parameters
///
/// - `AppAction`: Your app's full action type (no conformance required).
/// - `AppState`:  Your app's full state type (no conformance required).
///
/// Both are serialized using ``MirrorJSON`` by default — no `Encodable` needed.
/// Supply a custom `serialize` closure for types where reflection output is
/// unsuitable (e.g. types with computed properties you want to hide).
///
/// ## Usage
///
/// ```swift
/// // Zero-config: Mirror-based serialization
/// let recorder = makeDevToolsRecorder(instanceId: "my-app")
///
/// // Custom serialization
/// let recorder = makeDevToolsRecorder(
///     instanceId: "my-app",
///     serialize: { action, state in
///         (MirrorJSON.encode(action), (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
///     }
/// )
///
/// // Wire into the app behavior
/// let appBehavior = Behavior.combine(
///     featureBehavior.lift(...),
///     #if DEBUG
///     DevToolsBehavior.behavior.lift(action: ..., state: ..., environment: ...),
///     recorder.liftEnvironment(\AppEnvironment.devTools),
///     #endif
/// )
/// ```
///
/// - Parameters:
///   - instanceId:  Unique identifier shown in the devtools instance list.
///   - instanceName: Human-readable label in the devtools panel. Defaults to `instanceId`.
///   - serialize: Converts `(AppAction, AppState?)` to `(actionJSON, stateJSON)`.
///                Defaults to ``MirrorJSON`` reflection.
/// - Returns: `Behavior<AppAction, AppState, DevToolsEnvironment>` — lift the environment
///            to your app environment before combining.
public func makeDevToolsRecorder<AppAction: Sendable, AppState: Sendable>(
    instanceId: String,
    instanceName: String? = nil,
    serialize: @escaping @Sendable (AppAction, AppState?) -> (action: String, state: String)
        = { action, state in
            (MirrorJSON.encode(action), state.map { MirrorJSON.encode($0 as Any) } ?? "{}")
        }
) -> Behavior<AppAction, AppState, DevToolsEnvironment> {
    let name = instanceName ?? instanceId

    return Behavior { action, _ in
        // Capture serialized action in phase 1 (@MainActor, before mutation)
        let actionJSON = serialize(action, nil).action

        return .produce { ctx in
            Effect.task {
                let manager = ctx.environment.connectionManager
                guard await manager.isConnected else { return nil }

                // Read post-mutation state (requires @MainActor hop)
                let stateAfter = await ctx.stateAfter
                let (_, stateJSON) = serialize(action, stateAfter)

                // Send INIT exactly once per connection (tracked by the actor)
                if await manager.checkAndMarkInitSent() {
                    let initMsg = RemoteDevOutbound.`init`(
                        state: stateJSON,
                        instanceId: instanceId,
                        name: name
                    )
                    _ = await manager.send(SocketIO.emit("log", initMsg.toJSON()))
                }

                // Send ACTION for this dispatch cycle
                let actionMsg = RemoteDevOutbound.action(
                    action: actionJSON,
                    state: stateJSON,
                    instanceId: instanceId
                )
                _ = await manager.send(SocketIO.emit("log", actionMsg.toJSON()))

                return nil  // recorder never dispatches back into the store
            }
        }
    }
}
