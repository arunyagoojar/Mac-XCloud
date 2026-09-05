//
//  BrowserModel.swift
//  Mac XCloud
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
    var remotePlayActive = false
    var remoteServerStatus = "Unknown"
    var remoteConsoleStatus = "Unknown"
    var controllerMismatch = false
    var messages: [String] = []
}

enum ControllerInputOwner: Equatable {
    case none
    case stream
    case settings
    case controllerTools
    case profile(ProfileKind)
}

@MainActor
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

struct StreamTelemetry: Equatable {
    var pingMs: Double = -1
    var fps: Double = 0
    var bitrateMbps: Double = 0
    var packetLossPercent: Double = 0
    var packetLossCount: Int = 0
    var framesDropped: Int = 0
    var jitterMs: Double = 0
    var resolution = ""
    var decodeTimeMs: Double = 0

    static let empty = StreamTelemetry()
}

@MainActor
final class BrowserModel: ObservableObject {
    static let homeURL = URL(string: "https://www.xbox.com/play")!

    @Published private(set) var isLoading = true
    @Published private(set) var loadPhase: BrowserLoadPhase = .initialLoading
    @Published private(set) var hasReachedInitialReadiness = false
    @Published private(set) var hasFinishedBootVideo = false
    private var isSiteSemanticallyReady = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showReport = false
    @Published var isSettingsWindowOpen = false
    @Published private(set) var report = SpikeReport()
    @Published private(set) var isStreaming = false
    @Published private(set) var currentGameTitle = ""
    @Published private(set) var currentRegion = ""
    @Published private(set) var telemetry = StreamTelemetry.empty
    @Published private(set) var bridgeReady = false

    var remotePlayActive: Bool { report.remotePlayActive }
    var remoteServerStatus: String { report.remoteServerStatus }
    var remoteConsoleStatus: String { report.remoteConsoleStatus }
    var controllerMismatch: Bool { report.controllerMismatch }

