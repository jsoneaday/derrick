import Structure
import Testing

@Suite struct DerrickGoToolchainTests {
    @Test func minimumVersionIsPinned() {
        #expect(DerrickGoToolchain.minimumVersion == "1.27.1")
    }

    @Test func ensureInstalledAcceptsCurrentGo() throws {
        try DerrickGoToolchain.ensureInstalled()
    }
}
