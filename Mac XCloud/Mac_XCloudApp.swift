//
//  Mac_XCloudApp.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI
import Combine
import Sparkle

/// Shared Sparkle updater used by the app menu and the menu-bar menu.
/// Sparkle checks for updates automatically on launch and hourly
/// (SUEnableAutomaticChecks / SUScheduledCheckInterval in Config/Info.plist).
enum UpdaterService {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Menu item matching Sparkle's convention: enabled only when an update
/// check is possible.
struct CheckForUpdatesView: View {
    var body: some View {
        Button("Check for Updates…") {
            UpdaterService.checkForUpdates()
        }
        .disabled(!UpdaterService.controller.updater.canCheckForUpdates)
    }
}

@main
struct Mac_XCloudApp: App {
    @StateObject private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainWindowLauncher()
                StatusItemBootstrap()
                    .frame(width: 1, height: 1)
            }
            .environmentObject(browser)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
                Divider()
                Button("Sign Out") { browser.signOut() }
            }
            CommandMenu("Settings") {
                Button("Open Settings…") { browser.openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Keep these as two independent static top-level menus. Do not
            // observe controller state or nest a SwiftUI Menu/Picker here.
            CommandMenu("Left Trigger") {
                ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { mode in
                    Button(mode.htmlName) {
                        browser.controllerFeatures.updateSettings { settings in
                            settings.adaptiveTriggers.leftPreset = mode
                            settings.adaptiveTriggers.leftUsesCustom = false
                        }
                    }
                }
            }
            CommandMenu("Right Trigger") {
                ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { mode in
                    Button(mode.htmlName) {
                        browser.controllerFeatures.updateSettings { settings in
                            settings.adaptiveTriggers.rightPreset = mode
                            settings.adaptiveTriggers.rightUsesCustom = false
                        }
                    }
                }
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
    }
}
