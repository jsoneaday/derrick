import SwiftUI
import DBRepository
import LLMAgentClient
import ServiceContracts

private enum LLMModelSettingsSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case helperModels
    case multiAgent
    case containers
    case networkBlacklist
    case sensitiveContent
    case usageLimits
    case softwareFactory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helperModels:
            return "Select helper models"
        case .multiAgent:
            return "Multi-agent"
        case .containers:
            return "Containers"
        case .networkBlacklist:
            return "Network blacklist"
        case .sensitiveContent:
            return "Sensitive content"
        case .usageLimits:
            return "Usage limits"
        case .softwareFactory:
            return "Software Factory"
        }
    }

    var systemImage: String {
        switch self {
        case .helperModels:
            return "brain.head.profile"
        case .multiAgent:
            return "person.3"
        case .containers:
            return "shippingbox"
        case .networkBlacklist:
            return "hand.raised"
        case .sensitiveContent:
            return "eye.slash"
        case .usageLimits:
            return "gauge.with.dots.needle.67percent"
        case .softwareFactory:
            return "building.2"
        }
    }
}

struct LLMModelSettingsView: View {
    @ObservedObject var helperModelSettings: LLMModelSettings
    @ObservedObject private var contentSensitivity = ContentSensitivityGrantService.shared
    @ObservedObject private var usageLimits = UsageLimitsService.shared
    @ObservedObject private var containerLifecycle = ContainerLifecycleSettingsService.shared
    @ObservedObject private var orchestrationLimits = OrchestrationLimitsSettingsService.shared
    @ObservedObject private var softwareFactory = SoftwareFactorySettingsService.shared
    @State private var selectedItem: LLMModelSettingsSidebarItem = .helperModels
    @State private var contentError: String?
    @State private var draftLimits: UsageLimits = .default
    @State private var draftContainerTTLMinutes: Int = ContainerLifecycleSettings.default.containerRunMaxTTLMinutes
    @State private var draftOrchestrationLimits: OrchestrationLimits = .default

