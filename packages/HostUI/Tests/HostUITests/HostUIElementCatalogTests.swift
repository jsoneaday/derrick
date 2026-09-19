import HostUI
import Structure
import Testing

@Suite struct HostUIElementCatalogTests {
    @Test func elementIDsMatchBundledLibrary() throws {
        let libraryIDs = try HostUILibraryStore.elementIDs()
        for id in HostUIElementID.allCases {
            #expect(libraryIDs.contains(id.rawValue), "Missing library id \(id.rawValue)")
        }
        for libraryID in libraryIDs {
            #expect(HostUIElementID(rawValue: libraryID) != nil, "HostUI missing \(libraryID)")
        }
    }
}
