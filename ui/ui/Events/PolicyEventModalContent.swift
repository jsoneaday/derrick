import SwiftUI
import PolicyUserInteraction

/// Shared chrome for policy / system modals (icons + actions) matching the app’s neutral UI.
enum ModalChrome {
    /// Outline symbols + hierarchical rendering read more modern than heavy `.fill` glyphs.
    static func symbolName(for kind: PolicyEventKind) -> String {
        switch kind {
        case .failure:
            return "exclamationmark.circle"
        case .approvalRequired:
            return "checkmark.shield"
        case .networkAccessRequest:
            return "network"
        case .usageLimitRequest:
            return "gauge.with.dots.needle.67percent"
        case .notice:
            return "info.circle"
        }
    }

    static let bootstrapFailureSymbol = "exclamationmark.circle"
    static let bootstrapReadySymbol = "checkmark.circle"

    static func symbolColor(for kind: PolicyEventKind) -> Color {
        switch kind {
        case .failure:
            return Color(red: 0.72, green: 0.48, blue: 0.18)
        case .approvalRequired, .networkAccessRequest, .usageLimitRequest:
            return Color(red: 0.176, green: 0.286, blue: 0.576)
        case .notice:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    static let failureSymbolColor = Color(red: 0.72, green: 0.48, blue: 0.18)

    static var symbolFont: Font {
        .system(size: 17, weight: .medium)
    }
}

/// Shared body/footer content for policy notify & approve modals.
struct PolicyEventModalHeader: View {
    let event: PolicyUserEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ModalChrome.symbolName(for: event.kind))
                .font(ModalChrome.symbolFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ModalChrome.symbolColor(for: event.kind))
            Text(event.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

struct PolicyEventModalBody: View {
    let event: PolicyUserEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let toolName = event.toolName, !toolName.isEmpty {
                labeled("Tool", toolName)
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let preview = event.payloadPreview, !preview.isEmpty {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(title):")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct PolicyEventModalFooter: View {
    let event: PolicyUserEvent
    let onDismiss: () -> Void
    let onApprove: () -> Void
    let onApproveOnce: () -> Void
    let onApproveAlways: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch event.kind {
            case .failure, .notice:
                Button("OK", action: onDismiss)
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            case .approvalRequired:
                Button("Deny", action: onDeny)
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: onApprove)
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .networkAccessRequest:
                Button("Deny", action: onDeny)
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(
                    event.rememberKey?.hasPrefix("egress.blacklist.") == true ? "This run" : "Allow once",
                    action: onApproveOnce
                )
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .lineLimit(1)
                Button("Always", action: onApproveAlways)
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .usageLimitRequest:
                EmptyView()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}

// MARK: - Neutral modal buttons (no system accent blue)

struct ModalPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.68 : 0.85))
            )
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }
}

struct ModalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.08 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .foregroundStyle(Color(nsColor: .labelColor))
    }
}
