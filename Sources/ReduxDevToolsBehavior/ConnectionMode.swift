import Foundation

/// Configures how and when the devtools connection is initiated.
///
/// Set `connectionMode` on ``DevToolsEnvironment`` and then dispatch
/// ``DevToolsAction/activate`` once at app launch (e.g. from `@main` or your root
/// `Scene`). ``DevToolsBehavior/socketBehavior`` reads the mode from the environment
/// and starts the appropriate connection flow.
///
/// ```swift
/// // In your @main or scene delegate, after the store is ready:
/// store.dispatch(.devTools(.activate))
/// ```
///
/// ## Choosing a mode
///
/// | Mode | Who connects | Works with | Recommended for |
/// |---|---|---|---|
/// | `.manual` | App, explicitly | All | Full control, e.g. a debug settings screen |
/// | `.connectOnLaunch` | App → server | remotedev-server | Fixed CI/lab networks |
/// | `.browseOnLaunch` | App → server | remotedev-server | Developer's local machine |
/// | `.advertiseAcceptAll` | Server → app | Native Swift devtools only | Best developer UX (Phase 3) |
/// | `.advertise` | Server → app | Native Swift devtools only | Controlled pairing (Phase 3) |
///
/// ## Topology
///
/// ### Phase 1 modes (`.connectOnLaunch`, `.browseOnLaunch`)
///
/// ```
/// Phone ──WebSocket──▶ remotedev-server ◀── Redux DevTools panel
///                       (port 8000, relay)
/// ```
///
/// The phone acts as a **client** that connects to the relay server.
/// Both the phone and the Redux DevTools panel connect to the same server.
///
/// ### Phase 3 modes (`.advertiseAcceptAll`, `.advertise`)
///
/// ```
/// Phone ◀──WebSocket── native Swift devtools
/// (NWListener + Bonjour advertise)   (NWBrowser + connect)
/// ```
///
/// The phone acts as a **server**. The devtools browses Bonjour, finds the phone,
/// and connects directly — no relay server needed. This is the ideal developer UX
/// because no server setup is required and the connection happens automatically.
///
/// **Not yet implemented.** See roadmap in the README.
public enum ConnectionMode: Sendable {

    // MARK: - Phase 1 (phone connects to remotedev-server)

    /// No automatic connection.
    ///
    /// Dispatch ``DevToolsAction/connect(host:port:)`` or
    /// ``DevToolsAction/startBrowsing`` manually — e.g. from a debug settings screen.
    /// ``DevToolsAction/activate`` is a no-op in this mode.
    case manual

    /// Connects to a fixed `host:port` immediately when ``DevToolsAction/activate``
    /// is dispatched.
    ///
    /// Use this in CI environments or when the remotedev-server address is stable:
    ///
    /// ```swift
    /// devTools: .live(connectionMode: .connectOnLaunch(host: "192.168.1.100", port: 8000))
    /// ```
    case connectOnLaunch(host: String, port: UInt16)

    /// Starts Bonjour browsing immediately when ``DevToolsAction/activate`` is dispatched.
    ///
    /// ``DevToolsState/discoveredServices`` fills automatically as servers are found.
    /// Dispatch ``DevToolsAction/connectToService(_:)`` when the user selects one,
    /// or ``DevToolsAction/connect(host:port:)`` after resolving manually.
    ///
    /// ```swift
    /// devTools: .live(connectionMode: .browseOnLaunch(serviceType: "_reduxdevtools._tcp."))
    /// ```
    case browseOnLaunch(serviceType: String)

    // MARK: - Phase 3 (phone is the server, native Swift devtools required)

    /// Phone advertises itself via Bonjour and accepts **all** inbound connections.
    ///
    /// The native Swift devtools browses Bonjour, finds the phone, and connects
    /// automatically — no IP configuration, no relay server.
    ///
    /// - Important: **Not yet implemented.** Requires the native Swift devtools app
    ///   (Phase 3). Not compatible with the existing Electron `remotedev-server`.
    case advertiseAcceptAll(serviceType: String, serviceName: String?)

    /// Phone advertises itself and uses an ``AcceptPolicy`` to decide whether to
    /// accept each inbound connection.
    ///
    /// - Important: **Not yet implemented.** Requires the native Swift devtools app
    ///   (Phase 3). Not compatible with the existing Electron `remotedev-server`.
    case advertise(serviceType: String, serviceName: String?, accept: AcceptPolicy)
}

// MARK: - Acceptance policy (Phase 3)

/// Controls which inbound connections the phone accepts in ``ConnectionMode/advertise``
/// and ``ConnectionMode/advertiseAcceptAll``.
public enum AcceptPolicy: Sendable {
    /// Accept every inbound connection without user confirmation.
    case all
    // Future: case prompt — shows an OS alert asking the user to confirm
    // Future: case custom(@Sendable (RemoteConnectionInfo) -> Bool)
}

// MARK: - Convenience defaults

extension ConnectionMode {
    /// Browses for `"_reduxdevtools._tcp."` — the default remotedev-server Bonjour type.
    public static var browseOnLaunch: ConnectionMode {
        .browseOnLaunch(serviceType: "_reduxdevtools._tcp.")
    }

    /// Advertises as `"_reduxdevtools._tcp."` with the device name and accepts all. (Phase 3)
    public static var advertiseAcceptAll: ConnectionMode {
        .advertiseAcceptAll(serviceType: "_reduxdevtools._tcp.", serviceName: nil)
    }
}
