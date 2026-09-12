import Foundation

/// Host determination of Present. Not a procession slot.
public enum PluginPresentPolicy: Sendable {
    public static func bind(
        spec: PluginSpecDraft,
        isMessagingConnector: Bool = false
    ) -> PluginPresentBinding {
        if isMessagingConnector || spec.isMessagingConnect {
            return .decided(.thread)
        }
        guard let returnClass = spec.returnClass else {
            return .needsHumanChoice
        }
        switch returnClass {
        case .threadItems:
            return .decided(.thread)
        case .file:
            return .decided(.file)
        case .image:
            return .decided(.image)
        case .list:
            return .decided(.generatedView)
        case .brief, .message:
            return .decided(.conversation)
        }
    }

    public static func applyWrongness(
        _ text: String,
        current: PluginPresent
    ) -> PluginPresentBinding {
        let lowered = text.lowercased()
        let wantsGeneratedView = matches(
            lowered,
            [
                "not a wall of markdown",
                "not raw markdown",
                "raw ###",
                "skim",
                "many stories",
                "scan",
                "not one giant blob",
            ]
        )
        let wantsConversation = matches(
            lowered,
            [
                "just tell me",
                "in the chat",
                "in chat",
                "readable text",
                "don't need a view",
                "do not need a view",
            ]
        )
        let wantsFile = matches(
            lowered,
            [
                "actual document",
                "the actual document",
                "download",
                "save a file",
                "as a pdf",
                "as a file",
            ]
        )
        let wantsImage = matches(
            lowered,
            [
                "as an image",
                "a picture",
                "screenshot",
            ]
        )

        var hits: [PluginPresent] = []
        if wantsGeneratedView { hits.append(.generatedView) }
        if wantsConversation { hits.append(.conversation) }
        if wantsFile { hits.append(.file) }
        if wantsImage { hits.append(.image) }

        let unique = Array(Set(hits))
        if unique.count > 1 {
            return .needsHumanChoice
        }
        if unique.count == 1, let next = unique.first, next != current {
            return .decided(next)
        }
        if wantsGeneratedView, current == .conversation {
            return .decided(.generatedView)
        }
        if wantsConversation, current == .generatedView {
            return .decided(.conversation)
        }
        return .decided(current)
    }

    public static func presentFromChoice(_ text: String) -> PluginPresent? {
        let lowered = text.lowercased()
        if matches(lowered, ["file", "document", "download", "pdf"]) {
            return .file
        }
        if matches(lowered, ["scan", "view", "cards", "dashboard"]) {
            return .generatedView
        }
        if matches(lowered, ["text", "chat", "readable", "markdown"]) {
            return .conversation
        }
        return nil
    }

    private static func matches(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
