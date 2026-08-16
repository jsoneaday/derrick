import Foundation
import ServiceContracts

/// Shipped first sample. No auth. One public news HTML page via host HTTP.
public enum DailyNewsSample: Sendable {
    public static let pluginID = "daily-news"
    public static let version = "1.0.0"
    public static let description = "Headlines from one public news site. Optional topic and max article count."

    public static var handle: String {
        DerrickGuestTypeScript.registerPluginResourceBundle()
        return DerrickBundledText.mustLoad("guest/daily-news.ts")
    }

    public static func draft() -> FactoryPackageDraft {
        FactoryPackageDraft(
            goal: "Daily headlines from one public news site. No login.",
            pluginID: pluginID,
            version: version,
            description: description,
            handle: handle,
            volumeEnabled: false,
            fixturesJSON: #"[{"kind":"test","params":{"topic":"technology","max":5}}]"#
        )
    }
}
