import Core
import Foundation

extension String {
    /// Attempts to decode `self` as JSON into `T` using the decoder factory.
    /// Returns `nil` when `T` is not `Decodable` at runtime or when decoding fails —
    /// time travel and the Dispatcher tab silently no-op for non-`Decodable` types.
    ///
    /// Uses SE-0352 implicit existential opening: the inner `helper` function
    /// requires `D: Decodable & Sendable`; passing `any (Decodable & Sendable).Type`
    /// as its argument opens the existential and binds the concrete type, avoiding
    /// the "extension of protocol cannot have an inheritance clause" limitation of
    /// the earlier `_JSONDecodable` protocol approach.
    func jsonDecode<T: Sendable>(as type: T.Type, using factory: any DataDecoderFactory) -> T? {
        guard let data = data(using: .utf8),
              let concreteType = T.self as? any (Decodable & Sendable).Type else { return nil }

        func helper<D: Decodable & Sendable>(_ dt: D.Type) -> T? {
            (try? factory.dataDecoder(for: dt).run(data).get()) as? T
        }

        return helper(concreteType)
    }
}