    var body: some View {
        // Prefer a plain HStack over NavigationSplitView: split views often leave a blank
        // detail column when hosted in a free-floating NSWindow.
        HStack(spacing: 0) {
            List(selection: $selectedItem) {
                ForEach(LLMModelSettingsSidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            .frame(maxHeight: .infinity)

            Divider()

            // Single outer ScrollView so every pane shares the same trailing gutter
            // (macOS overlay scrollbars sit on the trailing edge of this view).
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch selectedItem {
                    case .helperModels:
                        helperModelDetail
                    case .multiAgent:
                        multiAgentDetail
                    case .containers:
                        containersDetail
                    case .networkBlacklist:
                        NetworkBlacklistSettingsView()
                    case .sensitiveContent:
                        sensitiveContentDetail
                    case .usageLimits:
                        usageLimitsDetail
                    case .softwareFactory:
                        softwareFactoryDetail
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 24)
                .padding(.leading, 24)
                .padding(.bottom, 24)
                // Keep controls clear of the scroller track (~12–16pt gap).
                .padding(.trailing, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            draftLimits = usageLimits.permanentLimits.clamped()
            draftContainerTTLMinutes = containerLifecycle.settings.containerRunMaxTTLMinutes
            draftOrchestrationLimits = orchestrationLimits.limits
        }
        .onChange(of: selectedItem) { _, item in
            if item == .usageLimits {
                draftLimits = usageLimits.permanentLimits.clamped()
            }
            if item == .containers {
                draftContainerTTLMinutes = containerLifecycle.settings.containerRunMaxTTLMinutes
            }
            if item == .multiAgent {
                draftOrchestrationLimits = orchestrationLimits.limits
            }
        }
        .onChange(of: usageLimits.permanentLimits) { _, newValue in
            if selectedItem == .usageLimits {
                draftLimits = newValue.clamped()
            }
        }
        .onChange(of: containerLifecycle.settings) { _, newValue in
            if selectedItem == .containers {
                draftContainerTTLMinutes = newValue.containerRunMaxTTLMinutes
            }
        }
        .onChange(of: orchestrationLimits.limits) { _, newValue in
            if selectedItem == .multiAgent {
                draftOrchestrationLimits = newValue
            }
        }
    }

    @ViewBuilder
    private var helperModelDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Helper models")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Choose the models Derrick uses for memory summarization, script review, and secondary agents spawned during a chat.")
                .foregroundStyle(.secondary)

            Form {
                Section("Summarizer model") {
                    helperModelPicker(
                        selection: $helperModelSettings.summarizerModel,
                        accessibilityLabel: "Summarizer model"
                    )
                }

                Section("Script reviewer model") {
                    helperModelPicker(
                        selection: $helperModelSettings.scriptReviewerModel,
                        accessibilityLabel: "Script reviewer model"
                    )
                }

                Section("Secondary agent model") {
                    helperModelPicker(
                        selection: $helperModelSettings.workerAgentModel,
                        accessibilityLabel: "Secondary agent model"
                    )
                    Text("Used when the main agent or you spawn worker agents (agents_spawn). The main chat keeps the model selected in the chat input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var multiAgentDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Multi-agent")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Caps for agents_spawn and worker turns in a chat session. New tabs use saved values; open tabs keep the limits they started with. Parallel script_exec runs may still queue on the Docker container pool.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Hierarchy")
                    .font(.headline)

                limitControlRow(
                    title: "Max hierarchy depth",
                    value: $draftOrchestrationLimits.maxDepth,
                    range: 0 ... OrchestrationLimits.absoluteMax.maxDepth,
                    step: 1
                )
                limitControlRow(
                    title: "Max workers per parent",
                    value: $draftOrchestrationLimits.maxChildrenPerAgent,
                    range: 1 ... OrchestrationLimits.absoluteMax.maxChildrenPerAgent,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Session")
                    .font(.headline)

                limitControlRow(
                    title: "Max parallel agent turns",
                    value: $draftOrchestrationLimits.maxConcurrentTurns,
                    range: 1 ... OrchestrationLimits.absoluteMax.maxConcurrentTurns,
                    step: 1
                )
                limitControlRow(
                    title: "Max agents per session",
                    value: $draftOrchestrationLimits.maxAgentsPerSession,
                    range: 2 ... OrchestrationLimits.absoluteMax.maxAgentsPerSession,
                    step: 1
                )
                limitControlRow(
                    title: "Max mailbox queue depth",
                    value: $draftOrchestrationLimits.maxMailboxDepth,
                    range: 8 ... OrchestrationLimits.absoluteMax.maxMailboxDepth,
                    step: 8
                )
            }

            Text("Defaults: depth 2, 4 workers per parent, 4 parallel turns, 8 agents, mailbox 64. See docs/orchestration-limits.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset to defaults") {
                    draftOrchestrationLimits = .default
                    Task { await orchestrationLimits.savePermanentLimits(.default) }
                }
                Spacer(minLength: 12)
                Button("Save") {
                    Task { await orchestrationLimits.savePermanentLimits(draftOrchestrationLimits.clamped()) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var containersDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Containers")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Controls how long a single script_exec run may keep a Docker container before it is released for other agents. Queue wait time does not count toward this limit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Container run time limit")
                    .font(.headline)

                limitControlRow(
                    title: "Maximum minutes per run",
                    value: $draftContainerTTLMinutes,
                    range: ContainerLifecycleSettings.minimumTTLSeconds / 60 ... ContainerLifecycleSettings.maximumTTLSeconds / 60,
                    step: 1
                )

                Text("Current limit: \(draftContainerTTLMinutes) minute\(draftContainerTTLMinutes == 1 ? "" : "s") (\(draftContainerTTLMinutes * 60)s). Network pool: up to 2 containers (1 warm). Offline pool: 1 container, queued.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reset to default") {
                    draftContainerTTLMinutes = ContainerLifecycleSettings.default.containerRunMaxTTLMinutes
                    Task {
                        await containerLifecycle.savePermanentSettings(.default)
                    }
                }
                Spacer(minLength: 12)
                Button("Save") {
                    Task {
                        await containerLifecycle.savePermanentSettings(
                            ContainerLifecycleSettings.fromMinutes(draftContainerTTLMinutes)
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var sensitiveContentDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sensitive content")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("When a reply may include sensitive data, Derrick can ask before showing it. Always-allow matches the “Always” button on those prompts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let contentError {
                Text(contentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(ContentSensitivityGrantService.grantableCategories, id: \.id) { item in
                    Toggle(
                        isOn: Binding(
                            get: { contentSensitivity.isPermanentlyGranted(item.id) },
                            set: { newValue in
                                Task {
                                    do {
                                        try await contentSensitivity.setPermanentGrant(
                                            category: item.id,
                                            enabled: newValue
                                        )
                                        contentError = nil
                                    } catch {
                                        contentError = error.localizedDescription
                                    }
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always allow \(item.title.lowercased())")
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Social Security–like numbers")
                        .font(.body)
                    Text("Always blocked by policy. Not overridable here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var usageLimitsDetail: some View {
        // Plain rows (no nested Form/ScrollView — outer settings ScrollView owns scrolling).
        VStack(alignment: .leading, spacing: 20) {
            Text("Usage limits")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Caps apply per user message (tool / script / reviewer) and over daily / weekly windows (provider token counts when available). When a limit is hit you can raise it for this session or save a permanent cap from the modal (presets or custom). Values here are permanent and cannot exceed built-in maximums.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Per message")
                    .font(.headline)

                limitControlRow(
                    title: "Max tool rounds",
                    value: $draftLimits.maxToolRoundsPerMessage,
                    range: 1...UsageLimits.absoluteMax.maxToolRoundsPerMessage,
                    step: 1
                )
                limitControlRow(
                    title: "Max script runs",
                    value: $draftLimits.maxScriptRunsPerMessage,
                    range: 0...UsageLimits.absoluteMax.maxScriptRunsPerMessage,
                    step: 1
                )
                limitControlRow(
                    title: "Max security reviews",
                    value: $draftLimits.maxReviewerCallsPerMessage,
                    range: 0...UsageLimits.absoluteMax.maxReviewerCallsPerMessage,
                    step: 1
                )
                limitControlRow(
                    title: "Max factory reviewer calls per build",
                    value: $draftLimits.maxFactoryReviewerCallsPerBuild,
                    range: 0...UsageLimits.absoluteMax.maxFactoryReviewerCallsPerBuild,
                    step: 1
                )
                limitControlRow(
                    title: "Max tests per plugin build",
                    value: $draftLimits.maxHarnessRunsPerBuild,
                    range: 0...UsageLimits.absoluteMax.maxHarnessRunsPerBuild,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Token budgets")
                    .font(.headline)
                Text("Budgets use provider-reported tokens when available (fallback: estimate). Set 0 to disable a budget. Dollar amounts are list-price estimates, not invoices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                limitControlRow(
                    title: "Daily token budget",
                    value: $draftLimits.dailyTokenBudget,
                    range: 0...UsageLimits.absoluteMax.dailyTokenBudget,
                    step: 10_000
                )
                limitControlRow(
                    title: "Weekly token budget",
                    value: $draftLimits.weeklyTokenBudget,
                    range: 0...UsageLimits.absoluteMax.weeklyTokenBudget,
                    step: 50_000
                )
                Text("Used today ≈ \(usageLimits.counters.dayTokens) tokens (~\(formatUSD(usageLimits.estimatedUSDToday))) · this week ≈ \(usageLimits.counters.weekTokens) tokens (~\(formatUSD(usageLimits.estimatedUSDThisWeek)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("List prices (USD / 1M tokens, input → output)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                ForEach(LLMModelChoice.allCases) { model in
                    let p = model.tokenPricing
                    Text("\(model.helperDisplayName): $\(String(format: "%.2f", p.inputUSDPer1MTokens)) → $\(String(format: "%.2f", p.outputUSDPer1MTokens))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reset to defaults") {
                    draftLimits = .default
                    Task { await usageLimits.savePermanentLimits(.default) }
                }
                Spacer(minLength: 12)
                Button("Save") {
                    Task { await usageLimits.savePermanentLimits(draftLimits.clamped()) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var softwareFactoryDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Software Factory")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("When on, the agent can build and install complementary plugins. Off by default. Guest JavaScript still cannot open sockets or see secrets. A plugin gets a private /data volume only if the factory asks and you approve (default off).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable Software Factory", isOn: Binding(
                get: { softwareFactory.isEnabled },
                set: { newValue in
                    Task { await softwareFactory.setEnabled(newValue) }
                }
            ))

            Divider()

            Text("Plugin secrets")
                .font(.headline)
            Text("Tokens stay on this Mac. Plugins never see them. Host HTTP attaches a secret only on that provider’s allowed hosts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PluginSecretsSettingsView()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func limitControlRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                adjustLimit(value, delta: -step, range: range)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(value.wrappedValue <= range.lowerBound)

            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                        value.wrappedValue = clamped
                    }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
            .labelsHidden()

            Button {
                adjustLimit(value, delta: step, range: range)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(value.wrappedValue >= range.upperBound)
        }
        .padding(.vertical, 4)
    }

    private func adjustLimit(_ value: Binding<Int>, delta: Int, range: ClosedRange<Int>) {
        let next = value.wrappedValue + delta
        value.wrappedValue = min(max(next, range.lowerBound), range.upperBound)
    }

    private func formatUSD(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    private func helperModelPicker(
        selection: Binding<LLMModelChoice>,
        accessibilityLabel: String
    ) -> some View {
        Picker(accessibilityLabel, selection: selection) {
            ForEach(LLMModelChoice.allCases) { model in
                Text(model.helperDisplayName).tag(model)
            }
        }
        .pickerStyle(.menu)
    }
}

#Preview {
    let config = DBRepositoryConfiguration(
        applicationName: "preview",
        databaseName: "preview",
        databaseDirectoryURL: FileManager.default.temporaryDirectory,
        username: "ui",
        password: "ui"
    )
    LLMModelSettingsView(helperModelSettings: LLMModelSettings(repository: DBRepository(configuration: config)))
}
