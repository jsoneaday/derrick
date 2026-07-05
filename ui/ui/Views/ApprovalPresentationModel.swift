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
    @Published var pendingRequest: ApprovalConfirmationRequest?
    @Published var editedArgumentsJSON = ""
    @Published var actor = "ui-user"
    @Published var validationError: String?

    private var continuation: CheckedContinuation<ApprovalConfirmationDecision, Never>?

    func confirm(_ request: ApprovalConfirmationRequest) async -> ApprovalConfirmationDecision {
        editedArgumentsJSON = request.argumentsJSON
        actor = "ui-user"
        validationError = nil
        pendingRequest = request

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
        continuation = nil
        pendingRequest = nil
        validationError = nil
    }

    func cancel() {
        let actorValue = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation?.resume(returning: .cancelled(actor: actorValue.isEmpty ? nil : actorValue))
        continuation = nil
        pendingRequest = nil
        validationError = nil
    }
}
