import SwiftUI

public struct HostUISelectOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct HostUISelect: View {
    private let label: String?
    private let options: [HostUISelectOption]
    @Binding private var selection: String

    public init(
        label: String? = nil,
        options: [HostUISelectOption],
        selection: Binding<String>
    ) {
        self.label = label
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HostUISection(title: label) {
            Picker(label ?? "Select", selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
