import Foundation

/// Invoke result that asks the UI to open a factory session.
public enum PluginHookPresentation: Sendable {
    public static let wirePrefix = "derrick.plugin_hook\n"

    public struct OpenFactory: Codable, Sendable, Hashable {
        public var kind: String
        public var sessionID: String
        public var title: String
        public var instructionPluginID: String
        public var reusePluginID: String?
        public var goal: String

        public init(
            sessionID: String,
            title: String,
            instructionPluginID: String,
            reusePluginID: String? = nil,
            goal: String = ""
        ) {
            self.kind = DerrickPluginHook.openFactorySession.rawValue
            self.sessionID = sessionID
            self.title = title
            self.instructionPluginID = instructionPluginID
            self.reusePluginID = reusePluginID
            self.goal = goal
        }
    }

    public static func encodeOpenFactory(_ payload: OpenFactory) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return wirePrefix + "{}"
        }
        return wirePrefix + json
    }

    public static func decodeOpenFactory(_ raw: String) -> OpenFactory? {
        guard raw.hasPrefix(wirePrefix) else { return nil }
        let json = String(raw.dropFirst(wirePrefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenFactory.self, from: data)
    }
}
