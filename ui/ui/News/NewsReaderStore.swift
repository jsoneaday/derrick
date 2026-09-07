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
    private let client: any NewsHTTPClient

    init(client: any NewsHTTPClient = URLSessionNewsHTTPClient()) {
        self.client = client
    }

    var selectedReader: NewsReaderSpec? {
        readers.first { $0.id == selectedReaderID }
    }

    func configure(repository: DBRepository) async {
        self.repository = repository
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
        let items = try await NewsReaderRefresh.validateAndFetch(spec: next, client: client)
        next.lastFetchedAt = .now
        next.lastError = nil
        try await repository.upsertNewsReader(next)
        try await repository.replaceNewsItems(readerID: next.id, items: items)
        await reload()
        selectedReaderID = next.id
        self.items = items
        return next
    }

    func refreshSelected() async {
        guard let repository, var reader = selectedReader else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await NewsReaderRefresh.validateAndFetch(spec: reader, client: client)
            reader.lastFetchedAt = .now
            reader.lastError = nil
            reader.updatedAt = .now
            try await repository.upsertNewsReader(reader)
            try await repository.replaceNewsItems(readerID: reader.id, items: fetched)
            items = fetched
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
