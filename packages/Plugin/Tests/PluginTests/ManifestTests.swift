import Foundation
import Testing
@testable import Plugin

@Test func pluginIDAcceptsAgentPluginNames() throws {
    _ = try PluginID("daily-news")
    _ = try PluginID("acme.tools")
    _ = try PluginID("a")
    _ = try PluginID("lint3r")
}

@Test func pluginIDRejectsInvalidNames() {
    #expect(throws: PluginManifestError.invalidName("My-Plugin")) {
        _ = try PluginID("My-Plugin")
    }
    #expect(throws: PluginManifestError.invalidName("-start")) {
        _ = try PluginID("-start")
    }
    #expect(throws: PluginManifestError.invalidName("has--double")) {
        _ = try PluginID("has--double")
    }
    #expect(throws: PluginManifestError.invalidName("too.many..dots")) {
        _ = try PluginID("too.many..dots")
    }
    #expect(throws: PluginManifestError.self) {
        _ = try PluginID("")
    }
}

@Test func pluginJSONDecodesClosedSchema() throws {
    let json = """
    {
      "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      "name": "daily-news",
      "version": "1.0.0",
      "description": "Headlines from one news host.",
      "extensions": {
        "app.derrick": {
          "entrypoint": "./app.derrick/plugin.js",
          "runtime": "./app.derrick/runtime.json"
        },
        "com.other.client": { "x": 1 }
      },
      "not_a_field": true
    }
    """
    let manifest = try AgentPluginManifest.decode(Data(json.utf8))
    #expect(manifest.name.rawValue == "daily-news")
    #expect(manifest.version == "1.0.0")
    #expect(manifest.derrick?.entrypoint == "./app.derrick/plugin.js")
    #expect(manifest.ignoredUnknownFields == ["not_a_field"])
    #expect(manifest.ignoredExtensionNamespaces == ["com.other.client"])
}

@Test func pluginJSONIgnoresNonObjectExtensions() throws {
    let json = """
    {
      "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      "name": "daily-news",
      "extensions": "nope"
    }
    """
    let manifest = try AgentPluginManifest.decode(Data(json.utf8))
    #expect(manifest.derrick == nil)
}

@Test func pluginJSONRejectsWrongSchemaAndTypes() {
    let missing = Data(#"{"name":"daily-news"}"#.utf8)
    #expect(throws: PluginManifestError.missingSchema) {
        _ = try AgentPluginManifest.decode(missing)
    }
    let badSchema = Data(#"{"$schema":"https://example/x","name":"daily-news"}"#.utf8)
    #expect(throws: PluginManifestError.unsupportedSchema("https://example/x")) {
        _ = try AgentPluginManifest.decode(badSchema)
    }
    let badVersion = Data(#"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"daily-news","version":1}"#.utf8)
    #expect(throws: PluginManifestError.invalidFieldType("version")) {
        _ = try AgentPluginManifest.decode(badVersion)
    }
    let extraAuthor = Data(#"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"daily-news","author":{"name":"A","twitter":"x"}}"#.utf8)
    #expect(throws: PluginManifestError.invalidAuthor) {
        _ = try AgentPluginManifest.decode(extraAuthor)
    }
}

@Test func derrickRuntimeNormalizesBareEntrypointAndValidates() throws {
    let json = """
    {
      "entrypoint": "plugin.js",
      "dependencies": { "example": "^1.0.0" },
      "triggers": [
        { "kind": "manual" },
        { "kind": "schedule", "interval_seconds": 3600 },
        { "kind": "message_in_room", "match": { "prefix": "/news" } }
      ],
      "auth_refs": [{ "name": "gmail", "provider": "google" }]
    }
    """
    let runtime = try PluginDecoding.decode(DerrickRuntime.self, from: Data(json.utf8))
    #expect(runtime.entrypoint == "./app.derrick/plugin.js")
    #expect(runtime.requiresLockfile)
    #expect(runtime.authRefs.first?.provider == "google")
    #expect(runtime.quotas.httpCallsPerInvoke == 20)
}

