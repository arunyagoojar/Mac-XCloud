//
//  Xbox_Cloud_GamingApp.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI

@main
struct Xbox_Cloud_GamingApp: App {
    @StateObject private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(browser)
                .frame(minWidth: 1024, minHeight: 576)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sign Out") { browser.signOut() }
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Page") { browser.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Back") { browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Go to xbox.com/play") { browser.loadHome() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button(browser.showReport ? "Hide Diagnostics" : "Show Diagnostics") {
                    browser.showReport.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Full Screen") { browser.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsRootView()
                .environmentObject(browser)
        }
    }
}
