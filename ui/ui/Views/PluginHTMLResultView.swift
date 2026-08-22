import SwiftUI

struct PluginHTMLResultView: View {
    let payload: PluginHTMLPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = payload.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(HTMLSanitizer.plainText(title))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HTMLResponseView(html: payload.html)
        }
    }
}
