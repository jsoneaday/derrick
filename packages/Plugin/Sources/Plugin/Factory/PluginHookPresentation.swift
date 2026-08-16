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
        guard let data = jsonData(in: raw) else { return nil }
        guard let payload = try? JSONDecoder().decode(OpenFactory.self, from: data) else { return nil }
        return payload.kind == DerrickPluginHook.openFactorySession.rawValue ? payload : nil
    }

    public struct OpenCreateWizard: Codable, Sendable, Hashable {
        public var kind: String
        public var instructionPluginID: String
        public var goal: String

        public init(instructionPluginID: String, goal: String = "") {
            self.kind = DerrickPluginHook.openCreateWizard.rawValue
            self.instructionPluginID = instructionPluginID
            self.goal = goal
        }
    }

    public static func encodeOpenCreateWizard(_ payload: OpenCreateWizard) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return wirePrefix + "{}"
        }
        return wirePrefix + json
    }

    public static func decodeOpenCreateWizard(_ raw: String) -> OpenCreateWizard? {
        guard let data = jsonData(in: raw) else { return nil }
        guard let payload = try? JSONDecoder().decode(OpenCreateWizard.self, from: data) else { return nil }
        return payload.kind == DerrickPluginHook.openCreateWizard.rawValue ? payload : nil
    }

    public static func isHookWire(_ raw: String) -> Bool {
        raw.hasPrefix(wirePrefix)
    }

    private static func jsonData(in raw: String) -> Data? {
        guard raw.hasPrefix(wirePrefix) else { return nil }
        return String(raw.dropFirst(wirePrefix.count)).data(using: .utf8)
    }
}
