import Foundation

/// Curated vendor API notes injected into the plugin factory builder for messaging connectors.
enum PluginFactoryConnectorDocs {
    enum Vendor: String, Sendable {
        case slack
    }

    static func detectedVendor(for goal: String) -> Vendor? {
        let lower = goal.lowercased()
        if lower.contains("slack") {
            return .slack
        }
        return nil
    }

    static func supplementalPrompt(for goal: String) -> String? {
        guard let vendor = detectedVendor(for: goal) else { return nil }
        let doc: String
        switch vendor {
        case .slack:
            doc = (try? PromptResources.connectorVendorSlack()) ?? ""
        }
        guard !doc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return """
        The user goal targets a \(vendor.rawValue) messaging connector. Follow this vendor documentation exactly:

        \(doc)
        """
    }
}
