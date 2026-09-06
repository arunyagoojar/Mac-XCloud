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
    @Published var nativeHUDVisible = false
    @Published private(set) var nativeHUDItems = ["fps", "ping", "btr"]
    @Published private(set) var nativeHUDPosition = "top-right"
    @Published private(set) var nativeHUDOpacity = 0.9
    @Published private(set) var nativeHUDTextSize = 9.0
    @Published private(set) var nativeHUDBackground = 0.65
    @Published private(set) var nativeHUDColors = false
    @Published private(set) var nativeHUDQuickGlance = false

    @Published private(set) var nativeHUDGlancing = false
    @Published private(set) var nativeHUDValues: [String: String] = [:]
    @Published private(set) var telemetryUpdatedAt = Date.distantPast
    @Published private(set) var bridgeReady = false

    var remotePlayActive: Bool { report.remotePlayActive }
    var remoteServerStatus: String { report.remoteServerStatus }
    var remoteConsoleStatus: String { report.remoteConsoleStatus }
    var controllerMismatch: Bool { report.controllerMismatch }

    var statusController: MenuBarStatusController?
    let controllerFeatures = ControllerFeatureService()
    lazy var controllerInput = ControllerInputService(controllerProvider: controllerFeatures.selectedControllerProvider)
    lazy var inputPresets: InputPresetStore = {
        let store = InputPresetStore(browser: self)
        store.onSettingsApplied = { [weak self] in
            guard let self, self.isSettingsWindowOpen else { return }
            self.settingsModel.load()
        }
        return store
    }()
    private var cancellables = Set<AnyCancellable>()
    private var loadingTimeout: DispatchWorkItem?
    private(set) var controllerInputOwner: ControllerInputOwner = .none
    private var focusObservers: [NSObjectProtocol] = []
    private var controllerObservers: [NSObjectProtocol] = []
    private var browserGamepadSyncTask: Task<Void, Never>?
    lazy var settingsModel = SettingsModel(browser: self)

    @Published var controllerWebDiagnostics = "Run Check Web Support with the controller connected."
    private var rumbleSamples: [[String: Any]] = []
    func inspectControllerWebSupport() async {
        do {
            controllerWebDiagnostics = try await callAsyncJS("return JSON.stringify(BxCBridge.controllerDiagnostics(), null, 2);") as? String ?? "No browser response"
        } catch { controllerWebDiagnostics = error.localizedDescription }
    }
    private var aimTestUntil = Date.distantPast
    private var syntheticInputTestTask: Task<Void, Never>?
    private var syntheticInputTestID: UUID?

    func testAimRoute() {
        startSyntheticInputTest(values: ["nativeControllerCount": 1, "gyroX": 0.35], samples: 1,
            message: "Return to the game within 3 seconds; the camera will move right briefly.")
    }
    /// Bypasses sensors, but still needs a focused stream and one browser-visible
    /// controller. Diagnostics report bridge submission, not game acknowledgement.
    func testSteerRoute() {
        startSyntheticInputTest(values: ["nativeControllerCount": 1, "LeftThumbXAxis": -0.6], samples: 10,
            message: "Return to the game within 3 seconds; the car should hold left for about 1.5 seconds.")
    }

    private func startSyntheticInputTest(values: [String: Double], samples: Int, message: String) {
        stopSyntheticInputTest(message: "Previous input test cancelled.")
        let id = UUID()
        syntheticInputTestID = id
        controllerWebDiagnostics = message
        syntheticInputTestTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.syntheticInputTestID == id else { return }
                for _ in 0..<samples {
                    try Task.checkCancellation()
                    guard self.controllerInputOwner == .stream,
                          self.report.nativeControllerIDs.count == 1,
                          self.report.webControllerIDs.count == 1 else {
                        self.stopSyntheticInputTest(message: "Input test cancelled: focus the game with exactly one native and browser-visible controller.")
                        return
                    }
                    self.aimTestUntil = .distantFuture
                    self.pendingStreamInput = nil
                    let result = try await self.callAsyncJS("""
                        const b = window.BxCBridge;
                        if (!b || !b.updateNativeInput(values)) throw new Error("Browser input bridge unavailable");
                        return JSON.stringify(b.controllerDiagnostics(), null, 2);
                        """, arguments: ["values": values]) as? String ?? "No diagnostics returned"
                    guard self.syntheticInputTestID == id else { return }
                    self.controllerWebDiagnostics = "Input test submitted (not game acknowledgement):\n" + result
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard self.syntheticInputTestID == id else { return }
                self.stopSyntheticInputTest(message: "Input test finished; native override released.\n" + self.controllerWebDiagnostics)
            } catch {
                guard let self, self.syntheticInputTestID == id else { return }
                self.stopSyntheticInputTest(message: "Input test stopped: \(error.localizedDescription)")
            }
        }
    }

    private func stopSyntheticInputTest(message: String) {
        guard syntheticInputTestTask != nil else { return }
        syntheticInputTestTask?.cancel()
        syntheticInputTestTask = nil
        syntheticInputTestID = nil
        aimTestUntil = .distantPast
        pendingStreamInput = nil
        controllerWebDiagnostics = message
        // Restore physical input explicitly, rather than waiting for the 200 ms TTL.
        evaluateJS("window.BxCBridge?.updateNativeInput({});") { [weak self] _, error in
            guard let error else { return }
            let detail = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.syntheticInputTestID == nil else { return }
                self.controllerWebDiagnostics += "\nInput test release failed: " + detail
            }
        }
    }
    func testWebRumble(trigger: Bool) async {
        controllerFeatures.stopStreamRumble()
        do { controllerWebDiagnostics = try await callAsyncJS("return BxCBridge.testWebRumble(trigger);", arguments: ["trigger":trigger]) as? String ?? "No response" }
        catch { controllerWebDiagnostics = error.localizedDescription }
    }
    func exportControllerDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mac-XCloud-controller-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report: [String: Any] = ["game": currentGameTitle, "web": controllerWebDiagnostics,
                "nativeMotion": controllerFeatures.gyroAvailable, "rumbleSamples": rumbleSamples,
                "steeringSensor": controllerFeatures.steeringPreview, "motionStatus": controllerFeatures.motionStatus,
                "inputBridgeCalls": inputBridgeCalls, "inputBridgeAverageMs": inputBridgeTotalMs / Double(max(inputBridgeCalls, 1)),
                "inputBridgeMaxMs": inputBridgeMaxMs]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { controllerWebDiagnostics = error.localizedDescription }
    }
    private var streamInputInFlight = false
    private var pendingStreamInput: [String: Double]?
    private var inputBridgeCalls = 0
    private var inputBridgeTotalMs = 0.0
    private var inputBridgeMaxMs = 0.0
    weak var webView: WKWebView?

    init() {
        controllerInput.onToggleOverlay = { [weak self] in
            self?.openSettingsWindow()
        }
        // Native Settings uses mouse/keyboard navigation, not gamepad UI input.
        controllerInput.isUIInputEnabled = { false }
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
        controllerFeatures.onNativeInputState = { [weak self] state in
            guard let self else { return }
            let held = self.controllerInputOwner == .stream && state.buttons.home.isPressed
            if self.nativeHUDGlancing != held { self.nativeHUDGlancing = held }
        }
        controllerFeatures.onStreamInput = { [weak self] values in
            guard let self, self.controllerInputOwner == .stream, Date() >= self.aimTestUntil else { return }
            self.pendingStreamInput = values
            guard !self.streamInputInFlight else { return }
            self.streamInputInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.streamInputInFlight = false }
                while let values = self.pendingStreamInput {
                    self.pendingStreamInput = nil
                    guard self.controllerInputOwner == .stream, Date() >= self.aimTestUntil else { break }
                    let deliveredAt = ProcessInfo.processInfo.systemUptime
                    defer {
                        let elapsed = (ProcessInfo.processInfo.systemUptime - deliveredAt) * 1000
                        self.inputBridgeCalls += 1; self.inputBridgeTotalMs += elapsed
                        self.inputBridgeMaxMs = max(self.inputBridgeMaxMs, elapsed)
                    }
                    do {
                        let reply = try await self.callAsyncJS("const b = window.BxCBridge; return {ready: Boolean(b?.updateNativeInput(values))};", arguments: ["values": values]) as? [String: Any] ?? [:]
                        let ready = reply["ready"] as? Bool ?? false
                        let status = ready ? "Browser input updated" : "Browser aiming connection unavailable — reload stream"
                        if self.controllerFeatures.aimDeliveryStatus != status { self.controllerFeatures.aimDeliveryStatus = status }
                    } catch {
                        let status = "Browser input failed: \(error.localizedDescription)"
                        if self.controllerFeatures.aimDeliveryStatus != status { self.controllerFeatures.aimDeliveryStatus = status }
                    }
                }
            }
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
    func openSettingsWindow(route: SettingsRoute = .home) {
        if settingsModel.route != route {
            settingsModel.navigate(to: route)
        }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Mac Xcloud"
            window.identifier = NSUserInterfaceItemIdentifier("xcg-settings")
            window.contentMinSize = NSSize(width: 800, height: 620)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            window.toolbarStyle = .unifiedCompact
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

    /// Deep-links Controller Tools into Settings. Repeated opens participate in
    /// Settings history and never create a standalone controller-tools window.
    func openControllerTools(section: ControllerToolSection = .overview) {
        openSettingsWindow(route: .controllerSection(section))
    }

    func settingsRouteDidChange() {
        reconcileControllerOwnerState()
        // Keep the throttle in sync when navigation happens without a window
        // focus change (sidebar clicks while Settings is already key).
        if case .controllerSection(let section) = settingsModel.route {
            controllerFeatures.setHighRateUIDetail(controllerInputOwner == .settings && (section == .test || section == .calibration))
        } else {
            controllerFeatures.setHighRateUIDetail(false)
        }
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
            // Keep controller tests and calibration isolated from gameplay,
            // even though native Settings does not use gamepad UI navigation.
            setGamepadPollingPaused(true)
        case .profile:
            // Profile editors remain separate and do not consume controller UI.
            setGamepadPollingPaused(false)
        }
        let controllerRouteIsVisible: Bool
        if case .controllerSection(let section) = settingsModel.route {
            controllerRouteIsVisible = true
            // Live test/calibration pages need per-frame snapshots; everywhere
            // else the published snapshot is throttled so Settings never lags.
            controllerFeatures.setHighRateUIDetail(controllerInputOwner == .settings && (section == .test || section == .calibration))
        } else {
            controllerRouteIsVisible = false
            controllerFeatures.setHighRateUIDetail(false)
        }
        controllerFeatures.setControllerToolsActive(controllerInputOwner == .settings && controllerRouteIsVisible)
    }

    private func transitionControllerOwner(to next: ControllerInputOwner) {
        guard next != controllerInputOwner else {
            reconcileControllerOwnerState()
            return
        }
        let previous = controllerInputOwner
        controllerInputOwner = next
        if previous == .stream && next != .stream {
            stopSyntheticInputTest(message: "Input test cancelled: the game lost focus.")
        }
        reconcileControllerOwnerState()
        controllerFeatures.streamInputEnabled = next == .stream
        if next != .stream {
            controllerFeatures.resetMacros()
            evaluateJS("window.BxCBridge?.updateNativeInput({});")
        }
        if next != .settings { controllerFeatures.cancelCalibration() }
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
        case .toggleStats:
            nativeHUDVisible.toggle()
            // Native toggle: flip the Better xCloud preference and sync the bar
            // immediately, instead of relying on the page's shortcut handler.
            evaluateJS("""
                try {
                  var next = BxCBridge.getStream('stats.showWhenPlaying') !== true;
                  BxCBridge.setStream('stats.showWhenPlaying', next, 'ui');

                  'ok'
                } catch (e) { 'err' }
                """)
        case .volumeUp: evaluateJS("try { ShortcutHandler.runAction('stream.volume.inc'); 'ok' } catch(e) { 'err' }")
        case .volumeDown: evaluateJS("try { ShortcutHandler.runAction('stream.volume.dec'); 'ok' } catch(e) { 'err' }")
        case .mute: evaluateJS("try { ShortcutHandler.runAction('stream.sound.toggle'); 'ok' } catch(e) { 'err' }")
        case .custom(let identifier): evaluateJS("try { ShortcutHandler.runAction('\(identifier)'); 'ok' } catch(e) { 'err' }")
        case .macro(let id): controllerFeatures.runMacro(id: id)
        }
    }

    private var statsPollInFlight = false
    func pollStreamInfo() {
        guard !statsPollInFlight else { return }
        statsPollInFlight = true
        Task {
            defer { statsPollInFlight = false }
            do {
                let result = try await callAsyncJS("""
                    try {
                      var info = await BxCBridge.streamInfo();
                      var stats = null;
                      try { if (info.playing) stats = await BxCBridge.streamStats(); } catch (_) {}
                      var remote = window.STATES && window.STATES.remotePlay || {};
                      return JSON.stringify({info:info, stats:stats, remote:{active:!!(window.STATES && window.STATES.isPlaying && remote), server:remote.serverStatus || remote.serverState || (remote.server ? 'Connected' : 'Unknown'), console:remote.consoleStatus || remote.consoleState || (remote.consoleName ? 'Available' : 'Unknown')}});
                    } catch (e) { return JSON.stringify({info:{playing:false,title:'',region:''},stats:null}); }
                    """)
                guard let text = result as? String, let data = text.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let info = root["info"] as? [String: Any] ?? [:]
                let remote = root["remote"] as? [String: Any] ?? [:]
                nativeHUDVisible = info["hudVisible"] as? Bool ?? false
                let items = info["hudItems"] as? [String] ?? ["fps", "ping", "btr"]
                if nativeHUDItems != items { nativeHUDItems = items }
                let position = info["hudPosition"] as? String ?? "top-right"
                if nativeHUDPosition != position { nativeHUDPosition = position }
                let opacity = min(max(info["hudOpacity"] as? Double ?? 90, 10), 100) / 100
                if nativeHUDOpacity != opacity { nativeHUDOpacity = opacity }
                let background = min(max(info["hudBackground"] as? Double ?? 65, 0), 100) / 100
                if nativeHUDBackground != background { nativeHUDBackground = background }
                let colors = info["hudColors"] as? Bool ?? false
                if nativeHUDColors != colors { nativeHUDColors = colors }
                let glance = info["hudQuickGlance"] as? Bool ?? false
                if nativeHUDQuickGlance != glance { nativeHUDQuickGlance = glance }
                let textSize = info["hudTextSize"] as? String ?? "0.9rem"
                let size = textSize == "1.1rem" ? 11.0 : textSize == "1.0rem" ? 10.0 : 9.0
                if nativeHUDTextSize != size { nativeHUDTextSize = size }
                report.remotePlayActive = remote["active"] as? Bool ?? false
                report.remoteServerStatus = remote["server"] as? String ?? "Unknown"
                report.remoteConsoleStatus = remote["console"] as? String ?? "Unknown"
                isStreaming = info["playing"] as? Bool ?? false
                currentGameTitle = info["title"] as? String ?? ""
                let gameID = info["gameID"] as? String ?? ""
                let playing = isStreaming, gameTitle = currentGameTitle
                let gameKey = playing ? InputPresetStore.gameKey(id: gameID, title: gameTitle) : ""
                if inputPresets.currentGameID != gameKey {
                    Task { await inputPresets.noteGame(id: gameID, title: gameTitle, playing: playing) }
                }
                currentRegion = info["region"] as? String ?? ""
                if let stats = root["stats"] as? [String: Any] {
                    telemetryUpdatedAt = .now
                    let display = stats["display"] as? [String: String] ?? [:]
                    if nativeHUDValues != display { nativeHUDValues = display }
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
                } else if !isStreaming {
                    telemetry = .empty
                    nativeHUDValues = [:]
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
        stopSyntheticInputTest(message: "Input test cancelled: page navigation started.")
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
        stopSyntheticInputTest(message: "Input test cancelled: browser content stopped.")
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
            if report.webControllerIDs.count != 1 {
                stopSyntheticInputTest(message: "Input test cancelled: browser controller count changed.")
            }
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
            let raw = body["raw"] as? [String: Any] ?? [:]
            rumbleSamples.append(["time": Date().timeIntervalSince1970, "game": currentGameTitle, "raw": raw,
                "durationMs": body["durationMs"] as? Double ?? 150])
            if rumbleSamples.count > 240 { rumbleSamples.removeFirst(rumbleSamples.count - 240) }
            let left = Float(body["leftMotorPercent"] as? Double ?? 0) / 100
            let right = Float(body["rightMotorPercent"] as? Double ?? 0) / 100
            let durationMs = body["durationMs"] as? Double ?? 150
            controllerFeatures.recordRumble(left: Float(raw["leftMotorPercent"] as? Double ?? 0) / 100,
                right: Float(raw["rightMotorPercent"] as? Double ?? 0) / 100,
                leftTrigger: Float(raw["leftTriggerMotorPercent"] as? Double ?? 0) / 100,
                rightTrigger: Float(raw["rightTriggerMotorPercent"] as? Double ?? 0) / 100)
            controllerFeatures.receiveStreamRumble(left: left, right: right,
                leftTrigger: Float(body["leftTriggerMotorPercent"] as? Double ?? 0) / 100,
                rightTrigger: Float(body["rightTriggerMotorPercent"] as? Double ?? 0) / 100,
                duration: durationMs / 1_000)

        default:
            note("\(type): \(body["detail"] as? String ?? "")")
        }
    }

    // MARK: - Native controller monitoring

    private func refreshNativeControllers() {
        report.nativeControllerIDs = GCController.controllers().map { controller in
            controller.vendorName ?? "Game Controller"
        }
        if report.nativeControllerIDs.count != 1 {
            stopSyntheticInputTest(message: "Input test cancelled: native controller count changed.")
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
