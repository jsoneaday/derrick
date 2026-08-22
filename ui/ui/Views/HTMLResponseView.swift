import AppKit
import SwiftUI

struct HTMLResponseView: View {
    let html: String

    var body: some View {
        Text(attributedString)
            .font(.system(size: 15))
            .tint(.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var attributedString: AttributedString {
        let sanitized = HTMLSanitizer.sanitize(html)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let native = try? NSAttributedString(
            data: Data(sanitized.utf8),
            options: options,
            documentAttributes: nil
        )
        else {
            return AttributedString(HTMLSanitizer.plainText(html))
        }
        return AttributedString(native)
    }
}
