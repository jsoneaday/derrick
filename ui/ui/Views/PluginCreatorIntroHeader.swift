import SwiftUI

enum PluginCreatorIntroCopy {
    static let body = "A plugin is an extension to derrick that provides a new feature. A feature can be anything that works with an agent to provide additional capability to derrick. Once created a plugin can be called by typing '/<plugin name>'"
}

/// Chrome above the Create plugin prompt. Not a user bubble and not the agent reply.
struct PluginCreatorIntroHeader: View {
    private let navy = Color(red: 0.176, green: 0.286, blue: 0.576)
    private let panelFill = Color(red: 0.945, green: 0.941, blue: 0.925)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(navy)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                Text("Plugin")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.primary)

                Text(PluginCreatorIntroCopy.body)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(navy.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plugin-creator-intro")
        .accessibilityLabel("Plugin. \(PluginCreatorIntroCopy.body)")
    }
}
