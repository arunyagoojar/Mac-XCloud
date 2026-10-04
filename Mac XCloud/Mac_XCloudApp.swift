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
    #if DEBUG
    /// Development builds never update themselves over the release.
    private static let startsAutomatically = false
    #else
    private static let startsAutomatically = true
    #endif

    static let controller = SPUStandardUpdaterController(
        startingUpdater: startsAutomatically,
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
    /// Held without observation: the model publishes many times a second,
    /// and re-rendering the App body rebuilds the menu bar, which closes any
    /// open submenu. Views observe it through the environment instead.
    @State private var browser = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainWindowLauncher()
                StatusItemBootstrap()
                    .frame(width: 1, height: 1)
            }
            .environmentObject(browser)
            .onAppear {
                appDelegate.browser = browser
                // Validation affordance for scripted UI checks: launching with
                // --xcg-open-settings opens Settings (optionally on the page
                // named by --xcg-settings-route) without UI scripting.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--xcg-appearance"), arguments.indices.contains(index + 1) {
                    NSApp.appearance = NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
                }
                #if DEBUG
                if let index = arguments.firstIndex(of: "--xcg-snapshot-settings"), arguments.indices.contains(index + 1) {
                    SettingsSnapshotter.run(browser: browser, directory: URL(fileURLWithPath: arguments[index + 1]))
                }
                #endif
                if arguments.contains("--xcg-open-settings") {
                    let route: SettingsRoute
                    if let index = arguments.firstIndex(of: "--xcg-settings-route"),
                       arguments.indices.contains(index + 1) {
                        route = SettingsRoute.launchRoute(named: arguments[index + 1])
                    } else {
                        route = .home
                    }
                    browser.openSettingsWindow(route: route)
                }
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { browser.openSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Sign Out of Xbox…") { browser.confirmSignOut() }
            }
            ControllerCommands(browser: browser)
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
                Button { browser.showReport.toggle() } label: { DiagnosticsMenuLabel(browser: browser) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Full Screen") { browser.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
    }
}

/// Menu label that follows the diagnostics overlay state on its own.
private struct DiagnosticsMenuLabel: View {
    @ObservedObject var browser: BrowserModel
    var body: some View { Text(browser.showReport ? "Hide Diagnostics" : "Show Diagnostics") }
}