@Test func derrickRuntimeRejectsBadTriggersAndProviders() {
    let short = Data(#"{"entrypoint":"plugin.js","triggers":[{"kind":"schedule","interval_seconds":30}]}"#.utf8)
    #expect(throws: PluginManifestError.intervalTooShort(30)) {
        _ = try PluginDecoding.decode(DerrickRuntime.self, from: short)
    }
    let slash = Data(#"{"entrypoint":"plugin.js","triggers":[{"kind":"message_in_room","match":{"prefix":"/"}}]}"#.utf8)
    #expect(throws: PluginManifestError.invalidTriggerPrefix("/")) {
        _ = try PluginDecoding.decode(DerrickRuntime.self, from: slash)
    }
    let emptyPrefix = Data(#"{"entrypoint":"plugin.js","triggers":[{"kind":"message_in_room","match":{"prefix":""}}]}"#.utf8)
    #expect(throws: PluginManifestError.invalidTriggerPrefix("")) {
        _ = try PluginDecoding.decode(DerrickRuntime.self, from: emptyPrefix)
    }
    let unknown = Data(#"{"entrypoint":"plugin.js","auth_refs":[{"name":"x","provider":"slack"}]}"#.utf8)
    #expect(throws: PluginManifestError.unknownAuthProvider("slack")) {
        _ = try PluginDecoding.decode(DerrickRuntime.self, from: unknown)
    }
    let escape = Data(#"{"entrypoint":"./../evil.js"}"#.utf8)
    #expect(throws: PluginManifestError.pathEscapesRoot("./../evil.js")) {
        _ = try PluginDecoding.decode(DerrickRuntime.self, from: escape)
    }
}

@Test func pluginPathRejectsEscapeAndRequiresRelative() {
    #expect(throws: PluginManifestError.pathNotRelative("plugin.js")) {
        _ = try PluginPath.validateRelative("plugin.js")
    }
    #expect(throws: PluginManifestError.pathEscapesRoot("./foo/../../etc/passwd")) {
        _ = try PluginPath.validateRelative("./foo/../../etc/passwd")
    }
    #expect(throws: PluginManifestError.invalidEntrypoint("./app.derrick/plugin.ts")) {
        _ = try PluginPath.validateJSEntrypoint("./app.derrick/plugin.ts")
    }
}

@Test func authProviderNeverAttachesToTokenHosts() {
    #expect(PluginAuthRegistry.google.attachDecision(host: "gmail.googleapis.com") == .attach)
    #expect(PluginAuthRegistry.google.attachDecision(host: "oauth2.googleapis.com") == .denyTokenHost)
    #expect(PluginAuthRegistry.google.attachDecision(host: "evil.example") == .denyNotAttachHost)
    #expect(PluginAuthRegistry.lookup("GOOGLE")?.id == "google")
    #expect(PluginAuthRegistry.lookup("slack") == nil)

    let telegramURL = URL(string: "https://api.telegram.org/bot123:ABC/getMe")!
    #expect(PluginAuthRegistry.telegram.urlContainsEmbeddedToken(telegramURL))
    let clean = URL(string: "https://api.telegram.org/getMe")!
    #expect(!PluginAuthRegistry.telegram.urlContainsEmbeddedToken(clean))
}

