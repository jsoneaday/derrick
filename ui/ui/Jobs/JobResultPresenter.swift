import AppKit
import Combine
import DBRepository
import Foundation
import ServiceContracts
import SwiftUI

/// Process-wide flags for notification panel sessions (readable from AppKit delegate callbacks).
enum JobResultPanelSession {
    nonisolated(unsafe) static var allowsTermination = true
    nonisolated(unsafe) static var isPanelOnlyLaunch =
        DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
    nonisolated(unsafe) static var swallowMouseEventsUntil = Date.distantPast
    nonisolated(unsafe) private static var mouseMonitor: Any?

    static func installMouseSwallowMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { event in
            if Date() < swallowMouseEventsUntil {
                return nil
            }
            return event
        }
    }
}

/// Presents scheduled-job completion in a **standalone floating panel**.
/// Not tied to the main chat window — notification taps show only this popup.
@MainActor
final class JobResultPresenter: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = JobResultPresenter()

    /// True when the user launched the interactive main UI (not panel-only / headless).
    static var interactiveSessionActive = false

    /// Set early from argv so SwiftUI never mounts `ContentView` for panel-only taps.
    static var panelOnlyLaunch: Bool {
        get { JobResultPanelSession.isPanelOnlyLaunch }
        set { JobResultPanelSession.isPanelOnlyLaunch = newValue }
    }

    static var shouldUseEphemeralSession: Bool {
        panelOnlyLaunch
            || !interactiveSessionActive
            || DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
    }

    @Published private(set) var activeResult: PresentedJobResult?
    @Published private(set) var isPresented = false

    var allowsTermination: Bool {
        get { JobResultPanelSession.allowsTermination }
        set { JobResultPanelSession.allowsTermination = newValue }
    }

    struct PresentedJobResult: Identifiable, Equatable {
        let id: String
        let jobID: String
        let responseText: String
        let failureDetail: String?
        let createdAt: Date
        let scheduledAt: Date?
        let failed: Bool
        let failureCode: String?

        var displayText: String {
            guard failed else { return responseText }
            return JobFailureDisplay.composePresentation(
                responseText: responseText,
                failureDetail: failureDetail,
                failureCode: failureCode
            )
        }
    }

    private var panel: NSPanel?
    private var presentGeneration = 0
    private var ephemeralSession = false
    private var automaticTerminationDisabled = false

    private override init() {
        super.init()
    }

    func present(
        row: DBRepository.JobResultRow,
        scheduledAt: Date? = nil,
        ephemeralSession: Bool = false,
        failed: Bool = false,
        failureDetail: String? = nil,
        failureCode: String? = nil
    ) {
        if let current = activeResult, current.id == row.id, isPresented {
            fputs("[ui] JobResultPresenter skip duplicate id=\(row.id)\n", stderr)
            return
        }
        self.ephemeralSession = ephemeralSession
        if ephemeralSession {
            allowsTermination = false
            disableAutomaticTerminationIfNeeded()
        }
        activeResult = PresentedJobResult(
            id: row.id,
            jobID: row.jobID,
            responseText: row.responseText,
            failureDetail: failureDetail,
            createdAt: row.createdAt,
            scheduledAt: scheduledAt,
            failed: failed,
            failureCode: failureCode
        )
        isPresented = true
        // Never build AppKit UI synchronously inside UNUserNotificationCenter callbacks —
        // setActivationPolicy / panel ordering there can EXC_BAD_ACCESS.
        presentGeneration += 1
        let generation = presentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentGeneration == generation else { return }
            self.showStandalonePanel()
        }
    }

    func dismiss() {
        isPresented = false
        activeResult = nil
        let shouldQuit = ephemeralSession
        ephemeralSession = false
        tearDownPanel()
        enableAutomaticTerminationIfNeeded()
        if shouldQuit {
            // Hard exit — NSApp.terminate can relaunch this process with the same
            // `--derrick-show-job-result` argv via window restoration / open -n resume.
            JobResultPanelSession.allowsTermination = true
            DerrickJobResultPresentationWake.takePendingResultID()
            _exit(0)
        } else if !JobResultPanelSession.isPanelOnlyLaunch {
            allowsTermination = true
        }
    }

    // MARK: - Standalone panel

    private func showStandalonePanel() {
        guard let result = activeResult else { return }

        let shortID = String(result.id.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        let root = JobResultStandaloneCard(
            result: result,
            shortID: shortID,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]

        // Always rebuild so chrome/shadow settings stay correct across presents.
        if panel != nil {
            tearDownPanel()
        }

        // Subclass so borderless panel can become key — otherwise accessory apps
        // look windowless and macOS auto-terminates them within seconds.
        let panel = JobResultKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 608, height: 264),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // SwiftUI draws the card shadow; AppKit window shadow shows as a square halo.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.contentViewController = hosting
        panel.delegate = self
        let fit = hosting.sizeThatFits(in: NSSize(width: 608, height: CGFloat.greatestFiniteMagnitude))
        let height = min(max(ceil(fit.height), 144), 576)
        panel.setContentSize(NSSize(width: 608, height: height))
        self.panel = panel

        position(panel)
        // Swallow residual mouse-up from the notification click that launched us.
        panel.ignoresMouseEvents = true
        JobResultPanelSession.swallowMouseEventsUntil = Date().addingTimeInterval(1.0)
        JobResultPanelSession.installMouseSwallowMonitorIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak panel] in
            panel?.ignoresMouseEvents = false
        }
    }

    private func disableAutomaticTerminationIfNeeded() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("derrick.job-result-panel")
        ProcessInfo.processInfo.disableSuddenTermination()
        automaticTerminationDisabled = true
    }

    private func enableAutomaticTerminationIfNeeded() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("derrick.job-result-panel")
        automaticTerminationDisabled = false
    }

    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        var frame = panel.frame
        if frame.width < 100 || frame.height < 100 {
            frame.size = NSSize(width: 608, height: 264)
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            panel.setFrame(frame, display: true)
        } else {
            panel.center()
        }
    }

    private func tearDownPanel() {
        if let panel {
            panel.orderOut(nil)
            panel.delegate = nil
            panel.contentViewController = nil
            self.panel = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        fputs("[ui] JobResultPresenter.windowWillClose ephemeral=\(ephemeralSession)\n", stderr)
        isPresented = false
        activeResult = nil
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel = nil
        let shouldQuit = ephemeralSession
        ephemeralSession = false
        enableAutomaticTerminationIfNeeded()
        if shouldQuit {
            JobResultPanelSession.allowsTermination = true
            DerrickJobResultPresentationWake.takePendingResultID()
            _exit(0)
        } else if !JobResultPanelSession.isPanelOnlyLaunch {
            allowsTermination = true
        }
    }
}

