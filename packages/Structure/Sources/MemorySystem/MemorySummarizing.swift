import Foundation

public struct MemorySummaryPair: Hashable, Codable, Sendable {
    public let layer1: MemorySummary
    public let layer2: MemorySummary

    public init(layer1: MemorySummary, layer2: MemorySummary) {
        self.layer1 = layer1
        self.layer2 = layer2
    }
}

public protocol MemorySummarizer: Sendable {
    func summarize(_ pair: PromptResponsePair) async throws -> MemorySummaryPair
}
