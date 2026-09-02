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

enum AuthStage {
    case landing      // pre-sign-in: show the landing page
    case signingIn    // sign-in window is open, waiting for it to finish
    case authenticated
}

@MainActor
final class BrowserModel: ObservableObject {
    static let homeURL = URL(string: "https://www.xbox.com/play")!

    @Published private(set) var authStage: AuthStage = {
        UserDefaults.standard.bool(forKey: "hasCompletedSignIn") ? .authenticated : .landing
    }()
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showReport = true
    @Published private(set) var report = SpikeReport()

    weak var webView: WKWebView?
    private var authWindow: NSWindow?
    private var authCoordinator: AuthFlowCoordinator?

    private static let signedInKey = "hasCompletedSignIn"

    init() {
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
            let ids = body["ids"] as? [String] ?? []
            report.webControllerIDs = ids
        case "gamepad-error":
            note("Gamepad polling error: \(body["detail"] as? String ?? "unknown")")
        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    // MARK: - Sign-in flow

    /// Opens a small separate window with the Xbox sign-in page. When the login
    /// flow eventually lands back on xbox.com/.../play, the window closes itself
    /// and the app proceeds — the session cookie lives in the app's shared,
    /// persistent website data store.
    func startSignIn() {
        guard authWindow == nil else { return }
        authStage = .signingIn

        let coordinator = AuthFlowCoordinator(browser: self)
        authCoordinator = coordinator

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Sign in to Xbox"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = coordinator

        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = coordinator
        window.contentView = webView
        webView.load(URLRequest(url: Self.homeURL))

        window.makeKeyAndOrderFront(nil)
        authWindow = window
    }

    func finishSignIn() {
        UserDefaults.standard.set(true, forKey: Self.signedInKey)
        authStage = .authenticated
        closeAuthWindow()
        note("Sign-in completed")
    }

    func signInCancelled() {
        guard authStage == .signingIn else { return }
        authStage = .landing
        authWindow = nil
        authCoordinator = nil
    }

    /// Clears all website data (session cookies included) and returns to the landing page.
    func signOut() {
        UserDefaults.standard.removeObject(forKey: Self.signedInKey)
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
            completionHandler: {}
        )
        closeAuthWindow()
        authStage = .landing
    }

    private func closeAuthWindow() {
        authWindow?.delegate = nil
        authWindow?.close()
        authWindow = nil
        authCoordinator = nil
    }

    // MARK: - Native controller monitoring

    private func refreshNativeControllers() {
        report.nativeControllerIDs = GCController.controllers().map { controller in
            controller.vendorName ?? "Game Controller"
        }
    }
}

/// Watches the sign-in window: any navigation that lands back on xbox.com's
/// player page means the Microsoft login succeeded and set the session cookie.
@MainActor
final class AuthFlowCoordinator: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private weak var browser: BrowserModel?

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, isSignedInPlayerURL(url) else { return }
        browser?.finishSignIn()
    }

    func windowWillClose(_ notification: Notification) {
        browser?.signInCancelled()
    }

    private func isSignedInPlayerURL(_ url: URL) -> Bool {
        guard let host = url.host, host.hasSuffix("xbox.com") else { return false }
        // The player lives at /play but xbox.com may localize the path (e.g. /en-US/play).
        return url.path.split(separator: "/").contains("play")
    }
}
