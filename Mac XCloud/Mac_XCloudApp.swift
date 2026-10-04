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

/// Owns the app's single model and its windows. The game window is created
/// in AppKit at launch (see `BrowserModel.openMainWindow`), so SwiftUI never
/// opens a placeholder window of its own that could be left behind blank.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var browser = BrowserModel()
    private var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if browser.statusController == nil { browser.statusController = MenuBarStatusController(browser: browser) }
        browser.openMainWindow()
        handleLaunchArguments()
    }

    /// Clicking the Dock icon with no window open brings the game window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { browser.openMainWindow() }
        return false
    }

    /// Intercepts termination to confirm when a game is still streaming.
    /// Covers Cmd-Q, the app menu, the Dock, and the menu-bar Quit item.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitConfirmed, browser.isStreaming else { return .terminateNow }
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

    func applicationWillTerminate(_ notification: Notification) {
        browser.prepareForTermination()
    }

    /// macOS delivers `macxcloud://…` links here when the app is already
    /// running or launched by the link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { browser.handleDeepLink(url) }
    }

    /// Recent games, a click away in the Dock.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        browser.dockMenu.menu()
    }

    /// A game chosen in Spotlight.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = GameLibrary.gameID(fromSpotlight: userActivity) else { return false }
        browser.play(gameID: id)
        return true
    }

    /// Validation affordances for scripted UI checks.
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--xcg-appearance"), arguments.indices.contains(index + 1) {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
        }
        #if DEBUG
        if let index = arguments.firstIndex(of: "--xcg-snapshot-settings"), arguments.indices.contains(index + 1) {
            SettingsSnapshotter.run(browser: browser, directory: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--xcg-selftest"), arguments.indices.contains(index + 1) {
            SelfTest.run(browser: browser, directory: URL(fileURLWithPath: arguments[index + 1]))
        }
        #endif
        // --xcg-open-settings opens Settings (optionally on the page named by
        // --xcg-settings-route) without UI scripting.
        if arguments.contains("--xcg-open-settings") {
            var route = SettingsRoute.home
            if let index = arguments.firstIndex(of: "--xcg-settings-route"), arguments.indices.contains(index + 1) {
                route = SettingsRoute.launchRoute(named: arguments[index + 1])
            }
            browser.openSettingsWindow(route: route)
        }
    }
}

@main
struct Mac_XCloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The model is read here without observation: it publishes many times a
    /// second, and re-rendering the App body rebuilds the menu bar, which
    /// closes any open submenu.
    private var browser: BrowserModel { appDelegate.browser }

    var body: some Scene {
        // Only a Settings scene: every window is created by the app itself,
        // so SwiftUI has no window group to open (or reopen) on its own.
        Settings { EmptyView() }
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
            CommandGroup(replacing: .newItem) {}
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
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Game Window") { browser.openMainWindow() }
            }
        }
    }
}

/// Menu label that follows the diagnostics overlay state on its own.
private struct DiagnosticsMenuLabel: View {
    @ObservedObject var browser: BrowserModel
    var body: some View { Text(browser.showReport ? "Hide Diagnostics" : "Show Diagnostics") }
}
