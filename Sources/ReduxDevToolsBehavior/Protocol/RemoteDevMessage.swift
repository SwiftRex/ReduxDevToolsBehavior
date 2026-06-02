import Foundation

/// Messages sent FROM the iOS app TO the remotedev-server.
///
/// All messages are emitted as Socket.io `"log"` events with a JSON body.
enum RemoteDevOutbound {
    /// Sent once when the connection is established — reports the initial state and
    /// registers the app as a named instance in the devtools panel.
    ///
    /// Wire format:
    /// ```json
    /// { "type": "INIT", "payload": "<stateJSON>", "instanceId": "<id>", "name": "<name>" }
    /// ```
    case `init`(state: String, instanceId: String, name: String)

    /// Sent after each reducer cycle — reports the dispatched action and the resulting state.
    ///
    /// Wire format:
    /// ```json
    /// { "type": "ACTION", "action": "<actionJSON>", "payload": "<stateJSON>", "instanceId": "<id>" }
    /// ```
    case action(action: String, state: String, instanceId: String)

    func toJSON() -> String {
        switch self {
        case let .`init`(state, instanceId, name):
            let payload = encodeStringForJSON(state)
            return """
            {"type":"INIT","payload":\(payload),"instanceId":"\(instanceId)","name":"\(name)"}
            """
        case let .action(action, state, instanceId):
            let actionPayload = encodeStringForJSON(action)
            let statePayload  = encodeStringForJSON(state)
            return """
            {"type":"ACTION","action":\(actionPayload),"payload":\(statePayload),"instanceId":"\(instanceId)"}
            """
        }
    }

    /// Embeds `json` as a JSON string value — if it parses as a JSON fragment already,
    /// it is embedded as-is; otherwise it is double-encoded as a quoted string.
    private func encodeStringForJSON(_ json: String) -> String {
        if let data = json.data(using: .utf8),
           JSONSerialization.isValidJSONObject(json) ||
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return json
        }
        return "\"\(json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

// MARK: - Inbound

/// Commands sent FROM the remotedev-server (or devtools panel) TO the iOS app.
///
/// Received as Socket.io `"dispatch"` events.
public enum RemoteDevCommand: Sendable {
    /// Time-travel: replay all stored actions up to (and including) this index.
    case jumpToAction(Int)
    /// Toggle (skip/re-enable) a single action in the history.
    case toggleAction(Int)
    /// Reset the store to the initial state (clear all history).
    case reset
    /// Commit the current state as the new baseline and clear the history.
    case commit
    /// Roll back to the state before the last committed checkpoint.
    case rollback
    /// Import a lifted-state snapshot (full history override).
    case importState(String)
    /// Any unrecognised or future command type.
    case unknown(String)

    static func from(payloadJSON: String) -> RemoteDevCommand {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = obj["type"] as? String else {
            return .unknown(payloadJSON)
        }

        switch type_ {
        case "JUMP_TO_ACTION":
            let id = (obj["actionId"] as? Int) ?? (obj["index"] as? Int) ?? 0
            return .jumpToAction(id)
        case "TOGGLE_ACTION":
            let id = (obj["id"] as? Int) ?? 0
            return .toggleAction(id)
        case "RESET":     return .reset
        case "COMMIT":    return .commit
        case "ROLLBACK":  return .rollback
        case "IMPORT_STATE":
            let raw = (try? JSONSerialization.data(withJSONObject: obj["nextLiftedState"] ?? "{}"))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .importState(raw)
        default:
            return .unknown(payloadJSON)
        }
    }
}
