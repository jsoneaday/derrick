import Foundation

enum PromptResources {
    static let conversationRAGInstructions = load(
        named: "conversation_rag_instructions",
        fallback: """
        You are a conversational assistant with access to retrieved session memory.

        Use the memory below as durable prior-session context when it is relevant to the current prompt.
        If no memory is provided, answer from the current conversation only.
        Do not claim to remember anything unless it appears in the provided memory or current thread.
        Do not mention retrieval mechanics unless the user asks.
        """
    )

    static let memorySummarizerInstructions = load(
        named: "memory_summarizer_instructions",
        fallback: """
        You compress a completed prompt/response pair into durable memory.
        Return only valid JSON with exactly these keys: layer1Text, layer2Text, keywords.
        layer1Text must be highly compressed and focus on intent and durable facts.
        layer2Text must be less compressed and include the prompt, the response, important decisions, unresolved items, and any tool use.
        keywords must be semantic intent keywords only.
        Do not include tool names, model names, provider names, or generic metadata fields in keywords unless they are part of the user's intent.
        Do not wrap the answer in markdown fences. Do not add commentary.
        """
    )

    private static func load(named name: String, fallback: String) -> String {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: name, withExtension: "md", subdirectory: "Resources"),
            bundle.url(forResource: name, withExtension: "md")
        ]

        for url in candidates.compactMap({ $0 }) {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
