import SwiftUI
import Structure

struct PluginsWorkspaceView: View {
    @ObservedObject var controller: PluginCreationController
    let sessionReady: Bool
    let helperAPIKey: String?
    let helperReviewerModelJSON: String?
    let sessionID: String
    let onOpenMessagingConnector: (String) -> Void

    var body: some View {
        ZStack {
            Color(red: 252.0 / 255.0, green: 252.0 / 255.0, blue: 250.0 / 255.0)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Plugins")
                    .font(.title2.weight(.semibold))
                Text("Installed plugins appear in the sidebar. Use Messaging to talk to connector plugins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(32)
        }
        .modalPopup(
            isPresented: true,
            minWidth: 400,
            minHeight: 0,
            maxWidth: 560,
            maxHeight: modalMaxHeight,
            onBackdropDismiss: canDismiss ? { controller.showIntro() } : nil,
            onEscape: canDismiss ? { controller.showIntro() } : nil,
            header: {
                Text(modalTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            },
            body: {
                modalBody
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            },
            footer: {
                modalFooter
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        )
    }

    private var modalMaxHeight: CGFloat {
        switch controller.phase {
        case .skill, .preview: return 720
        default: return 560
        }
    }

    private var canDismiss: Bool {
        switch controller.phase {
        case .creating, .discoveringAuth: return false
        default: return true
        }
    }

    private var modalTitle: String {
        switch controller.phase {
        case .intro: return "Create a plugin"
        case .goal: return "What should it do?"
        case .skill: return "Define the skill"
        case .preview: return "Preview"
        case .discoveringAuth: return "Reading authentication docs"
        case .creating: return creatingTitle
        case .collectCredentials: return "Plugin credentials"
        case .failed: return failureTitle
        case .succeeded(_, let outcome):
            return "Plugin ready"
        }
    }

    private var creatingTitle: String {
        switch controller.skillDraft.plannedKind {
        case .messagingConnector: return "Creating connector"
        case .customCapability: return "Building plugin"
        }
    }

    private var failureTitle: String {
        return "Could not create plugin"
    }

    @ViewBuilder
    private var modalBody: some View {
        switch controller.phase {
        case .intro:
            Text("""
            Describe what you want Derrick to do. Derrick will draft a skill, show you a preview, and build a secure plugin package.
            """)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)

        case .goal:
            VStack(alignment: .leading, spacing: 10) {
                Text("What do you want Derrick to do?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(
                    "e.g. Send Slack messages from Messaging, or fetch tech headlines",
                    text: controller.skillDraftBinding(\.goal),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .accessibilityIdentifier("plugin-goal-field")
            }

        case .skill:
            skillBuilderForm

        case .preview:
            previewForm

        case .discoveringAuth, .creating:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(controller.progressSteps) { step in
                    progressStepRow(step)
                }
                if !controller.statusMessage.isEmpty {
                    FactoryCreatingStatusLine(message: controller.statusMessage)
                        .padding(.top, 2)
                }
            }

        case .collectCredentials(let pluginID):
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored in Keychain for /\(pluginID). Values never enter the plugin sandbox.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.skillDraft.inferredConnectorVendor == .slack {
                    Text(ConnectorReplyThreadAccessMessage.slackSetupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.credentialFields) { field in
                    credentialFieldRow(field)
                }
            }

        case .failed(_, let message, let technicalDetail):
            failureBody(message: message, technicalDetail: technicalDetail)

        case .succeeded(let pluginID, let outcome):
            successBody(pluginID: pluginID, outcome: outcome)
        }
    }

    @ViewBuilder
    private var modalFooter: some View {
        switch controller.phase {
        case .intro:
            HStack {
                Spacer()
                Button("Begin") { controller.beginCreate() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

        case .goal:
            HStack {
                Button("Back") { controller.showIntro() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Continue") { controller.continueFromGoal() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(!controller.canContinueFromGoal)
                    .keyboardShortcut(.defaultAction)
            }

        case .skill:
            HStack {
                Button("Back") { controller.goBackToGoal() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Preview") { controller.continueToPreview() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(!controller.canContinueFromSkill)
                    .keyboardShortcut(.defaultAction)
            }

        case .preview:
            HStack {
                Button("Back") { controller.goBackToSkill() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button(buildButtonTitle) {
                    controller.confirmPreview(
                        sessionID: sessionID,
                        helperAPIKey: helperAPIKey,
                        helperReviewerModelJSON: helperReviewerModelJSON
                    )
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(!sessionReady || !controller.canContinueFromSkill)
                .keyboardShortcut(.defaultAction)
            }

        case .discoveringAuth, .creating:
            EmptyView()

        case .collectCredentials:
            HStack {
                Spacer()
                Button("Save and create") {
                    controller.saveCredentialsAndFinish()
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(!controller.canSaveCredentials)
                .keyboardShortcut(.defaultAction)
            }

        case .failed:
            HStack {
                Button("Back") { controller.retryFromFailure() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Start over") { controller.showIntro() }
                    .buttonStyle(ModalSecondaryButtonStyle())
            }

        case .succeeded(let pluginID, let outcome):
            HStack {
                if outcome != .plugin || controller.skillDraft.plannedKind == .messagingConnector {
                    Button("Done") { controller.dismissSuccess() }
                        .buttonStyle(ModalSecondaryButtonStyle())
                }
                Spacer()
                switch outcome {
                case .plugin where controller.skillDraft.plannedKind == .messagingConnector:
                    Button("Open connector") {
                        onOpenMessagingConnector(pluginID)
                    }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                case .plugin:
                    Button("Done") { controller.dismissSuccess() }
                        .buttonStyle(ModalPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }

        }
    }

    private var buildButtonTitle: String {
        "Build plugin"
    }

    private var skillBuilderForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                plannedKindBadge

                VStack(alignment: .leading, spacing: 6) {
                    Text("Purpose")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("What this plugin does", text: controller.skillDraftBinding(\.purpose), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("When to use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(PluginSkillDraft.Trigger.allCases, id: \.self) { trigger in
                            triggerChip(trigger)
                        }
                    }
                }

                examplesSection

                nameFieldSection

                if let blocked = controller.skillDraft.buildBlockedReason {
                    Text(blocked)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var plannedKindBadge: some View {
        let (label, icon) = plannedKindPresentation
        return Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var plannedKindPresentation: (String, String) {
        switch controller.skillDraft.plannedKind {
        case .messagingConnector:
            let vendor = controller.skillDraft.inferredConnectorVendor?.displayName ?? "Messaging"
            return ("\(vendor) connector", "bubble.left.and.bubble.right")
        case .customCapability:
            return ("Custom capability", "wand.and.stars")
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Examples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add example") { controller.addExample() }
                    .font(.caption)
            }
            ForEach(controller.skillDraft.examples) { example in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("You say…", text: exampleBinding(example.id, field: .userSays))
                        .textFieldStyle(.roundedBorder)
                    TextField("Plugin does…", text: exampleBinding(example.id, field: .pluginDoes))
                        .textFieldStyle(.roundedBorder)
                    if controller.skillDraft.examples.count > 1 {
                        Button("Remove") { controller.removeExample(id: example.id) }
                            .font(.caption)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private enum ExampleField { case userSays, pluginDoes }

    private func exampleBinding(_ id: String, field: ExampleField) -> Binding<String> {
        Binding(
            get: {
                guard let index = controller.skillDraft.examples.firstIndex(where: { $0.id == id }) else {
                    return ""
                }
                switch field {
                case .userSays: return controller.skillDraft.examples[index].userSays
                case .pluginDoes: return controller.skillDraft.examples[index].pluginDoes
                }
            },
            set: { newValue in
                switch field {
                case .userSays: controller.updateExample(id: id, userSays: newValue)
                case .pluginDoes: controller.updateExample(id: id, pluginDoes: newValue)
                }
            }
        )
    }

    private func triggerChip(_ trigger: PluginSkillDraft.Trigger) -> some View {
        let available = controller.skillDraft.isTriggerAvailable(trigger)
        let on = available && controller.skillDraft.triggers.contains(trigger)
        return Button {
            controller.toggleTrigger(trigger)
        } label: {
            Text(trigger.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(chipBackground(on: on, available: available))
                .foregroundStyle(available ? .primary : .tertiary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(triggerHelp(trigger, available: available))
    }

    private func chipBackground(on: Bool, available: Bool) -> Color {
        guard available else { return Color.primary.opacity(0.03) }
        return on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)
    }

    private func triggerHelp(
        _ trigger: PluginSkillDraft.Trigger,
        available: Bool
    ) -> String {
        guard !available else { return "" }
        switch controller.skillDraft.plannedKind {
        case .messagingConnector:
            switch trigger {
            case .schedule:
                return "Connectors respond in Messaging, not on a timer."
            default:
                return "Not available for messaging connectors."
            }
        case .customCapability:
            switch trigger {
            case .messaging:
                return "Only messaging connectors use the Messaging tab."
            default:
                return "Not available for this plugin type."
            }
        }
    }

    private var nameFieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugin name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Plugin name", text: controller.skillDraftBinding(\.pluginName))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("connector-plugin-name")
            if controller.canConfirmPluginName {
                Text("Invoke this plugin in chat as /\(normalizedPluginID()).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Use letters, numbers, and hyphens (for example tech-news).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func normalizedPluginID() -> String {
        let trimmed = controller.skillDraft.pluginName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = try? PluginID.normalized(trimmed) {
            return normalized.rawValue
        }
        return trimmed.isEmpty ? "plugin" : trimmed
    }

    private var previewForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                plannedKindBadge

                nameFieldSection

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scenarios")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(controller.skillDraft.previewScenarios(), id: \.self) { scenario in
                        Text(scenario)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Package")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(controller.skillDraft.packageOutline(), id: \.self) { line in
                        Label(line, systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("SKILL.md")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(controller.skillDraft.skillMarkdown())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func failureBody(message: String, technicalDetail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Nothing was installed", systemImage: "minus.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Your sidebar and Messaging are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if let technicalDetail, !technicalDetail.isEmpty {
                DisclosureGroup("Technical details") {
                    Text(technicalDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func successBody(pluginID: String, outcome: PluginCreationController.SuccessOutcome) -> some View {
        switch outcome {
        case .plugin:
            if controller.skillDraft.plannedKind == .messagingConnector {
                Text("Your connector /\(pluginID) is ready. Open it to start talking in Messaging.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your plugin /\(pluginID) is ready.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func progressStepRow(_ step: PluginCreationController.ProgressStepState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            progressStepIcon(step.status)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            Text(step.title)
                .font(.body)
                .foregroundStyle(step.status == .pending ? .secondary : .primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func progressStepIcon(_ status: PluginCreationController.ProgressStepState.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func credentialFieldRow(_ field: PluginCredentialFieldPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if field.hasStoredValue {
                Text(String(repeating: "•", count: 12))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved value hidden")
            }
            if field.usesSecureField {
                SecureField(
                    field.hasStoredValue ? "Leave blank to keep saved value" : field.label,
                    text: credentialBinding(for: field.id)
                )
                .textFieldStyle(.roundedBorder)
            } else {
                TextField(
                    field.hasStoredValue ? "Leave blank to keep saved value" : field.label,
                    text: credentialBinding(for: field.id)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func credentialBinding(for id: String) -> Binding<String> {
        Binding(
            get: { controller.credentialDrafts[id] ?? "" },
            set: { controller.credentialDrafts[id] = $0 }
        )
    }
}

/// Simple horizontal flow for trigger chips when `Layout` is unavailable.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

struct FactoryCreatingStatusLine: View {
    let message: String
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let wait = PluginCreationElapsedWait.label(
                    elapsedSeconds: Int(context.date.timeIntervalSince(startedAt))
                ) {
                    Text(wait)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { startedAt = Date() }
        .onChange(of: message) { _, _ in
            startedAt = Date()
        }
    }
}

enum PluginCreationElapsedWait {
    static func label(elapsedSeconds: Int) -> String? {
        guard elapsedSeconds >= 8 else { return nil }
        if elapsedSeconds < 60 {
            return "Still working · \(elapsedSeconds) seconds"
        }
        let minutes = elapsedSeconds / 60
        let remainder = elapsedSeconds % 60
        if remainder == 0 {
            return "Still working · \(minutes) min"
        }
        return "Still working · \(minutes) min \(remainder) sec"
    }
}
