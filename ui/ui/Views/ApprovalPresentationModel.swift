//
//  ApprovalPresentationModel.swift
//  ui
//
//  Created by David Choi on 7/4/26.
//

import SwiftUI
import Combine

@MainActor
final class ApprovalPresentationModel: ObservableObject, ApprovalConfirmationPresenting {
    private enum Constants {
        static let timeoutNanoseconds: UInt64 = 60_000_000_000
    }

    @Published var pendingRequest: ApprovalConfirmationRequest?
    @Published var editedArgumentsJSON = ""
    @Published var actor = "ui-user"
    @Published var validationError: String?

    private var continuation: CheckedContinuation<ApprovalConfirmationDecision, Never>?
    private var timeoutTask: Task<Void, Never>?

    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        editedArgumentsJSON = request.argumentsJSON
        actor = "ui-user"
        validationError = nil
        pendingRequest = request
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Constants.timeoutNanoseconds)
            await self?.expirePendingApproval(requestID: request.id)
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func approve() {
        guard let data = editedArgumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              json is [String: Any] else {
            validationError = "Arguments must be a valid JSON object."
            return
        }

        let actorValue = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation?.resume(returning: .approved(
            editedArgumentsJSON: editedArgumentsJSON,
            actor: actorValue.isEmpty ? nil : actorValue
        ))
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        pendingRequest = nil
        validationError = nil
    }

    func cancel() {
        let actorValue = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation?.resume(returning: .cancelled(actor: actorValue.isEmpty ? nil : actorValue))
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        pendingRequest = nil
        validationError = nil
    }

    private func expirePendingApproval(requestID: String) {
        guard pendingRequest?.id == requestID else {
            return
        }
        continuation?.resume(returning: .cancelled(actor: "system-timeout"))
        timeoutTask = nil
        continuation = nil
        pendingRequest = nil
        validationError = nil
        debugLog("Approval request expired after timeout.")
    }
}
