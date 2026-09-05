import Foundation

public struct PluginUICard: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var title: String
    public var widgets: [PluginUIWidget]

    public init(schemaVersion: Int = PluginContract.uiSchemaVersion, title: String, widgets: [PluginUIWidget]) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.widgets = widgets
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case title, widgets
    }
}

public struct PluginUIWidget: Codable, Sendable, Hashable {
    public var type: PluginUIWidgetType
    public var id: String
    public var value: String?
    public var label: String?
    public var href: String?
    public var placeholder: String?
    public var secure: Bool?
    public var actionID: String?
    public var style: String?
    public var columns: [String]?
    public var rows: [[String]]?
    public var options: [PluginUISelectOption]?

    public init(
        type: PluginUIWidgetType,
        id: String,
        value: String? = nil,
        label: String? = nil,
        href: String? = nil,
        placeholder: String? = nil,
        secure: Bool? = nil,
        actionID: String? = nil,
        style: String? = nil,
        columns: [String]? = nil,
        rows: [[String]]? = nil,
        options: [PluginUISelectOption]? = nil
    ) {
        self.type = type
        self.id = id
        self.value = value
        self.label = label
        self.href = href
        self.placeholder = placeholder
        self.secure = secure
        self.actionID = actionID
        self.style = style
        self.columns = columns
        self.rows = rows
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case type, id, value, label, href, placeholder, secure, style, columns, rows, options
        case actionID = "action_id"
    }
}

public enum PluginUIWidgetType: String, Codable, Sendable, Hashable {
    case text
    case markdown
    case table
    case select
    case textField = "text_field"
    case link
    case button
}

public struct PluginUISelectOption: Codable, Sendable, Hashable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
