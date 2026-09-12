import SwiftUI

/// Placeholder Chat-tab body for Present pipes that are not conversation or thread yet.
struct PluginPresentTabBody: View {
    let surface: ChatTabSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0))
    }

    private var title: String {
        switch surface {
        case .generatedView: return "Generated view"
        case .file: return "File"
        case .image: return "Image"
        case .conversation, .thread: return "Chat"
        }
    }

    private var detail: String {
        switch surface {
        case .generatedView:
            return "This plugin’s result will show as a view you can scan in this Chat tab."
        case .file:
            return "This plugin’s result will show as a file in this Chat tab."
        case .image:
            return "This plugin’s result will show as an image in this Chat tab."
        case .conversation, .thread:
            return ""
        }
    }
}
