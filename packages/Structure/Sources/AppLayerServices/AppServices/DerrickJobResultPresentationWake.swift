import Foundation

/// Cross-process wake to present a job-result panel (sandbox-safe: app group file + Darwin notify).
public enum DerrickJobResultPresentationWake: Sendable {
    public static let darwinName = "derrick.ui.presentJobResult"
    public static let localNotificationName = Notification.Name("derrick.ui.presentJobResult.local")
    private static let pendingFileName = "pending_job_result_presentation.txt"

    public static func post(resultID: String) {
        guard !resultID.isEmpty else { return }
        if let url = pendingFileURL() {
            try? resultID.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        let name = CFNotificationName(darwinName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    /// Read pending id without clearing (used to decide panel-only launch chrome).
    public static func peekPendingResultID() -> String? {
        readPendingResultID()
    }

    /// Read and clear the pending result id (if any).
    public static func takePendingResultID() -> String? {
        guard let id = readPendingResultID(), let url = pendingFileURL() else { return nil }
        try? FileManager.default.removeItem(at: url)
        return id
    }

    private static func readPendingResultID() -> String? {
        guard let url = pendingFileURL() else { return nil }
        guard let data = try? Data(contentsOf: url),
              let id = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    private static func pendingFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent(pendingFileName, isDirectory: false)
    }
}

/// Bridges Darwin notify → main-queue `NotificationCenter` without touching Swift objects in the CF callback.
public final class DerrickDarwinNotifyObserver: @unchecked Sendable {
    private let darwinName: String
    private let localName: Notification.Name
    private var cfObserver: UnsafeMutableRawPointer?
    private var localObserver: NSObjectProtocol?
    private let handler: @Sendable () -> Void

    public init(
        darwinName: String,
        localName: Notification.Name = DerrickJobResultPresentationWake.localNotificationName,
        handler: @escaping @Sendable () -> Void
    ) {
        self.darwinName = darwinName
        self.localName = localName
        self.handler = handler
    }

    public func start() {
        guard cfObserver == nil else { return }
        let token = Unmanaged.passUnretained(self).toOpaque()
        cfObserver = token
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            token,
            { _, observer, _, _, _ in
                // Darwin callback: only hop to GCD — no Swift/ObjC object use here.
                guard let observer else { return }
                let raw = UInt(bitPattern: observer)
                DispatchQueue.main.async {
                    let ptr = UnsafeMutableRawPointer(bitPattern: raw)
                    guard let ptr else { return }
                    let box = Unmanaged<DerrickDarwinNotifyObserver>.fromOpaque(ptr).takeUnretainedValue()
                    NotificationCenter.default.post(name: box.localName, object: nil)
                }
            },
            darwinName as CFString,
            nil,
            .deliverImmediately
        )
        localObserver = NotificationCenter.default.addObserver(
            forName: localName,
            object: nil,
            queue: .main
        ) { [handler] _ in
            handler()
        }
    }

    public func stop() {
        if let token = cfObserver {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                token,
                CFNotificationName(darwinName as CFString),
                nil
            )
            cfObserver = nil
        }
        if let localObserver {
            NotificationCenter.default.removeObserver(localObserver)
            self.localObserver = nil
        }
    }

    deinit {
        stop()
    }
}
