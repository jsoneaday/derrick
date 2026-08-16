import Foundation
import LLMAgentClient
import MCP
import MCPClient
import MemorySystem
import PartialJSON
import Lib
import AppEvents
import PolicyUserInteraction
import Plugin
import ServiceContracts

extension ConversationPipeline {
    func streamWithPolicyInterception(
        prompt: String,
        sessionID: String,
        parentAgentID: String? = nil,
        toolCalls: [ToolCallRecord] = [],
        scope: MemoryAccessibility = .private,
        interceptor: PolicyInterceptor = DefaultPolicyInterceptor(),
        approvalPresenter: (any ApprovalConfirmationPresenting)? = nil,
        responseSchema: AgentSchema? = nil
    ) async -> AsyncThrowingStream<AgentResponseNextChunk, Error> {
        return AsyncThrowingStream(AgentResponseNextChunk.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                let overallStarted = Date()
                do {
                    var workingPrompt = prompt
                    var aggregatedToolCalls = toolCalls
                    await MainActor.run {
                        UsageLimitsService.shared.resetMessageCounters()
                    }
                    // Upper bound is absolute max; per-message cap + session raises gate tool rounds.
                    let maxToolRoundIterations = FactorySessionID.isFactorySession(sessionID)
                        ? FactoryTurnGate.pipelineToolRounds
                        : UsageLimits.absoluteMax.maxToolRoundsPerMessage
                    let jsonDecoder = JSONDecoder()
                    let jsonEncoder = JSONEncoder()
                    PipelineTiming.log(
                        "turn_start session=\(sessionID.prefix(8)) model=\(String(describing: model)) max_tool_rounds_cap=\(maxToolRoundIterations)"
                    )

                    for round in 0...maxToolRoundIterations {
                        let roundStarted = Date()
                        let roundLabel = "round_\(round + 1)"
                        await MainActor.run {
                            debugLog("Prompt sent (round \(round + 1)): \(workingPrompt.prefix(120))")
                        }

                        let memoryStarted = Date()
                        let retrieval = (try? await retrieveMemoryContext(for: workingPrompt)) ?? ""
                        let memoryMS = PipelineTiming.elapsedMS(from: memoryStarted)

                        let catalogStarted = Date()
                        let toolCatalog = try await toolCatalogContext()
                        let catalogMS = PipelineTiming.elapsedMS(from: catalogStarted)

                        let promptBuildStarted = Date()
                        let request = AgentRequest.prompt(
                            workingPrompt,
                            system: systemPrompt(from: retrieval, toolCatalog: toolCatalog),
                            temperature: 0.1,
                            responseSchema: responseSchema
                        )
                        let promptBuildMS = PipelineTiming.elapsedMS(from: promptBuildStarted)
                        let systemChars = (request.messages.first { $0.role == .system }?.content.utf8.count) ?? 0
                        let userChars = (request.messages.last { $0.role == .user }?.content.utf8.count) ?? 0
                        PipelineTiming.log(
                            "\(roundLabel) setup memory_ms=\(memoryMS) catalog_ms=\(catalogMS) prompt_build_ms=\(promptBuildMS) system_chars=\(systemChars) user_chars=\(userChars) memory_chars=\(retrieval.utf8.count) catalog_chars=\(toolCatalog.utf8.count)"
                        )

                        await MainActor.run {
                            debugLog(Self.formatLLMRequest(request, round: round + 1))
                        }
                        let llmStarted = Date()
                        var llmFirstChunkAt: Date?
                        let upstream = client.stream(request, model: model)
                        var completion = ""
                        var agentResponse: AgentResponse?
                        var chunkIndex = 0
                        var streamedVisibleContent = false
                        var lastYieldedCompletionLength = 0
                        var lastPublishedThought = ""
                        var publishedChunkDenial = false
                        /// When true, stop painting complete deltas (sensitive content pending review).
                        var holdCompleteUI = false
                        var heldCompleteThroughLength = 0
                        var lastAPIUsage: AgentTokenUsage?
                        var partialJSONDecodeCount = 0
                        var chunkPolicyMS = 0

                        upstreamLoop: for try await streamEvent in upstream {
                            if case .usage(let usage) = streamEvent {
                                lastAPIUsage = usage
                                continue upstreamLoop
                            }
                            guard case .text(let chunk) = streamEvent else {
                                continue upstreamLoop
                            }
                            if llmFirstChunkAt == nil {
                                llmFirstChunkAt = Date()
                            }
                            let event = AssistantChunkEvent(
                                sessionID: sessionID,
                                chunkIndex: chunkIndex,
                                content: chunk
                            )

                            let chunkPolicyStarted = Date()
                            let chunkIntercept = try await interceptor.interceptAssistantChunk(event)
                            chunkPolicyMS += PipelineTiming.elapsedMS(from: chunkPolicyStarted)
                            let interceptedContent: String
                            switch chunkIntercept {
                            case .denied(let reason):
                                if !publishedChunkDenial {
                                    publishedChunkDenial = true
                                    await PolicyDecisionRouting.publishNotice(
                                        PolicyUserEventFactory.contentGovernanceDenied(
                                            reason: reason,
                                            payloadPreview: String(chunk.prefix(400)),
                                            correlationId: sessionID
                                        )
                                    )
                                    await MainActor.run {
                                        debugLog("Chunk blocked by policy: \(reason)")
                                    }
                                }
                                continue upstreamLoop
                            case .confirm(let content, _):
                                // Chunk confirm is soft-allow (no modal mid-stream).
                                interceptedContent = content
                            case .allowed(let content):
                                interceptedContent = content
                            }

                            completion += interceptedContent
                            chunkIndex += 1

                            // PartialJSON may yield non-object values mid-stream (String/Number/Bool).
                            // JSONSerialization aborts on invalid top-level types — try? does not catch that.
                            if let jsonAny = try? PartialJSON.parse(completion),
                               JSONSerialization.isValidJSONObject(jsonAny),
                               let jsonData = try? JSONSerialization.data(withJSONObject: jsonAny, options: []) {
                                partialJSONDecodeCount += 1
                                // Only replace when decode succeeds. PartialJSON often yields incomplete
                                // status strings (e.g. "tool") that fail enum decode; assigning nil would
                                // wipe a previously decoded partial response.
                                if let decoded = try? jsonDecoder.decode(AgentResponse.self, from: jsonData) {
                                    agentResponse = decoded
                                }

                                if round == 0 {
                                    if chunkIndex == 1 {
                                        let currentPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                        await MainActor.run {
                                            debugLog("Model started formulating plan to: \(currentPrompt)")
                                        }
                                    } else if chunkIndex % 150 == 0 {
                                        let currentChunks = chunkIndex
                                        let currentPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                        await MainActor.run {
                                            debugLog("Model is formulating plan (chunk \(currentChunks)) to: \(currentPrompt)")
                                        }
                                    }
                                } else {
                                    if chunkIndex == 1 {
                                        await MainActor.run {
                                            debugLog("Model started generating final response...")
                                        }
                                    } else if chunkIndex % 150 == 0 {
                                        let currentChunks = chunkIndex
                                        await MainActor.run {
                                            debugLog("Model is generating final response (chunk \(currentChunks))...")
                                        }
                                    }
                                }

                                switch agentResponse?.status {
                                case .none:
                                    // Mid-stream: partial JSON not yet a full AgentResponse.
                                    break
                                case .toolCall:
                                    if let thought = agentResponse?.thought, agentResponse?.toolCall == nil {
                                        Self.publishThoughtSnapshot(
                                            thought,
                                            lastPublished: &lastPublishedThought,
                                            continuation: continuation
                                        )
                                    } else {
                                        var toolName: String?
                                        if let toolCall = agentResponse?.toolCall {
                                            toolName = toolCall.toolName
                                        } else {
                                            let singleToolCall = Self.parseToolPayload(agentResponse)
                                            
                                            switch singleToolCall {
                                            case .single(let toolRequest):
                                                toolName = toolRequest.toolName
                                            default:
                                                toolName = nil
                                            }
                                        }
                                        continuation.yield(AgentResponseNextChunk(status: .toolCall, chunk: "", toolName: toolName))
                                    }
                                    break
                                case .toolBatch:
                                    if let thought = agentResponse?.thought, agentResponse?.toolBatch == nil {
                                        Self.publishThoughtSnapshot(
                                            thought,
                                            lastPublished: &lastPublishedThought,
                                            continuation: continuation
                                        )
                                    } else {
                                        var toolNames: String?
                                        if let toolCall = agentResponse?.toolBatch {
                                            let tools = toolCall.tools
                                            let count = tools?.count ?? 0
                                            toolNames = count > 0 ? tools?.map{ tool in tool.toolName ?? "batch tool name error" }.joined(separator: ", "): "batch tool name error"
                                        } else {
                                            let batchToolCall = Self.parseToolPayload(agentResponse)
                                            
                                            switch batchToolCall {
                                            case .batch(let toolRequest):
                                                toolNames = toolRequest.invocations.map { $0.toolName } .joined(separator: ", ")
                                            default:
                                                toolNames = nil
                                            }
                                        }
                                        continuation.yield(AgentResponseNextChunk(status: .toolCall, chunk: "", toolName: toolNames))
                                    }
                                    break
                                case .complete:
                                    let factoryStillRunning = FactoryTurnGate.nextRequiredStep(
                                        sessionID: sessionID,
                                        records: aggregatedToolCalls
                                    ) != nil
                                    if factoryStillRunning {
                                        break
                                    }
                                    if let assistantResponse = agentResponse?.assistantResponse {
                                        // Smart hold: only pause complete *UI* once ungranted email appears.
                                        // Thinking/tool_call keep streaming; non-sensitive answers stream fully.
                                        if !holdCompleteUI {
                                            let shouldHold = await MainActor.run {
                                                ContentSensitivityGrantService.shared.shouldHoldCompleteStreaming(
                                                    for: assistantResponse,
                                                    sessionID: sessionID
                                                )
                                            }
                                            if shouldHold {
                                                holdCompleteUI = true
                                                heldCompleteThroughLength = lastYieldedCompletionLength
                                                await MainActor.run {
                                                    debugLog("Holding complete UI stream (ungranted sensitive content detected)")
                                                }
                                            }
                                        }
                                        if !holdCompleteUI {
                                            let newLength = assistantResponse.count
                                            if newLength > lastYieldedCompletionLength {
                                                let index = assistantResponse.index(assistantResponse.startIndex, offsetBy: lastYieldedCompletionLength)
                                                let delta = String(assistantResponse[index...])

                                                streamedVisibleContent = true
                                                continuation.yield(AgentResponseNextChunk(status: .complete, chunk: delta))
                                                lastYieldedCompletionLength = newLength
                                            }
                                        }
                                    }
                                case .thinking:
                                    if let thought = agentResponse?.thought, !thought.isEmpty {
                                        if Self.publishThoughtSnapshot(
                                            thought,
                                            lastPublished: &lastPublishedThought,
                                            continuation: continuation
                                        ) {
                                            streamedVisibleContent = true
                                        }
                                    }
                                default:
                                    // Known statuses are exhaustive; keep a quiet fallback for future enum cases.
                                    break
                                }
                            }
                        }

                        let llmEnded = Date()
                        let llmTtfbMS = llmFirstChunkAt.map { PipelineTiming.elapsedMS(from: llmStarted, to: $0) } ?? PipelineTiming.elapsedMS(from: llmStarted, to: llmEnded)
                        let llmStreamMS = llmFirstChunkAt.map { PipelineTiming.elapsedMS(from: $0, to: llmEnded) } ?? 0
                        let llmTotalMS = PipelineTiming.elapsedMS(from: llmStarted, to: llmEnded)
                        PipelineTiming.log(
                            "\(roundLabel) llm ttfb_ms=\(llmTtfbMS) stream_ms=\(llmStreamMS) total_ms=\(llmTotalMS) chunks=\(chunkIndex) completion_chars=\(completion.utf8.count) partial_json_decodes=\(partialJSONDecodeCount) chunk_policy_ms=\(chunkPolicyMS) usage=\(lastAPIUsage.map { "\($0.totalTokens)(\($0.source.rawValue))" } ?? "none")"
                        )

                        guard !completion.isEmpty else {
                            debugLog("Completion is empty (round \(round + 1), llm_chunks=\(chunkIndex), ttfb_ms=\(llmTtfbMS))")
                            PipelineTiming.log("\(roundLabel) empty_completion llm_chunks=\(chunkIndex) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted))")
                            break
                        }
                        await MainActor.run {
                            debugLog("LLM completion received (round \(round + 1), chunks=\(chunkIndex))")
                            debugLog(Self.formatLLMResponse(completion, round: round + 1))
                        }

                        debugLog("**Start Completion**")
                        let finalizeStarted = Date()
                        // Prefer a full re-decode of the finished stream. Mid-stream PartialJSON can leave
                        // a stale agentResponse (e.g. tool_call without complete arguments) that then
                        // fails parseToolPayload and skips execution — empty follow-up / "no live fetch".
                        if let finalized = Self.decodeAgentResponse(from: completion, decoder: jsonDecoder) {
                            agentResponse = finalized
                        }
                        let finalizeDecodeMS = PipelineTiming.elapsedMS(from: finalizeStarted)

                        // Prefer structured assistant_response; if the model ignored the JSON schema
                        // and returned plain prose, surface that text instead of an empty bubble.
                        var fullCompletion = Self.getFullCompletion(agentResponse, jsonEncoder: jsonEncoder)
                        if fullCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let raw = completion.trimmingCharacters(in: .whitespacesAndNewlines)
                            let isToolStatus = agentResponse?.status == .toolCall || agentResponse?.status == .toolBatch
                            if !raw.isEmpty, !isToolStatus {
                                fullCompletion = raw
                                await MainActor.run {
                                    debugLog("Using raw completion text (model did not emit schema-shaped assistant_response)")
                                }
                            }
                        }
                        let completionEvent = AssistantCompletionEvent(
                            sessionID: sessionID,
                            fullCompletion: fullCompletion,
                            chunkCount: chunkIndex
                        )
                        let completionPolicyStarted = Date()
                        let completionIntercept = try await interceptor.interceptAssistantCompletion(completionEvent)
                        var completionPolicyMS = PipelineTiming.elapsedMS(from: completionPolicyStarted)
                        let contentConfirmStarted = Date()
                        let interceptedCompletion: String?
                        switch completionIntercept {
                        case .denied(let reason):
                            await PolicyDecisionRouting.publishNotice(
                                PolicyUserEventFactory.contentGovernanceDenied(
                                    reason: reason,
                                    payloadPreview: String(fullCompletion.prefix(800)),
                                    correlationId: sessionID
                                )
                            )
                            await MainActor.run {
                                debugLog("Completion blocked by policy engine: \(reason)")
                            }
                            interceptedCompletion = nil
                        case .confirm(let contentToConfirm, let requiredFields):
                            await MainActor.run {
                                debugLog("Completion requires content confirmation fields=\(requiredFields.joined(separator: ","))")
                            }
                            interceptedCompletion = await ContentSensitivityGrantService.shared.resolveConfirm(
                                content: contentToConfirm,
                                requiredFields: requiredFields,
                                sessionID: sessionID
                            )
                        case .allowed(let allowedContent):
                            interceptedCompletion = allowedContent
                        }
                        let contentConfirmMS = PipelineTiming.elapsedMS(from: contentConfirmStarted)
                        if case .confirm = completionIntercept {
                            completionPolicyMS += contentConfirmMS
                            PipelineTiming.log("\(roundLabel) content_confirm_ms=\(contentConfirmMS)")
                        }

                        guard let interceptedCompletion else {
                            PipelineTiming.log(
                                "\(roundLabel) completion_blocked finalize_decode_ms=\(finalizeDecodeMS) completion_policy_ms=\(completionPolicyMS) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted))"
                            )
                            break
                        }
                        await MainActor.run {
                            debugLog("Completion validated by policy engine")
                        }
                        PipelineTiming.log(
                            "\(roundLabel) post_llm finalize_decode_ms=\(finalizeDecodeMS) completion_policy_ms=\(completionPolicyMS) status=\(agentResponse?.status.rawValue ?? "nil")"
                        )

                        // Prefer provider-reported usage; fall back to estimate if the API omitted it.
                        let usageStarted = Date()
                        let tokenOK: Bool
                        if let usage = lastAPIUsage {
                            tokenOK = await UsageLimitsService.shared.recordAPIUsage(
                                usage,
                                pricing: model.tokenPricing
                            )
                        } else {
                            tokenOK = await UsageLimitsService.shared.recordTokens(
                                promptText: workingPrompt,
                                completionText: completion,
                                pricing: model.tokenPricing
                            )
                        }
                        let usageMS = PipelineTiming.elapsedMS(from: usageStarted)
                        if !tokenOK {
                            await MainActor.run {
                                debugLog("Stopped: usage token budget exhausted")
                            }
                            PipelineTiming.log(
                                "\(roundLabel) stopped_usage_budget usage_ms=\(usageMS) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted)) turn_total_ms=\(PipelineTiming.elapsedMS(from: overallStarted))"
                            )
                            if !streamedVisibleContent {
                                continuation.yield(
                                    AgentResponseNextChunk(
                                        status: .complete,
                                        chunk: "Stopped: usage token budget reached. You can raise session limits when prompted, or set permanent caps in Settings → Usage limits."
                                    )
                                )
                            }
                            break
                        }

                        // Flush any held complete text after allow/confirm (single paint of remainder).
                        let factoryStillRunning = FactoryTurnGate.nextRequiredStep(
                            sessionID: sessionID,
                            records: aggregatedToolCalls
                        ) != nil
                        if factoryStillRunning == false, agentResponse?.status == .complete || holdCompleteUI {
                            let text = interceptedCompletion
                            if holdCompleteUI || lastYieldedCompletionLength < text.count {
                                let start = min(heldCompleteThroughLength, text.count)
                                if start < text.count {
                                    let idx = text.index(text.startIndex, offsetBy: start)
                                    let remainder = String(text[idx...])
                                    if !remainder.isEmpty {
                                        streamedVisibleContent = true
                                        continuation.yield(AgentResponseNextChunk(status: .complete, chunk: remainder))
                                        lastYieldedCompletionLength = text.count
                                    }
                                }
                            }
                        }
                        
                        if agentResponse?.status == .toolCall || agentResponse?.status == .toolBatch {
                            let limitStarted = Date()
                            let roundAllowed = await UsageLimitsService.shared.allowToolRound(
                                roundIndex: round,
                                factoryPipeline: FactorySessionID.isFactorySession(sessionID)
                            )
                            let toolLimitMS = PipelineTiming.elapsedMS(from: limitStarted)
                            if !roundAllowed {
                                await MainActor.run {
                                    debugLog("Stopped: max tool rounds reached (round \(round))")
                                }
                                PipelineTiming.log(
                                    "\(roundLabel) stopped_tool_round_limit tool_limit_ms=\(toolLimitMS) usage_ms=\(usageMS) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted)) turn_total_ms=\(PipelineTiming.elapsedMS(from: overallStarted))"
                                )
                                let stopMessage = FactoryTurnGate.userFacingStopMessage(
                                    sessionID: sessionID,
                                    records: aggregatedToolCalls
                                )
                                continuation.yield(
                                    AgentResponseNextChunk(
                                        status: .complete,
                                        chunk: stopMessage
                                    )
                                )
                                break
                            }
                            await MainActor.run {
                                debugLog("Tool request detected; forwarding to policy engine")
                            }
                            let parseStarted = Date()
                            let parsedTool = Self.parseToolPayload(agentResponse)
                            let parseToolMS = PipelineTiming.elapsedMS(from: parseStarted)
                            let schedulingToolNames = Self.jobSchedulingToolNames(in: agentResponse)
                            if parsedTool == nil {
                                await MainActor.run {
                                    let name = agentResponse?.toolCall?.toolName ?? agentResponse?.toolBatch?.tools?.first?.toolName ?? "(unknown)"
                                    let rawArgs = agentResponse?.toolCall?.arguments ?? ""
                                    let head = String(rawArgs.prefix(240))
                                    let tail = rawArgs.count > 240 ? String(rawArgs.suffix(120)) : ""
                                    debugLog(
                                        "Tool payload parse failed for status=\(agentResponse?.status.rawValue ?? "?") name=\(name) argsLen=\(rawArgs.count) head=\(head) tail=\(tail)"
                                    )
                                }
                                for toolName in schedulingToolNames {
                                    await PolicyDecisionRouting.publishNotice(
                                        PolicyUserEventFactory.jobSchedulingFailed(
                                            toolName: toolName,
                                            reason: "The job could not be scheduled because the tool request was invalid.",
                                            detail: "Tool arguments could not be parsed. No job was created.",
                                            correlationId: sessionID
                                        )
                                    )
                                }
                            }
                            let toolStarted = Date()
                            let toolExecution: (summary: String, records: [ToolCallRecord])
                            do {
                                toolExecution = try await executeToolRequest(
                                    parsedTool,
                                    sessionID: sessionID,
                                    userPrompt: prompt,
                                    approvalPresenter: approvalPresenter
                                )
                            } catch {
                                for toolName in schedulingToolNames {
                                    await PolicyDecisionRouting.publishNotice(
                                        PolicyUserEventFactory.jobSchedulingFailed(
                                            toolName: toolName,
                                            reason: "The job could not be scheduled.",
                                            detail: error.localizedDescription,
                                            correlationId: sessionID
                                        )
                                    )
                                }
                                throw error
                            }
                            let toolWallMS = PipelineTiming.elapsedMS(from: toolStarted)
                            aggregatedToolCalls.append(contentsOf: toolExecution.records)
                            for record in toolExecution.records where FactoryTurnGate.isPipelineTool(record.name) {
                                debugLog(
                                    FactoryAttemptLog.describe(
                                        tool: record.name,
                                        arguments: record.arguments,
                                        result: record.result
                                    )
                                )
                            }
                            let slimFollowUpBody = ToolFollowUpFormatter.slimToolResults(records: toolExecution.records)
                            let slimRequestLine = ToolFollowUpFormatter.slimToolRequestLine(records: toolExecution.records)
                            await MainActor.run {
                                // Full wire result for debug only; agent follow-up uses slim body.
                                debugLog(
                                    "Tool result full summaryChars=\(toolExecution.summary.count) records=\(toolExecution.records.count) slimFollowUpChars=\(slimFollowUpBody.count)\n\(toolExecution.summary)"
                                )
                            }
                            PipelineTiming.log(
                                "\(roundLabel) tool wall_ms=\(toolWallMS) parse_ms=\(parseToolMS) limit_ms=\(toolLimitMS) usage_ms=\(usageMS) records=\(toolExecution.records.count) summary_chars=\(toolExecution.summary.utf8.count) slim_followup_chars=\(slimFollowUpBody.utf8.count) names=\(toolExecution.records.map(\.name).joined(separator: ","))"
                            )

                            if let hookResult = toolExecution.records.reversed().compactMap({ record -> String? in
                                guard record.name == "plugin.invoke" else { return nil }
                                let raw = record.result ?? ""
                                return PluginHookPresentation.decodeOpenFactory(raw) == nil ? nil : raw
                            }).first {
                                continuation.yield(
                                    AgentResponseNextChunk(
                                        status: .complete,
                                        chunk: hookResult
                                    )
                                )
                                PipelineTiming.log("\(roundLabel) plugin_hook_complete")
                                break
                            }

                            if let promoteTest = toolExecution.records.reversed().compactMap({ record -> PluginInvokePresentation.TestReport? in
                                guard record.name == FactoryTurnGate.factoryPromote
                                    || record.name == FactoryTurnGate.factoryInstallSample else {
                                    return nil
                                }
                                return PluginInvokePresentation.testReport(fromPromoteResult: record.result ?? "")
                            }).first {
                                continuation.yield(
                                    AgentResponseNextChunk(
                                        status: .complete,
                                        chunk: PluginInvokePresentation.encodeTestReport(promoteTest)
                                    )
                                )
                                PipelineTiming.log(
                                    "\(roundLabel) factory_test_complete plugin=\(promoteTest.heading) kind=\(promoteTest.kind.rawValue)"
                                )
                                break
                            }

                            let followUpStarted = Date()
                            if let factoryFollowUp = FactoryTurnGate.continuationPrompt(
                                sessionID: sessionID,
                                originalPrompt: prompt,
                                assistantToolRequest: slimRequestLine,
                                toolResultSummary: slimFollowUpBody,
                                records: aggregatedToolCalls
                            ) {
                                workingPrompt = factoryFollowUp
                            } else {
                                workingPrompt = Self.buildFollowUpPrompt(
                                    originalPrompt: prompt,
                                    assistantToolRequest: slimRequestLine,
                                    toolResultSummary: slimFollowUpBody
                                )
                            }
                            let followUpBuildMS = PipelineTiming.elapsedMS(from: followUpStarted)
                            PipelineTiming.log(
                                "\(roundLabel) followup_build_ms=\(followUpBuildMS) followup_chars=\(workingPrompt.utf8.count) slim_result_chars=\(slimFollowUpBody.utf8.count) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted))"
                            )
                            continue
                        }

                        if agentResponse?.status == .toolCall || agentResponse?.status == .toolBatch {
                            await MainActor.run {
                                debugLog("Tool request payload failed strict schema validation")
                            }
                            PipelineTiming.log(
                                "\(roundLabel) tool_payload_invalid round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted))"
                            )
                            continue
                        }

                        if let factoryFollowUp = FactoryTurnGate.continuationPrompt(
                            sessionID: sessionID,
                            originalPrompt: prompt,
                            assistantToolRequest: nil,
                            toolResultSummary: nil,
                            records: aggregatedToolCalls
                        ) {
                            await MainActor.run {
                                debugLog("Factory session incomplete — continuing to next required tool")
                            }
                            PipelineTiming.log(
                                "\(roundLabel) factory_continue usage_ms=\(usageMS) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted)) tool_records=\(aggregatedToolCalls.count)"
                            )
                            workingPrompt = factoryFollowUp
                            continue
                        }

                        if !streamedVisibleContent {
                            let text = interceptedCompletion.trimmingCharacters(in: .whitespacesAndNewlines)
                            if text.isEmpty {
                                await MainActor.run {
                                    debugLog("Chunk final complete (empty — nothing to show)")
                                }
                            } else {
                                await MainActor.run {
                                    debugLog("Chunk final complete (\(text.count) chars)")
                                }
                                continuation.yield(AgentResponseNextChunk(status: .complete, chunk: interceptedCompletion))
                            }
                        }

                        PipelineTiming.log(
                            "\(roundLabel) final_complete usage_ms=\(usageMS) round_total_ms=\(PipelineTiming.elapsedMS(from: roundStarted)) turn_total_ms=\(PipelineTiming.elapsedMS(from: overallStarted)) tool_records=\(aggregatedToolCalls.count)"
                        )
                        let ingestStarted = Date()
                        try? await memoryCoordinator.ingest(
                            MemoryIngestInput(
                                sessionKey: sessionKey,
                                parentAgentID: parentAgentID,
                                prompt: prompt,
                                completion: fullCompletion,
                                toolCalls: aggregatedToolCalls,
                                scope: scope
                            )
                        )
                        PipelineTiming.log(
                            "turn_complete ingest_ms=\(PipelineTiming.elapsedMS(from: ingestStarted)) turn_total_ms=\(PipelineTiming.elapsedMS(from: overallStarted)) tool_records=\(aggregatedToolCalls.count)"
                        )
                        break
                    }

                    continuation.finish()
                } catch {
                    PipelineTiming.log("turn_error turn_total_ms=\(PipelineTiming.elapsedMS(from: overallStarted)) error=\(error.localizedDescription)")
                    await MainActor.run {
                        debugLog("Error occurred during streaming: \(error)")
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { reason in
                // Cancelling on normal finish races nested consumers and can drop all yields.
                if case .cancelled = reason {
                    task.cancel()
                }
            }
        }
    }
    
    /// Decode a finished model completion. Prefer full JSONSerialization over PartialJSON mid-stream state.
    private static func decodeAgentResponse(from completion: String, decoder: JSONDecoder) -> AgentResponse? {
        let trimmed = completion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let response = try? decoder.decode(AgentResponse.self, from: data) {
            return response
        }

        // Fallback: PartialJSON → object → Data → decode (only when top-level is a JSON object/array).
        if let jsonAny = try? PartialJSON.parse(trimmed),
           JSONSerialization.isValidJSONObject(jsonAny),
           let data = try? JSONSerialization.data(withJSONObject: jsonAny, options: []),
           let response = try? decoder.decode(AgentResponse.self, from: data) {
            return response
        }

        return nil
    }

    private static func getFullCompletion(_ agentResponse: AgentResponse?, jsonEncoder: JSONEncoder) -> String {
        if agentResponse == nil {
            return ""
        }
        
        if agentResponse?.status == .complete {
            return agentResponse?.assistantResponse ?? ""
        } else if agentResponse?.status == .toolCall {
            if let toolCallData = try? jsonEncoder.encode(agentResponse?.toolCall) {
                return String(data: toolCallData, encoding: .utf8) ?? ""
            }
        } else if agentResponse?.status == .toolBatch {
            if let toolBatchData = try? jsonEncoder.encode(agentResponse?.toolBatch) {
                return String(data: toolBatchData, encoding: .utf8) ?? ""
            }
        } else if agentResponse?.status == .thinking {
            return agentResponse?.thought ?? ""
        }
        
        return ""
    }

    private static func formatLLMRequest(_ request: AgentRequest, round: Int) -> String {
        let messages = request.messages.enumerated().map { index, message in
            "[\(index)] \(message.role.rawValue):\n\(preview(message.content))"
        }
        return "LLM request (round \(round)):\n" + messages.joined(separator: "\n\n")
    }

    private static func preview(_ content: String) -> String {
        guard content.count > 40 else {
            return content
        }
        return String(content.prefix(37)) + "..."
    }

    private static func formatLLMResponse(_ completion: String, round: Int) -> String {
        "LLM response (round \(round)):\n\(completion)"
    }

    private func executeToolRequest(
        _ request: ParsedToolRequest?,
        sessionID: String,
        userPrompt: String?,
        approvalPresenter: (any ApprovalConfirmationPresenting)?
    ) async throws -> (summary: String, records: [ToolCallRecord]) {
        guard let request else {
            return (
                """
                Tool call payload could not be parsed, so nothing ran. Do not tell the user a job was scheduled or completed. \
                Ask them to retry, or schedule again with a simpler one-line script.
                """,
                []
            )
        }
        
        switch request {
        case .single(let single):
            let result: MCPToolResult
            do {
                result = try await callToolWithPolicyInterception(
                    named: single.toolName,
                    arguments: single.arguments ?? [:],
                    sessionID: sessionID,
                    userPrompt: userPrompt,
                    approvalPresenter: approvalPresenter
                )
            } catch {
                let text = error.localizedDescription
                return (
                    "\(single.toolName): \(text)",
                    [ToolCallRecord(
                        name: single.toolName,
                        arguments: Self.toolCallRecordArguments(from: single.arguments ?? [:]),
                        result: text
                    )]
                )
            }

            let record = ToolCallRecord(
                name: single.toolName,
                arguments: Self.toolCallRecordArguments(from: single.arguments ?? [:]),
                result: result.text
            )
            let summary = "\(single.toolName): \(result.content)"
            return (summary, [record])
        case .batch(let batchRequest):
            let batchResult = try await batchCallToolsWithPolicyInterception(
                batchRequest,
                sessionID: sessionID,
                userPrompt: userPrompt,
                approvalPresenter: approvalPresenter
            )
            let records = zip(batchRequest.invocations, batchResult.results).map { invocation, result in
                ToolCallRecord(
                    name: invocation.toolName,
                    arguments: Self.toolCallRecordArguments(from: invocation.arguments),
                    result: result.text
                )
            }
            return (batchResult.combinedContent, records)
        }
    }
    
    private static func mcpToolBatchRequest(_ agentResponse: AgentResponse?) throws -> MCPToolBatchRequest? {
        guard let agentResponse = agentResponse else {
            return nil
        }
                
        var mcpToolInvocations: [MCPToolInvocation] = []
        for tool in agentResponse.toolBatch?.tools ?? [] {
            mcpToolInvocations.append(MCPToolInvocation(name: tool.toolName ?? "", arguments: try toolArgumentsFromJSON(tool.arguments ?? "")))
        }
        
        return MCPToolBatchRequest(invocations: mcpToolInvocations, filterQuery: nil)
    }
    
    private static func mcpSingleToolRequest(_ agentResponse: AgentResponse?) throws -> MCPSingleToolRequest? {
        guard let agentResponse = agentResponse else {
            return nil
        }
        let toolName = agentResponse.toolCall?.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !toolName.isEmpty else {
            return nil
        }

        let rawArguments = agentResponse.toolCall?.arguments ?? ""
        // Shared resilient parser (handles illegal escapes like `\$` in model-emitted scripts).
        let arguments = try parseToolArgumentsObject(rawArguments)

        return MCPSingleToolRequest(
            toolName: toolName,
            arguments: arguments
        )
    }

    private static func isJobSchedulingTool(_ name: String) -> Bool {
        name == "jobs_create" || name == "jobs_schedule_create"
    }

    private static func jobSchedulingToolNames(in response: AgentResponse?) -> [String] {
        guard let response else { return [] }
        if response.status == .toolCall {
            let name = response.toolCall?.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isJobSchedulingTool(name) ? [name] : []
        }
        if response.status == .toolBatch {
            let names = (response.toolBatch?.tools ?? []).compactMap { tool -> String? in
                let name = tool.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return isJobSchedulingTool(name) ? name : nil
            }
            return names
        }
        return []
    }

    private static func parseToolPayload(_ agentResponse: AgentResponse?) -> ParsedToolRequest? {
        guard let agentResponse = agentResponse else {
            return nil
        }

        if let batch = try? mcpToolBatchRequest(agentResponse),
           !batch.invocations.isEmpty {
            return .batch(batch)
        }

        do {
            if let single = try mcpSingleToolRequest(agentResponse),
               !single.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .single(single)
            }
        } catch {
            // Keep nil so executeToolRequest reports a clear message; error is logged by caller preview.
            debugLog("parseToolPayload single failed: \(error.localizedDescription)")
            return nil
        }

        return nil
    }

