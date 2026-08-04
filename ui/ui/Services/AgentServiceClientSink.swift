import Foundation
import ServiceContracts

/// UI-side reverse XPC object: receives turn chunks from AgentService.
public final class AgentServiceClientSink: NSObject, AgentServiceClientSinkXPC, @unchecked Sendable {
    public struct Handlers: Sendable {
        public var onLog: (@Sendable (String) -> Void)?
        public var onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)?
        public var onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)?

        public init(
            onLog: (@Sendable (String) -> Void)? = nil,
            onChunk: (@Sendable (String, AgentTurnChunkDTO) -> Void)? = nil,
            onFinish: (@Sendable (String, AgentTurnErrorDTO?) -> Void)? = nil
        ) {
            self.onLog = onLog
            self.onChunk = onChunk
            self.onFinish = onFinish
        }
    }

    private let lock = NSLock()
    private var handlers: Handlers

    public init(handlers: Handlers = Handlers()) {
        self.handlers = handlers
        super.init()
    }

    public func updateHandlers(_ handlers: Handlers) {
        lock.lock()
        self.handlers = handlers
        lock.unlock()
    }

    public func appendServiceLogLine(_ line: String) {
        lock.lock()
        let onLog = handlers.onLog
        lock.unlock()
        onLog?(line)
        Task { @MainActor in
            debugLog("[AgentService] \(line)")
        }
    }

    public func turnDidEmitChunk(_ turnID: String, chunkJSON: NSData) {
        guard let dto = try? AgentServiceXPCCodec.decodeTurnChunk(chunkJSON as Data) else {
            Task { @MainActor in
                debugLog("AgentService sink: failed to decode chunk for turn \(turnID)")
            }
            return
        }
        lock.lock()
        let onChunk = handlers.onChunk
        lock.unlock()
        onChunk?(turnID, dto)
    }

    public func turnDidFinish(_ turnID: String, errorJSON: NSData) {
        let payload = errorJSON as Data
        let errorDTO: AgentTurnErrorDTO?
        if payload.isEmpty {
            errorDTO = nil
        } else {
            errorDTO = try? AgentServiceXPCCodec.decodeTurnError(payload)
        }
        Task { @MainActor in
            if let errorDTO {
                debugLog("AgentService sink: turn \(turnID) finished with error: \(errorDTO.message)")
            } else {
                debugLog("AgentService sink: turn \(turnID) finished ok")
            }
        }
        lock.lock()
        let onFinish = handlers.onFinish
        lock.unlock()
        onFinish?(turnID, errorDTO)
    }
}
