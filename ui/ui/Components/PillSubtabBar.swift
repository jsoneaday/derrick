import SwiftUI

/// Standard in-panel sub-tab chrome: dark selected pill, light unselected pill.
struct PillSubtabBar<Tab: Hashable & Identifiable>: View where Tab.ID: Hashable {
    let tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String
    var accessibilityIdentifier: String? = nil

    private let chromeFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let selectedFill = Color(red: 0.18, green: 0.18, blue: 0.17)
    private let unselectedFill = Color.primary.opacity(0.06)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                pillButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(chromeFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "pill-subtabs")
    }

    private func pillButton(_ tab: Tab) -> some View {
        let selected = selection == tab
        let label = title(tab)
        return Button {
            selection = tab
        } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? chromeFill : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? selectedFill : unselectedFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(label)
    }
}

/// Compact pill chip for mutually exclusive filters (same visual language as sub-tabs).
struct PillFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    private let chromeFill = Color(red: 248.0 / 255.0, green: 248.0 / 255.0, blue: 246.0 / 255.0)
    private let selectedFill = Color(red: 0.18, green: 0.18, blue: 0.17)
    private let unselectedFill = Color.primary.opacity(0.06)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? chromeFill : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? selectedFill : unselectedFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
    }
}
