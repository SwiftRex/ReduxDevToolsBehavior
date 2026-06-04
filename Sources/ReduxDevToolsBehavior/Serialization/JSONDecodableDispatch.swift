import Foundation

/// Private protocol that enables calling `JSONDecoder.decode` on an existential
/// `any (Decodable & Sendable).Type` without type erasure.
///
/// Because `JSONDecoder.decode<T: Decodable>(_ type:from:)` is a generic method,
/// it cannot be called with an existential argument directly. This protocol provides
/// a static requirement that the default extension wires to the concrete `Self.self`,
/// allowing the behavior (which is generic over `AppState: Sendable`) to decode at
/// runtime when `AppState` happens to be `Decodable`.
protocol _JSONDecodable {
    static func _decode(from data: Data, using decoder: JSONDecoder) -> Self?
}

extension Decodable {
    static func _decode(from data: Data, using decoder: JSONDecoder) -> Self? {
        try? decoder.decode(Self.self, from: data)
    }
}

extension String {
    /// Attempts to decode `self` as JSON into `T` using the decoder.
    /// Returns `nil` if `T` is not `Decodable` at runtime or if decoding fails.
    func jsonDecode<T: Sendable>(as: T.Type, using decoder: JSONDecoder) -> T? {
        guard let helperType = T.self as? any _JSONDecodable.Type,
              let data = data(using: .utf8),
              let decoded = helperType._decode(from: data, using: decoder) else { return nil }
        return decoded as? T
    }
}
