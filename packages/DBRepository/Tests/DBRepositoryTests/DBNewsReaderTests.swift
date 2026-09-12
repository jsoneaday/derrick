import XCTest
import Structure
@testable import DBRepository

final class DBNewsReaderTests: XCTestCase {
    func testNewsReaderRoundTripAndItems() async throws {
        let repository = try makeRepository()
        _ = try await repository.createEmptyDatabaseIfNeeded(username: "app-user", password: "app-secret")

        let spec = NewsReaderSpec(
            name: "Markets",
            topics: ["Financial", "rates"],
            sources: [NewsSource(label: "BBC", url: "https://feeds.bbci.co.uk/news/world/rss.xml")],
            mode: .summary,
            maxCount: 10,
            schedule: .daily,
            summaryText: "Markets moved higher."
        )
        try await repository.upsertNewsReader(spec)
        let listed = try await repository.listNewsReaders()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].name, "Markets")
        XCTAssertEqual(listed[0].topics, ["Financial", "rates"])
        XCTAssertEqual(listed[0].mode, .summary)
        XCTAssertEqual(listed[0].summaryText, "Markets moved higher.")

        let item = NewsItem(
            readerID: spec.id,
            title: "Rates rise",
            sourceURL: "https://example.com/rates",
            sourceLabel: "BBC",
            summary: "A summary"
        )
        try await repository.replaceNewsItems(readerID: spec.id, items: [item])
        let items = try await repository.listNewsItems(readerID: spec.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sourceURL, "https://example.com/rates")

        try await repository.deleteNewsReader(id: spec.id)
        let remainingReaders = try await repository.listNewsReaders()
        let remainingItems = try await repository.listNewsItems(readerID: spec.id)
        XCTAssertTrue(remainingReaders.isEmpty)
        XCTAssertTrue(remainingItems.isEmpty)
    }

    private func makeRepository() throws -> DBRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DBRepository(
            configuration: DBRepositoryConfiguration(
                applicationName: "ui",
                databaseName: "derrick",
                databaseDirectoryURL: directory,
                username: "app-user",
                password: "app-secret"
            )
        )
    }
}