    var statusController: MenuBarStatusController?
    let controllerFeatures = ControllerFeatureService()
    lazy var controllerInput = ControllerInputService(controllerProvider: controllerFeatures.selectedControllerProvider)
    lazy var inputPresets = InputPresetStore(browser: self)
    private var cancellables = Set<AnyCancellable>()
    private var loadingTimeout: DispatchWorkItem?
    private(set) var controllerInputOwner: ControllerInputOwner = .none
    private var focusObservers: [NSObjectProtocol] = []
    private var controllerObservers: [NSObjectProtocol] = []
    private var browserGamepadSyncTask: Task<Void, Never>?
    lazy var settingsModel = SettingsModel(browser: self)

    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            self?.openSettingsWindow()
        }
        // UI controller input is routed only to the active/key native window.
        controllerInput.isUIInputEnabled = { [weak self] in
            self?.controllerInputOwner == .settings
        }
        controllerInput.isSettingsShortcutEnabled = { [weak self] in
            self?.controllerInputOwner == .stream
        }
        // Auto-hide the mouse cursor while a controller is connected.
        controllerInput.onPresenceChange = { [weak self] connected in
            self?.evaluateJS("window.postMessage({ type: 'xcg-cursor-hide', enabled: \(connected) }, '*')")
        }
        // Mirror controller battery into the in-stream stats bar.
        controllerInput.$batteryPercent.combineLatest(controllerInput.$batteryStateText)
            .receive(on: RunLoop.main)
            .sink { [weak self] percent, stateText in
                guard let self, let percent else { return }
                let suffix = stateText == "Charging" ? " · Charging" : ""
                self.evaluateJS("window.postMessage({ type: 'xcg-battery', text: '🔋 \(percent)%\(suffix)' }, '*')")
            }
            .store(in: &cancellables)
        controllerInput.start()
        controllerFeatures.onShortcutAction = { [weak self] action in
            guard self?.controllerInputOwner == .stream else { return }
            self?.handleNativeAction(action)
        }
        controllerFeatures.onMacroButtonAction = { [weak self] control, isPressed in
            guard let self, self.controllerInputOwner == .stream,
                  let field = Self.macroField(for: control) else { return }
            let value = isPressed ? "1" : "null"
            self.evaluateJS("try { window.BxCBridge && BxCBridge.updateMacroButtons({\(field):\(value)}); } catch (e) {}")
        }
        controllerFeatures.onMacroReset = { [weak self] in
            self?.resetWebMacroOverlay()
        }
        controllerFeatures.startPolling(interval: 1.0 / 60.0)
        _ = inputPresets

        // This app drives a website, not documents: File and Edit menus add
        // noise. Remove them once the (SwiftUI-built) main menu exists.
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pruneFileAndEditMenus()
            }
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recomputeControllerOwner()
                    if let window = notification.object as? NSWindow,
                       window.identifier?.rawValue == "xcg-main",
                       window.isVisible {
                        self.synchronizeBrowserGamepadIfNeeded()
                    }
                }
            })
        }
        controllerObservers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        })
        controllerObservers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeControllers() }
        })
        refreshNativeControllers()
    }

    // MARK: - Main window

    private(set) var mainWindow: NSWindow?
    private var mainWindowDelegate: WindowCloseDelegate?
    private var escapeMonitor: Any?

    /// The main window is created in AppKit with its final chrome-less style
    /// mask from the start, so the game content runs edge-to-edge under the
    /// floating traffic lights (no titlebar strip).
    func openMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeBrowserGamepadIfNeeded()
            }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Mac Xcloud"
        window.identifier = NSUserInterfaceItemIdentifier("xcg-main")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1024, height: 576)
        window.center()
        window.contentView = NSHostingView(rootView:
            ContentView()
                .environmentObject(self)
                .ignoresSafeArea()
        )
        let mainDelegate = WindowCloseDelegate { [weak self, weak window] in
            guard let self, let window else { return }
            if self.mainWindow === window { self.mainWindow = nil }
            self.recomputeControllerOwner()
        }
        mainWindowDelegate = mainDelegate
        window.delegate = mainDelegate
        mainWindow = window
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let window = self?.mainWindow,
                      window.styleMask.contains(.fullScreen) else { return event }
                window.toggleFullScreen(nil)
                return nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeBrowserGamepadIfNeeded()
        }
    }

    // MARK: - Settings window

    private var settingsWindow: NSWindow?
    private var profileWindows: [ProfileKind: NSWindow] = [:]

    /// Opens the settings as a real, separate NSWindow that we fully control
    /// (the SwiftUI Settings scene's responder action proved unreliable).
    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Mac Xcloud"
            window.identifier = NSUserInterfaceItemIdentifier("xcg-settings")
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

    /// Legacy entry point retained for source compatibility. Controller Tools
    /// now lives inside Settings and the settings window owns controller input.
    func openControllerTools() {
        settingsModel.selectCategory("controller")
        openSettingsWindow()
    }

    private var isGamepadPollingPaused = false

    deinit {
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
        controllerObservers.forEach(center.removeObserver)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        browserGamepadSyncTask?.cancel()
    }

    func setGamepadPollingPaused(_ paused: Bool, force: Bool = false) {
        // Focus notifications can fire in bursts; repeatedly rewriting the flag
        // in the page makes xCloud's input loop stutter. Only send real changes.
        guard force || paused != isGamepadPollingPaused else { return }
        isGamepadPollingPaused = paused
        evaluateJS("try { if (window.BxCBridge) BxCBridge.setGamepadPollingPaused(\(paused)); else if (window.BX_EXPOSED) window.BX_EXPOSED.disableGamepadPolling = \(paused); 'ok' } catch (e) { 'err' }")
    }

    func resendGamepadPollingState() {
        setGamepadPollingPaused(controllerInputOwner == .settings, force: true)
        synchronizeBrowserGamepadIfNeeded()
    }

    /// Native GameController and WebKit expose the same physical device through
    /// different layers. When native presence is true but the page has not yet
    /// exposed its real Gamepad, keep the main WKWebView focused and ask the
    /// browser layer to rescan for a bounded startup window. No fake Gamepad is
    /// created; this only reproduces the focus transition that currently makes
    /// switching windows repair detection.
    private func synchronizeBrowserGamepadIfNeeded() {
        guard !report.nativeControllerIDs.isEmpty,
              controllerInputOwner == .stream || controllerInputOwner == .none,
              mainWindow?.isVisible == true else { return }
        browserGamepadSyncTask?.cancel()
        browserGamepadSyncTask = Task { [weak self] in
            for _ in 0..<24 {
                guard !Task.isCancelled, let self,
                      !self.report.nativeControllerIDs.isEmpty,
                      self.report.webControllerIDs.isEmpty else { return }
                await MainActor.run {
                    guard let webView = self.webView else { return }
                    if webView.window?.firstResponder !== webView {
                        webView.window?.makeFirstResponder(webView)
                    }
                    self.evaluateJS("try { window.BxCBridge && BxCBridge.rescanGamepads(); } catch (e) {}")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func resetWebMacroOverlay() {
        evaluateJS("try { window.BxCBridge && BxCBridge.resetMacroButtons(); } catch (e) {}")
    }

    private static func macroField(for control: ControllerControl) -> String? {
        switch control {
        case .buttonA: "A"
        case .buttonB: "B"
        case .buttonX: "X"
        case .buttonY: "Y"
        case .menu: "Menu"
        case .options: "View"
        case .home: "Nexus"
        case .leftShoulder: "LeftShoulder"
        case .rightShoulder: "RightShoulder"
        case .leftStickButton: "LeftThumb"
        case .rightStickButton: "RightThumb"
        case .dpadUp: "DPadUp"
        case .dpadDown: "DPadDown"
        case .dpadLeft: "DPadLeft"
        case .dpadRight: "DPadRight"
        case .touchpadButton: "Share"
        case .leftTrigger: "LeftTrigger"
        case .rightTrigger: "RightTrigger"
        }
    }

    private func owner(for window: NSWindow?) -> ControllerInputOwner {
        guard NSApp.isActive, let window else { return .none }
        let root = window.sheetParent ?? window
        switch root.identifier?.rawValue {
        case "xcg-main": return .stream
        case "xcg-settings": return .settings
        case "xcg-controller-tools": return .controllerTools
        case let value? where value.hasPrefix("xcg-profile-"):
            let raw = String(value.dropFirst("xcg-profile-".count))
            return ProfileKind(rawValue: raw).map(ControllerInputOwner.profile) ?? .none
        default: return .none
        }
    }

    private func recomputeControllerOwner() {
        transitionControllerOwner(to: owner(for: NSApp.keyWindow))
    }

    private func reconcileControllerOwnerState() {
        switch controllerInputOwner {
        case .stream, .none:
            // A transient loss of key window (fullscreen transitions, system
            // dialogs) must not pause the page's gamepad polling; only native
            // tooling windows take ownership of input.
            setGamepadPollingPaused(false)
        case .settings:
            // Settings is the only native consumer that currently translates
            // controller buttons into UI actions.
            setGamepadPollingPaused(true)
        case .controllerTools, .profile:
            // Profile editors remain separate and do not consume controller UI.
            setGamepadPollingPaused(false)
        }
        controllerFeatures.setControllerToolsActive(controllerInputOwner == .settings && settingsModel.selectedCategoryId == "controller")
    }

    private func transitionControllerOwner(to next: ControllerInputOwner) {
        guard next != controllerInputOwner else {
            reconcileControllerOwnerState()
            return
        }
        controllerInputOwner = next
        reconcileControllerOwnerState()
        if next != .stream { controllerFeatures.resetMacros() }
        if next != .controllerTools { controllerFeatures.cancelCalibration() }
    }

    func openProfileEditor(_ kind: ProfileKind) {
        if profileWindows[kind] == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = kind.title
            window.identifier = NSUserInterfaceItemIdentifier("xcg-profile-\(kind.rawValue)")
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
        navigationStarted()
        webView?.reload()
    }

    func retryLoading() {
        loadPhase = hasReachedInitialReadiness ? .subsequentLoading : .initialLoading
        if let webView, webView.url != nil { webView.reload() } else { loadHome() }
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
        guard let webView else {
            let error = NSError(domain: "BrowserModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web view is unavailable"])
            completion?(nil, error)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    func handleNativeAction(_ action: ControllerNativeAction) {
        guard controllerInputOwner == .stream else { return }
        switch action {
        case .none: break
        case .toggleSettings: openSettingsWindow()
        case .toggleFullscreen: toggleFullscreen()
        case .screenshot: evaluateJS("try { ShortcutHandler.runAction('stream.screenshot.capture'); 'ok' } catch(e) { 'err' }")
        case .toggleStats: evaluateJS("try { ShortcutHandler.runAction('stream.stats.toggle'); 'ok' } catch(e) { 'err' }")
        case .volumeUp: evaluateJS("try { ShortcutHandler.runAction('stream.volume.inc'); 'ok' } catch(e) { 'err' }")
        case .volumeDown: evaluateJS("try { ShortcutHandler.runAction('stream.volume.dec'); 'ok' } catch(e) { 'err' }")
        case .mute: evaluateJS("try { ShortcutHandler.runAction('stream.sound.toggle'); 'ok' } catch(e) { 'err' }")
        case .custom(let identifier): evaluateJS("try { ShortcutHandler.runAction('\(identifier)'); 'ok' } catch(e) { 'err' }")
        case .macro(let id): controllerFeatures.runMacro(id: id)
        }
    }

    func pollStreamInfo() {
        Task {
            do {
                let result = try await callAsyncJS("""
                    try {
                      var info = await BxCBridge.streamInfo();
                      var stats = info.playing ? await BxCBridge.streamStats() : null;
                      var remote = window.STATES && window.STATES.remotePlay || {};
                      return JSON.stringify({info:info, stats:stats, remote:{active:!!(window.STATES && window.STATES.isPlaying && remote), server:remote.serverStatus || remote.serverState || (remote.server ? 'Connected' : 'Unknown'), console:remote.consoleStatus || remote.consoleState || (remote.consoleName ? 'Available' : 'Unknown')}});
                    } catch (e) { return JSON.stringify({info:{playing:false,title:'',region:''},stats:null}); }
                    """)
                guard let text = result as? String, let data = text.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let info = root["info"] as? [String: Any] ?? [:]
                let remote = root["remote"] as? [String: Any] ?? [:]
                report.remotePlayActive = remote["active"] as? Bool ?? false
                report.remoteServerStatus = remote["server"] as? String ?? "Unknown"
                report.remoteConsoleStatus = remote["console"] as? String ?? "Unknown"
                isStreaming = info["playing"] as? Bool ?? false
                currentGameTitle = info["title"] as? String ?? ""
                currentRegion = info["region"] as? String ?? ""
                if let stats = root["stats"] as? [String: Any] {
                    let loss = stats["loss"] as? [String: Any] ?? [:]
                    let frames = stats["frames"] as? [String: Any] ?? [:]
                    telemetry = StreamTelemetry(
                        pingMs: (stats["ping"] as? NSNumber)?.doubleValue ?? -1,
                        fps: (stats["fps"] as? NSNumber)?.doubleValue ?? 0,
                        bitrateMbps: (stats["bitrate"] as? NSNumber)?.doubleValue ?? 0,
                        packetLossPercent: (loss["packetPercent"] as? NSNumber)?.doubleValue ?? 0,
                        packetLossCount: (loss["packets"] as? NSNumber)?.intValue ?? 0,
                        framesDropped: (frames["dropped"] as? NSNumber)?.intValue ?? 0,
                        jitterMs: (stats["jitter"] as? NSNumber)?.doubleValue ?? 0,
                        resolution: stats["resolution"] as? String ?? "",
                        decodeTimeMs: (stats["decodeTime"] as? NSNumber)?.doubleValue ?? 0
                    )
                } else {
                    telemetry = .empty
                }
                statusController?.refreshMenu()
            } catch {
                // Keep the last good telemetry sample; the page may be navigating.
            }
        }
    }

    func callAsyncJS(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw CocoaError(.coderInvalidValue) }
        return try await webView.callAsyncJavaScript(functionBody, arguments: arguments, contentWorld: .page)
    }

    // MARK: - State updates (called by WebView.Coordinator)

    func navigationStarted() {
        inputPresets.invalidateWebOperationsForNavigation()
        controllerFeatures.resetMacros()
        bridgeReady = false
        // The new page starts with polling enabled; clear the cache so the
        // next ownership reconcile re-sends the correct flag.
        isGamepadPollingPaused = false
        isLoading = true
        reconcileControllerOwnerState()
        loadPhase = hasReachedInitialReadiness ? .subsequentLoading : .initialLoading
        loadingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLoading else { return }
            self.loadPhase = .failed(BrowserLoadFailure(
                title: "Connection issue",
                message: "Xbox Cloud Gaming took too long to become ready.",
                recoverySuggestion: "Check your connection and try again.",
                failingURL: self.webView?.url
            ))
            self.isLoading = false
        }
        loadingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        if loading { navigationStarted() }
    }

    func bootVideoFinished() {
        hasFinishedBootVideo = true
        completeInitialLoadIfPossible()
    }

    func pageBecameReady() {
        isSiteSemanticallyReady = true
        completeInitialLoadIfPossible()
    }

    private func completeInitialLoadIfPossible() {
        guard isSiteSemanticallyReady else { return }
        guard hasReachedInitialReadiness || hasFinishedBootVideo else { return }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        hasReachedInitialReadiness = true
        isLoading = false
        withAnimation(.easeInOut(duration: 0.55)) { loadPhase = .ready }
    }

    func navigationFailed(_ error: Error, url: URL? = nil) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        loadPhase = .failed(BrowserLoadFailure(error: error, failingURL: url))
    }

    private var webContentTerminationDates: [Date] = []

    func webContentTerminated() {
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        bridgeReady = false
        controllerFeatures.stopHaptics()
        let now = Date()
        webContentTerminationDates = webContentTerminationDates.filter { now.timeIntervalSince($0) < 60 }
        webContentTerminationDates.append(now)
        let repeatedlyTerminated = webContentTerminationDates.count >= 3
        loadPhase = .failed(BrowserLoadFailure(
            title: repeatedlyTerminated ? "Xbox page repeatedly stopped" : "Connection issue",
            message: repeatedlyTerminated
                ? "The WebKit content process stopped several times. This can be caused by a private WebKit crash outside the app's control."
                : "The Xbox web process stopped unexpectedly.",
            recoverySuggestion: repeatedlyTerminated
                ? "Quit and reopen the app, then retry with the default renderer."
                : "Retry to restart the Xbox page."
        ))
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
        case "remote-status":
            report.remotePlayActive = body["active"] as? Bool ?? false
            report.remoteServerStatus = body["server"] as? String ?? "Unknown"
            report.remoteConsoleStatus = body["console"] as? String ?? "Unknown"
        case "gamepads":
            report.webControllerIDs = body["ids"] as? [String] ?? []
            report.controllerMismatch = !report.nativeControllerIDs.isEmpty && report.webControllerIDs.isEmpty
            if !report.webControllerIDs.isEmpty {
                inputPresets.retryActiveWebSettings()
            } else {
                controllerFeatures.resetMacros()
            }
        case "gamepad-error":
            note("Gamepad polling error: \(body["detail"] as? String ?? "unknown")")
        case "app-fullscreen":
            toggleFullscreen()
        case "site-ready":
            let readyState = body["readyState"] as? String ?? ""
            if readyState == "interactive" || readyState == "complete" {
                pageBecameReady()
                inputPresets.retryActiveWebSettings()
                if isSettingsWindowOpen { settingsModel.load() }
            }
        case "bridge-ready":
            bridgeReady = true
            evaluateJS("try { window.BxCBridge && BxCBridge.rescanGamepads(); } catch (e) {}")
            reconcileControllerOwnerState()
            setGamepadPollingPaused(controllerInputOwner == .settings, force: true)
            inputPresets.retryActiveWebSettings()
            if isSettingsWindowOpen { settingsModel.load() }
            note("Better xCloud bridge ready")
        case "native-rumble":
            let left = Float(body["leftMotorPercent"] as? Double ?? 0) / 100
            let right = Float(body["rightMotorPercent"] as? Double ?? 0) / 100
            let durationMs = body["durationMs"] as? Double ?? 150
            let intensity = min(max(max(left, right), 0), 1)
            if intensity > 0 {
                controllerFeatures.playTestPulse(
                    intensity: intensity,
                    sharpness: min(max(right, 0), 1),
                    duration: min(max(durationMs / 1_000, 0.03), 2)
                )
            }
        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    // MARK: - Native controller monitoring

    private func refreshNativeControllers() {
        report.nativeControllerIDs = GCController.controllers().map { controller in
            controller.vendorName ?? "Game Controller"
        }
        report.controllerMismatch = !report.nativeControllerIDs.isEmpty && report.webControllerIDs.isEmpty
        // Ask WebKit/Better xCloud to rescan its own real Gamepad list after
        // native connect/current notifications. This does not fabricate input.
        evaluateJS("try { window.BxCBridge && BxCBridge.rescanGamepads(); } catch (e) {}")
    }

    func retryControllerDiscovery() {
        refreshNativeControllers()
        evaluateJS("try { window.BxCBridge && BxCBridge.rescanGamepads(); } catch (e) {}")
        note("Requested a safe native/browser controller rescan")
    }
}
