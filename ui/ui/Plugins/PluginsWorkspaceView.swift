import SwiftUI
import Structure

struct PluginsWorkspaceView: View {
    @ObservedObject var controller: PluginCreationController
    let sessionReady: Bool
    let helperAPIKey: String?
    let helperReviewerModelJSON: String?
    let sessionID: String
    let onOpenMessagingConnector: (String) -> Void
    var onOpenNewsReader: (String) -> Void = { _ in }

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
            maxWidth: 520,
            maxHeight: controller.phase == .chooseNews ? 720 : 560,
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

    private var canDismiss: Bool {
        switch controller.phase {
        case .creating, .discoveringAuth: return false
        default: return true
        }
    }

    private var modalTitle: String {
        switch controller.phase {
        case .intro: return "Create a plugin"
        case .chooseType: return "Create a plugin"
        case .chooseVendor: return "Choose a vendor"
        case .chooseName: return "Name this connector"
        case .chooseNews: return "News list"
        case .discoveringAuth: return "Reading authentication docs"
        case .creating: return controller.selectedType == .newsReader ? "Creating news list" : "Creating connector"
        case .collectCredentials: return "Connector credentials"
        case .failed: return controller.selectedType == .newsReader ? "Could not create news list" : "Could not create connector"
        case .succeeded: return "Connector ready"
        case .succeededNews: return "News list ready"
        }
    }

