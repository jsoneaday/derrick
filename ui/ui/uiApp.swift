//
//  uiApp.swift
//  ui
//
//  Created by David Choi on 6/23/26.
//

import SwiftUI

@main
struct uiApp: App {
    @StateObject private var logStore = LogStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logStore)
                .preferredColorScheme(.light)
        }
    }
}
