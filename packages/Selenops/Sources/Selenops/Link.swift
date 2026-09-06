import Foundation

extension Crawler {
    /// Represents a link containing a URL, title, and similarity score.
    public struct Link: Hashable, Sendable {
        public var url: URL
        public var title: String
        public var score: Double?

        public init(url: URL, title: String, score: Double? = nil) {
            self.url = url
            self.title = title
            self.score = score
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(url)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.url == rhs.url
        }
    }
}
