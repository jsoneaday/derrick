import Foundation
import Testing
@testable import Structure

@Suite struct PluginFactoryReleaseEditableFilesTests {
    @Test func packageFilesOmitRuntimeAndIncludeSkills() {
        let skillFiles = [
            "skills/weather/SKILL.md": "# Weather",
            "skills/weather/references/api.md": "# API",
        ]
        let release = makeRelease(skillFiles: skillFiles)
        let paths = Set(release.packageFiles().keys)
        #expect(paths.contains("plugin.json"))
        #expect(paths.contains("app.derrick/plugin.go"))
        #expect(paths.contains("skills/weather/SKILL.md"))
        #expect(paths.contains("skills/weather/references/api.md"))
        #expect(!paths.contains(PluginFactoryRelease.runtimePackagePath))
        #expect(paths.contains(PluginFactoryRelease.compiledArtifactPackagePath))
        #expect(release.verifyIntegrity())
    }

    @Test func browserFilesPrettyPrintManifestAndHideRuntime() {
        let release = makeRelease(
            pluginID: "slack-connector-1",
            skillFiles: [
                "skills/slack-connector-1/SKILL.md": "---\nname: slack\ndescription: Slack\n---\n",
            ],
            manifestJSON: #"{"name":"slack-connector-1","version":"1.0.0"}"#
        )
        let items = release.browserPackageFiles()
        let paths = items.map(\.path)
        #expect(paths.contains("plugin.json"))
        #expect(paths.contains("app.derrick/plugin.go"))
        #expect(paths.contains("skills/slack-connector-1/SKILL.md"))
        #expect(!paths.contains(PluginFactoryRelease.runtimePackagePath))
        let manifest = items.first { $0.path == "plugin.json" }?.body ?? ""
        #expect(manifest.contains("\n"))
        #expect(manifest.contains("slack-connector-1"))
    }

    @Test func legacyRuntimeHashStillVerifies() {
        let artifact = Data("compiled-binary".utf8)
        let guestSource = "package main\n"
        let manifestJSON = #"{"name":"weather-tool","extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.go"}}}"#
        let runtimeJSON = #"{"language":"go","entrypoint":"./app.derrick/plugin.go"}"#
        let skillFiles = ["skills/weather/SKILL.md": "# Weather"]
        var files: [String: Data] = [
            "plugin.json": Data(manifestJSON.utf8),
            "app.derrick/runtime.json": Data(runtimeJSON.utf8),
            "app.derrick/plugin.go": Data(guestSource.utf8),
            "app.derrick/plugin": artifact,
        ]
        for (path, body) in skillFiles {
            files[path] = Data(body.utf8)
        }
        let release = PluginFactoryRelease(
            pluginID: "weather-tool",
            version: "1.0.0",
            manifestJSON: manifestJSON,
            runtimeJSON: runtimeJSON,
            guestSource: guestSource,
            compiledArtifact: artifact,
            skillFiles: skillFiles,
            contentHash: PluginContentHash.hash(files: files),
            reviewSummary: "approved"
        )
        #expect(release.verifyIntegrity())
    }

    @Test func replacingEditableTextFilesRecalculatesHashAndKeepsArtifact() {
        let release = makeRelease(skillFiles: [
            "skills/weather/SKILL.md": "# Weather",
        ])
        var drafts = Dictionary(uniqueKeysWithValues: release.browserPackageFiles().map {
            ($0.path, $0.body)
        })
        drafts["skills/weather/SKILL.md"] = "# Weather\n\nUpdated."
        drafts["app.derrick/plugin.go"] = "package main\n// edited\n"

        let updated = release.replacingEditableTextPackageFiles(drafts)
        #expect(updated.verifyIntegrity())
        #expect(updated.compiledArtifact == release.compiledArtifact)
        #expect(updated.skillFiles["skills/weather/SKILL.md"] == "# Weather\n\nUpdated.")
        #expect(updated.guestSource.contains("edited"))
        #expect(updated.runtimeJSON.isEmpty)
        #expect(updated.contentHash != release.contentHash)
    }

