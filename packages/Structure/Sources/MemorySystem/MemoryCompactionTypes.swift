import Foundation

public enum MemoryCompactionInstruction: Hashable, Codable, Sendable {
    case summarize(UUID)
    case dropRaw(UUID)
    case dropDetailed(UUID)
    case dropCompressed(UUID)
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
