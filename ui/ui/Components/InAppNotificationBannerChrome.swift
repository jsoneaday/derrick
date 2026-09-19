import SwiftUI

/// Shared look for floating / in-app notification surfaces (job results, inbound toasts).
enum InAppNotificationKind: Equatable {
    case message
    case success
    case warning
    case failure
    case info

    var symbolName: String {
        switch self {
        case .message: return "bubble.left.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var accent: Color {
        switch self {
        case .message:
            return Color(red: 0.176, green: 0.286, blue: 0.576)
        case .success:
            return Color(red: 0.15, green: 0.48, blue: 0.32)
        case .warning:
            return Color(red: 0.72, green: 0.48, blue: 0.18)
        case .failure:
            return Color(red: 0.72, green: 0.22, blue: 0.18)
        case .info:
            return Color(red: 0.176, green: 0.286, blue: 0.576)
        }
    }
}

enum InAppNotificationBannerChrome {
    static let fill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    /// Pill-like continuous corners (matches sub-tab language without forcing a true Capsule on tall cards).
    static let cornerRadius: CGFloat = 22
}

/// Compact toast used for inbound messaging alerts.
struct InAppNotificationToast: View {
    let text: String
    var kind: InAppNotificationKind = .message
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(kind.accent)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 520, alignment: .leading)
            .background(InAppNotificationBannerChrome.fill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(kind.accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

extension View {
    /// Link / hand pointer when this attributed string contains tappable links.
    @ViewBuilder
    func linkPointerStyle(ifPresentIn attributed: AttributedString) -> some View {
        if attributed.runs.contains(where: { $0.link != nil }) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }

    /// Same as above for markdown source that may parse to links.
    func linkPointerStyle(forMarkdown markdown: String) -> some View {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let attributed = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        return linkPointerStyle(ifPresentIn: attributed)
    }
}
