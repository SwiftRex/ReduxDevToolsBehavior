# ReduxDevToolsBehavior

Connects a [SwiftRex](https://github.com/SwiftRex/SwiftRex) app to the
[Redux DevTools](https://github.com/reduxjs/redux-devtools) standalone Electron app
(or any compatible `remotedev-server`) for action monitoring, state inspection,
and time-travel debugging.

```
iOS/macOS app  ──WebSocket──▶  remotedev-server  ◀──  Redux DevTools panel
                               (port 8000)              (Electron / browser)
```

Every dispatched action is forwarded in real time. The devtools panel shows the full
action log, a state diff before and after each action, and lets you jump to any point
in history.

---

## Requirements

- iOS 16 / macOS 13 / tvOS 16 / watchOS 9
- Swift 6.2
- SwiftRex (main branch)
- A running `remotedev-server` on your Mac (or any machine on the same network):
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

// AppAction — add a devTools case
enum AppAction: Sendable {
    case counter(CounterAction)
    case settings(SettingsAction)
    #if DEBUG
    case devTools(DevToolsAction)
    #endif
}

// AppState — add a devTools sub-state
struct AppState: Sendable {
    var counter: CounterState
    var settings: SettingsState
    #if DEBUG
    var devTools: DevToolsState = .initial
    #endif
}

// AppEnvironment — add the devTools environment
struct AppEnvironment: Sendable {
    var counter: CounterEnvironment
    var settings: SettingsEnvironment
    #if DEBUG
    var devTools: DevToolsEnvironment = .live()
    #endif
}
```

### 2. Add the behavior

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
    DevToolsBehavior.behaviors(
        action: AppAction.prism.devTools,
        state: \AppState.devTools,
        environment: \AppEnvironment.devTools
    ),
    #endif
)
```

### 3. Connect

```swift
// Hardcode an IP (useful for CI / known networks)
store.dispatch(.devTools(.connect(host: "192.168.1.100", port: 8000)))

// Or browse the local network for a remotedev-server automatically
store.dispatch(.devTools(.startBrowsing))
```

---

## Architecture

`DevToolsBehavior.behaviors(action:state:environment:)` composes two behaviors internally:

### `DevToolsBehavior.socketBehavior`

`Behavior<DevToolsAction, DevToolsState, DevToolsEnvironment>`

Manages the WebSocket connection lifecycle. When `.connect` is dispatched it starts a
single long-running effect that:

1. Opens the WebSocket.
2. Performs the Engine.io v4 + Socket.io v4 handshake.
3. Emits `._connected` once confirmed.
4. Drives the receive loop — sends PONG for server PINGs, routes `DISPATCH` events from
   the devtools panel back into the store (`JUMP_TO_ACTION`, `TOGGLE_ACTION`, `RESET`, etc.).
5. Emits `._connectionLost` when the server closes the connection.

The effect is scheduled with `.replacing(id: "devtools-connection")` — re-connecting
automatically cancels any previous session.

### `DevToolsBehavior.timeMachineBehavior`

`Behavior<AppAction, AppState, DevToolsEnvironment>`

Observes **every** dispatched `AppAction`. For each one it:

1. Encodes the action and post-mutation state to JSON using `env.encodeAction` /
   `env.encodeState` (see [Serialization](#serialization)).
2. Stores the state JSON in a **bounded ring buffer** inside `DevToolsConnectionManager`
   (max 200 entries by default — see [Memory model](#memory-model)).
3. Sends `INIT` on the first action after a connection is established, then `ACTION`
   for every subsequent cycle.

When the devtools panel requests time travel (`JUMP_TO_ACTION`, `TOGGLE_ACTION`,
`IMPORT_STATE`), the time machine behavior retrieves the stored JSON at the target index,
decodes it via `env.decodeState`, and dispatches `restoreStateAction(decoded)`.

---

## Serialization

Configuration lives entirely in `DevToolsEnvironment`, not in the behavior call site.

### `AppState: Codable` — zero config

```swift
// Automatically uses JSONEncoder for encoding and JSONDecoder for time travel
var devTools: DevToolsEnvironment = .live(for: AppState.self)
```

| Direction | What happens |
|---|---|
| Send to devtools | `JSONEncoder` (via `encodeState` closure) |
| Receive / time travel | `JSONDecoder` (via `decodeState` closure) |

### No `Codable` — MirrorJSON fallback

```swift
// MirrorJSON uses Swift Mirror to encode any value to JSON without Encodable
var devTools: DevToolsEnvironment = .live()
```

`MirrorJSON` automatically uses `JSONEncoder` for any value that happens to conform to
`Encodable`, and falls back to `Mirror` reflection for everything else. Time travel is
disabled (no `decodeState`).

```swift
MirrorJSON.encode(AppAction.increment)               // → "\"increment\""
MirrorJSON.encode(AppAction.setText("hi"))           // → "{\"setText\":\"hi\"}"
MirrorJSON.encode(AppAction.load(id: 1, force: false)) // → "{\"load\":{\"id\":1,\"force\":false}}"
```

### Custom encoding

Pass closures to `DevToolsEnvironment.live(encodeAction:encodeState:decodeState:)`:

```swift
let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase

var devTools: DevToolsEnvironment = .live(
    for: AppState.self,        // auto-wires decodeState
    instanceId: "com.myapp",
    encodeAction: { action in
        (try? encoder.encode(action as! Encodable))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? MirrorJSON.encode(action)
    }
)
```

Or provide full control:

```swift
var devTools: DevToolsEnvironment = .live(
    instanceId: "com.myapp",
    encodeAction: { action in /* ... */ },
    encodeState: { state in /* ... */ },
    decodeState: { json in /* ... */ }
)
```

---

## Time travel

Time travel requires:
1. `env.decodeState` — decodes state JSON back to `AppState` (auto-wired by `.live(for:)`)
2. `restoreStateAction` — an `AppAction` that replaces the live state
3. `extractDevToolsAction` — lets the time machine intercept devtools commands

### Wiring for `AppState: Codable`

```swift
// AppAction — add a restore case
enum AppAction: Sendable {
    // ...
    #if DEBUG
    case devTools(DevToolsAction)
    case restoreState(AppState)      // dispatched during time travel
    #endif
}

// Handle it in your Behavior or Reducer:
case .restoreState(let snapshot):
    state = snapshot
```

```swift
// Environment — auto-wires JSONDecoder
#if DEBUG
var devTools: DevToolsEnvironment = .live(for: AppState.self)
#endif

// Behavior — add extractDevToolsAction + restoreStateAction
#if DEBUG
DevToolsBehavior.behaviors(
    action: AppAction.prism.devTools,
    state: \AppState.devTools,
    environment: \AppEnvironment.devTools,
    extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
    restoreStateAction: { .restoreState($0) }
)
#endif
```

### Wiring without `Codable`

Provide `decodeState` manually in the environment and `restoreStateAction` in the behavior:

```swift
var devTools: DevToolsEnvironment = .live(
    instanceId: "my-app",
    decodeState: { json in myCustomDecode(json) }   // returns AppState?
)

DevToolsBehavior.behaviors(
    action: AppAction.prism.devTools,
    state: \AppState.devTools,
    environment: \AppEnvironment.devTools,
    extractDevToolsAction: { if case .devTools(let dt) = $0 { return dt }; return nil },
    restoreStateAction: { .restoreState($0) }
)
```

### TOGGLE_ACTION

The devtools panel can skip / re-enable individual actions. Since SwiftRex doesn't expose
the reducer to external code, toggling approximates full re-computation:

- **Skip action N** → restore the nearest non-skipped state before N.
- **Un-skip action N** → restore state N directly.

This is accurate for most debugging sessions. The only deviation from exact re-computation
is that actions after a toggled one are not re-run — they remain as originally computed.

### IMPORT_STATE

When the devtools panel imports a full `liftedState` blob, the ring buffer and skip set
are replaced. If `decodeState` is available, the state at `currentStateIndex` is restored.

---

## Memory model

State history is stored as **JSON strings**, not as live `AppState` objects, in a bounded
ring buffer inside `DevToolsConnectionManager`. The canonical full history lives in the
devtools panel on the Mac (abundant RAM); the iOS device keeps only a recent window.

| Setting | Default | Configure via |
|---|---|---|
| Max ring buffer size | 200 entries | `.live(maxHistorySize: N)` |

When the buffer is full the oldest entry is evicted. `JUMP_TO_ACTION` for evicted indices
is silently ignored (the devtools panel still shows them, but restoration is unavailable).

Typical memory usage: 200 entries × ~5 KB average state JSON ≈ **1 MB**.

---

## Bonjour discovery

```swift
// Start browsing
store.dispatch(.devTools(.startBrowsing))

// DevToolsState.discoveredServices fills with DiscoveredService values.
// Present them in a picker; on selection:
store.dispatch(.devTools(.stopBrowsing))

let resolved = try await env.resolveService(selectedService).run().get()
store.dispatch(.devTools(.connect(
    host: resolved.preferredHost ?? "",
    port: resolved.port ?? 8000
)))
```

The default Bonjour service type is `"_reduxdevtools._tcp."`. Override it:

```swift
var devTools: DevToolsEnvironment = .live(bonjourServiceType: "_myapp._tcp.")
```

---

## `DevToolsEnvironment.live()` reference

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `instanceId` | `String` | bundle identifier | Key in the devtools instance list |
| `instanceName` | `String?` | `nil` → uses `instanceId` | Label in the devtools panel |
| `maxHistorySize` | `Int` | `200` | Ring buffer cap on the iOS device |
| `bonjourServiceType` | `String` | `"_reduxdevtools._tcp."` | Bonjour service type for browsing |
| `encodeAction` | `(Any) -> String` | `MirrorJSON.encode` | Serializes `AppAction` to JSON |
| `encodeState` | `(Any?) -> String` | `MirrorJSON` | Serializes `AppState?` to JSON |
| `decodeState` | `((String) -> Any?)?` | `nil` | Decodes JSON → `AppState`; enables time travel |
| `urlSession` | `URLSession` | `.shared` | Session for WebSocket connections |

**`live(for: AppState.self)` overload** — when `AppState: Codable`, sets `encodeState` to
`JSONEncoder` and `decodeState` to `JSONDecoder` automatically. Accepts all parameters above
except `encodeState` and `decodeState` (they are pre-wired).

---

## `DevToolsState` reference

| Property | Type | Default |
|---|---|---|
| `connectionStatus` | `.disconnected` / `.connecting` / `.connected(host:port:)` | `.disconnected` |
| `discoveredServices` | `[DiscoveredService]` | `[]` |
| `isBrowsing` | `Bool` | `false` |
| `stateHistory` | `[String]` — JSON, one per step (from `IMPORT_STATE`) | `[]` |
| `actionHistory` | `[String]` — JSON, one per step | `[]` |
| `skippedActionIds` | `Set<Int>` — actions toggled off in devtools | `[]` |
| `currentActionIndex` | `Int?` — active time-travel position; `nil` = live | `nil` |
| `isPaused` | `Bool` — recording paused from devtools panel | `false` |
| `isLocked` | `Bool` — state changes locked from devtools panel | `false` |

---

## `DevToolsAction` reference

| Case | Dispatched by | Purpose |
|---|---|---|
| `.connect(host:port:)` | App / UI | Open connection to remotedev-server |
| `.startBrowsing` | App / UI | Browse Bonjour for servers |
| `.stopBrowsing` | App / UI | Stop Bonjour browsing |
| `.disconnect` | App / UI | Close connection |
| `._connected(host:port:)` | Effect | Handshake completed |
| `._connectionFailed(Error)` | Effect | Connection attempt failed |
| `._connectionLost(Error?)` | Effect | Established connection closed |
| `._serviceFound / _serviceRemoved` | Effect | Bonjour discovery events |
| `._received(RemoteDevCommand)` | Effect | Raw command from devtools |
| `.jumpToAction(Int)` | Surfaced command | Time-travel to action at index |
| `.jumpToState(Int)` | Surfaced command | Time-travel to state at index |
| `.toggleAction(Int)` | Surfaced command | Skip / re-enable action |
| `.reset` | Surfaced command | Clear history, restore initial state |
| `.commit` | Surfaced command | Set current state as new baseline |
| `.rollback` | Surfaced command | Pop to previous checkpoint |
| `.importState(ImportedLiftedState)` | Surfaced command | Replace full history from devtools |
| `.pause / .resume` | Surfaced command | Pause / resume recording |
| `.lockChanges / .unlockChanges` | Surfaced command | Lock / unlock state changes |

Cases prefixed with `_` are internal — do not dispatch them from application code.

---

## Protocol

`ReduxDevToolsBehavior` speaks **Socket.io v4 over WebSocket**, compatible with
`remotedev-server` out of the box.

**Outbound** (app → devtools):
```
42["log",{"type":"INIT","payload":"<stateJSON>","instanceId":"...","name":"..."}]
42["log",{"type":"ACTION","action":"<actionJSON>","payload":"<stateJSON>","instanceId":"..."}]
```

**Inbound** (devtools → app):
```
42["dispatch",{"type":"JUMP_TO_ACTION","actionId":5}]
42["dispatch",{"type":"TOGGLE_ACTION","id":3}]
42["dispatch",{"type":"RESET"}]
42["dispatch",{"type":"IMPORT_STATE","nextLiftedState":{...}}]
```

Engine.io ping/pong (`2` / `3`) is handled transparently.

---

## Roadmap

- [x] Phase 1 — action monitoring, connection lifecycle, Bonjour discovery
- [x] Phase 2 — time travel (`JUMP_TO_ACTION`, `JUMP_TO_STATE`) via JSON ring buffer
- [x] Phase 2 — `TOGGLE_ACTION` with nearest-snapshot approximation
- [x] Phase 2 — `IMPORT_STATE` full history import
- [x] Phase 2 — `PAUSE_RECORDING` / `LOCK_CHANGES`
- [x] Phase 2 — automatic `JSONEncoder`/`JSONDecoder` for `AppState: Codable`
- [x] Phase 2 — bounded ring buffer (memory-efficient on iOS)
- [ ] Phase 3 — Native Swift devtools app (replaces Electron `remotedev-server`)
- [ ] Phase 3 — Linux support via NIO WebSocket backend
