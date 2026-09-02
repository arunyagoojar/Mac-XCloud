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
    @Published var showSettingsOverlay = false
    @Published private(set) var report = SpikeReport()

    let controllerInput = ControllerInputService()
    lazy var overlayModel = OverlayModel(browser: self)

    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            guard let self else { return }
            self.showSettingsOverlay.toggle()
            if self.showSettingsOverlay { self.overlayModel.load() }
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

    func toggleSettingsOverlay() {
        showSettingsOverlay.toggle()
        if showSettingsOverlay {
            overlayModel.load()
        }
    }

    func evaluateJS(_ script: String, completion: ((Any?, (any Error)?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script, completionHandler: completion)
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
