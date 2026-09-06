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
            maxWidth: 520,
            maxHeight: 560,
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
        case .creating: return false
        default: return true
        }
    }

    private var modalTitle: String {
        switch controller.phase {
        case .intro: return "Create or edit a plugin"
        case .chooseType: return "Create a plugin"
        case .chooseVendor: return "Choose a vendor"
        case .describe: return "Describe your connector"
        case .creating: return "Creating connector"
        case .collectCredentials: return "Connector credentials"
        case .failed: return "Could not create connector"
        case .succeeded: return "Connector ready"
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
                    subtitle: "Messaging integration (Slack, Telegram, …)",
                    type: .connector,
                    enabled: true
                )
                typeButton(
                    title: "News reader",
                    subtitle: "Coming soon",
                    type: .newsReader,
                    enabled: false
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
                        Button {
                            controller.selectedVendor = vendor
                        } label: {
                            Text(vendor.displayName)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    controller.selectedVendor == vendor
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.05)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if controller.selectedVendor == .custom {
                    TextField("Vendor name", text: $controller.customVendorName)
                        .textFieldStyle(.roundedBorder)
                }
            }

        case .describe:
            VStack(alignment: .leading, spacing: 12) {
                Text("What should this connector do?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(PluginFactoryCreateInput.ConnectorScope.allCases, id: \.self) { scope in
                        scopeButton(scope)
                    }
                }
                Text("Additional details (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.connectorDescription)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12))
                    )
                Text("Derrick will read the vendor API docs, build the plugin, run tests, and run a safety review — in that order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .creating:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(controller.progressSteps) { step in
                    progressStepRow(step)
                }
                if !controller.statusMessage.isEmpty {
                    Text(controller.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

        case .collectCredentials(let pluginID):
            VStack(alignment: .leading, spacing: 12) {
                Text("Stored in Keychain for /\(pluginID). Values never enter the plugin sandbox.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(controller.credentialFields) { field in
                    credentialFieldRow(field)
                }
            }

        case .failed(_, let message, let technicalDetail):
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

        case .succeeded(let pluginID):
            Text("Your connector /\(pluginID) is ready. Open it to start talking in Messaging.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modalFooter: some View {
        switch controller.phase {
        case .intro:
            HStack {
                Button("Edit existing") { controller.beginEdit() }
                    .buttonStyle(ModalSecondaryButtonStyle())
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
                    .disabled(controller.selectedType != .connector)
                    .keyboardShortcut(.defaultAction)
            }

        case .chooseVendor:
            HStack {
                Button("Back") { controller.goBackToTypeSelection() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Continue") { controller.confirmVendor() }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

        case .describe:
            HStack {
                Button("Back") { controller.goBackToVendorSelection() }
                    .buttonStyle(ModalSecondaryButtonStyle())
                Spacer()
                Button("Create") {
                    controller.startCreation(
                        sessionID: sessionID,
                        helperAPIKey: helperAPIKey,
                        helperReviewerModelJSON: helperReviewerModelJSON
                    )
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .disabled(!sessionReady)
                .keyboardShortcut(.defaultAction)
            }

        case .creating:
            EmptyView()

        case .collectCredentials:
            HStack {
                Spacer()
                Button("Save and continue") {
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

    private func scopeButton(_ scope: PluginFactoryCreateInput.ConnectorScope) -> some View {
        Button {
            controller.selectedScope = scope
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.displayName)
                        .font(.body.weight(.semibold))
                    Text(scope.wizardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if controller.selectedScope == scope {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                controller.selectedScope == scope
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(0.05)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
}
