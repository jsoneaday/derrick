import AppKit
import Combine
import DBRepository
import Structure
import SwiftUI

@MainActor
final class DebugLogsViewModel: ObservableObject {
    @Published private(set) var selectedService: String?
    @Published private(set) var isRefreshing = false
    @Published var autoScroll = true

    private var repository: DBRepository?
    private var pollTask: Task<Void, Never>?
    private var lastPolledAt: Date?

    let knownServices = ["ui", "agent", "mcp", "daemon", "job", "connector", "messaging", "docker"]

    func configure(repository: DBRepository?) {
        self.repository = repository
        pollTask?.cancel()
        guard repository != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(full: false)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(full: Bool) async {
        guard let repository else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if full || lastPolledAt == nil {
                let batch = try await repository.recentServiceLogs(
                    service: selectedService,
                    limit: 2_000
                )
                let ordered = batch.sorted { $0.createdAt < $1.createdAt }
                DebugLogStore.shared.mergePersisted(ordered)
                lastPolledAt = ordered.last?.createdAt
            } else if let lastPolledAt {
                let batch = try await repository.serviceLogs(
                    createdAfter: lastPolledAt,
                    service: selectedService,
                    limit: 500
                )
                if !batch.isEmpty {
                    DebugLogStore.shared.mergePersisted(batch)
                    self.lastPolledAt = batch.last?.createdAt ?? lastPolledAt
                }
            }
        } catch {
            DebugLogStore.shared.log(
                "Debug log refresh failed: \(error.localizedDescription)",
                code: "debug-refresh",
                level: .warning
            )
        }
    }

    func selectService(_ service: String?) {
        selectedService = service
        lastPolledAt = nil
        Task { await refresh(full: true) }
    }
}

struct DebugLogsView: View {
    let repository: DBRepository?

    @ObservedObject private var logStore = DebugLogStore.shared
    @StateObject private var viewModel = DebugLogsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            serviceFilter
            DebugLogTextView(text: logStore.fullText, autoScrollToEnd: viewModel.autoScroll)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
        .onAppear {
            viewModel.configure(repository: repository)
            Task { await viewModel.refresh(full: true) }
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Debug Logs")
                    .font(.system(size: 22, weight: .semibold))
                Text("Persistent logs from UI, daemon, agent, MCP, and messaging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $viewModel.autoScroll)
                .toggleStyle(.checkbox)
            Button("Refresh") {
                Task { await viewModel.refresh(full: true) }
            }
            Button("Copy All") {
                copyToPasteboard(logStore.fullText)
            }
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var serviceFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", service: nil)
                ForEach(viewModel.knownServices, id: \.self) { service in
                    filterChip(title: service, service: service)
                }
            }
        }
    }

    private func filterChip(title: String, service: String?) -> some View {
        let selected = viewModel.selectedService == service
        return Button(title) {
            viewModel.selectService(service)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            selected ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.05),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
