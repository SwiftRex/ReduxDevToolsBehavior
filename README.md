# ReduxDevToolsBehavior

Connects a [SwiftRex](https://github.com/SwiftRex/SwiftRex) app to the
[Redux DevTools](https://github.com/reduxjs/redux-devtools) standalone Electron app
(or any compatible `remotedev-server`) for action monitoring, state inspection,
and time-travel debugging.

```
iOS/macOS app  ──WebSocket──▶  remotedev-server  ◀──  Redux DevTools panel
                               (port 8000)              (Electron / browser)
```

Every action dispatched in your SwiftRex store is forwarded in real time to the
devtools panel, which shows the action log, a diff of the state before and after,
and lets you jump to any point in history.

---

## Requirements

- iOS 16 / macOS 13 / tvOS 16 / watchOS 9
- Swift 6.2
- SwiftRex (main branch)
- [remotedev-server](https://github.com/zalmoxisus/remotedev-server) running on your
  Mac (or any machine on the same network):
  ```
  npx @redux-devtools/cli --hostname=0.0.0.0 --port=8000
  ```
  Then open the [Redux DevTools standalone app](https://github.com/reduxjs/redux-devtools/releases).

---

## Installation

```swift
// Package.swift
.package(url: "https://github.com/SwiftRex/ReduxDevToolsBehavior.git", branch: "master"),

// Target dependency
.product(name: "ReduxDevToolsBehavior", package: "ReduxDevToolsBehavior"),
```

---

## Quick start

### 1. Extend your app types

```swift
import ReduxDevToolsBehavior

// AppAction
enum AppAction: Sendable {
    case counter(CounterAction)
    case settings(SettingsAction)
    #if DEBUG
    case devTools(DevToolsAction)
    #endif
}

// AppState
struct AppState: Sendable {
    var counter: CounterState
    var settings: SettingsState
    #if DEBUG
    var devTools: DevToolsState = .initial
    #endif
}

// AppEnvironment
struct AppEnvironment: Sendable {
    var counter: CounterEnvironment
    var settings: SettingsEnvironment
    #if DEBUG
    var devTools: DevToolsEnvironment = .live()
    #endif
}
```

### 2. Add the behaviors

```swift
import ReduxDevToolsBehavior

let appBehavior = Behavior.combine(
    counterBehavior.lift(
        action: AppAction.prism.counter,
        state: \AppState.counter,
        environment: \AppEnvironment.counter
    ),
    settingsBehavior.lift(
        action: AppAction.prism.settings,
        state: \AppState.settings,
        environment: \AppEnvironment.settings
    ),
    #if DEBUG
    // Manages the connection lifecycle + routes devtools commands
    DevToolsBehavior.behavior.lift(
        action: AppAction.prism.devTools,
        state: \AppState.devTools,
        environment: \AppEnvironment.devTools
    ),
    // Observes every AppAction and forwards it to the devtools panel
    makeDevToolsRecorder(instanceId: Bundle.main.bundleIdentifier ?? "app")
        .liftEnvironment(\AppEnvironment.devTools),
    #endif
)
```

### 3. Connect

```swift
// From a debug settings screen, on launch, or triggered by a shake gesture:
store.dispatch(.devTools(.connect(host: "192.168.1.100", port: 8000)))

// Or browse the local network automatically:
store.dispatch(.devTools(.startBrowsing))
```

---

## Architecture

Two behaviors work together:

### `DevToolsBehavior`

`Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment>`

Manages the connection lifecycle. When `.connect(host:port:)` is dispatched it
starts a **single long-running effect** that:

1. Opens a WebSocket to the remotedev-server.
2. Performs the Engine.io v4 + Socket.io v4 handshake (`0{...}` OPEN → `40` CONNECT → `40{...}` ACK).
3. Emits `._connected` once the handshake completes.
4. Drives the receive loop indefinitely — responds to PING frames inline (sends PONG)
   and routes `DISPATCH` events from the devtools panel back into the store as
   `DevToolsAction._received(RemoteDevCommand)`.
5. Emits `._connectionLost` and stops when the server closes the connection.

The whole stream is scheduled with `.replacing(id: "devtools-connection")` so
re-connecting cancels any previous session automatically.

### `makeDevToolsRecorder`

`Behavior<AppAction, AppState, DevToolsEnvironment>`

Observes **every** dispatched `AppAction`. For each one it:

1. Reads the serialized action description in phase 1 (`@MainActor`, pre-mutation).
2. In phase 3, reads the post-mutation state and serializes it.
3. On the first action after a connection is established, sends an `INIT` message
   (reports the current state and registers the app instance in the devtools panel).
4. For every subsequent action, sends an `ACTION` message.

Serialization uses `MirrorJSON` by default — no `Encodable` conformance needed.

---

## Serialization

### Default: `MirrorJSON` (zero-config)

`MirrorJSON` uses Swift's `Mirror` API to encode any value to JSON without
requiring `Encodable`:

```swift
enum AppAction {
    case increment
    case setText(String)
    case loadUser(id: Int, force: Bool)
}

MirrorJSON.encode(AppAction.increment)
// → "\"increment\""

MirrorJSON.encode(AppAction.setText("hello"))
// → "{\"setText\":\"hello\"}"

MirrorJSON.encode(AppAction.loadUser(id: 1, force: false))
// → "{\"loadUser\":{\"id\":1,\"force\":false}}"
```

Types that conform to `Encodable` use `JSONEncoder` for the highest-fidelity output.

### Custom serializer

Supply a `serialize` closure when `MirrorJSON` output is unsuitable — for example,
when you want snake_case keys or want to hide internal properties:

```swift
makeDevToolsRecorder(
    instanceId: "my-app",
    instanceName: "My App",
    serialize: { action, state in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let actionJSON = (try? encoder.encode(action as! Encodable))
            .flatMap { String(data: $0, encoding: .utf8) } ?? MirrorJSON.encode(action)
        let stateJSON  = state.flatMap { s in
            (try? encoder.encode(s as! Encodable)).flatMap { String(data: $0, encoding: .utf8) }
        } ?? "{}"

        return (actionJSON, stateJSON)
    }
)
```

---

## Bonjour discovery

If `remotedev-server` is advertising via Bonjour (service type `_reduxdevtools._tcp.`),
you can browse for it automatically instead of hardcoding an IP:

```swift
// Dispatch to start browsing
store.dispatch(.devTools(.startBrowsing))

// DevToolsState.discoveredServices will fill with DiscoveredService values.
// The app can present them in a picker; when the user selects one:
store.dispatch(.devTools(.stopBrowsing))

// Resolve the selected service to get host + port, then connect:
let env = store.environment.devTools
let resolved = try await env.resolveService(selectedService).run().get()
if let url = resolved.webSocketURL() {
    store.dispatch(.devTools(.connect(host: resolved.preferredHost ?? "", port: resolved.port ?? 8000)))
}
```

The default Bonjour service type searched is `"_reduxdevtools._tcp."`. Override it in
`DevToolsEnvironment.live(bonjourServiceType:)` if your server advertises a different type.

---

## Handling devtools commands in your reducer

Time-travel and other devtools commands surface as `DevToolsAction` values that
the **app's reducer** must handle. `DevToolsBehavior` deliberately does not modify
`AppState` — only `DevToolsState`.

### JUMP_TO_ACTION (time travel)

`DevToolsBehavior` stores a JSON snapshot of the state after each action in
`DevToolsState.stateHistory`. When the devtools panel requests time travel:

```swift
// In your AppAction reducer / Behavior:
case .devTools(.jumpToAction(let index)):
    // Restore the state snapshot from the devtools history
    guard index < state.devTools.stateHistory.count else { break }
    let json = state.devTools.stateHistory[index]
    if let data = json.data(using: .utf8),
       let snapshot = try? JSONDecoder().decode(AppState.self, from: data) {
        state = snapshot
    }
```

> **Note:** This requires `AppState: Decodable`. If you use `MirrorJSON` for
> serialization, the snapshot JSON may not be perfectly round-trip decodable —
> in that case, provide a custom serializer that uses `JSONEncoder`/`JSONDecoder`.

### RESET

```swift
case .devTools(.reset):
    state = AppState.initial  // reset to your known initial state
```

### COMMIT / ROLLBACK

These only affect `DevToolsState.stateHistory` (handled by `DevToolsBehavior`)
and do not require any changes in the app reducer.

---

## `DevToolsEnvironment`

| Property | Type | Purpose |
|---|---|---|
| `connectionManager` | `DevToolsConnectionManager` (actor) | Shared connection holder; used by both `DevToolsBehavior` and `makeDevToolsRecorder` |
| `openConnection` | `(String, UInt16) -> DeferredTask<Result<WebSocketConnection, Error>>` | Opens a WebSocket and performs Socket.io handshake |
| `browseServices` | `(String) -> DeferredStream<Result<DiscoveredServiceEvent, Error>>` | Browses the local network via Bonjour |
| `resolveService` | `(DiscoveredService) -> DeferredTask<Result<ResolvedService, Error>>` | Resolves a service name to host + port |

All types are platform-agnostic: `WebSocketConnection`, `DiscoveredService`, and
`ResolvedService` carry no Apple-specific framework types. The live implementation
(backed by `URLSessionWebSocketTask` and `NWBrowser` from
[NetworkTools](https://github.com/luizmb/NetworkTools)) is provided by
`DevToolsEnvironment.live()` and is conditionally compiled with `#if canImport(Darwin)`.

---

## `DevToolsState`

| Property | Type | Default |
|---|---|---|
| `connectionStatus` | `ConnectionStatus` (`.disconnected` / `.connecting` / `.connected(host:port:)`) | `.disconnected` |
| `discoveredServices` | `[DiscoveredService]` | `[]` |
| `isBrowsing` | `Bool` | `false` |
| `stateHistory` | `[String]` (JSON snapshots, one per action) | `[]` |
| `actionHistory` | `[String]` (JSON descriptions, one per action) | `[]` |

---

## `DevToolsAction`

| Case | Dispatched by | Purpose |
|---|---|---|
| `.connect(host:port:)` | App / UI | Open connection to remotedev-server |
| `.startBrowsing` | App / UI | Browse Bonjour for servers |
| `.stopBrowsing` | App / UI | Stop Bonjour browsing |
| `.disconnect` | App / UI | Close connection |
| `._connected(host:port:)` | Effect | Handshake completed |
| `._connectionFailed(Error)` | Effect | Connection attempt failed |
| `._connectionLost(Error?)` | Effect | Established connection closed |
| `._serviceFound(DiscoveredService)` | Effect | Bonjour service appeared |
| `._serviceRemoved(DiscoveredService)` | Effect | Bonjour service disappeared |
| `._received(RemoteDevCommand)` | Effect | Command received from devtools |
| `.jumpToAction(Int)` | Surfaced command | Time-travel to action at index |
| `.toggleAction(Int)` | Surfaced command | Skip / re-enable action at index |
| `.reset` | Surfaced command | Reset state history |
| `.commit` | Surfaced command | Set current state as new baseline |
| `.rollback` | Surfaced command | Pop to previous checkpoint |

Cases prefixed with `_` are dispatched by the behavior's own effects and are not
intended to be dispatched by application code.

---

## Protocol

`ReduxDevToolsBehavior` speaks **Socket.io v4 over WebSocket**, compatible with
`remotedev-server` out of the box.

Wire format (outbound):
```
42["log",{"type":"INIT","payload":"<stateJSON>","instanceId":"...","name":"..."}]
42["log",{"type":"ACTION","action":"<actionJSON>","payload":"<stateJSON>","instanceId":"..."}]
```

Wire format (inbound from devtools panel):
```
42["dispatch",{"type":"JUMP_TO_ACTION","actionId":5}]
42["dispatch",{"type":"RESET"}]
42["dispatch",{"type":"COMMIT"}]
```

Engine.io ping/pong frames (`2` / `3`) are handled transparently.

---

## Roadmap

- [x] Phase 1 — monitoring, connection lifecycle, devtools commands surfaced to app
- [ ] Phase 2 — `TOGGLE_ACTION` implementation (skip/re-enable)
- [ ] Phase 2 — `IMPORT_STATE` full state override
- [ ] Phase 2 — Native Swift devtools app (replaces Electron `remotedev-server`)
- [ ] Phase 2 — Linux support via NIO WebSocket backend
