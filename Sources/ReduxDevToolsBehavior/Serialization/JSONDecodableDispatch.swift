import Core
import Foundation

/// Private protocol enabling `DataDecoderFactory.dataDecoder(for:)` to be called
/// on an existential `any (Decodable & Sendable).Type` without knowing the concrete
/// type at the call site.
///
/// `DataDecoderFactory` produces typed `DataDecoder<Output>` converters, but the
/// generic parameter requires `Output: Decodable` at compile time. This protocol
/// provides a static requirement that the default extension wires to `Self.self`,
/// allowing the behavior (generic over `AppState: Sendable`) to decode at runtime
/// when `AppState` happens to be `Decodable`.
protocol _JSONDecodable {
    static func _decode(from data: Data, using factory: any DataDecoderFactory) -> Self?
}

extension Decodable {
    static func _decode(from data: Data, using factory: any DataDecoderFactory) -> Self? {
        try? factory.dataDecoder(for: Self.self).run(data).get()
    }
}

extension String {
    /// Attempts to decode `self` as JSON into `T` using the decoder factory.
    /// Returns `nil` when `T` is not `Decodable` at runtime or when decoding fails —
    /// time travel and the Dispatcher tab silently no-op for non-`Decodable` types.
    func jsonDecode<T: Sendable>(as type: T.Type, using factory: any DataDecoderFactory) -> T? {
        guard let helperType = T.self as? any _JSONDecodable.Type,
              let data = data(using: .utf8),
              let decoded = helperType._decode(from: data, using: factory) else { return nil }
        return decoded as? T
    }
}
