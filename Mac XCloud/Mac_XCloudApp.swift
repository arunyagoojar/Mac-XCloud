//
//  Mac_XCloudApp.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import SwiftUI
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

/// Adaptive-trigger mode picker for one trigger side, shown in the app's
/// main menu bar. Checkmarks follow the live controller settings.
struct TriggerModeMenu: View {
    @ObservedObject var features: ControllerFeatureService
    let side: TriggerSide

    enum TriggerSide { case left, right }

    private var title: String { side == .left ? "Left Trigger" : "Right Trigger" }

    private var binding: Binding<AdaptiveTriggerPreset> {
        Binding(
            get: {
                side == .left
                    ? features.settings.adaptiveTriggers.leftPreset
                    : features.settings.adaptiveTriggers.rightPreset
            },
            set: { mode in
                features.updateSettings { settings in
                    if side == .left {
                        settings.adaptiveTriggers.leftPreset = mode
                        settings.adaptiveTriggers.leftUsesCustom = false
                    } else {
                        settings.adaptiveTriggers.rightPreset = mode
                        settings.adaptiveTriggers.rightUsesCustom = false
                    }
                }
            }
        )
    }

    var body: some View {
        Menu(title) {
            Picker(title, selection: binding) {
                ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { mode in
                    Text(mode.htmlName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(!features.capabilities.hasAdaptiveTriggers)
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
            CommandMenu("Triggers") {
                TriggerModeMenu(features: browser.controllerFeatures, side: .left)
                TriggerModeMenu(features: browser.controllerFeatures, side: .right)
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
