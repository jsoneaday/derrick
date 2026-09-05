import Foundation

/// Host ↔ guest JSON. Codable is the default. Dictionary graphs are sanitized so
/// Swift `Optional.none` becomes JSON `null` (not a Cocoa encode crash).
public enum JSONWire: Sendable {
    public static func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func data(jsonObject: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: sanitize(jsonObject), options: [.sortedKeys])
    }

    /// Unwraps Optionals recursively. `.none` → `NSNull()` so `"error": null` means success.
    public static func sanitize(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return sanitize(child.value)
        }
        if let object = value as? [String: Any] {
            return object.mapValues { sanitize($0) }
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0) }
        }
        return value
    }
}
