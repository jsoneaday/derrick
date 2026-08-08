//
//  uiApp.swift
//  ui
//
//  Created by David Choi on 6/23/26.
//

import SwiftUI
import UserNotifications

@main
struct uiApp: App {
    @StateObject private var logStore = LogStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        RuntimeLog.shared.addSink { message in
            Task { @MainActor in
                DebugLogStore.shared.log(message)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logStore)
                .preferredColorScheme(.light)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = JobResultNotificationDelegate.shared
        JobResultNotificationPoster.requestAuthorizationIfNeeded()
        _ = JobResultPresenter.shared
    }
}
