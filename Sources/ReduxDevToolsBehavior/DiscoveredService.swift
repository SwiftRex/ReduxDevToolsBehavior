import Foundation

/// A Bonjour service found on the local network, in a platform-agnostic form.
///
/// Used by ``DevToolsEnvironment/browseServices`` as a primitive type that
/// does not expose any Apple Network.framework types. On Apple platforms,
/// the live environment converts `BonjourBrowseEvent`/`BonjourServiceInfo`
/// into this type internally.
///
/// ```swift
/// for await result in environment.browseServices("_reduxdevtools._tcp.") {
///     if case .success(.found(let svc)) = result {
///         print("found:", svc.name)
///         let resolved = try await environment.resolveService(svc).run().get()
///         if let url = resolved.webSocketURL() { /* connect */ }
///     }
/// }
/// ```
public struct DiscoveredService: Sendable, Equatable, Codable {
    public let name: String
    public let type: String
    public let domain: String
    public let txt: [String: String]?

    public init(name: String, type: String, domain: String, txt: [String: String]? = nil) {
        self.name = name
        self.type = type
        self.domain = domain
        self.txt = txt
    }
}

/// A Bonjour service after its hostname and port have been resolved.
///
/// Produced by ``DevToolsEnvironment/resolveService``. The primary use is
/// building a WebSocket URL via ``webSocketURL(path:secure:)``.
public struct ResolvedService: Sendable, Equatable {
    public let name: String
    public let type: String
    public let domain: String
    public let host: String?
    public let ips: [String]
    public let port: UInt16?
    public let txt: [String: String]?

    public init(
        name: String,
        type: String,
        domain: String,
        host: String?,
        port: UInt16?,
        ips: [String] = [],
        txt: [String: String]? = nil
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.host = host
        self.port = port
        self.ips = ips
        self.txt = txt
    }

    /// The preferred connection host: first resolved IP, then hostname.
    public var preferredHost: String? { ips.first ?? host }

    /// Builds a WebSocket URL from the resolved host and port.
    ///
    /// ```swift
    /// resolved.webSocketURL()                    // ws://192.168.1.10:8000
    /// resolved.webSocketURL(path: "/", secure: false)
    /// ```
    public func webSocketURL(path: String = "", secure: Bool = false) -> URL? {
        guard let rawHost = preferredHost, let port else { return nil }
        let scheme = secure ? "wss" : "ws"
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        return URL(string: "\(scheme)://\(host):\(port)\(path)")
    }
}
