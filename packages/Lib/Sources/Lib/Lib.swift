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

public func isJSONObjectOrArray(_ string: String) -> Bool {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{" || trimmed.first == "[" else { return false }
    guard let data = trimmed.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data, options: [])
    else { return false }
    return value is [String: Any] || value is [Any]
}

public func prettifyJSON(_ jsonString: String) -> String? {
    guard let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let prettyData = try? JSONSerialization.data(
              withJSONObject: object,
              options: [.prettyPrinted]
          ),
          let pretty = String(data: prettyData, encoding: .utf8)
    else {
        return nil
    }
    return pretty
}
