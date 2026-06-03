import Foundation

/// Minimal SocketCluster v20 framing for talking to `@redux-devtools/cli`.
///
/// ## Protocol overview
///
/// SocketCluster v20 runs plain JSON messages over WebSocket:
///
/// ```
/// WebSocket frame (text)
///   └─ JSON object
///         ├─ Request  (client→server, expects ack): {"event":"…","data":…,"cid":N}
///         ├─ Response (server→client, acks request): {"rid":N,"data":…}
///         ├─ Transmit (fire-and-forget): {"event":"…","data":…}
///         └─ Ping: "" (empty string) — client replies with ""
/// ```
///
/// ## Handshake
///
/// 1. Client → `{"event":"#handshake","data":{"authToken":null},"cid":1}`
/// 2. Server → `{"rid":1,"data":{"id":"SOCKET_ID","pingTimeout":20000,…}}`
/// 3. Client → `{"event":"#subscribe","data":{"channel":"sc-SOCKET_ID"},"cid":2}`
///
/// ## Sending actions to devtools
///
/// Transmit to the `log-noid` channel — the server adds the socket ID and
/// re-publishes to `log`, which the devtools panel subscribes to:
///
/// ```
/// {"event":"#publish","data":{"channel":"log-noid","data":{…}}}
/// ```
///
/// ## Receiving commands from devtools
///
/// Devtools sends time-travel commands directly to the per-socket channel:
///
/// ```
/// {"event":"#publish","data":{"channel":"sc-SOCKET_ID","data":{"type":"DISPATCH","action":{…}}}}
/// ```
enum SocketCluster {
    // MARK: - Outbound

    static let pong = ""

    static func handshake(cid: Int) -> String {
        "{\"event\":\"#handshake\",\"data\":{\"authToken\":null},\"cid\":\(cid)}"
    }

    static func subscribe(channel: String, cid: Int) -> String {
        "{\"event\":\"#subscribe\",\"data\":{\"channel\":\"\(channel)\"},\"cid\":\(cid)}"
    }

    static func publish(channel: String, jsonPayload: String) -> String {
        "{\"event\":\"#publish\",\"data\":{\"channel\":\"\(channel)\",\"data\":\(jsonPayload)}}"
    }

    // MARK: - Inbound

    enum Packet {
        /// Server→client ping — caller should respond with ``pong``.
        case ping
        /// Ack for a client request (handshake, subscribe, etc.).
        case handshakeAck(socketId: String, pingTimeout: Int)
        /// A message published to a channel the client subscribed to.
        case publish(channel: String, payload: String)
        /// Any other frame — logged and discarded.
        case unknown(String)
    }

    static func parse(_ text: String) -> Packet {
        if text == "" { return .ping }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown(text) }

        // Response to a request (handshake ack, subscribe ack, …)
        if let rid = json["rid"] as? Int, rid == 1,
           let dataDict = json["data"] as? [String: Any],
           let socketId = dataDict["id"] as? String,
           let pingTimeout = dataDict["pingTimeout"] as? Int {
            return .handshakeAck(socketId: socketId, pingTimeout: pingTimeout)
        }

        // Incoming publish
        if let event = json["event"] as? String, event == "#publish",
           let dataDict = json["data"] as? [String: Any],
           let channel = dataDict["channel"] as? String {
            let payload: String
            if let payloadObj = dataDict["data"],
               let payloadData = try? JSONSerialization.data(withJSONObject: payloadObj),
               let payloadStr = String(data: payloadData, encoding: .utf8) {
                payload = payloadStr
            } else {
                payload = "{}"
            }
            return .publish(channel: channel, payload: payload)
        }

        return .unknown(text)
    }
}
