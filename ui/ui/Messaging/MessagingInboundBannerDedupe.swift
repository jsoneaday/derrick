import Foundation
import Structure

/// Stable keys for inbound in-app toast dedupe (session lifetime).
enum MessagingInboundBannerDedupe {
    static func key(for message: MessagingMessageDTO) -> String {
        let thread = message.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let vendor = message.vendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !vendor.isEmpty {
            return "\(thread)#v:\(vendor)"
        }
        return "\(thread)#id:\(message.id)"
    }

    static func freshKeys(current: Set<String>, alreadyPresented: Set<String>) -> Set<String> {
        current.subtracting(alreadyPresented)
    }
}
