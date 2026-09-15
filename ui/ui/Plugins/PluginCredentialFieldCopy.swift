import Foundation

enum PluginCredentialFieldCopy {
    static let keepSavedValuePlaceholder = "Leave blank to keep saved value"

    static func storedValueCaption(hasStoredValue: Bool) -> String? {
        hasStoredValue ? "A value is already saved. Leave the field blank to keep it." : nil
    }

    /// Do not put a Keychain or .env secret into the field. That draws a second
    /// bullet row next to the saved-value hint.
    static func draftValue(hasStoredValue: Bool, developmentValue: String?) -> String {
        if hasStoredValue { return "" }
        return developmentValue ?? ""
    }
}
