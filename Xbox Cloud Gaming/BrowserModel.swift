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

    @Published private(set) var authStage: AuthStage
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
        authStage = UserDefaults.standard.bool(forKey: Self.signedInKey) ? .authenticated : .landing

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
        case "authcheck":
            // The player page is showing a public signed-out homepage: the saved
            // session is gone, so fall back to the landing page.
            if (body["signedOut"] as? Bool) == true, authStage == .authenticated {
                UserDefaults.standard.removeObject(forKey: Self.signedInKey)
                authStage = .landing
                note("Session expired — sign-in required")
            }
        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    // MARK: - Sign-in flow

    /// Opens a small separate window with the Xbox sign-in flow. Success is
    /// verified, not assumed: the page must be back on xbox.com's player AND no
    /// longer show a "Sign in" button in its header, on consecutive checks.
    func startSignIn() {
        guard authWindow == nil else { return }
        authStage = .signingIn

        let coordinator = AuthFlowCoordinator(browser: self)
        authCoordinator = coordinator

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(source: AuthFlowCoordinator.authCheckScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.add(coordinator, name: "authHandler")
        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Sign in to Xbox"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = coordinator

        let webView = WKWebView(frame: .zero, configuration: config)
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

/// Watches the sign-in window. "Signed in" means: on an xbox.com player URL and
/// the page header no longer offers a Sign in action, twice in a row. This
/// matters because xbox.com shows a public homepage at /play when signed out
/// instead of redirecting to the login flow.
@MainActor
final class AuthFlowCoordinator: NSObject, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    private weak var browser: BrowserModel?
    private var cleanChecks = 0

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let signedOut = (body["signedOut"] as? Bool) ?? true
        let urlString = body["url"] as? String ?? ""
        let onPlayerPage = isPlayerURL(urlString)

        if !signedOut && onPlayerPage {
            cleanChecks += 1
            if cleanChecks >= 2 {
                browser?.finishSignIn()
            }
        } else {
            cleanChecks = 0
        }
    }

    func windowWillClose(_ notification: Notification) {
        browser?.signInCancelled()
    }

    private func isPlayerURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host, host.hasSuffix("xbox.com") else { return false }
        // The player lives at /play but xbox.com may localize the path (e.g. /en-US/play).
        return url.path.split(separator: "/").contains("play")
    }

    /// Reports whether the page still offers a "Sign in" action (checked in the
    /// first chunk of the page text, where the site header lives).
    static let authCheckScript = #"""
    (function () {
      function send() {
        try {
          var text = document.body ? document.body.innerText.slice(0, 1500).toLowerCase() : '';
          window.webkit.messageHandlers.authHandler.postMessage({
            signedOut: text.indexOf('sign in') !== -1,
            url: location.href
          });
        } catch (e) {}
      }
      setInterval(send, 900);
      send();
    })();
    """#
}
