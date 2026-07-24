import SwiftUI
import PolicyUserInteraction

/// Shared body/footer content for policy notify & approve modals.
struct PolicyEventModalHeader: View {
    let event: PolicyUserEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(event.title)
                .font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var iconName: String {
        switch event.kind {
        case .failure: return "exclamationmark.triangle.fill"
        case .approvalRequired: return "hand.raised.fill"
        case .notice: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .failure: return .orange
        case .approvalRequired: return .accentColor
        case .notice: return .secondary
        }
    }
}

struct PolicyEventModalBody: View {
    let event: PolicyUserEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if let toolName = event.toolName, !toolName.isEmpty {
                labeled("Tool", toolName)
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = event.payloadPreview, !preview.isEmpty {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(title):")
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct PolicyEventModalFooter: View {
    let event: PolicyUserEvent
    let onDismiss: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack {
            Spacer()
            switch event.kind {
            case .failure, .notice:
                Button("OK", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            case .approvalRequired:
                Button("Deny", role: .cancel, action: onDeny)
                Button("Allow", action: onApprove)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}
