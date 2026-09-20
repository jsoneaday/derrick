import SwiftUI

/// Temporary in-flight chip. Replace with the shared chat status control in Phase 1b.
public struct HostUIAgentWorkIndicator: View {
    public let status: String

    public init(status: String) {
        self.status = status
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.35 + ((sin(t * 6) + 1) * 0.325)
            HStack(spacing: 8) {
                Text("…")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(pulse)
                Text(status)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.black.opacity(0.06), lineWidth: 1)
                    )
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel(status)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
