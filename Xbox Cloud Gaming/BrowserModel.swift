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
    case landing      // "Who's playing today?" profile picker
    case signingIn    // sign-in window is open, waiting for it to finish
    case authenticated
}

/// One signed-in Microsoft account. `id` doubles as the identifier of the
/// profile's own persistent cookie store, so multiple accounts stay signed in
/// side by side.
struct PlayerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var gamertag: String
    var avatarURL: String?
}

@MainActor
final class BrowserModel: ObservableObject {
    static let homeURL = URL(string: "https://www.xbox.com/play")!

    private static let profilesKey = "playerProfiles"
    private static let selectedProfileKey = "selectedProfileID"

    @Published private(set) var authStage: AuthStage
    /// True once the saved session has been verified against the live site.
    /// While false, the landing page covers the player so a dead session can
    /// never flash the signed-out web page on launch.
    @Published private(set) var isSessionValidated: Bool
    @Published private(set) var profiles: [PlayerProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showReport = true
    @Published private(set) var report = SpikeReport()

    weak var webView: WKWebView?
    private var authWindow: NSWindow?
    private var authCoordinator: AuthFlowCoordinator?

    init() {
        var decodedProfiles: [PlayerProfile] = []
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([PlayerProfile].self, from: data) {
            decodedProfiles = decoded
        }
        let savedSelection = UserDefaults.standard.string(forKey: Self.selectedProfileKey).flatMap(UUID.init(uuidString:))

        if let id = savedSelection, decodedProfiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
            authStage = .authenticated
            isSessionValidated = false
        } else {
            selectedProfileID = nil
            authStage = .landing
            isSessionValidated = true
        }
        profiles = decodedProfiles

        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        }
        refreshNativeControllers()
    }

    var selectedProfile: PlayerProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    /// Each profile has its own persistent cookie jar; guest browsing (skip
    /// sign-in) uses a throwaway store so it can't touch any account.
    var activeDataStore: WKWebsiteDataStore {
        if let id = selectedProfileID {
            return WKWebsiteDataStore(forIdentifier: id)
        }
        return .nonPersistent()
    }

    // MARK: - Sign-in flow

    /// Opens a small separate window that goes straight to the Microsoft login
    /// page (it auto-clicks through xbox.com's "Sign in" button). Success is
    /// verified: the page must be back on the player, signed in, on consecutive
    /// checks — then the window closes itself and the profile is saved.
    func startSignIn(for profile: PlayerProfile? = nil) {
        guard authWindow == nil else { return }
        authStage = .signingIn

        let coordinator = AuthFlowCoordinator(browser: self,
                                              storeID: profile?.id ?? UUID(),
                                              existingProfileID: profile?.id)
        authCoordinator = coordinator

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(source: AuthFlowCoordinator.autoSignInScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.addUserScript(
            WKUserScript(source: AuthFlowCoordinator.authCheckScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.add(coordinator, name: "authHandler")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: coordinator.storeID)
        config.userContentController = contentController

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Microsoft Sign In"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = coordinator

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.attach(webView)
        window.contentView = webView
        webView.load(URLRequest(url: Self.homeURL))

        window.makeKeyAndOrderFront(nil)
        authWindow = window
    }

    func completeSignIn(storeID: UUID, existingProfileID: UUID?, gamertag: String?, avatarURL: String?) {
        let cleaned = gamertag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (cleaned?.isEmpty == false) ? cleaned! : "Player \(profiles.count + 1)"

        if let id = existingProfileID, let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].gamertag = name
            profiles[index].avatarURL = avatarURL
            selectedProfileID = id
        } else {
            let profile = PlayerProfile(id: storeID, gamertag: name, avatarURL: avatarURL)
            profiles.append(profile)
            selectedProfileID = profile.id
        }
        persistProfiles()
        persistSelection()
        closeAuthWindow()
        authStage = .authenticated
        isSessionValidated = true
    }

    func signInCancelled() {
        guard authStage == .signingIn else { return }
        authStage = .landing
        authWindow = nil
        authCoordinator = nil
    }

    /// Picks an existing profile. The session under it is re-verified first;
    /// if it has expired, the sign-in window opens for that account.
    func pickProfile(_ profile: PlayerProfile) {
        selectedProfileID = profile.id
        persistSelection()
        authStage = .authenticated
        isSessionValidated = false
    }

    /// Enter without an account (browse the store; streaming still needs a login).
    func skipSignIn() {
        selectedProfileID = nil
        persistSelection()
        authStage = .authenticated
        isSessionValidated = true
    }

    /// Signs out the selected profile: wipes its cookie store and removes it
    /// from the "Who's playing today?" list.
    func signOutSelectedProfile() {
        guard let profile = selectedProfile else { return }
        removeProfile(profile)
        authStage = .landing
        isSessionValidated = true
    }

    func removeProfile(_ profile: PlayerProfile) {
        let store = WKWebsiteDataStore(forIdentifier: profile.id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast,
                         completionHandler: {})
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = nil
        }
        persistProfiles()
        persistSelection()
        if authStage == .authenticated && selectedProfileID == nil {
            authStage = .landing
        }
    }

    private func closeAuthWindow() {
        authWindow?.delegate = nil
        authWindow?.close()
        authWindow = nil
        authCoordinator = nil
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
            handleAuthCheck(signedOut: (body["signedOut"] as? Bool) ?? false)
        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    private func handleAuthCheck(signedOut: Bool) {
        // Guests browse signed-out by design; nothing to verify.
        guard authStage == .authenticated, selectedProfileID != nil else { return }

        if signedOut {
            // Session died: go back to the picker and immediately offer
            // re-authentication for this account.
            isSessionValidated = false
            authStage = .landing
            note("Session expired — sign in again")
            if let profile = selectedProfile {
                startSignIn(for: profile)
            }
        } else {
            isSessionValidated = true
        }
    }

    // MARK: - Persistence

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }

    private func persistSelection() {
        if let id = selectedProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: Self.selectedProfileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedProfileKey)
        }
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
    let storeID: UUID
    private let existingProfileID: UUID?
    private weak var browser: BrowserModel?
    private weak var webView: WKWebView?
    private var cleanChecks = 0
    private var finished = false

    init(browser: BrowserModel, storeID: UUID, existingProfileID: UUID?) {
        self.browser = browser
        self.storeID = storeID
        self.existingProfileID = existingProfileID
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !finished, let body = message.body as? [String: Any] else { return }
        let signedOut = (body["signedOut"] as? Bool) ?? true
        let urlString = body["url"] as? String ?? ""

        if !signedOut && isPlayerURL(urlString) {
            cleanChecks += 1
            if cleanChecks >= 2 {
                finished = true
                scrapeIdentityAndFinish()
            }
        } else {
            cleanChecks = 0
        }
    }

    func windowWillClose(_ notification: Notification) {
        browser?.signInCancelled()
    }

    /// Grabs the gamertag and gamerpic from the signed-in page so the profile
    /// picker can show the real account. Falls back to a generic name.
    private func scrapeIdentityAndFinish() {
        let storeID = self.storeID
        let existingProfileID = self.existingProfileID
        webView?.evaluateJavaScript(Self.identityScript) { [weak self] result, _ in
            MainActor.assumeIsolated {
                var gamertag: String?
                var avatar: String?
                if let dict = result as? [String: Any] {
                    gamertag = dict["gamertag"] as? String
                    avatar = dict["avatar"] as? String
                }
                self?.browser?.completeSignIn(storeID: storeID,
                                              existingProfileID: existingProfileID,
                                              gamertag: gamertag,
                                              avatarURL: avatar)
            }
        }
    }

    private func isPlayerURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host, host.hasSuffix("xbox.com") else { return false }
        // The player lives at /play but xbox.com may localize the path (e.g. /en-US/play).
        return url.path.split(separator: "/").contains("play")
    }

    /// xbox.com shows its public homepage when signed out instead of a login
    /// redirect, so find the header "Sign in" control and click it. Stops as
    /// soon as the browser leaves for the Microsoft login domain.
    static let autoSignInScript = #"""
    (function () {
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        if (tries > 30) { clearInterval(timer); return; }
        var host = location.host;
        if (host.indexOf('login.') === 0 || host.indexOf('signin.') !== -1 || host.indexOf('live.com') !== -1) {
          clearInterval(timer);
          return;
        }
        if (host.indexOf('xbox.com') === -1) { return; }
        var els = document.querySelectorAll('a, button, [role="button"]');
        for (var i = 0; i < els.length; i++) {
          var label = ((els[i].innerText || '') + ' ' + (els[i].getAttribute('aria-label') || '')).trim().toLowerCase();
          if (label === 'sign in' || label.indexOf('sign in') === 0) {
            els[i].click();
            clearInterval(timer);
            return;
          }
        }
      }, 700);
    })();
    """#

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

    static let identityScript = #"""
    (function () {
      try {
        var img = document.querySelector('img[src*="xboxlive"], img[src*="gamerpic"], img[alt*="gamertag" i]');
        var name = null;
        var els = document.querySelectorAll('button[aria-label], a[aria-label]');
        for (var i = 0; i < els.length; i++) {
          var label = els[i].getAttribute('aria-label') || '';
          if (/profile|account|gamertag/i.test(label) && label.length < 60) { name = label; break; }
        }
        return { avatar: img ? img.src : null, gamertag: name };
      } catch (e) {
        return { avatar: null, gamertag: null };
      }
    })();
    """#
}
