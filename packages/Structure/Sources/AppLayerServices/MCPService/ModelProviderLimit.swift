import Foundation

/// A model-provider spend or rate limit. Any screen can hit this.
public enum ModelProviderLimit: Sendable {
    public static let summary = """
    The model provider refused the request because this project has reached its \
    spend or rate limit. Raise the limit, then try again.
    """

    public static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("http 429")
            || lower.contains("insufficient_quota")
            || lower.contains("spend limit")
            || lower.contains("rate limit")
            || lower.contains("rate_limit")
            || lower.contains("spend or rate limit")
    }
}
