import Testing
@testable import ui

@Suite struct InAppNotificationBannerChromeTests {
    @Test func kindsExposeDistinctSymbolsAndAccents() {
        let kinds: [InAppNotificationKind] = [.message, .success, .warning, .failure, .info]
        let symbols = Set(kinds.map(\.symbolName))
        #expect(symbols.count == kinds.count)
        #expect(InAppNotificationKind.message.symbolName.contains("bubble"))
        #expect(InAppNotificationKind.failure.symbolName.contains("octagon"))
        #expect(InAppNotificationBannerChrome.cornerRadius >= 16)
    }
}
