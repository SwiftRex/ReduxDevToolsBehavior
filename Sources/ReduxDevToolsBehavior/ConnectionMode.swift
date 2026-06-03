import Foundation

/// Configures how and when the devtools connection is initiated.
///
/// Set `connectionMode` on ``DevToolsEnvironment`` and dispatch
/// ``DevToolsAction/activate`` once at app launch:
///
/// ```swift
/// // Environment
/// devTools: .live(connectionMode: .autoConnect)
///
/// // App launch
/// store.dispatch(.devTools(.activate))
/// ```
///
/// All modes connect the phone **to** a running `remotedev-server` on the Mac.
/// The phone is always the WebSocket client; the devtools panel is never the initiator.
public enum ConnectionMode: Sendable {

    /// No automatic connection.
    ///
    /// Dispatch ``DevToolsAction/connect(host:port:)``, ``DevToolsAction/startBrowsing``,
    /// or ``DevToolsAction/connectToService(_:)`` manually — e.g. from a debug settings screen.
    /// ``DevToolsAction/activate`` is a no-op in this mode.
    case manual

    /// Connects to a fixed `host:port` immediately when ``DevToolsAction/activate``
    /// is dispatched.
    ///
    /// Use this when the remotedev-server address is stable (CI, lab network):
    ///
    /// ```swift
    /// devTools: .live(connectionMode: .connectOnLaunch(host: "192.168.1.100", port: 8000))
    /// ```
    case connectOnLaunch(host: String, port: UInt16)

    /// Browses via Bonjour and **automatically connects to the first server found**,
    /// then stops browsing.
    ///
    /// This is the recommended mode for day-to-day development: launch the app,
    /// and as soon as it discovers a running `remotedev-server` on the local network
    /// the connection is established with no further action from the developer.
    ///
    /// ```swift
    /// devTools: .live(connectionMode: .autoConnect)
    ///
    /// // At app launch:
    /// store.dispatch(.devTools(.activate))   // starts browsing; connects automatically
    /// ```
    ///
    /// If no server is found the behavior stays in browse mode until the user
    /// manually dispatches ``DevToolsAction/disconnect`` or the app is relaunched.
    case autoConnect(serviceType: String)

    /// Browses via Bonjour and fills ``DevToolsState/discoveredServices``, but does
    /// **not** connect automatically. The user must pick a service and dispatch
    /// ``DevToolsAction/connectToService(_:)``.
    ///
    /// Use this when multiple remotedev-servers may be running and you want
    /// explicit control over which one to connect to.
    ///
    /// ```swift
    /// devTools: .live(connectionMode: .browseOnLaunch)
    ///
    /// // At app launch:
    /// store.dispatch(.devTools(.activate))   // starts browsing
    ///
    /// // When the user picks a discovered service:
    /// store.dispatch(.devTools(.connectToService(selectedService)))
    /// ```
    case browseOnLaunch(serviceType: String)
}

// MARK: - Convenience defaults

extension ConnectionMode {
    /// ``autoConnect`` using the default `"_reduxdevtools._tcp."` service type.
    public static var autoConnect: ConnectionMode {
        .autoConnect(serviceType: "_reduxdevtools._tcp.")
    }

    /// ``browseOnLaunch`` using the default `"_reduxdevtools._tcp."` service type.
    public static var browseOnLaunch: ConnectionMode {
        .browseOnLaunch(serviceType: "_reduxdevtools._tcp.")
    }
}
