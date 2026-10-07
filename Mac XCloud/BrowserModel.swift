//
//  BrowserModel.swift
//  Mac XCloud
//
//  Created by Arunya on 02/09/26.
//

import AppKit
import Combine
import GameController
import IOKit.pwr_mgt
import Network
import SwiftUI
import UserNotifications
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
    /// Called whenever the window finishes moving/resizing and before close,
    /// used to persist the window frame per display.
    var onFrameChange: ((NSWindow) -> Void)?
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { onFrameChange?(window) }
        onClose()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { onFrameChange?(window) }
    }
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { onFrameChange?(window) }
    }
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
    var packetsReceived: Int = 0
    var framesReceived: Int = 0
    /// The network's jitter (RTP interarrival, ms). `jitterMs` is Better
    /// xCloud's figure, the playout buffer's delay.
    var networkJitterMs: Double = 0
    var freezeCount: Int = 0
    var frameHeight: Int = 0

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
    @Published private(set) var currentGameID = ""
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
    @Published private(set) var isOffline = false

    var remotePlayActive: Bool { report.remotePlayActive }
    var remoteServerStatus: String { report.remoteServerStatus }
    var remoteConsoleStatus: String { report.remoteConsoleStatus }
    var controllerMismatch: Bool { report.controllerMismatch }

    var statusController: MenuBarStatusController?
    /// The running app's model, for App Intents (Shortcuts, Siri, Spotlight).
    private(set) static weak var current: BrowserModel?

    let controllerFeatures = ControllerFeatureService(defaults: BrowserModel.checkDefaults ?? .standard,
                                                      automaticallyAttach: !BrowserModel.isAutomatedCheck)
    let keyboardMouse = KeyboardMouseStore()
    let gameLibrary = GameLibrary()
    let streamHealth = StreamHealthMonitor()
    lazy var dockMenu = DockMenuBuilder(browser: self)
    lazy var controllerInput = ControllerInputService(controllerProvider: controllerFeatures.selectedControllerProvider)
    lazy var inputPresets: InputPresetStore = {
        let store = InputPresetStore(browser: self, defaults: Self.checkDefaults ?? .standard, directory: Self.checkProfilesDirectory)
        store.onSettingsApplied = { [weak self] in
            guard let self, self.isSettingsWindowOpen else { return }
            self.settingsModel.load()
        }
        store.onNewGameProfile = { [weak self] id, title in self?.offerSetup(gameID: id, title: title) }
        return store
    }()
    private var cancellables = Set<AnyCancellable>()
    private var loadingTimeout: DispatchWorkItem?
    private(set) var controllerInputOwner: ControllerInputOwner = .none
    private var focusObservers: [NSObjectProtocol] = []
    private var controllerObservers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    /// Set when the connection drops while a load is in flight or on the
    /// connection-issue screen; cleared after the automatic retry fires.
    private var autoRetryOnReconnect = false
    /// IOKit assertion id while the display must stay awake; 0 = none held.
    private var displaySleepAssertion: IOPMAssertionID = 0
    /// Game key the "your turn" alert has already fired for; reset when the
    /// session ends so the next launch alerts again.
    private var gameReadyAlertedKey = ""
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
                "steeringAngle": controllerFeatures.liveSteeringAngle, "motionStatus": controllerFeatures.motionStatus,
                "motionReportRateHz": controllerFeatures.motionReportRateHz,
                "steeringTrace": controllerFeatures.steeringTraceExport,
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
    /// True while the page holds pointer lock (keyboard & mouse play).
    @Published private(set) var pointerCaptured = false
    @Published private(set) var isFullscreen = false
    private var escapeHoldTask: Task<Void, Never>?
    private var escapeForwarded = false

    /// Delivers one virtual-controller state through the shared
    /// newest-sample-wins bridge path (used by motion engines and the
    /// keyboard/mouse fallback alike; stale samples never queue).
    private func submitStreamInput(_ values: [String: Double]) {
        guard controllerInputOwner == .stream, Date() >= aimTestUntil else { return }
        pendingStreamInput = values
        guard !streamInputInFlight else { return }
        streamInputInFlight = true
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

    func runMkbDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.callAsyncJS("""
                    const b = window.BxCBridge;
                    if (!b || !b.mkbDiagnostics) return JSON.stringify({bridge: false});
                    return JSON.stringify(b.mkbDiagnostics(), null, 2);
                    """) as? String ?? "No browser response"
                self.controllerWebDiagnostics = "Keyboard & mouse diagnostics:\n" + result
            } catch {
                self.controllerWebDiagnostics = "MKB diagnostics failed: \(error.localizedDescription)"
            }
        }
    }

    /// Who plays in the current game: "off" (no game, or nothing used yet in
    /// a game with its own keyboard & mouse support), "ready" (nothing used
    /// yet), "keyboard", "mouse" (keyboard with the mouse captured),
    /// "native" (the game's own keyboard & mouse) or "controller".
    @Published private(set) var keyboardEmulationState = "off"

    // MARK: - Full screen for games

    private static let fullscreenForGamesKey = "games.fullscreenOnStart.v1"
    static let fullscreenPersistedKeys = [fullscreenForGamesKey]
    /// Enter full screen when a game starts, so macOS can turn on Game Mode
    /// (game priority, and controllers polled more often over Bluetooth).
    @Published var fullscreenForGames = UserDefaults.standard.bool(forKey: fullscreenForGamesKey) {
        didSet { UserDefaults.standard.set(fullscreenForGames, forKey: Self.fullscreenForGamesKey) }
    }
    private var enteredFullscreenForGame = false

    private func gameSessionChanged(playing: Bool) {
        guard let window = mainWindow else { return }
        let inFullscreen = window.styleMask.contains(.fullScreen)
        if playing, fullscreenForGames, !inFullscreen, window.isVisible {
            enteredFullscreenForGame = true
            window.toggleFullScreen(nil)
        } else if !playing, enteredFullscreenForGame {
            enteredFullscreenForGame = false
            if inFullscreen { window.toggleFullScreen(nil) }
        }
    }

    /// A setup offered for a game played for the first time.
    @Published private(set) var setupOffer: GameSetupOffer?
    private var setupOfferTask: Task<Void, Never>?

    /// Looks up a new game's genre and, for racing games and shooters, offers
    /// the setup that suits it.
    private func offerSetup(gameID: String, title: String) {
        guard GameSetupPreferences.suggestionsEnabled else { return }
        setupOfferTask?.cancel()
        setupOfferTask = Task { @MainActor [weak self] in
            guard let self, let game = await self.gameLibrary.details(for: gameID), !Task.isCancelled,
                  self.isStreaming, self.currentGameID.uppercased() == gameID.uppercased(),
                  let kind = GameSetupKind.suggested(category: game.category, title: title.isEmpty ? game.title : title) else { return }
            let offer = GameSetupOffer(gameID: gameID, title: title.isEmpty ? game.title : title, kind: kind)
            withAnimation(.easeOut(duration: 0.25)) { self.setupOffer = offer }
            // Unanswered, it goes away on its own.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if self.setupOffer == offer { withAnimation(.easeIn(duration: 0.25)) { self.setupOffer = nil } }
        }
    }

    func acceptSetupOffer() {
        guard let offer = setupOffer else { return }
        controllerFeatures.updateSettings { offer.kind.apply(to: &$0) }
        withAnimation(.easeIn(duration: 0.2)) { setupOffer = nil }
        showHint("\(offer.title) is set up for \(offer.kind.purpose)", symbol: "checkmark.circle")
        mainWindow?.makeFirstResponder(webView)
    }

    func dismissSetupOffer(forever: Bool) {
        if forever {
            GameSetupPreferences.suggestionsEnabled = false
            showHint("Setup suggestions are off · Turn them on in Settings › Game Profiles", symbol: "info.circle")
        }
        withAnimation(.easeIn(duration: 0.2)) { setupOffer = nil }
        mainWindow?.makeFirstResponder(webView)
    }

    /// A one-off notice at the top of the game window ("Gyro aiming paused").
    @Published private(set) var transientHint: GameHint?
    private var transientHintCount = 0

    func showHint(_ text: String, symbol: String? = nil) {
        transientHintCount += 1
        let hint = GameHint(key: "notice-\(transientHintCount)", text: text, symbol: symbol)
        transientHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.transientHint == hint { self?.transientHint = nil }
        }
    }

    /// Sends the current keyboard layout and settings to the running page.
    func pushKeyboardConfiguration() {
        let json = keyboardMouse.pageConfigurationJSON
        evaluateJS("try { window.BxCBridge && BxCBridge.configureKeyboard(\(json)); } catch (e) {}")
    }

    // MARK: - Pointer capture and Escape

    /// Called by the web view's pointer-lock delegate and the page.
    func pointerLockChanged(_ locked: Bool) {
        guard pointerCaptured != locked else { return }
        pointerCaptured = locked
        if !locked {
            escapeHoldTask?.cancel(); escapeHoldTask = nil
            if escapeForwarded {
                escapeForwarded = false
                evaluateJS("try { window.BxCBridge && BxCBridge.forwardEscape(false); } catch (e) {}")
            }
        }
    }

    /// May the page capture the mouse right now?
    func allowsPointerLock(for webView: WKWebView) -> Bool {
        controllerInputOwner == .stream && webView.window?.isKeyWindow == true
            && WebView.Coordinator.isTrustedBridgeHost(webView.url?.host)
    }

    /// Forgets keyboard & mouse state belonging to a page that is going away.
    private func resetKeyboardMouseState() {
        escapeHoldTask?.cancel(); escapeHoldTask = nil
        escapeForwarded = false
        if pointerCaptured { pointerCaptured = false }
        if keyboardEmulationState != "off" { keyboardEmulationState = "off" }
        setupOfferTask?.cancel()
        if setupOffer != nil { setupOffer = nil }
    }

    /// User scripts are built once per web view; rebuild them before a reload
    /// so the page starts from the current settings (keyboard & mouse
    /// switches, mouse sensitivity, mirrored Better xCloud values).
    private func refreshUserScripts() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        BetterXCloud.userScripts(keyboardConfiguration: keyboardMouse.pageConfigurationJSON).forEach(controller.addUserScript)
        controller.addUserScript(WKUserScript(source: WebView.Coordinator.capabilitiesScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// Escape in the main window. While the mouse is captured WebKit would
    /// release it on any Escape press; instead a quick press is forwarded to
    /// the game and holding it releases the mouse. Otherwise Escape leaves
    /// full screen, then reaches the page as usual.
    private func routeEscape(_ event: NSEvent) -> NSEvent? {
        if pointerCaptured || escapeForwarded {
            if event.type == .keyDown {
                guard !event.isARepeat else { return nil }
                escapeForwarded = true
                evaluateJS("try { window.BxCBridge && BxCBridge.forwardEscape(true); } catch (e) {}")
                escapeHoldTask?.cancel()
                escapeHoldTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(KeyboardMouseStore.escapeHoldToRelease * 1_000_000_000))
                    guard let self, !Task.isCancelled, self.escapeForwarded else { return }
                    self.evaluateJS("try { window.BxCBridge && BxCBridge.releasePointer(); } catch (e) {}")
                }
            } else {
                escapeHoldTask?.cancel(); escapeHoldTask = nil
                if escapeForwarded {
                    escapeForwarded = false
                    evaluateJS("try { window.BxCBridge && BxCBridge.forwardEscape(false); } catch (e) {}")
                }
            }
            return nil
        }
        if event.type == .keyDown, !event.isARepeat, let window = mainWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return nil
        }
        return event
    }

    // MARK: - Full screen

    /// The page asked for (or left) element fullscreen.
    private func setNativeFullscreen(_ enter: Bool) {
        guard let window = mainWindow else { return }
        if window.styleMask.contains(.fullScreen) != enter { window.toggleFullScreen(nil) }
    }

    private func nativeFullscreenChanged(_ window: NSWindow) {
        guard window === mainWindow else { return }
        let active = window.styleMask.contains(.fullScreen)
        if isFullscreen != active { isFullscreen = active }
        // Leaving full screen from the window keeps the page "full screen"
        // while the mouse is captured (keyboard & mouse keeps working in a
        // window); otherwise the page follows, so its own button stays in sync.
        if !active, !pointerCaptured {
            evaluateJS("try { window.__xcgExitPageFullscreen && window.__xcgExitPageFullscreen(); } catch (e) {}")
        }
    }

    init() {
        Self.current = self
        gameLibrary.onChange = { AppShortcutsSync.refresh() }
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
            // A controller wakes up with its own light; show the chosen color.
            if connected { self?.settingsModel.applyLightBar() }
        }
        controllerFeatures.onLightRestore = { [weak self] in self?.settingsModel.applyLightBar() }
        keyboardMouse.onChange = { [weak self] in self?.pushKeyboardConfiguration() }
        streamHealth.onNotice = { [weak self] issue in
            guard let self, self.controllerInputOwner == .stream, self.setupOffer == nil else { return }
            self.showHint("\(issue.title) · \(issue.shortAdvice)", symbol: issue.symbol)
        }
        controllerFeatures.onGyroPauseToggled = { [weak self] off in
            guard let self, self.controllerInputOwner == .stream else { return }
            self.showHint(off ? "Gyro aiming off" : "Gyro aiming on", symbol: off ? "pause.circle" : "gyroscope")
        }
        controllerInput.onBatteryLow = { [weak self] percent in
            self?.notifyBatteryLow(percent: percent)
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
            self.submitStreamInput(values)
        }
        // 120 Hz: motion and touch reach the page within ~8 ms of the hand.
        controllerFeatures.startPolling(interval: 1.0 / 120.0)
        _ = inputPresets

        // This app drives a website, not documents: File and Edit menus add
        // noise. Remove them once the (SwiftUI-built) main menu exists.
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pruneFileAndEditMenus()
            }
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow else { return }
                    self?.nativeFullscreenChanged(window)
                }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recomputeControllerOwner()
                    if notification.name == NSApplication.didBecomeActiveNotification {
                        self.controllerFeatures.restoreControllerEffects()
                    }
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

        // Watch internet reachability: publish offline state for friendlier
        // errors, and retry automatically once when connectivity returns to a
        // load that the dropout interrupted.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOffline = !satisfied
                if !satisfied, self.isLoading || self.loadPhase.isLoading {
                    self.autoRetryOnReconnect = true
                } else if satisfied, self.autoRetryOnReconnect {
                    self.autoRetryOnReconnect = false
                    self.retryLoading()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "xcg.path-monitor", qos: .utility))

        // Mac Xcloud exists to play games: keep the MacBook awake for as long
        // as the app runs, so the screen never sleeps mid-session. Released
        // again when the model tears down (app quit).
        beginKeepingAwake()
    }

    /// Last chance to persist state that is otherwise saved lazily.
    func prepareForTermination() {
        controllerFeatures.persistLearnedState()
    }

    // MARK: - Keep-awake

    private func beginKeepingAwake() {
        guard displaySleepAssertion == 0 else { return }
        var assertionID: IOPMAssertionID = 0
        let reason = "Mac Xcloud is running" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            displaySleepAssertion = assertionID
        }
    }

    // MARK: - Main window

    private(set) var mainWindow: NSWindow?
    private var mainWindowDelegate: WindowCloseDelegate?
    private var escapeMonitor: Any?

    /// An unattended development check (see AutomatedCheck) is running.
    static var isAutomatedCheck: Bool {
        #if DEBUG
        AutomatedCheck.isRunning
        #else
        false
        #endif
    }

    /// Where such a check keeps game profiles and controller settings (nil:
    /// the real ones).
    private static var checkProfilesDirectory: URL? {
        #if DEBUG
        AutomatedCheck.isRunning ? AutomatedCheck.profilesDirectory : nil
        #else
        nil
        #endif
    }
    private static var checkDefaults: UserDefaults? {
        #if DEBUG
        AutomatedCheck.isRunning ? AutomatedCheck.defaults : nil
        #else
        nil
        #endif
    }

    /// The main window is created in AppKit with its final chrome-less style
    /// mask from the start, so the game content runs edge-to-edge under the
    /// floating traffic lights (no titlebar strip).
    func openMainWindow() {
        if let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activateIgnoringOtherAppsCompat(false)
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
        restoreMainWindowFrame(window)
        if Self.isAutomatedCheck { window.setFrameOrigin(NSPoint(x: -8000, y: -8000)) }
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
        mainDelegate.onFrameChange = { [weak self] window in
            guard !Self.isAutomatedCheck else { return }
            self?.saveMainWindowFrame(window)
        }
        mainWindowDelegate = mainDelegate
        window.delegate = mainDelegate
        mainWindow = window
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard event.keyCode == 53, let self, let window = self.mainWindow,
                      event.window === window else { return event }
                return self.routeEscape(event)
            }
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeBrowserGamepadIfNeeded()
        }
    }

    // MARK: - Per-display window frame memory

    private static let windowFramesKey = "xcg.mainWindow.frames.v1"
    private static let windowLastDisplayKey = "xcg.mainWindow.lastDisplay.v1"
    static var windowFramesDefaultsKey: String { windowFramesKey }

    private static func displayKey(for window: NSWindow) -> String? {
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return id.map { "d\($0.uint32Value)" }
    }

    private func saveMainWindowFrame(_ window: NSWindow) {
        // Full-screen frames are just display bounds — never persist those.
        guard window.styleMask.contains(.fullScreen) == false,
              window.isMiniaturized == false,
              let key = Self.displayKey(for: window) else { return }
        var frames = UserDefaults.standard.dictionary(forKey: Self.windowFramesKey) as? [String: String] ?? [:]
        frames[key] = NSStringFromRect(window.frame)
        UserDefaults.standard.set(frames, forKey: Self.windowFramesKey)
        UserDefaults.standard.set(key, forKey: Self.windowLastDisplayKey)
    }

    private func restoreMainWindowFrame(_ window: NSWindow) {
        window.center()
        guard let frames = UserDefaults.standard.dictionary(forKey: Self.windowFramesKey) as? [String: String],
              !frames.isEmpty else { return }
        // Try the display the window was last on first (e.g. after its frame
        // was moved), then any other display that still recognises a frame.
        var candidates = frames.keys.sorted()
        if let last = UserDefaults.standard.string(forKey: Self.windowLastDisplayKey),
           candidates.contains(last) {
            candidates.removeAll { $0 == last }
            candidates.insert(last, at: 0)
        }
        for key in candidates {
            guard let text = frames[key], let displayID = Self.displayID(fromKey: key) else { continue }
            let frame = NSRectFromString(text)
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }), screen.frame.intersects(frame),
               frame.width >= window.minSize.width, frame.height >= window.minSize.height else { continue }
            window.setFrame(frame, display: false)
            return
        }
    }

    private static func displayID(fromKey key: String) -> UInt32? {
        guard key.hasPrefix("d") else { return nil }
        return UInt32(key.dropFirst())
    }

    // MARK: - Settings window

    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: WindowCloseDelegate?
    private var profileWindows: [ProfileKind: NSWindow] = [:]

    /// Opens the settings as a real, separate NSWindow that we fully control
    /// (the SwiftUI Settings scene's responder action proved unreliable).
    func openSettingsWindow(route: SettingsRoute = .home) {
        if settingsModel.route != route {
            settingsModel.navigate(to: route)
        }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Mac Xcloud"
            window.identifier = NSUserInterfaceItemIdentifier("xcg-settings")
            window.contentMinSize = NSSize(width: 800, height: 620)
            // Unified toolbar look: the SwiftUI sidebar material and its
            // header row render inside the titlebar region itself.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView:
                SettingsRootView(model: settingsModel)
                    .environmentObject(self)
            )
            let delegate = WindowCloseDelegate { [weak self, weak window] in
                guard let self, let window, self.settingsWindow === window else { return }
                self.isSettingsWindowOpen = false
                self.settingsWindow = nil
                self.settingsWindowDelegate = nil
                self.recomputeControllerOwner()
            }
            settingsWindowDelegate = delegate
            window.delegate = delegate
            settingsWindow = window
        }
        isSettingsWindowOpen = true
        settingsModel.load()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activateIgnoringOtherAppsCompat(false)
    }

    private func pruneFileAndEditMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where ["File", "Edit"].contains(item.title) {
            mainMenu.removeItem(item)
        }
    }

    func settingsRouteDidChange() {
        reconcileControllerOwnerState()
    }

    private var isGamepadPollingPaused = false

    deinit {
        let center = NotificationCenter.default
        focusObservers.forEach(center.removeObserver)
        controllerObservers.forEach(center.removeObserver)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        browserGamepadSyncTask?.cancel()
        pathMonitor.cancel()
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
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
        // Live previews (stick dots, wheel angle, controller test) need fast
        // snapshots; every other page gets the throttled rate so Settings
        // never costs the game anything.
        let liveRoute = controllerInputOwner == .settings && (settingsModel.route.pane?.showsLiveInput ?? false)
        controllerFeatures.setHighRateUIDetail(liveRoute)
        controllerFeatures.setControllerToolsActive(liveRoute)
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
            // Another window took input: never leave the mouse captured.
            if pointerCaptured { evaluateJS("try { window.BxCBridge && BxCBridge.releasePointer(); } catch (e) {}") }
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
        NSApp.activateIgnoringOtherAppsCompat(false)
    }

    // MARK: - Actions

    func loadHome() {
        refreshUserScripts()
        webView?.load(URLRequest(url: Self.homeURL))
    }

    func reload() {
        navigationStarted()
        refreshUserScripts()
        webView?.reload()
    }

    func retryLoading() {
        refreshUserScripts()
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

    /// Asks first: signing out clears every Xbox website cookie and storage.
    func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of Xbox?"
        alert.informativeText = "You'll need to sign in with your Microsoft account again. Your Mac Xcloud settings and game profiles are kept."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { signOut() }
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
                if currentGameID != gameID { currentGameID = gameID }
                let playing = isStreaming, gameTitle = currentGameTitle
                // Remember the last title so macxcloud://resume can reopen it,
                // however the game was started.
                if playing, !gameID.isEmpty { lastPlayedGameID = gameID }
                // "Your turn": fire once per game start the moment a live
                // session appears, so a player waiting in queue can leave the
                // app and still hear/feel when the game is up.
                if playing {
                    let key = gameID.isEmpty ? gameTitle : gameID
                    if gameReadyAlertedKey != key {
                        gameReadyAlertedKey = key
                        notifyGameReady()
                        if !gameID.isEmpty { gameLibrary.notePlayed(id: gameID, title: gameTitle) }
                        gameSessionChanged(playing: true)
                    }
                } else {
                    if !gameReadyAlertedKey.isEmpty { gameSessionChanged(playing: false) }
                    gameReadyAlertedKey = ""
                }
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
                        decodeTimeMs: (stats["decodeTime"] as? NSNumber)?.doubleValue ?? 0,
                        packetsReceived: (loss["received"] as? NSNumber)?.intValue ?? 0,
                        framesReceived: (frames["received"] as? NSNumber)?.intValue ?? 0,
                        networkJitterMs: (stats["networkJitter"] as? NSNumber)?.doubleValue ?? 0,
                        freezeCount: (frames["freezes"] as? NSNumber)?.intValue ?? 0,
                        frameHeight: (stats["height"] as? NSNumber)?.intValue ?? 0
                    )
                    if isStreaming { streamHealth.ingest(telemetry) }
                } else if !isStreaming {
                    telemetry = .empty
                    nativeHUDValues = [:]
                }
                if !isStreaming { streamHealth.reset() }
                watchPageMemory()
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
        resetKeyboardMouseState()
        bridgeReady = false
        // The new page starts with polling enabled; clear the cache so the
        // next ownership reconcile re-sends the correct flag.
        isGamepadPollingPaused = false
        isLoading = true
        reconcileControllerOwnerState()
        controllerFeatures.recheckMotionSensors()
        streamInputInFlight = false
        loadPhase = hasReachedInitialReadiness ? .subsequentLoading : .initialLoading
        loadingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLoading else { return }
            self.failUnlessPageIsAlive { [weak self] in
            guard let self, self.isLoading else { return }
            self.loadPhase = .failed(BrowserLoadFailure(
                title: self.isOffline ? "You appear to be offline" : "Connection issue",
                message: self.isOffline
                    ? "This Mac has no internet connection, so Xbox Cloud Gaming can't load."
                    : "Xbox Cloud Gaming took too long to become ready.",
                recoverySuggestion: self.isOffline
                    ? "Reconnect to Wi-Fi or Ethernet — the page reloads automatically when the connection returns."
                    : "Check your connection and try again.",
                failingURL: self.webView?.url
            ))
            self.isLoading = false
            if self.isOffline { self.autoRetryOnReconnect = true }
            }
        }
        loadingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
    }

    /// The load watchdog's last check: a page that has rendered and answers
    /// script is working, whatever WebKit's navigation callbacks said (a
    /// replaced or same-document navigation never reports "finished").
    private func failUnlessPageIsAlive(_ fail: @escaping () -> Void) {
        guard let webView, !isOffline else { fail(); return }
        webView.evaluateJavaScript("document.readyState === 'complete' && !!document.body && document.body.childElementCount > 0") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if result as? Bool == true {
                    self.note("Load watchdog: page is responsive, treating it as ready")
                    self.pageBecameReady()
                    self.isLoading = false
                    if self.hasReachedInitialReadiness { self.loadPhase = .ready }
                } else {
                    fail()
                }
            }
        }
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        if loading { navigationStarted() }
    }

    func pageDidFinishLoading() {
        // The document fully loaded. If a ready signal already arrived, this
        // completes the load; otherwise a shorter timer still resolves the
        // overlay instead of leaving it stuck on "Loading".
        loadingTimeout?.cancel()
        loadingTimeout = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isSiteSemanticallyReady {
                self.completeInitialLoadIfPossible()
            } else {
                self.failUnlessPageIsAlive { [weak self] in
                    guard let self else { return }
                    self.loadPhase = .failed(BrowserLoadFailure(
                        title: "Connection issue",
                        message: "Xbox Cloud Gaming finished loading but never became ready.",
                        recoverySuggestion: "Retry to reload the page.",
                        failingURL: self.webView?.url
                    ))
                    self.isLoading = false
                }
            }
        }
        loadingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func bootVideoFinished() {
        hasFinishedBootVideo = true
        completeInitialLoadIfPossible()
    }

    func pageBecameReady() {
        isSiteSemanticallyReady = true
        // The page is genuinely interactive now; the pending finish-loading
        // timer is no longer needed.
        loadingTimeout?.cancel()
        loadingTimeout = nil
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

    private var silentRetryAt = Date.distantPast

    func navigationFailed(_ error: Error, url: URL? = nil, provisional: Bool = true) {
        let nsError = error as NSError
        // A navigation replaced by another one, or interrupted by a policy
        // decision, is not a failure.
        let interrupted = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204))
        if interrupted {
            if webView?.isLoading == false {
                loadingTimeout?.cancel(); loadingTimeout = nil
                isLoading = false
                if hasReachedInitialReadiness, case .subsequentLoading = loadPhase { loadPhase = .ready }
            }
            return
        }
        // A late error on a page that already committed and is working (a
        // dropped request after load) must not cover the page.
        if !provisional, hasReachedInitialReadiness {
            note("Ignored a late load error on a working page: \(nsError.localizedDescription)")
            loadingTimeout?.cancel(); loadingTimeout = nil
            isLoading = false
            if case .subsequentLoading = loadPhase { loadPhase = .ready }
            return
        }
        // Brief network hiccups (Wi-Fi roaming, a connection reset) get one
        // quiet retry before anything is shown.
        let transient: Set<Int> = [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                                   NSURLErrorSecureConnectionFailed, NSURLErrorDNSLookupFailed]
        if nsError.domain == NSURLErrorDomain, transient.contains(nsError.code), !isOffline,
           Date().timeIntervalSince(silentRetryAt) > 20 {
            silentRetryAt = Date()
            note("Retrying after a transient network error: \(nsError.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if let url, self.webView?.url == nil || self.webView?.url == url {
                    self.webView?.load(URLRequest(url: url))
                } else {
                    self.webView?.reload()
                }
            }
            return
        }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        let offline = isOffline || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet)
        autoRetryOnReconnect = offline
        var failure = BrowserLoadFailure(error: error, failingURL: url)
        if offline {
            failure = BrowserLoadFailure(
                title: "You appear to be offline",
                message: "This Mac has no internet connection, so Xbox Cloud Gaming couldn't load.",
                recoverySuggestion: "Reconnect to Wi-Fi or Ethernet — the page reloads automatically when the connection returns.",
                failingURL: url
            )
        }
        loadPhase = .failed(failure)
    }

    // MARK: - Page memory

    private var memoryWatch = PageMemoryWatch()
    private var memoryCheckedAt: TimeInterval = 0
    private var memoryStepInFlight = false

    /// Every two seconds while a game streams, reads how much memory macOS
    /// charges the Xbox page (see PageMemoryGuard.swift).
    private func watchPageMemory() {
        guard isStreaming else { memoryWatch.reset(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - memoryCheckedAt >= 2, let webView,
              webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              let megabytes = PageProcess.footprintMB(pid: pid) else { return }
        memoryCheckedAt = now
        guard memoryWatch.add(megabytes, at: now) else { return }
        memoryWatch.reset()
        lightenRenderer(footprintMB: megabytes)
    }

    /// The page's memory is racing toward WebKit's limit: Sharpening moves to
    /// the next lighter renderer while the game keeps running (Better xCloud
    /// switches it live), and that choice is kept.
    private func lightenRenderer(footprintMB: Double) {
        guard !memoryStepInFlight else { return }
        memoryStepInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.memoryStepInFlight = false }
            let reply = try? await self.callAsyncJS("""
                try {
                  return JSON.stringify({renderer: String(BxCBridge.getStream('video.player.type')),
                                         processing: String(BxCBridge.getStream('video.processing'))});
                } catch (e) { return null; }
                """) as? String
            guard let data = reply?.data(using: .utf8),
                  let current = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let renderer = current["renderer"] else { return }
            let megabytes = Int(footprintMB.rounded())
            guard let lighter = PageMemoryWatch.lighterRenderer(than: renderer),
                  let def = self.settingsModel.def("app.clarityPipeline") else {
                self.note("Page memory: \(megabytes) MB and climbing with the plain video renderer")
                return
            }
            let pipeline = PageMemoryWatch.pipeline(renderer: lighter, processing: current["processing"] ?? "cas")
            self.settingsModel.write(id: def.id, scope: def.scope, value: pipeline)
            self.note("Page memory: \(megabytes) MB and climbing with the \(renderer) renderer; Sharpening switched to \(pipeline)")
            self.showHint(lighter == "default" ? "Sharpening turned off to keep the game running"
                                               : "Sharpening switched to Standard to keep the game running", symbol: "memorychip")
        }
    }

    private var webContentTerminationDates: [Date] = []
    private var lastAutoReconnectAt = Date.distantPast

    /// `reason` is WebKit's: 0 memory limit, 1 CPU limit, 2 requested by the
    /// app, 3 crash; nil when WebKit doesn't say.
    func webContentTerminated(reason: Int? = nil) {
        let wasPlaying = isStreaming
        note("Web content process terminated" + (reason == 0 ? " (memory limit)" : reason == 1 ? " (CPU limit)" : reason == 3 ? " (crash)" : ""))
        stopSyntheticInputTest(message: "Input test cancelled: browser content stopped.")
        loadingTimeout?.cancel()
        loadingTimeout = nil
        isLoading = false
        bridgeReady = false
        resetKeyboardMouseState()
        controllerFeatures.stopHaptics()
        memoryWatch.reset()
        let now = Date()
        webContentTerminationDates = webContentTerminationDates.filter { now.timeIntervalSince($0) < 60 }
        webContentTerminationDates.append(now)
        let repeatedlyTerminated = webContentTerminationDates.count >= 3
        // Mid-game, go straight back to the game: Xbox keeps the session for
        // a few minutes, so reloading the stream page picks it up again.
        // Once a minute at most, so a page that keeps failing at once still
        // ends on the screen below.
        if wasPlaying, reason != 2, !isOffline, !repeatedlyTerminated, now.timeIntervalSince(lastAutoReconnectAt) > 60 {
            lastAutoReconnectAt = now
            showHint(reason == 0 ? "The Xbox page ran out of memory · Reconnecting to your game"
                                 : "The Xbox page stopped · Reconnecting to your game", symbol: "arrow.clockwise")
            retryLoading()
            return
        }
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
        case "navigate-back":
            if !isStreaming && !isSettingsWindowOpen { goBack() }
        case "env":
            report.pageURL = body["url"] as? String
            report.gamepadAPI = (body["gamepadAPI"] as? Bool) ?? false
            report.webRTC = (body["webrtc"] as? Bool) ?? false
            report.userAgent = body["ua"] as? String ?? ""
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
            if let enter = body["enter"] as? Bool { setNativeFullscreen(enter) } else { toggleFullscreen() }
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
            controllerFeatures.recheckMotionSensors()
            pushKeyboardConfiguration()
            setGamepadPollingPaused(controllerInputOwner == .settings, force: true)
            inputPresets.retryActiveWebSettings()
            // The automatic region selector must receive Xbox's offered
            // endpoints even when the settings window is closed.
            settingsModel.load()
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
        case "mkb-emulation":
            let state = body["state"] as? String ?? "off"
            if keyboardEmulationState != state { keyboardEmulationState = state }
        case "mkb-state":
            // Only Escape routing depends on the mouse being captured; who
            // plays is decided in the page (see "mkb-emulation").
            pointerLockChanged(body["pointerLocked"] as? Bool ?? false)

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

    // MARK: - Deep links

    /// Handles a `macxcloud://` URL opened from Finder, a browser link,
    /// the `open` command, Raycast, etc. Formats:
    ///   macxcloud://home              → xbox.com/play
    ///   macxcloud://play/<productId>  → launch that game's stream directly
    ///   macxcloud://resume            → re-open the last played game
    /// Returns false for anything it does not understand.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "macxcloud" else { return false }
        openMainWindow()
        // Support both macxcloud://play/ID (host = "play") and
        // macxcloud:/play/ID styles so hand-typed links keep working.
        var parts: [String] = []
        if let host = url.host, !host.isEmpty, host != "localhost" { parts.append(host) }
        parts.append(contentsOf: url.path.split(separator: "/").map(String.init))
        guard let command = parts.first?.lowercased() else { return false }
        switch command {
        case "home":
            loadHome()
            return true
        case "play":
            guard let productID = parts.dropFirst().first, isUsableGameIdentifier(productID) else { return false }
            streamGame(productID: productID)
            return true
        case "resume":
            if let last = lastPlayedGameID { streamGame(productID: last) } else { loadHome() }
            return true
        default:
            return false
        }
    }

    private static let lastPlayedKey = "xcg.lastPlayedGameID.v1"
    private var lastPlayedGameID: String? {
        get { UserDefaults.standard.string(forKey: Self.lastPlayedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastPlayedKey) }
    }

    /// Xbox product ids are 8-20 chars of A-Z and 0-9 (e.g. 9NPDN9R45JX4).
    /// Anything else is rejected so a stray link can't inject odd strings.
    private func isUsableGameIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return value.count >= 8 && value.count <= 20
            && value.uppercased().unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Starts a game by its Xbox product ID (Dock menu, Shortcuts, Spotlight).
    func play(gameID: String) {
        openMainWindow()
        guard isUsableGameIdentifier(gameID) else { return }
        streamGame(productID: gameID)
    }

    func resumeLastGame() {
        openMainWindow()
        if let last = gameLibrary.recent.first?.id ?? lastPlayedGameID { streamGame(productID: last) } else { loadHome() }
    }

    private func streamGame(productID: String) {
        let id = productID.uppercased()
        lastPlayedGameID = id
        // If the same title is already streaming, don't restart the session.
        if isStreaming, !currentGameID.isEmpty, currentGameID == id {
            note("Already streaming this game")
            return
        }
        let launch = URL(string: "https://www.xbox.com/play/launch/\(id)")
        if let launch { webView?.load(URLRequest(url: launch)) }
        note("Launching game \(id) via deep link")
    }

    // MARK: - Notifications

    /// Posts a macOS notification when the connected controller runs low.
    /// Authorization is requested lazily on first use; if the build lacks the
    /// notification entitlement the request fails silently and nothing else
    /// changes.
    func notifyBatteryLow(percent: Int) {
        note("Controller battery low: \(percent)%")
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Controller battery low"
            content.body = "Your controller is at \(percent)%. Plug it in soon — rumble and lightbar effects may stop."
            let request = UNNotificationRequest(
                identifier: "xcg-battery-low-\(percent)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
    }

    /// Fires the "your game is ready" alert — push notification, three green
    /// LED pulses, and a short controller rumble. Triggered when a game
    /// becomes playable (the queue admitted you, or Play connected the
    /// stream), at most once per game start.
    func notifyGameReady() {
        let title = currentGameTitle.isEmpty ? "your game" : currentGameTitle
        note("Game ready: \(title)")
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your game is ready"
            content.body = "\(title) is live — hop back in!"
            let request = UNNotificationRequest(
                identifier: "xcg-game-ready-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try? await center.add(request)
        }
        controllerFeatures.readyAlertFlash()
    }
}
