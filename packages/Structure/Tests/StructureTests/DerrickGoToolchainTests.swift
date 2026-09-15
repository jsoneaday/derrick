import Testing
@testable import Structure

@Suite struct DerrickGoToolchainTests {
    @Test func minimumVersionIsPinned() {
        #expect(DerrickGoToolchain.minimumVersion == "1.27.1")
    }

    @Test func parseVersionReadsGoVersionLine() {
        #expect(
            DerrickGoToolchain.parseVersion("go version go1.27.1 darwin/arm64") == "1.27.1"
        )
    }

    @Test func parseVersionRejectsEmptyOutput() {
        #expect(DerrickGoToolchain.parseVersion("") == nil)
        #expect(DerrickGoToolchain.parseVersion("go version") == nil)
    }

    @Test func versionSatisfiesAcceptsCurrentAndNewer() {
        #expect(DerrickGoToolchain.versionSatisfies("1.27.1", minimum: "1.27.1"))
        #expect(DerrickGoToolchain.versionSatisfies("1.28.0", minimum: "1.27.1"))
    }

    @Test func versionSatisfiesRejectsOlder() {
        #expect(!DerrickGoToolchain.versionSatisfies("1.27.0", minimum: "1.27.1"))
        #expect(!DerrickGoToolchain.versionSatisfies("1.26.9", minimum: "1.27.1"))
    }
}