    @ViewBuilder
    private var modalBody: some View {
        switch controller.phase {
        case .intro:
            Text("""
            A plugin is a small program that extends the capabilities of Derrick. This form will guide you through the process of building your own unique and secure plugins.
            """)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)

        case .chooseType:
            VStack(alignment: .leading, spacing: 10) {
                Text("What kind of plugin do you want?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                typeButton(
                    title: "Connector",
                    subtitle: "Messaging integration (Slack)",
                    type: .connector,
                    enabled: true
                )
                typeButton(
                    title: "News reader",
                    subtitle: "Saved lists from topics and sources",
                    type: .newsReader,
                    enabled: true
                )
                typeButton(
                    title: "Custom",
                    subtitle: "Coming soon",
                    type: .custom,
                    enabled: false
                )
            }

        case .chooseVendor:
            VStack(alignment: .leading, spacing: 10) {
                Text("Which service should this connector use?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(PluginFactoryCreateInput.ConnectorVendor.allCases, id: \.self) { vendor in
                        let enabled = vendor.isSelectableInWizard
                        Button {
                            guard enabled else { return }
                            controller.selectedVendor = vendor
                        } label: {
                            VStack(spacing: 4) {
                                Text(vendor.displayName)
                                    .font(.subheadline.weight(.medium))
                                if !enabled {
                                    Text("Soon")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                enabled && controller.selectedVendor == vendor
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.primary.opacity(enabled ? 0.05 : 0.03)
                            )
                            .foregroundStyle(enabled ? .primary : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel(enabled ? vendor.displayName : "\(vendor.displayName), coming soon")
                    }
                }
                if controller.selectedVendor == .custom {
                    TextField("Vendor name", text: $controller.customVendorName)
                        .textFieldStyle(.roundedBorder)
                }
                Text("This connector lists conversations as tabs, including reply threads, then sends and receives new messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if controller.selectedVendor == .slack {
                    Text(ConnectorReplyThreadAccessMessage.slackSetupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .chooseName:
            VStack(alignment: .leading, spacing: 10) {
                Text("Give this connector a name. You can change the default.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Connector name", text: $controller.connectorName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connector-plugin-name")
            }

        case .chooseNews:
            newsReaderForm

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
                if controller.selectedVendor == .slack {
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
            VStack(alignment: .leading, spacing: 10) {
                if controller.selectedType == .newsReader {
                    Label(
                        message.localizedCaseInsensitiveContains("paywall")
                            ? "Blocked because of a paywall"
                            : "News list was not created",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(message.localizedCaseInsensitiveContains("paywall") ? Color.orange : Color.secondary)
                    .accessibilityIdentifier(
                        message.localizedCaseInsensitiveContains("paywall")
                            ? "news-paywall-blocked"
                            : "news-create-failed"
                    )
                    if message.localizedCaseInsensitiveContains("paywall") {
                        Text(NewsPaywall.userWarning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Nothing was installed", systemImage: "minus.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Your sidebar and Messaging are unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

        case .succeeded(let pluginID):
            Text("Your connector /\(pluginID) is ready. Open it to start talking in Messaging.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .succeededNews:
            Text("Your news list is ready. Every article includes a source link.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modalFooter: some View {
        switch controller.phase {
        case .intro:
            HStack {
                Spacer()
                Button("Create plugin") { controller.beginCreate() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

        case .chooseType:
            HStack {
                Button("Back") { controller.showIntro() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Continue") { controller.confirmTypeSelection() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(
                        controller.selectedType != .connector
                            && controller.selectedType != .newsReader
                    )
                    .keyboardShortcut(.defaultAction)
            }

        case .chooseVendor:
            HStack {
                Button("Back") { controller.goBackToTypeSelection() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Continue") {
                    controller.confirmVendor(
                        sessionID: sessionID,
                        helperAPIKey: helperAPIKey,
                        helperReviewerModelJSON: helperReviewerModelJSON
                    )
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(!sessionReady || !controller.canConfirmVendor)
                .keyboardShortcut(.defaultAction)
            }

        case .chooseName:
            HStack {
                Button("Back") { controller.goBackToVendor() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Continue") { controller.confirmConnectorName() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(!controller.canConfirmName)
                    .keyboardShortcut(.defaultAction)
            }

        case .chooseNews:
            HStack {
                Button("Back") { controller.goBackToTypeSelection() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Create") { controller.startNewsCreation() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .disabled(!controller.canConfirmNews)
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

        case .succeeded(let pluginID):
            HStack {
                Button("Done") { controller.dismissSuccess() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Open connector") {
                    onOpenMessagingConnector(pluginID)
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }

        case .succeededNews(let readerID):
            HStack {
                Button("Done") { controller.dismissSuccess() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Open news list") {
                    onOpenNewsReader(readerID)
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
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

    private func typeButton(
        title: String,
        subtitle: String,
        type: PluginFactoryCreateInput.PluginType,
        enabled: Bool
    ) -> some View {
        Button {
            guard enabled else { return }
            controller.selectType(type)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !enabled {
                    Text("Soon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if controller.selectedType == type {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                controller.selectedType == type && enabled
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(enabled ? 0.05 : 0.03)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var newsReaderForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Name this list", text: $controller.newsName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("news-list-name")
                Text("Topics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(NewsPresetTopic.allCases) { topic in
                        let on = controller.selectedNewsTopics.contains(topic)
                        Button {
                            if on {
                                controller.selectedNewsTopics.remove(topic)
                            } else {
                                controller.selectedNewsTopics.insert(topic)
                            }
                        } label: {
                            Text(topic.displayName)
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Add a custom topic", text: $controller.newsTopicDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { controller.addNewsTopic() }
                    Button("Add") { controller.addNewsTopic() }
                }
                if !controller.extraNewsTopics.isEmpty {
                    Text(controller.extraNewsTopics.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(NewsPresetSource.allCases) { source in
                        let on = controller.selectedNewsSources.contains(source)
                        Button {
                            if on {
                                controller.selectedNewsSources.remove(source)
                            } else {
                                controller.selectedNewsSources.insert(source)
                            }
                        } label: {
                            Text(source.source.label)
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("https://…", text: $controller.newsURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("news-url-field")
                        .onSubmit { controller.addNewsURL() }
                    Button("Add URL") { controller.addNewsURL() }
                }
                ForEach(controller.extraNewsURLs, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(url)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") { controller.removeNewsURL(url) }
                                .font(.caption)
                        }
                        if let reason = newsURLPaywallReason(url) {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(NewsPaywall.userWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("news-paywall-warning")
                Picker("Mode", selection: $controller.newsMode) {
                    ForEach(NewsReaderMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Stepper("Up to \(controller.newsMaxCount) items", value: $controller.newsMaxCount, in: 5...50, step: 5)
                Picker("Schedule", selection: $controller.newsSchedule) {
                    ForEach(NewsReaderSchedule.allCases, id: \.self) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }
            }
        }
    }

    private func newsURLPaywallReason(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else { return nil }
        return NewsPaywall.preflightRejection(url: url)
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
