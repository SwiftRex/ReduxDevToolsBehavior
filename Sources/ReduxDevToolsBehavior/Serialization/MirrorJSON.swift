import Foundation

/// Reflection-based JSON encoder that works on any Swift value without requiring `Encodable`.
///
/// `MirrorJSON` uses `Mirror` to walk a value's structure at runtime. It handles:
/// - Primitives: `Bool`, `Int` family, `Float`/`Double`, `String`, `nil`
/// - Collections: `Array`, `Dictionary`, `Set`
/// - Optionals: unwrapped transparently; `nil` → `null`
/// - Enums: case name (no payload) → `"caseName"`;
///          single associated value → the value itself;
///          labeled associated values → `{ "label": value, ... }`
/// - Structs and classes: `{ "property": value, ... }`
/// - `Encodable` types: encoded via `JSONEncoder` for maximum fidelity
///
/// This is the zero-constraint fallback used by ``DevToolsRecorder``. For types
/// where the Mirror output is unsuitable, supply a custom `serialize` closure to
/// ``makeDevToolsRecorder(serialize:)``.
///
/// ## Example
///
/// ```swift
/// enum AppAction {
///     case increment
///     case setText(String)
///     case loadUser(id: Int, force: Bool)
/// }
///
/// MirrorJSON.encode(AppAction.increment)               // → "\"increment\""
/// MirrorJSON.encode(AppAction.setText("hello"))        // → "\"hello\""
/// MirrorJSON.encode(AppAction.loadUser(id: 1, force: false))
/// // → "{\"id\":1,\"force\":false}"
/// ```
public enum MirrorJSON {
    /// Encodes `value` to a compact JSON string using Mirror reflection.
    /// Always succeeds — falls back to `"\"\(value)\""` for unrepresentable types.
    public static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: toJSONObject(value)),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return string
    }

    // MARK: - Action description for Redux DevTools

    /// Produces a Redux-DevTools-friendly action description by walking the enum
    /// hierarchy using runtime type names. Types whose name contains `"Action"` are
    /// treated as part of the action path; the first non-Action associated value
    /// becomes the payload.
    ///
    /// Example: `AppAction.navigation(.push(.reportInput))`
    /// → type `".navigation(.push)"`, payload `"reportInput"`
    static func actionDescription(_ value: Any) -> (type: String, payloadJSON: String) {
        let (path, payload) = buildActionPath(value)
        let typeName = formatActionPath(path, index: 0)
        let payloadJSON = payload.map { encode($0) } ?? "{}"
        return (typeName, payloadJSON)
    }

    private static func buildActionPath(_ value: Any) -> ([String], Any?) {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum else { return ([], value) }
        let typeName = String(describing: type(of: value))
        guard typeName.contains("Action") else { return ([], value) }
        guard let child = mirror.children.first else {
            return (["\(value)"], nil)           // no-payload action case
        }
        let caseName = child.label ?? "\(value)"
        let (subPath, subPayload) = buildActionPath(child.value)
        if !subPath.isEmpty { return ([caseName] + subPath, subPayload) }
        return ([caseName], child.value)
    }

    private static func formatActionPath(_ path: [String], index: Int) -> String {
        guard index < path.count else { return "" }
        let seg = ".\(path[index])"
        guard index < path.count - 1 else { return seg }
        return "\(seg)(\(formatActionPath(path, index: index + 1)))"
    }

    // MARK: - Internal

    static func toJSONObject(_ value: Any) -> Any {
        // Encodable fast path — highest fidelity
        if let encodable = value as? any Encodable {
            if let obj = try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode(encodable)
            ) {
                // Simplify {"caseName": {}} → "caseName" for no-payload Codable enum cases
                // so e.g. AppRoute.reportInput encodes as "reportInput" not {"reportInput":{}}
                let mirror = Mirror(reflecting: value)
                if mirror.displayStyle == .enum,
                   let dict = obj as? [String: Any], dict.count == 1,
                   let key = dict.keys.first,
                   let nested = dict[key] as? [String: Any], nested.isEmpty {
                    return key
                }
                return obj
            }
        }

        // Nil / Optional
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return toJSONObject(child.value)
            }
            return NSNull()
        }

        // Primitives
        switch value {
        case let b as Bool:   return b
        case let i as Int:    return i
        case let i as Int8:   return i
        case let i as Int16:  return i
        case let i as Int32:  return i
        case let i as Int64:  return i
        case let i as UInt:   return i
        case let i as UInt8:  return i
        case let i as UInt16: return i
        case let i as UInt32: return i
        case let i as UInt64: return i
        case let f as Float:  return Double(f)
        case let d as Double: return d
        case let s as String: return s
        default: break
        }

        switch mirror.displayStyle {
        case .enum:
            guard let child = mirror.children.first else {
                // Case with no payload → just the case name as a string
                return "\(value)"
            }
            let caseName = child.label ?? "\(value)"
            let payload = child.value
            let payloadMirror = Mirror(reflecting: payload)

            if payloadMirror.displayStyle == .tuple {
                let children = Array(payloadMirror.children)
                // All labels present → object; otherwise array/single value
                if children.allSatisfy({ $0.label != nil && !($0.label!.starts(with: ".")) }) {
                    var dict: [String: Any] = [:]
                    for c in children { dict[c.label!] = toJSONObject(c.value) }
                    return [caseName: dict]
                } else if children.count == 1 {
                    return [caseName: toJSONObject(children[0].value)]
                } else {
                    return [caseName: children.map { toJSONObject($0.value) }]
                }
            }
            return [caseName: toJSONObject(payload)]

        case .struct, .class:
            var dict: [String: Any] = [:]
            for child in mirror.children {
                if let label = child.label {
                    dict[label] = toJSONObject(child.value)
                }
            }
            return dict

        case .collection, .set:
            return mirror.children.map { toJSONObject($0.value) }

        case .dictionary:
            var dict: [String: Any] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value)
                let children = Array(pair.children)
                if children.count == 2 {
                    let key = "\(toJSONObject(children[0].value))"
                    dict[key] = toJSONObject(children[1].value)
                }
            }
            return dict

        case .tuple:
            let children = Array(mirror.children)
            if children.allSatisfy({ $0.label != nil && !($0.label!.starts(with: ".")) }) {
                var dict: [String: Any] = [:]
                for c in children { dict[c.label!] = toJSONObject(c.value) }
                return dict
            }
            return children.map { toJSONObject($0.value) }

        default:
            return "\(value)"
        }
    }
}
