import Foundation

/// Minimal Socket.io v4 / Engine.io v4 framing for talking to a `remotedev-server`.
///
/// ## Protocol overview
///
/// Socket.io v4 sits on top of Engine.io v4 which itself sits on top of WebSocket:
///
/// ```
/// WebSocket frame (text)
///   └─ Engine.io packet  ("4" = MESSAGE)
///         └─ Socket.io packet  ("2" = EVENT)
///               └─ ["event_name", {...}]   JSON array
/// ```
///
/// Relevant packet types:
///
/// | Wire prefix | Meaning                         | Direction       |
/// |-------------|----------------------------------|-----------------|
/// | `0{...}`    | Engine.io OPEN — session info    | Server → Client |
/// | `2`         | Engine.io PING                   | Server → Client |
/// | `3`         | Engine.io PONG                   | Client → Server |
/// | `40`        | Socket.io CONNECT (namespace /)  | Client → Server |
/// | `40{...}`   | Socket.io CONNECT ACK            | Server → Client |
/// | `42[...]`   | Socket.io EVENT                  | Both            |
///
/// ## Handshake
///
/// 1. Server sends `0{"sid":"...","pingInterval":25000,"pingTimeout":5000}`
/// 2. Client sends `40` → Socket.io connects to default namespace
/// 3. Server sends `40{"sid":"..."}` → connection confirmed
/// 4. Server sends `2` (PING) every `pingInterval` ms; client must reply `3` (PONG)
///
/// ## Event emission
///
/// To emit event `"log"` with JSON payload `{...}`:
///
/// ```
/// 42["log",{...}]
/// ```
///
/// ## Event reception
///
/// Incoming text frames that start with `42` carry Socket.io events.
/// Parse the JSON array: `["event_name", payload]`.
enum SocketIO {
    // MARK: - Outbound

    /// Engine.io PONG — sent in response to every `2` (PING) from the server.
    static let pong = "3"

    /// Socket.io CONNECT to the default namespace `/` — sent immediately after the
    /// Engine.io handshake (`0{...}`) is received.
    static let connect = "40"

    /// Encodes a Socket.io event as a text frame.
    ///
    /// ```swift
    /// SocketIO.emit("log", "{\"type\":\"INIT\",\"payload\":\"{}\"}")
    /// // → 42["log",{"type":"INIT","payload":"{}"}]
    /// ```
    static func emit(_ event: String, _ jsonPayload: String) -> String {
        "42[\"\(event)\",\(jsonPayload)]"
    }

    // MARK: - Inbound

    enum Packet {
        /// Engine.io OPEN — contains session info JSON.
        case open(sid: String, pingInterval: Int, pingTimeout: Int)
        /// Engine.io PING — caller should respond with ``pong``.
        case ping
        /// Socket.io CONNECT ACK — namespace connected.
        case connected
        /// Socket.io EVENT — `(eventName, payloadJSON)`.
        case event(name: String, payload: String)
        /// Anything else — logged and discarded.
        case unknown(String)
    }

    /// Parses an incoming text frame into a ``Packet``.
    static func parse(_ text: String) -> Packet {
        // Engine.io OPEN
        if text.hasPrefix("0"), let json = String(text.dropFirst()).nonEmpty {
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let sid = obj["sid"] as? String ?? ""
                let interval = obj["pingInterval"] as? Int ?? 25_000
                let timeout  = obj["pingTimeout"]  as? Int ?? 5_000
                return .open(sid: sid, pingInterval: interval, pingTimeout: timeout)
            }
            return .unknown(text)
        }

        // Engine.io PING
        if text == "2" { return .ping }

        // Socket.io CONNECT ACK
        if text.hasPrefix("40") { return .connected }

        // Socket.io EVENT
        if text.hasPrefix("42"), let body = String(text.dropFirst(2)).nonEmpty {
            if let data = body.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let name = array.first as? String {
                let payload: String
                if array.count > 1 {
                    let payloadData = (try? JSONSerialization.data(withJSONObject: array[1])) ?? Data()
                    payload = String(data: payloadData, encoding: .utf8) ?? "{}"
                } else {
                    payload = "{}"
                }
                return .event(name: name, payload: payload)
            }
        }

        return .unknown(text)
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
