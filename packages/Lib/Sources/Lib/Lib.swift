import Foundation
import MCP

public func toolArgumentsFromJSON(_ json: String) throws -> [String: Value] {
    guard let data = json.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj.mapValues { jsonToToolValue($0) }
}

public func jsonToToolValue(_ obj: Any) -> Value {
    if let str = obj as? String {
        return .string(str)
    } else if let num = obj as? NSNumber {
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
            return .bool(num.boolValue)
        } else if num.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
            return .int(num.intValue)
        } else {
            return .double(num.doubleValue)
        }
    } else if let bool = obj as? Bool {
        return .bool(bool)
    } else if let arr = obj as? [Any] {
        return .array(arr.map { jsonToToolValue($0) })
    } else if let dict = obj as? [String: Any] {
        return .object(dict.mapValues { jsonToToolValue($0) })
    }
    return .null
}
