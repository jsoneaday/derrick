import Foundation

/// One host library element in a `ui.present` tree. `element` is a catalog id.
public struct HostUINode: Codable, Sendable, Hashable {
    public var element: String
    public var id: String?
    public var bind: String?
    public var config: [String: PluginJSON]?
    public var children: [HostUINode]?

    public init(
        element: String,
        id: String? = nil,
        bind: String? = nil,
        config: [String: PluginJSON]? = nil,
        children: [HostUINode]? = nil
    ) {
        self.element = element
        self.id = id
        self.bind = bind
        self.config = config
        self.children = children
    }

    public var configString: [String: String] {
        Dictionary(
            uniqueKeysWithValues: (config ?? [:]).compactMap { key, value in
                value.stringValue.map { (key, $0) }
            }
        )
    }

    public func contains(element id: String) -> Bool {
        if element == id { return true }
        return children?.contains { $0.contains(element: id) } == true
    }

    public func first(element id: String) -> HostUINode? {
        if element == id { return self }
        for child in children ?? [] {
            if let found = child.first(element: id) { return found }
        }
        return nil
    }

    /// `tab_strip` bound to conversations selects the first conversation. `selection=none` leaves none selected.
    public var opensFirstConversation: Bool {
        let selection = configString["selection"]
            ?? (contains(element: "tab_strip") ? "conversations" : "none")
        return selection == "conversations"
    }
}

public enum HostUILibraryError: Error, LocalizedError, Equatable, Sendable {
    case missingResource
    case invalidJSON
    case unknownElement(String)
    case missingRoot

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "Host UI library is missing."
        case .invalidJSON:
            return "Host UI library JSON is invalid."
        case .unknownElement(let id):
            return "Host UI library has no element named \(id)."
        case .missingRoot:
            return "ui.present must include a root from the host UI library."
        }
    }
}

/// Loads the bundled host UI catalog the plugin builder may request.
public enum HostUILibraryStore: Sendable {
    public static let resourceName = "host-ui-library.json"
    public static let messagingInboxExample = "messaging_inbox"

    public static func loadText() throws -> String {
        let data = try resourceData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostUILibraryError.invalidJSON
        }
        return text
    }

    public static func loadJSON() throws -> [String: Any] {
        try JSONSchema.object(from: try resourceData(), name: resourceName)
    }

    public static func validateBundledLibrary() throws {
        try GuestContract.validate(try loadJSON(), against: .hostUILibrary)
    }

    public static func elementIDs() throws -> Set<String> {
        let json = try loadJSON()
        guard let elements = json["elements"] as? [String: Any] else {
            throw HostUILibraryError.invalidJSON
        }
        return Set(elements.keys)
    }

    public static func example(named name: String) throws -> HostUINode {
        let json = try loadJSON()
        guard let examples = json["examples"] as? [String: Any],
              let raw = examples[name] else {
            throw HostUILibraryError.missingRoot
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(HostUINode.self, from: data)
    }

    public static func messagingInbox() throws -> HostUINode {
        try example(named: messagingInboxExample)
    }

    public static func validate(node: HostUINode) throws {
        let data = try JSONEncoder().encode(node)
        try GuestContract.validate(json: data, against: .hostUINode)
        let allowed = try elementIDs()
        try validateElements(node, allowed: allowed)
    }

    /// Reads `root` from a `ui.present` envelope payload.
    public static func node(fromPresentPayload payload: [String: PluginJSON]) throws -> HostUINode {
        guard let root = payload["root"] else {
            throw HostUILibraryError.missingRoot
        }
        let data = try JSONEncoder().encode(root)
        let node = try JSONDecoder().decode(HostUINode.self, from: data)
        try validate(node: node)
        return node
    }

    private static func validateElements(_ node: HostUINode, allowed: Set<String>) throws {
        guard allowed.contains(node.element) else {
            throw HostUILibraryError.unknownElement(node.element)
        }
        for child in node.children ?? [] {
            try validateElements(child, allowed: allowed)
        }
    }

    private static func resourceData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: nil,
            subdirectory: "contracts"
        ) else {
            throw HostUILibraryError.missingResource
        }
        return try Data(contentsOf: url)
    }
}

public enum HostUIPresentWake: Sendable {
    public static let darwinName = "derrick.hostUIPresent.didChange"
    public static let localNotificationName = Notification.Name("derrick.hostUIPresent.didChange")
    public static let pluginIDKey = "pluginID"
    private static let pendingFileName = "pending_host_ui_present.json"

    public static func postDarwin(pluginID: String) {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if let url = pendingFileURL(),
           let data = try? JSONEncoder().encode(["pluginID": id]) {
            try? data.write(to: url, options: .atomic)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName as CFString),
            nil,
            nil,
            true
        )
    }

    public static func takePendingPluginID() -> String? {
        guard let url = pendingFileURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let id = payload["pluginID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return id
    }

    public static func clearPending(pluginID: String) {
        let wanted = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty,
              let url = pendingFileURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              payload["pluginID"]?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func pendingFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(pendingFileName, isDirectory: false)
    }
}

/// Durable store for validated `ui.present` trees. Implementations typically write SQLite.
public protocol HostUIPresentPersisting: Sendable {
    func saveHostUIPresent(pluginID: String, root: HostUINode) async throws
    func loadHostUIPresent(pluginID: String) async throws -> HostUINode?
}

/// Last `ui.present` tree per plugin. Guest hops write; Chat tabs read.
/// Memory cache plus optional durable persister (DB) so trees survive restart.
public actor HostUIPresentStore {
    public static let shared = HostUIPresentStore()

    private var roots: [String: HostUINode] = [:]
    private var persister: (any HostUIPresentPersisting)?

    public init() {}

    public func configure(persister: (any HostUIPresentPersisting)?) {
        self.persister = persister
    }

    public func record(pluginID: String, root: HostUINode) async {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        roots[id] = root
        if let persister {
            try? await persister.saveHostUIPresent(pluginID: id, root: root)
        }
        let postedID = id
        HostUIPresentWake.postDarwin(pluginID: postedID)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: HostUIPresentWake.localNotificationName,
                object: nil,
                userInfo: [HostUIPresentWake.pluginIDKey: postedID]
            )
        }
    }

    public func root(pluginID: String) async -> HostUINode? {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if let cached = roots[id] {
            return cached
        }
        if let loaded = try? await persister?.loadHostUIPresent(pluginID: id) {
            roots[id] = loaded
            return loaded
        }
        return nil
    }

    public func clear(pluginID: String) {
        let id = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        roots.removeValue(forKey: id)
    }
}

public struct HostUIPresentHopHandler: PluginHopHandler {
    public let pluginID: String

    public init(pluginID: String) {
        self.pluginID = pluginID
    }

    public func handleUIPresent(payload: [String: PluginJSON]) async -> PluginHopEvent? {
        if let node = try? HostUILibraryStore.node(fromPresentPayload: payload) {
            await HostUIPresentStore.shared.record(pluginID: pluginID, root: node)
        }
        // script_exec may continue; plugin.invoke records the tree and finishes the hop.
        return PluginHopEvent(kind: .uiAction)
    }

    public func handleSecretRequest(payload: [String: PluginJSON]) async -> PluginHopEvent? {
        _ = payload
        return nil
    }
}
