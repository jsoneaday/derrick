import Combine
import DBRepository
import Foundation
import Structure

@MainActor
final class NewsReaderStore: ObservableObject {
    static let shared = NewsReaderStore()

    @Published private(set) var readers: [NewsReaderSpec] = []
    @Published private(set) var items: [NewsItem] = []
    @Published var selectedReaderID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private var repository: DBRepository?
    private let worker: any NewsWorkerRunning
    private var summarizer: NewsReaderSummarizer?

    init(
        worker: any NewsWorkerRunning = MCPServiceNewsWorker(),
        summarizer: NewsReaderSummarizer? = nil
    ) {
        self.worker = worker
        self.summarizer = summarizer
    }

    func attachSummarizer(_ settings: LLMModelSettings) {
        self.summarizer = NewsReaderSummarizer(settings: settings)
    }

    var selectedReader: NewsReaderSpec? {
        readers.first { $0.id == selectedReaderID }
    }

    func configure(repository: DBRepository, summarizerSettings: LLMModelSettings? = nil) async {
        self.repository = repository
        if let summarizerSettings {
            attachSummarizer(summarizerSettings)
        }
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        do {
            readers = try await repository.listNewsReaders()
            if selectedReaderID == nil {
                selectedReaderID = readers.first?.id
            }
            if let id = selectedReaderID {
                items = try await repository.listNewsItems(readerID: id)
            } else {
                items = []
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func select(id: String) async {
        selectedReaderID = id
        await reloadItems()
        if let reader = selectedReader, shouldRefreshForSchedule(reader) {
            await refreshSelected()
        }
    }

    @discardableResult
    func create(_ spec: NewsReaderSpec) async throws -> NewsReaderSpec {
        guard let repository else {
            throw NewsReaderError.notReady
        }
        var next = spec
        next.updatedAt = .now
        let fetched = try await NewsReaderRefresh.validateAndFetch(
            spec: next,
            worker: worker,
            summarizer: summarizer
        )
        next.lastFetchedAt = .now
        next.lastError = nil
        next.summaryText = fetched.summaryText
        try await repository.upsertNewsReader(next)
        try await repository.replaceNewsItems(readerID: next.id, items: fetched.items)
        selectedReaderID = next.id
        self.items = fetched.items
        await reload()
        return next
    }

    func refreshSelected() async {
        guard let repository, var reader = selectedReader else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await NewsReaderRefresh.validateAndFetch(
                spec: reader,
                worker: worker,
                summarizer: summarizer
            )
            reader.lastFetchedAt = .now
            reader.lastError = nil
            reader.updatedAt = .now
            reader.summaryText = fetched.summaryText
            try await repository.upsertNewsReader(reader)
            try await repository.replaceNewsItems(readerID: reader.id, items: fetched.items)
            items = fetched.items
            lastError = nil
            await reload()
        } catch {
            reader.lastError = error.localizedDescription
            reader.updatedAt = .now
            try? await repository.upsertNewsReader(reader)
            lastError = error.localizedDescription
            await reload()
        }
    }

    func deleteSelected() async {
        guard let repository, let id = selectedReaderID else { return }
        try? await repository.deleteNewsReader(id: id)
        selectedReaderID = nil
        await reload()
    }

    private func reloadItems() async {
        guard let repository, let id = selectedReaderID else {
            items = []
            return
        }
        items = (try? await repository.listNewsItems(readerID: id)) ?? []
    }

    private func shouldRefreshForSchedule(_ reader: NewsReaderSpec) -> Bool {
        guard reader.schedule != .off else { return false }
        guard let last = reader.lastFetchedAt else { return true }
        switch reader.schedule {
        case .off:
            return false
        case .hourly:
            return Date().timeIntervalSince(last) >= 3_600
        case .daily:
            return Date().timeIntervalSince(last) >= 86_400
        }
    }
}