    /// Builds the round-2+ user message. `toolResultSummary` must already be slimmed for the model
    /// (`ToolFollowUpFormatter`); full tool JSON is logged separately before this is called.
    /// Publishes the current plan as a full snapshot. The UI replaces `thought`; it must not append.
    @discardableResult
    private static func publishThoughtSnapshot(
        _ thought: String,
        lastPublished: inout String,
        continuation: AsyncThrowingStream<AgentResponseNextChunk, Error>.Continuation
    ) -> Bool {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastPublished else { return false }
        lastPublished = trimmed
        continuation.yield(AgentResponseNextChunk(status: .thinking, chunk: trimmed))
        return true
    }

    private static func buildFollowUpPrompt(
        originalPrompt: String,
        assistantToolRequest: String,
        toolResultSummary: String
    ) -> String {
        """
        Original user prompt:
        \(originalPrompt)

        You requested the following tool call:
        \(assistantToolRequest)

        Tool execution result (stdout/stderr only; internal review/timing fields omitted):
        \(toolResultSummary)

        Produce the final user-facing response using the tool execution result as authoritative.
        Do not say you cannot fetch live data if the tool result contains live data.
        Do not ask the user whether to run a command that has already run.
        When presenting a list of choices, options, steps, items, or alternative paths to the user, ALWAYS format them as a clean Markdown bulleted list (using `-` or `*`) or a numbered list (using `1.`, `2.`), instead of writing them as plain paragraphs.
        Use the JSON schema to respond. Set status to "complete" and populate the assistant_response field.
        """
    }

    private static func toolCallRecordArguments(from arguments: [String: Value]) -> [String: String] {
        var mapped: [String: String] = [:]
        for (key, value) in arguments {
            mapped[key] = describe(value: value)
        }
        return mapped
    }

    private static func describe(value: Value) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .string(let string):
            return string
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let array):
            return "[" + array.map(describe(value:)).joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { key in
                "\(key): \(describe(value: object[key] ?? .null))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }
}

private enum ParsedToolRequest {
    case single(MCPSingleToolRequest)
    case batch(MCPToolBatchRequest)
}

private enum ToolProbeStreamingState {
    case undecided(buffer: String)
    case toolRequest
    case prose(prefix: String)
}
