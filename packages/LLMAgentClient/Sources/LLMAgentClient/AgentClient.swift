import Foundation
import Structure

public struct AgentClient<Provider: AgentProvider>: Sendable {
    public let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public func stream(_ request: AgentRequest, model: Provider.Model) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        provider.stream(request, model: model)
    }
}

/// Collect full assistant text and last usage event from a stream.
public func collectAgentStream(
    _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
) async throws -> (text: String, usage: AgentTokenUsage?) {
    var text = ""
    var usage: AgentTokenUsage?
    for try await event in stream {
        switch event {
        case .text(let chunk):
            text += chunk
        case .usage(let u):
            usage = u
        }
    }
    return (text, usage)
}

public typealias OpenAIAgentClient = AgentClient<OpenAIProvider>
public typealias GeminiAgentClient = AgentClient<GeminiProvider>