/// Borderless `NSPanel` defaults to `canBecomeKey == false`, which makes accessory
/// panel-only launches look windowless and get auto-terminated by the system.
private final class JobResultKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Standalone card (not hosted inside ContentView)

private struct JobResultStandaloneCard: View {
    let result: JobResultPresenter.PresentedJobResult
    let shortID: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JobResultModalHeader(shortID: shortID, failed: result.failed)
            JobResultModalBody(result: result)
            JobResultModalFooter(onDismiss: onDismiss)
        }
        .frame(width: 576)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(16)
        .preferredColorScheme(.light)
    }
}

struct JobResultModalHeader: View {
    var shortID: String?
    var failed: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                .font(ModalChrome.symbolFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    failed
                        ? Color(red: 0.72, green: 0.22, blue: 0.18)
                        : Color(red: 0.176, green: 0.286, blue: 0.576)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(failed ? "Derrick · Job failed" : "Derrick · Job finished")
                    .font(.headline)
                    .lineLimit(1)
                if let shortID, !shortID.isEmpty {
                    Text("Result \(shortID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

struct JobResultModalBody: View {
    let result: JobResultPresenter.PresentedJobResult

    private var displayText: String {
        result.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsScroll: Bool {
        displayText.count > 504 || displayText.components(separatedBy: "\n").count > 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let scheduledAt = result.scheduledAt {
                Text("Scheduled for \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                if needsScroll {
                    ScrollView {
                        responseMarkdown
                    }
                    .frame(maxHeight: 288)
                } else {
                    responseMarkdown
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private var responseMarkdown: some View {
        MarkdownResponseView(
            text: displayText,
            allowsCSVExport: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JobResultModalFooter: View {
    let onDismiss: () -> Void
    @State private var acceptClicks = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button("OK") {
                guard acceptClicks else { return }
                onDismiss()
            }
            .buttonStyle(ModalPrimaryButtonStyle())
            .opacity(acceptClicks ? 1 : 0.55)
            .allowsHitTesting(acceptClicks)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .padding(.top, 0)
        .onAppear {
            // Click-through guard: notification mouse-up must not dismiss the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                DispatchQueue.main.async {
                    acceptClicks = true
                }
            }
        }
    }
}
