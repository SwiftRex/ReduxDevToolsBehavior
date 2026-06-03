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
            // payload must be a JSON string (not an object) so the devtools can
            // JSON.parse each snapshot independently and compute state diffs.
            let payload = jsonStringLiteral(state)
            return """
            {"type":"INIT","payload":\(payload),"instanceId":"\(instanceId)","name":"\(name)"}
            """
        case let .action(action, state, instanceId):
            let actionPayload = normalizeAction(action)
            let statePayload  = jsonStringLiteral(state)
            return """
            {"type":"ACTION","action":\(actionPayload),"payload":\(statePayload),"instanceId":"\(instanceId)"}
            """
        }
    }

    /// Normalises an action JSON string into `{"type":"..."}` shape that Redux DevTools
    /// expects. MirrorJSON produces `"caseName"` for no-payload cases and
    /// `{"caseName": payload}` for associated-value cases — neither has a `type` key.
    /// Nested single-key objects are flattened into a slash-separated path, e.g.
    /// `{"calendar":{"selectDay":{...}}}` → `{"type":"calendar/selectDay","payload":{...}}`.
    private func normalizeAction(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return "{\"type\":\"\(json)\"}" }

        // Plain string (no-payload enum case) → {"type":"caseName"}
        if let str = try? JSONSerialization.jsonObject(with: data) as? String {
            return "{\"type\":\"\(str)\"}"
        }

        // Single-key object → flatten path, keep leaf as payload
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["type"] == nil {
            let (path, payload) = flattenPath(obj)
            var result: [String: Any] = ["type": path]
            if let p = payload { result["payload"] = p }
            if let d = try? JSONSerialization.data(withJSONObject: result),
               let s = String(data: d, encoding: .utf8) { return s }
        }

        return encodeStringForJSON(json)
    }

    /// Recursively flattens a chain of single-key dictionaries into a `/`-separated
    /// type path, returning the leaf value as the payload.
    /// `{"a":{"b":{"c":42}}}` → `("a/b/c", 42)`
    private func flattenPath(_ obj: [String: Any]) -> (String, Any?) {
        guard obj.count == 1, let key = obj.keys.first else {
            return (obj.keys.sorted().joined(separator: "/"), obj)
        }
        let value = obj[key]
        // No-payload nested enum case — string value is the sub-case name, not a payload
        if let str = value as? String {
            return ("\(key)/\(str)", nil)
        }
        // Single-key dict → recurse
        if let nested = value as? [String: Any], nested.count == 1 {
            let (subPath, payload) = flattenPath(nested)
            return ("\(key)/\(subPath)", payload)
        }
        return (key, value)
    }

    /// Always returns `json` as a JSON string literal (double-encoded).
    /// Required for `payload` so Redux DevTools JSON.parses each snapshot
    /// independently and can compute state diffs between them.
    /// Note: does NOT use JSONSerialization — passing a String to
    /// dataWithJSONObject raises an NSException that try? cannot catch.
    private func jsonStringLiteral(_ json: String) -> String {
        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Embeds `json` as a JSON value — if it already parses, embed as-is;
    /// otherwise double-encode as a quoted string.
    private func encodeStringForJSON(_ json: String) -> String {
        if let data = json.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return json
        }
        return jsonStringLiteral(json)
    }
}

// MARK: - Inbound

/// Commands sent FROM the remotedev-server (or devtools panel) TO the iOS app.
///
/// Received as Socket.io `"dispatch"` events.
public enum RemoteDevCommand: Sendable, Codable {
    // MARK: - Time travel

    /// Time-travel to the state produced by the action at `index`.
    case jumpToAction(Int)
    /// Jump directly to the pre-computed state at `index` (some devtools versions
    /// use this instead of, or in addition to, `JUMP_TO_ACTION`).
    case jumpToState(Int)
    /// Toggle (skip/re-enable) the action at `id` and re-evaluate.
    case toggleAction(Int)

    // MARK: - History management

    /// Reset the store to the initial state and clear all history.
    case reset
    /// Commit the current state as the new baseline and clear the history.
    case commit
    /// Roll back to the state before the last committed checkpoint.
    case rollback
    /// Import a full `liftedState` snapshot (replaces all history).
    case importState(String)

    // MARK: - Recording control

    /// Pause or resume recording new actions.
    case pauseRecording(Bool)
    /// Lock or unlock state changes (prevent the app from dispatching back).
    case lockChanges(Bool)

    // MARK: - Unknown

    /// An action dispatched from the devtools "Dispatcher" tab.
    /// `actionJSON` is the raw JSON string typed by the developer.
    case dispatchFromDevTools(actionJSON: String)

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
        case "JUMP_TO_STATE":
            let index = (obj["index"] as? Int) ?? 0
            return .jumpToState(index)
        case "TOGGLE_ACTION":
            let id = (obj["id"] as? Int) ?? 0
            return .toggleAction(id)
        case "RESET":    return .reset
        case "COMMIT":   return .commit
        case "ROLLBACK": return .rollback
        case "ACTION":
            // Dispatched from the devtools "Dispatcher" tab.
            // The action field may be a JSON string or an already-decoded object.
            let actionJSON: String
            if let raw = obj["action"] as? String {
                actionJSON = raw
            } else if let obj = obj["action"],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let str  = String(data: data, encoding: .utf8) {
                actionJSON = str
            } else {
                actionJSON = "{}"
            }
            return .dispatchFromDevTools(actionJSON: actionJSON)
        case "IMPORT_STATE":
            let raw = (try? JSONSerialization.data(withJSONObject: obj["nextLiftedState"] ?? "{}"))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .importState(raw)
        case "PAUSE_RECORDING":
            return .pauseRecording((obj["status"] as? Bool) ?? true)
        case "LOCK_CHANGES":
            return .lockChanges((obj["status"] as? Bool) ?? true)
        default:
            return .unknown(type_)
        }
    }
}

// MARK: - Imported lifted state

/// Parsed representation of the `nextLiftedState` payload from `IMPORT_STATE`.
public struct ImportedLiftedState: Sendable, Codable {
    /// JSON-encoded state strings, one per step (index 0 = initial state).
    public let computedStateJSONs: [String]
    /// Action IDs that were marked as skipped in the imported history.
    public let skippedActionIds: Set<Int>
    /// The step index to restore as the current state.
    public let currentStateIndex: Int
    public let isPaused: Bool
    public let isLocked: Bool

    /// Parses the raw JSON string from an `IMPORT_STATE` command.
    /// Returns `nil` if the JSON is malformed or missing required fields.
    static func from(json: String) -> ImportedLiftedState? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let computedStates = (obj["computedStates"] as? [[String: Any]]) ?? []
        let stateJSONs: [String] = computedStates.compactMap { entry in
            guard let stateObj = entry["state"] else { return nil }
            return (try? JSONSerialization.data(withJSONObject: stateObj))
                .flatMap { String(data: $0, encoding: .utf8) }
        }

        let skippedRaw = (obj["skippedActionIds"] as? [Int]) ?? []
        let currentIndex = (obj["currentStateIndex"] as? Int) ?? max(0, stateJSONs.count - 1)

        return ImportedLiftedState(
            computedStateJSONs: stateJSONs,
            skippedActionIds: Set(skippedRaw),
            currentStateIndex: min(currentIndex, max(0, stateJSONs.count - 1)),
            isPaused: (obj["isPaused"] as? Bool) ?? false,
            isLocked: (obj["isLocked"] as? Bool) ?? false
        )
    }
}
