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

/// Intercepts app termination to confirm when a game is still streaming.
/// Covers Cmd-Q, the app menu, the Dock, and the menu-bar Quit item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var browser: BrowserModel? {
        didSet {
            // A macxcloud:// URL that opened the app can arrive before the
            // SwiftUI scene hands us the model; flush those now.
            guard browser != nil, !pendingLinks.isEmpty else { return }
            let links = pendingLinks
            pendingLinks.removeAll()
            links.forEach { browser?.handleDeepLink($0) }
        }
    }
    private var pendingLinks: [URL] = []
    private var quitConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitConfirmed else { return .terminateNow }
        guard let browser, browser.isStreaming else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while streaming?"
        let title = browser.currentGameTitle.isEmpty ? "A game" : browser.currentGameTitle
        alert.informativeText = "\(title) is still running in Xbox Cloud Gaming. Quitting now ends the session."
        alert.addButton(withTitle: "Quit and End Session")
        alert.addButton(withTitle: "Stay")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            quitConfirmed = true
            return .terminateNow
        }
        return .terminateCancel
    }

    /// macOS delivers `macxcloud://…` links here when the app is already
    /// running or launched by the link. Works regardless of window state
    /// because our real window is AppKit-owned, not SwiftUI.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser else {
            pendingLinks.append(contentsOf: urls)
            return
        }
        for url in urls { browser.handleDeepLink(url) }
    }
}

@main
struct Mac_XCloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainWindowLauncher()
                StatusItemBootstrap()
                    .frame(width: 1, height: 1)
            }
            .environmentObject(browser)
            .onAppear { appDelegate.browser = browser }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
                Divider()
                Button("Sign Out") { browser.signOut() }
            }
            CommandMenu("Settings") {
                Button("Open Settings…") { browser.openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()

            }
            AdaptiveTriggerCommands(service: browser.controllerFeatures)
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
