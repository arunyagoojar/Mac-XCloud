//
//  BrowserModel.swift
//  Xbox Cloud Gaming
//
//  Created by Arunya on 02/09/26.
//

import AppKit
import Combine
import GameController
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
    var settingsModel: SettingsModel?

    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            self?.openSettingsWindow()
        }
        controllerInput.start()

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

    func openSettingsWindow() {
        // SwiftUI's Settings scene responder; falls back to the 14.x selector.
        let selectors = ["showSettingsWindow:", "showSettings:"]
        for selector in selectors {
            if NSApp.sendAction(Selector(selector), to: nil, from: nil) { return }
        }
        NSLog("XCG could not open settings window")
    }

    func closeSettingsWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("settings") == true || $0.title == "Settings" }) {
            window.performClose(nil)
        } else if let keyWindow = NSApp.keyWindow, keyWindow != mainContentWindow() {
            keyWindow.performClose(nil)
        }
    }

    private func mainContentWindow() -> NSWindow? {
        webView?.window
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

    func evaluateJS(_ script: String, completion: ((Any?, (any Error)?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script, completionHandler: completion)
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
