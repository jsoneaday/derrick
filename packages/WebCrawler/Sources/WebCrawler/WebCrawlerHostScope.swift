import Foundation
import Structure

actor WebCrawlerHostScope {
  private var allowedHosts: Set<String>

  init(initialHosts: Set<String>) {
    self.allowedHosts = Set(initialHosts.map { $0.lowercased() })
  }

  func contains(_ host: String) -> Bool {
    allowedHosts.contains(host.lowercased())
  }

  func add(_ host: String) {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return }
    allowedHosts.insert(normalized)
  }

  func snapshot() -> Set<String> {
    allowedHosts
  }
}