@Test func contentHashIsDeterministicAndSensitive() {
    let a: [String: Data] = [
        "plugin.json": Data(#"{"name":"a"}"#.utf8),
        "app.derrick/plugin.js": Data("export function handle(){}" .utf8),
    ]
    let b = a.merging(["app.derrick/plugin.js": Data("export function handle(){ return []; }" .utf8)]) { _, n in n }
    let ha = PluginContentHash.hash(files: a)
    let hb = PluginContentHash.hash(files: a)
    let hc = PluginContentHash.hash(files: b)
    #expect(ha == hb)
    #expect(ha != hc)
    #expect(ha.rawValue.count == 64)
    #expect(ha.prefix8.count == 8)
    #expect(PluginContentHash.shouldHash(relativePath: "app.derrick/node_modules/x") == false)
}

@Test func packageLoadHandlePluginAndSkillsOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("derrick-plugin-pr1-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeHandlePlugin(at: root)
    let loaded = try PluginPackage.load(from: root)
    #expect(loaded.pluginID.rawValue == "daily-news")
    #expect(loaded.isHandlePlugin)
    #expect(loaded.runtime?.entrypoint == "./app.derrick/plugin.js")
    #expect(loaded.skills.count == 1)
    #expect(loaded.skills[0].name == "daily-news")
    #expect(loaded.skills[0].description == "Headlines from one news host.")
    #expect(loaded.contentHash.rawValue.count == 64)

    let mutated = try PluginContentHash.hash(root: root)
    #expect(mutated == loaded.contentHash)
    try "changed".write(to: root.appendingPathComponent("app.derrick/plugin.js"), atomically: true, encoding: .utf8)
    #expect(try PluginContentHash.hash(root: root) != loaded.contentHash)
}

@Test func packageLoadSkillsOnlyHasNoRuntime() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("derrick-plugin-skill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root.appendingPathComponent("skills/pack"), withIntermediateDirectories: true)
    try pluginJSON(name: "skill-pack", derrick: false).write(to: root.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    try """
    ---
    name: pack
    description: docs only
    ---
    Use this skill.
    """.write(to: root.appendingPathComponent("skills/pack/SKILL.md"), atomically: true, encoding: .utf8)

    let loaded = try PluginPackage.load(from: root)
    #expect(!loaded.isHandlePlugin)
    #expect(loaded.runtime == nil)
    #expect(loaded.skills.map(\.name) == ["pack"])
}

@Test func packageRequiresLockfileWhenDepsPresent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("derrick-plugin-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeHandlePlugin(at: root, dependencies: true, lockfile: false)
    #expect(throws: PluginManifestError.missingLockfile) {
        _ = try PluginPackage.load(from: root)
    }
    try "{}".write(to: root.appendingPathComponent("app.derrick/bun.lock"), atomically: true, encoding: .utf8)
    let loaded = try PluginPackage.load(from: root)
    #expect(loaded.runtime?.requiresLockfile == true)
}

@Test func packageSkipsInvalidSkills() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("derrick-plugin-skip-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeHandlePlugin(at: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("skills/empty"), withIntermediateDirectories: true)
    try "".write(to: root.appendingPathComponent("skills/empty/SKILL.md"), atomically: true, encoding: .utf8)
    let loaded = try PluginPackage.load(from: root)
    #expect(loaded.skippedSkills.contains("empty"))
    #expect(loaded.skills.map(\.directoryName) == ["daily-news"])
}

private func pluginJSON(name: String, derrick: Bool) -> String {
    var json = """
    {
      "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      "name": "\(name)",
      "version": "1.0.0",
      "description": "Headlines from one news host."
    """
    if derrick {
        json += """
        ,
          "extensions": {
            "app.derrick": {
              "entrypoint": "./app.derrick/plugin.js",
              "runtime": "./app.derrick/runtime.json"
            }
          }
        """
    }
    json += "\n}"
    return json
}

private func writeHandlePlugin(at root: URL, dependencies: Bool = false, lockfile: Bool = true) throws {
    let derrick = root.appendingPathComponent("app.derrick")
    let skill = root.appendingPathComponent("skills/daily-news")
    try FileManager.default.createDirectory(at: derrick, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try pluginJSON(name: "daily-news", derrick: true)
        .write(to: root.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    try """
    ---
    name: daily-news
    description: Headlines from one news host.
    ---
    Summarize one news host.
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "export function handle() { return []; }\n"
        .write(to: derrick.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)
    var runtime = """
    {
      "entrypoint": "plugin.js",
      "triggers": [{ "kind": "manual" }],
      "auth_refs": []
    """
    if dependencies {
        runtime += #", "dependencies": { "example": "^1.0.0" }"#
    }
    runtime += "\n}"
    try runtime.write(to: derrick.appendingPathComponent("runtime.json"), atomically: true, encoding: .utf8)
    if lockfile, dependencies {
        try "{}\n".write(to: derrick.appendingPathComponent("bun.lock"), atomically: true, encoding: .utf8)
    }
}
