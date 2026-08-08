import AppKit
import Combine
import DBRepository
import Foundation
import SwiftUI

/// Presents scheduled-job completion content in a centered themed modal (notification tap).
@MainActor
final class JobResultPresenter: ObservableObject {
    static let shared = JobResultPresenter()

    @Published private(set) var activeResult: PresentedJobResult?
    @Published private(set) var isPresented = false

    struct PresentedJobResult: Identifiable, Equatable {
        let id: String
        let jobID: String
        let responseText: String
        let createdAt: Date
        let scheduledAt: Date?
    }

    private init() {}

    func present(row: DBRepository.JobResultRow, scheduledAt: Date? = nil) {
        activeResult = PresentedJobResult(
            id: row.id,
            jobID: row.jobID,
            responseText: row.responseText,
            createdAt: row.createdAt,
            scheduledAt: scheduledAt
        )
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        isPresented = false
        activeResult = nil
    }
}

struct JobResultModalHeader: View {
    var shortID: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(ModalChrome.symbolFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(red: 0.176, green: 0.286, blue: 0.576))
            VStack(alignment: .leading, spacing: 2) {
                Text("Derrick · Job finished")
                    .font(.headline)
                    .lineLimit(1)
                if let shortID, !shortID.isEmpty {
                    Text("Result \(shortID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

struct JobResultModalBody: View {
    let result: JobResultPresenter.PresentedJobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let scheduledAt = result.scheduledAt {
                Text("Scheduled for \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                MarkdownResponseView(
                    text: result.responseText.trimmingCharacters(in: .whitespacesAndNewlines),
                    allowsCSVExport: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

struct JobResultModalFooter: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button("OK", action: onDismiss)
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}
