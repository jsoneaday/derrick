import Foundation

public enum MemoryCompactionInstruction: Hashable, Codable, Sendable {
    case summarize(UUID)
    case dropRaw(UUID)
    case dropDetailed(UUID)
}

public struct MemoryCompactionPlan: Hashable, Codable, Sendable {
    public let instructions: [MemoryCompactionInstruction]

    public init(instructions: [MemoryCompactionInstruction]) {
        self.instructions = instructions
    }
}

public protocol MemoryCompactionPolicy: Sendable {
    func plan(entries: [MemoryWorkingEntry], budget: MemoryBudget) -> MemoryCompactionPlan
}

public struct TieredMemoryCompactionPolicy: MemoryCompactionPolicy {
    public init() {}

    public func plan(entries: [MemoryWorkingEntry], budget: MemoryBudget) -> MemoryCompactionPlan {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }

        var instructions: [MemoryCompactionInstruction] = []
        var projectedTokens = entries.reduce(0) { $0 + $1.estimatedTokenCount }

        for entry in sorted {
            guard projectedTokens > budget.maxTokenCount else { break }

            if entry.rawPair != nil {
                instructions.append(.summarize(entry.id))
                projectedTokens -= max(entry.rawPair?.totalTokenCount ?? 0, 1)
                projectedTokens += max(entry.detailedSummary?.metadata.summaryTokenCount ?? 0, 1)
            }

            if projectedTokens > budget.maxTokenCount, entry.rawPair != nil {
                instructions.append(.dropRaw(entry.id))
                projectedTokens -= max(entry.rawPair?.totalTokenCount ?? 0, 0)
                projectedTokens += max(entry.detailedSummary?.metadata.summaryTokenCount ?? entry.compressedSummary?.metadata.summaryTokenCount ?? 0, 0)
            }

            if projectedTokens > budget.maxTokenCount, entry.detailedSummary != nil {
                instructions.append(.dropDetailed(entry.id))
                projectedTokens -= max(entry.detailedSummary?.metadata.summaryTokenCount ?? 0, 0)
                projectedTokens += max(entry.compressedSummary?.metadata.summaryTokenCount ?? 0, 0)
            }
        }

        return MemoryCompactionPlan(instructions: instructions)
    }
}
