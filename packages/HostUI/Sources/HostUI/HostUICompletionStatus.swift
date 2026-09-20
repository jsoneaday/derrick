import Structure
import SwiftUI

/// In-flight status used by chat and messaging (pulsing ellipsis + label chip).
public struct HostUICompletionStatus: View {
    public var status: String
    public var toolName: String?

    @State private var isVisible = false

    public init(status: String, toolName: String? = nil) {
        self.status = status
        self.toolName = toolName
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.35 + ((sin(t * 6) + 1) * 0.325)
            HStack(spacing: 8) {
                Text("…")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(pulse)
                Text(Self.label(status: status, toolName: toolName))
                    .id(status)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.black.opacity(0.06), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 2)
            .animation(.easeOut(duration: 0.18), value: status)
            .animation(.easeOut(duration: 0.18), value: isVisible)
            .onAppear {
                isVisible = true
            }
        }
        .padding(.top, 5)
        .padding(.bottom, 6)
        .accessibilityLabel(Self.label(status: status, toolName: toolName))
        .accessibilityAddTraits(.updatesFrequently)
    }

    public static func label(status: String, toolName: String? = nil) -> String {
        let base = agentResponseStatusLabel(status: status)
        guard let toolName, !toolName.isEmpty else { return base }
        return "\(base) \(toolName)"
    }
}

#Preview("Chat thinking") {
    HostUICompletionStatus(status: "Thinking...", toolName: nil)
        .padding()
        .background(Color(red: 248.0 / 255.0, green: 244.0 / 255.0, blue: 240.0 / 255.0))
}

#Preview("Agent working") {
    HostUICompletionStatus(status: "Working…", toolName: nil)
        .padding()
        .background(Color(red: 248.0 / 255.0, green: 244.0 / 255.0, blue: 240.0 / 255.0))
}
