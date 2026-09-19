import SwiftUI

public struct HostUICalendar: View {
    private let label: String?
    @Binding private var date: Date

    public init(label: String? = nil, date: Binding<Date>) {
        self.label = label
        self._date = date
    }

    public var body: some View {
        HostUISection(title: label) {
            DatePicker(
                label ?? "Date",
                selection: $date,
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.field)
        }
    }
}
