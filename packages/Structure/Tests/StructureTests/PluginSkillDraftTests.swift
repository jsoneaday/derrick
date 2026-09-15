import Foundation
import Testing
@testable import Structure

@Suite struct PluginSkillDraftTests {
    @Test func newsGoalIsCustomCapabilityNotACoreProduct() {
        var draft = PluginSkillDraft(goal: "Fetch tech news headlines daily")
        PluginSkillDraftPlanner.applyGoal(draft.goal, to: &draft, existingPluginIDs: [])
        #expect(draft.plannedKind == .customCapability)
    }

    @Test func infersSlackConnectorFromGoal() {
        var draft = PluginSkillDraft(goal: "Send messages in Slack from Messaging")
        PluginSkillDraftPlanner.applyGoal(draft.goal, to: &draft, existingPluginIDs: [])
        #expect(draft.plannedKind == .messagingConnector)
        #expect(draft.inferredConnectorVendor == .slack)
        #expect(draft.examples.count >= 1)
    }

    @Test func infersCustomCapabilityFromGenericGoal() {
        var draft = PluginSkillDraft(goal: "Summarize my clipboard when I ask")
        PluginSkillDraftPlanner.applyGoal(draft.goal, to: &draft, existingPluginIDs: [])
        #expect(draft.plannedKind == .customCapability)
    }

    @Test func skillMarkdownIncludesPurposeAndExamples() {
        var draft = PluginSkillDraft(
            goal: "Do something",
            purpose: "Help with tasks",
            triggers: [.chat],
            examples: [
                PluginSkillDraft.Example(userSays: "run it", pluginDoes: "returns a result"),
            ],
            pluginName: "my-plugin"
        )
        let markdown = draft.skillMarkdown()
        #expect(markdown.contains("my-plugin"))
        #expect(markdown.contains("Help with tasks"))
        #expect(markdown.contains("run it"))
    }

    @Test func makeFromSkillDraftBuildsConnectorInput() throws {
        var draft = PluginSkillDraft(
            goal: "Slack connector",
            purpose: "Messaging",
            examples: [
                PluginSkillDraft.Example(userSays: "hi", pluginDoes: "send"),
            ],
            pluginName: "slack-connector-1"
        )
        let input = try PluginFactoryCreateInput.makeFromSkillDraft(draft)
        #expect(input.pluginType == .connector)
        #expect(input.vendor == .slack)
        #expect(input.pluginID == "slack-connector-1")
        #expect(input.skillMarkdown != nil)
    }

    @Test func makeFromSkillDraftBuildsCustomInput() throws {
        var draft = PluginSkillDraft(
            goal: "Summarize text",
            purpose: "Summarize",
            examples: [
                PluginSkillDraft.Example(userSays: "summarize", pluginDoes: "returns summary"),
            ],
            pluginName: "summarizer"
        )
        let input = try PluginFactoryCreateInput.makeFromSkillDraft(draft)
        #expect(input.pluginType == .custom)
        #expect(input.vendor == nil)
        #expect(input.pluginID == "summarizer")
    }

    @Test func messagingConnectorDisallowsScheduleTrigger() {
        let allowed = PluginSkillDraftPlanner.availableTriggers(for: .messagingConnector)
        #expect(allowed == Set([.chat, .messaging, .mention]))
        var draft = PluginSkillDraft(
            goal: "Slack connector",
            triggers: [.schedule, .chat, .messaging],
            pluginName: "slack-1"
        )
        PluginSkillDraftPlanner.sanitizeTriggers(in: &draft)
        #expect(draft.triggers == Set([.chat, .messaging]))
    }
}
