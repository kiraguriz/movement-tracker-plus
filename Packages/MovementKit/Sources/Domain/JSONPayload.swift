import Foundation

/// UTF-8 JSON that Domain stores without interpreting: spec blobs, insight payloads, tool calls, setting values.
/// The owning module (MotionCore, CoachKit, the app) decides the shape.
public struct JSONPayload: Hashable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(json: String) {
        self.data = Data(json.utf8)
    }

    /// Encodes `value` with sorted keys so equal values give equal bytes (stable input hashes).
    public init<Value: Encodable>(encoding value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.data = try encoder.encode(value)
    }

    public var string: String {
        String(decoding: data, as: UTF8.self)
    }

    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    /// Cheap well-formedness check; fragments such as `true` or `"text"` are valid.
    public var isValidJSON: Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}
