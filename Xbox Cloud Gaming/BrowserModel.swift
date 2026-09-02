//
//  BrowserModel.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import AppKit
import Combine
import GameController
import SwiftUI
import WebKit

struct SpikeReport: Equatable {
    var pageURL: String?
    var gamepadAPI = false
    var webRTC = false
    var userAgent = ""
    var webControllerIDs: [String] = []
    var nativeControllerIDs: [String] = []
    var messages: [String] = []
}

@MainActor
final class BrowserModel: ObservableObject {
    static let homeURL = URL(string: "https://www.xbox.com/play")!

    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showReport = false
    @Published var isSettingsWindowOpen = false
    @Published private(set) var report = SpikeReport()

    let controllerInput = ControllerInputService()
    lazy var settingsModel = SettingsModel(browser: self)

    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            self?.openSettingsWindow()
        }
        controllerInput.start()

        // This app drives a website, not documents: File and Edit menus add
        // noise. Remove them once the (SwiftUI-built) main menu exists.
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pruneFileAndEditMenus()
            }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        }
        refreshNativeControllers()
    }

    // MARK: - Settings window

    private var settingsWindow: NSWindow?
    private var profileWindows: [ProfileKind: NSWindow] = [:]

    /// Opens the settings as a real, separate NSWindow that we fully control
    /// (the SwiftUI Settings scene's responder action proved unreliable).
    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Settings"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView:
                SettingsRootView(model: settingsModel)
                    .environmentObject(self)
            )
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    private func pruneFileAndEditMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where ["File", "Edit"].contains(item.title) {
            mainMenu.removeItem(item)
        }
    }

    func closeSettingsWindow() {
        settingsWindow?.performClose(nil)
    }

    func openProfileEditor(_ kind: ProfileKind) {
        if profileWindows[kind] == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = kind.title
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView:
                ProfileEditorView(model: ProfileEditorModel(kind: kind, browser: self))
            )
            profileWindows[kind] = window
        }
        profileWindows[kind]?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    // MARK: - Actions

    func loadHome() {
        webView?.load(URLRequest(url: Self.homeURL))
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func toggleFullscreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    /// Wipes the persistent session cookies, signing the user out of the site.
    func signOut() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
            completionHandler: {}
        )
        loadHome()
    }

    func evaluateJS(_ script: String, completion: (@Sendable (Any?, (any Error)?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script, completionHandler: completion)
    }

    func callAsyncJS(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw CocoaError(.coderInvalidValue) }
        return try await webView.callAsyncJavaScript(functionBody, arguments: arguments, contentWorld: .page)
    }

    // MARK: - State updates (called by WebView.Coordinator)

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    func syncNavState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }

    func note(_ message: String) {
        report.messages.append(message)
        if report.messages.count > 50 {
            report.messages.removeFirst(report.messages.count - 50)
        }
    }

    func handleSpikeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "env":
            report.pageURL = body["url"] as? String
            report.gamepadAPI = (body["gamepadAPI"] as? Bool) ?? false
            report.webRTC = (body["webrtc"] as? Bool) ?? false
            report.userAgent = body["ua"] as? String ?? ""
        case "gamepads":
            report.webControllerIDs = body["ids"] as? [String] ?? []
        case "gamepad-error":
            note("Gamepad polling error: \(body["detail"] as? String ?? "unknown")")
        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    // MARK: - Native controller monitoring

    private func refreshNativeControllers() {
        report.nativeControllerIDs = GCController.controllers().map { controller in
            controller.vendorName ?? "Game Controller"
        }
    }
}
