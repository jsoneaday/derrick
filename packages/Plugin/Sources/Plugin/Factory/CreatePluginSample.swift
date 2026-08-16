import Foundation
import ServiceContracts

/// System plugin: skill-only. Opens the create-plugin wizard via a granted before-hook.
public enum CreatePluginSample: Sendable {
    public static let pluginID = "create-plugin"
    public static let version = "1.0.0"
    public static let description = "Create or change a complementary plugin."

    public static var skillMarkdown: String {
        DerrickBundledText.mustLoad("create_plugin_skill.md")
    }

    public static var hooksJSON: String {
        PluginHookGrant.encodeList([PluginHookGrant(hook: .openCreateWizard)])
    }

    public static var skillsJSON: String {
        let object = [pluginID: skillMarkdown]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static var manifestJSON: String {
        let object: [String: Any] = [
            "$schema": PluginContract.agentPluginSchema,
            "name": pluginID,
            "version": version,
            "description": description,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static var runtimeJSON: String {
        #"{"hooks":["open_create_wizard"]}"#
    }

    public static func contentHash() -> PluginContentHash {
        PluginContentHash.hash(files: [
            "plugin.json": Data(manifestJSON.utf8),
            "skills/create-plugin/SKILL.md": Data(skillMarkdown.utf8),
        ])
    }
}