    private func makeRelease(
        pluginID: String = "weather-tool",
        skillFiles: [String: String],
        manifestJSON: String? = nil
    ) -> PluginFactoryRelease {
        let artifact = Data("compiled-binary".utf8)
        let guestSource = "package main\n"
        let manifest = manifestJSON
            ?? "{\"name\":\"\(pluginID)\",\"extensions\":{\"app.derrick\":{\"entrypoint\":\"./app.derrick/plugin.go\"}}}"
        var files: [String: Data] = [
            "plugin.json": Data(manifest.utf8),
            "app.derrick/plugin.go": Data(guestSource.utf8),
            "app.derrick/plugin": artifact,
        ]
        for (path, body) in skillFiles {
            files[path] = Data(body.utf8)
        }
        return PluginFactoryRelease(
            pluginID: pluginID,
            version: "1.0.0",
            manifestJSON: manifest,
            runtimeJSON: "",
            guestSource: guestSource,
            compiledArtifact: artifact,
            skillFiles: skillFiles,
            contentHash: PluginContentHash.hash(files: files),
            reviewSummary: "approved"
        )
    }
}

@Suite struct PluginSkillDisclosureTests {
    @Test func indexExposesNameAndDescriptionOnly() {
        let release = PluginFactoryRelease(
            pluginID: "weather-tool",
            version: "1.0.0",
            manifestJSON: #"{"name":"weather-tool"}"#,
            runtimeJSON: "",
            guestSource: "package main",
            compiledArtifact: Data(),
            skillFiles: [
                "skills/weather/SKILL.md": """
                ---
                name: weather
                description: Fetch forecasts
                ---
                # Weather
                Long body that should not appear in the index alone.
                """,
            ],
            contentHash: try! PluginContentHash(hex: String(repeating: "a", count: 64)),
            reviewSummary: "ok"
        )
        let index = PluginSkillDisclosure.index(from: release)
        #expect(index.count == 1)
        #expect(index[0].skillName == "weather")
        #expect(index[0].description == "Fetch forecasts")
    }

    @Test func activateAndReferenceAreOnDemand() {
        let skills = [
            "skills/weather/SKILL.md": "---\nname: weather\ndescription: x\n---\n# Body\n",
            "skills/weather/references/api.md": "# API docs",
        ]
        #expect(PluginSkillDisclosure.activate(skillFiles: skills, skillNameOrPath: "weather")?.contains("# Body") == true)
        let ref = PluginSkillDisclosure.reference(skillFiles: skills, requested: "api.md")
        #expect(ref?.path == "skills/weather/references/api.md")
        #expect(ref?.body == "# API docs")
    }

    @Test func indexPromptBlockIsRoutingOnly() {
        let entries = [
            PluginSkillDisclosure.IndexEntry(
                pluginID: "weather-tool",
                skillName: "weather",
                description: "Fetch forecasts",
                skillMarkdownPath: "skills/weather/SKILL.md"
            )
        ]
        let block = PluginSkillDisclosure.indexPromptBlock(entries: entries)
        #expect(block.contains("plugin.skill"))
        #expect(block.contains("/weather-tool · weather: Fetch forecasts"))
        #expect(!block.contains("# Body"))
        #expect(PluginSkillDisclosure.indexPromptBlock(entries: []).isEmpty)
    }

    @Test func hostUICatalogSummaryListsElementsWithoutFullDump() throws {
        let summary = try HostUIDisclosure.catalogSummary()
        #expect(summary.contains("tab_strip"))
        #expect(summary.contains("button"))
        #expect(summary.contains("never substitutes"))
        #expect(!summary.contains("always applies"))
        #expect(!summary.contains("\"examples\""))
        let schema = try HostUIDisclosure.elementSchema(id: "button")
        #expect(schema.contains("button"))
    }
}
