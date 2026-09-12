import Foundation
import Testing
@testable import Structure

@Suite struct PluginSpecProcessionTests {
    @Test func internetDoesNotBindConnect() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Summaries of today’s tech news.")
        #expect(session.ask == .slot(.connect))
        let turn = PluginSpecProcession.advance(session: &session, utterance: "Just the internet. Google is fine.")
        #expect(session.draft.connect == nil)
        #expect(session.ask == .slot(.connect))
        #expect(turn.reply.contains("not a place"))
    }

    @Test func parksReturnFromClaimedOutcomeButDoesNotSkipConnect() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Give me summaries of today’s tech news.")
        #expect(session.draft.claimedOutcome != nil)
        #expect(session.ask == .slot(.connect))
        #expect(session.draft.parked[PluginSpecSlot.returnPayload.rawValue] != nil)
    }

    @Test func namedSiteBindsConnectThenAsksAccess() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Summaries of tech news")
        _ = PluginSpecProcession.advance(session: &session, utterance: "Google News, and also the Wall Street Journal.")
        #expect(session.draft.connect?.klass == .namedSite)
        #expect(session.ask == .slot(.access))
    }

    @Test func unreachableAccessBlocksBuild() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Fetch files")
        _ = PluginSpecProcession.advance(session: &session, utterance: "files on this Mac")
        let turn = PluginSpecProcession.advance(session: &session, utterance: "paywall, I cannot open them")
        #expect(session.draft.access == .unreachable)
        #expect(turn.ask == .blocked(.accessUnreachable))
        #expect(session.draft.isBuildable == false)
    }

    @Test func completeSpecInfersConversationPresent() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "A short brief of my notes")
        _ = PluginSpecProcession.advance(session: &session, utterance: "files on this Mac")
        _ = PluginSpecProcession.advance(session: &session, utterance: "yes I can open them")
        _ = PluginSpecProcession.advance(session: &session, utterance: "summarize them")
        _ = PluginSpecProcession.advance(session: &session, utterance: "a brief")
        _ = PluginSpecProcession.advance(session: &session, utterance: "when I ask in chat")
        #expect(session.draft.present == .conversation)
        #expect(session.draft.presentSource == .inferred)
        #expect(session.ask == .wrongness)
        let done = PluginSpecProcession.advance(session: &session, utterance: "nothing, that is fine")
        #expect(done.isComplete)
        #expect(session.draft.isBuildable)
    }

    @Test func slackConnectInfersThreadPresent() {
        var session = PluginSpecSession()
        _ = PluginSpecProcession.advance(session: &session, utterance: "Read my Slack inbox")
        _ = PluginSpecProcession.advance(session: &session, utterance: "Slack")
        _ = PluginSpecProcession.advance(session: &session, utterance: "yes I am logged in")
        _ = PluginSpecProcession.advance(session: &session, utterance: "list my channels")
        _ = PluginSpecProcession.advance(session: &session, utterance: "thread items")
        _ = PluginSpecProcession.advance(session: &session, utterance: "from messaging")
        #expect(session.draft.present == .thread)
    }
}

@Suite struct PluginPresentPolicyTests {
    @Test func listReturnBindsGeneratedView() {
        var spec = PluginSpecDraft(returnClass: .list)
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.generatedView))
        spec.returnClass = .file
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.file))
        spec.returnClass = .image
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.image))
        spec.returnClass = .brief
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.conversation))
        spec.connect = PluginConnectBinding(klass: .messagingInbox, detail: "Slack")
        #expect(PluginPresentPolicy.bind(spec: spec) == .decided(.thread))
    }

    @Test func wrongnessOverridesConversationToGeneratedView() {
        let binding = PluginPresentPolicy.applyWrongness(
            "Not a wall of markdown; I need to skim many stories",
            current: .conversation
        )
        #expect(binding == .decided(.generatedView))
    }

    @Test func wrongnessOverridesGeneratedViewToConversation() {
        let binding = PluginPresentPolicy.applyWrongness(
            "Just tell me in the chat",
            current: .generatedView
        )
        #expect(binding == .decided(.conversation))
    }

    @Test func wrongnessCanForceFile() {
        #expect(
            PluginPresentPolicy.applyWrongness("I need the actual document", current: .conversation)
                == .decided(.file)
        )
    }

    @Test func makeFromSpecDraftRequiresPresent() {
        let empty = PluginSpecDraft(claimedOutcome: "do it")
        #expect(throws: PluginCreatorSpecError.notBuildable) {
            try PluginFactoryCreateInput.makeFromSpecDraft(empty)
        }
    }

    @Test func makeFromSpecDraftSucceedsWhenComplete() throws {
        let spec = PluginSpecDraft(
            claimedOutcome: "Summarize my notes",
            connect: PluginConnectBinding(klass: .localFiles, detail: "files on this Mac"),
            access: .reachable,
            work: .summarize,
            returnClass: .brief,
            trigger: .chat,
            present: .conversation,
            presentSource: .inferred,
            wrongness: "not an empty reply"
        )
        let input = try PluginFactoryCreateInput.makeFromSpecDraft(spec)
        #expect(input.pluginType == .custom)
        #expect(input.pluginID != nil)
    }
}
