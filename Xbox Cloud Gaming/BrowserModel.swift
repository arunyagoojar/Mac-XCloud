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
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var showReport = false
    @Published var isSettingsWindowOpen = false
    @Published private(set) var report = SpikeReport()
    @Published private(set) var isStreaming = false
    @Published private(set) var currentGameTitle = ""
    @Published private(set) var currentRegion = ""
    @Published private(set) var telemetry = StreamTelemetry.empty

    var statusController: MenuBarStatusController?
    let controllerInput = ControllerInputService()
    let controllerFeatures = ControllerFeatureService()
    private var cancellables = Set<AnyCancellable>()
    private var loadingTimeout: DispatchWorkItem?
    private var macroFields: [String: Double] = [:]
    lazy var settingsModel = SettingsModel(browser: self)

    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            self?.openSettingsWindow()
        }
        // UI controller input is live only while the settings window is open.
        controllerInput.isUIInputEnabled = { [weak self] in
            self?.settingsWindow?.isVisible == true
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
        controllerFeatures.onShortcutAction = { [weak self] action in self?.handleNativeAction(action) }
        controllerFeatures.onNativeInputState = { [weak self] snapshot in self?.sendNativeInput(snapshot) }
        controllerFeatures.onMacroButtonAction = { [weak self] control, isPressed in
            self?.setMacroField(control, isPressed: isPressed)
        }
        controllerFeatures.startPolling(interval: 1.0 / 60.0)

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

    // MARK: - Main window

    private(set) var mainWindow: NSWindow?
    private var escapeMonitor: Any?

    /// The main window is created in AppKit with its final chrome-less style
    /// mask from the start, so the game content runs edge-to-edge under the
    /// floating traffic lights (no titlebar strip).
    func openMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Xbox Cloud Gaming"
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
    }

    // MARK: - Settings window

    private var settingsWindow: NSWindow?
    private var controllerToolsWindow: NSWindow?
    private var controllerToolsDelegate: WindowCloseDelegate?
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

    func openControllerTools() {
        if controllerToolsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Controller Tools"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            let closeDelegate = WindowCloseDelegate { [weak self] in
                self?.setGamepadPollingPaused(false)
            }
            controllerToolsDelegate = closeDelegate
            window.delegate = closeDelegate
            window.center()
            window.contentView = NSHostingView(rootView:
                ControllerToolsView(service: controllerFeatures)
                    .environmentObject(self)
            )
            controllerToolsWindow = window
        }
        controllerToolsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func setGamepadPollingPaused(_ paused: Bool) {
        evaluateJS("try { if (window.BX_EXPOSED) window.BX_EXPOSED.disableGamepadPolling = \(paused); 'ok' } catch (e) { 'err' }")
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
        webView?.evaluateJavaScript(script, completionHandler: completion)
    }

    private var lastNativeInputSentAt: TimeInterval = 0

    func sendNativeInput(_ snapshot: ControllerInputSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNativeInputSentAt >= (1.0 / 60.0) else { return }
        lastNativeInputSentAt = now

        let gyroSettings = controllerFeatures.settings.gyro
        var gyroX: Double = 0
        var gyroY: Double = 0
        if let motion = snapshot.motion, gyroSettings.mode != .off {
            let active = gyroSettings.mode != .pointer || snapshot.leftTrigger > 0.15
            if active {
                switch gyroSettings.mode {
                case .raw: // steering from controller roll/gravity
                    gyroX = motion.gravity.x * Double(gyroSettings.sensitivityX)
                    gyroY = 0
                case .rightStick, .pointer:
                    gyroX = motion.rotationRate.y * Double(gyroSettings.sensitivityX) * 0.08
                    gyroY = -motion.rotationRate.x * Double(gyroSettings.sensitivityY) * 0.08
                case .off:
                    break
                }
                if abs(gyroX) < Double(gyroSettings.deadzone) { gyroX = 0 }
                if abs(gyroY) < Double(gyroSettings.deadzone) { gyroY = 0 }
                if gyroSettings.invertX { gyroX *= -1 }
                if gyroSettings.invertY { gyroY *= -1 }
            }
        }

        let calibration = controllerFeatures.settings.calibration
        let state: [String: Any] = [
            "enabled": true,
            "leftStick": ["x": snapshot.leftStick.x, "y": snapshot.leftStick.y],
            "rightStick": ["x": snapshot.rightStick.x, "y": snapshot.rightStick.y],
            "leftTrigger": snapshot.leftTrigger,
            "rightTrigger": snapshot.rightTrigger,
            "buttons": [
                "a": snapshot.buttons.a.value, "b": snapshot.buttons.b.value,
                "x": snapshot.buttons.x.value, "y": snapshot.buttons.y.value,
                "leftShoulder": snapshot.buttons.leftShoulder.value,
                "rightShoulder": snapshot.buttons.rightShoulder.value,
                "leftStick": snapshot.buttons.leftStick.value,
                "rightStick": snapshot.buttons.rightStick.value,
                "dpadUp": snapshot.buttons.dpadUp.value,
                "dpadDown": snapshot.buttons.dpadDown.value,
                "dpadLeft": snapshot.buttons.dpadLeft.value,
                "dpadRight": snapshot.buttons.dpadRight.value,
                "menu": snapshot.buttons.menu.value,
                "options": snapshot.buttons.options.value,
                "home": snapshot.buttons.home.value,
            ],
            // Calibration has already been applied natively to the snapshot;
            // keep bridge transform neutral and merge gyro afterward.
            "calibration": [:],
            "curve": ["default": 1.0],
            "deadzone": ["default": 0.0],
            "gyro": gyroSettings.mode == .raw
                ? ["LeftThumbXAxis": max(-1, min(1, gyroX))]
                : ["RightThumbXAxis": max(-1, min(1, gyroX)), "RightThumbYAxis": max(-1, min(1, gyroY))],
            "suppressBrowserRumble": controllerFeatures.settings.haptics.mode != .standard,
            "preset": controllerFeatures.settings.categoryPreset.selectedPreset.rawValue,
            "macro": macroFields,
        ]
        _ = calibration // documents that snapshots are already calibrated

        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateJS("try { BxCBridge.updateNativeInput(\(json)); 'ok' } catch (e) { 'err' }")
    }

    private func setMacroField(_ control: ControllerControl, isPressed: Bool) {
        let key: String?
        switch control {
        case .buttonA: key = "A"
        case .buttonB: key = "B"
        case .buttonX: key = "X"
        case .buttonY: key = "Y"
        case .menu: key = "Menu"
        case .options: key = "View"
        case .home: key = "Nexus"
        case .leftShoulder: key = "LeftShoulder"
        case .rightShoulder: key = "RightShoulder"
        case .leftStickButton: key = "LeftThumb"
        case .rightStickButton: key = "RightThumb"
        case .dpadUp: key = "DPadUp"
        case .dpadDown: key = "DPadDown"
        case .dpadLeft: key = "DPadLeft"
        case .dpadRight: key = "DPadRight"
        case .leftTrigger: key = "LeftTrigger"
        case .rightTrigger: key = "RightTrigger"
        case .touchpadButton: key = nil
        }
        guard let key else { return }
        if isPressed { macroFields[key] = 1 } else { macroFields.removeValue(forKey: key) }
    }

    func handleNativeAction(_ action: ControllerNativeAction) {
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
                      return JSON.stringify({info:info, stats:stats});
                    } catch (e) { return JSON.stringify({info:{playing:false,title:'',region:''},stats:null}); }
                    """)
                guard let text = result as? String, let data = text.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let info = root["info"] as? [String: Any] ?? [:]
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
        isLoading = true
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

    func pageBecameReady() {
        loadingTimeout?.cancel()
        loadingTimeout = nil
        hasReachedInitialReadiness = true
        isLoading = false
        withAnimation(.easeInOut(duration: 0.35)) { loadPhase = .ready }
    }

    func navigationFailed(_ error: Error, url: URL? = nil) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        loadPhase = .failed(BrowserLoadFailure(error: error, failingURL: url))
    }

    func webContentTerminated() {
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        loadPhase = .failed(BrowserLoadFailure(
            title: "Connection issue",
            message: "The Xbox web process stopped unexpectedly.",
            recoverySuggestion: "Retry to restart the Xbox page."
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
        case "gamepads":
            report.webControllerIDs = body["ids"] as? [String] ?? []
        case "gamepad-error":
            note("Gamepad polling error: \(body["detail"] as? String ?? "unknown")")
        case "app-fullscreen":
            toggleFullscreen()
        case "site-ready":
            let readyState = body["readyState"] as? String ?? ""
            if readyState == "interactive" || readyState == "complete" {
                pageBecameReady()
            }
        case "bridge-ready":
            note("Better xCloud bridge ready")
        case "native-rumble":
            let left = Float(body["leftMotorPercent"] as? Double ?? 0)
            let right = Float(body["rightMotorPercent"] as? Double ?? 0)
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
    }
}
