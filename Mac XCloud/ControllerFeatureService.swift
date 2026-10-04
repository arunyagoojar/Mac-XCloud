//
//  ControllerFeatureService.swift
//  Mac XCloud
//
//  Native GameController/CoreHaptics feature foundation. This service observes
//  physical controller state; it never writes into a live controller snapshot or
//  attempts to alter WKWebView gamepad values.
//

import Combine
import CoreHaptics
import Foundation
import GameController
import simd

@MainActor
final class ControllerFeatureService: ObservableObject {
    typealias SnapshotHandler = (ControllerInputSnapshot) -> Void
    typealias ActionHandler = (ControllerNativeAction) -> Void
    typealias MacroButtonHandler = (ControllerControl, Bool) -> Void
    typealias MacroResetHandler = () -> Void

    @Published private(set) var descriptor: ControllerDescriptor?
    @Published private(set) var capabilities = ControllerCapabilities.unavailable
    @Published private(set) var snapshot = ControllerInputSnapshot.empty

    /// The single native controller selected for feature and app-level input.
    /// Consumers must use this reference rather than independently choosing the
    /// first item in GCController.controllers(), which can disagree with the
    /// current controller during reconnects.
    private(set) weak var selectedController: GCController?

    var selectedControllerProvider: () -> GCController? {
        { [weak self] in self?.selectedController }
    }
    @Published private(set) var calibrationProgress: ControllerCalibrationProgress?
    @Published private(set) var lastError: String?
    @Published var settings: ControllerSettings {
        didSet {
            persistSettings()
            applySettingsToAttachedController(previous: oldValue)
        }
    }

    @Published var globalRumbleGain: Float = UserDefaults.standard.object(forKey: "controller.globalRumbleGain") as? Float ?? 1 {
        didSet { UserDefaults.standard.set(globalRumbleGain, forKey: "controller.globalRumbleGain") }
    }
    @Published var applyCalibrationToStream = UserDefaults.standard.bool(forKey: "controller.streamCalibration") {
        didSet { UserDefaults.standard.set(applyCalibrationToStream, forKey: "controller.streamCalibration") }
    }
    @Published private(set) var rumbleEventCount = 0
    @Published private(set) var triggerRumbleEventCount = 0
    @Published private(set) var rumbleChannels = "No stream rumble received"
    @Published private(set) var gyroAvailable = false
    var enhancements: ControllerEnhancements { settings.enhancements ?? ControllerEnhancements() }
    var onStreamInput: (([String: Double]) -> Void)?
    var streamInputEnabled = false {
        didSet {
            if !streamInputEnabled { rapidFireStartedAt = nil; stopStreamRumble() }
            lastSentOutput = ["_": 0]  // force a fresh delivery on the next tick
        }
    }
    private var lastStreamInputAt: TimeInterval = 0
    private var sentStreamInput = false
    @Published private(set) var motionStatus = "Gyro disabled"
    @Published var aimDeliveryStatus = "Waiting for stream input"
    private var lastMotionReportAt: TimeInterval = 0
    private var rumbleCounts = (all: 0, trigger: 0)
    private var lastRumblePublishAt: TimeInterval = 0
    private var rapidFireStartedAt: TimeInterval?
    /// Continuous rumble players, one per output channel (left grip, right
    /// grip, or a single combined channel).
    private var rumblePlayers: [HapticLocality: CHHapticAdvancedPatternPlayer] = [:]
    private var rumbleLevels: [HapticLocality: (intensity: Float, sharpness: Float)] = [:]
    private var streamRumbleEndsAt: TimeInterval = 0
    private var triggerFeedbackEndsAt: TimeInterval = 0
    private var lastGameTriggerLevels = ControllerVector2(x: -1, y: -1)
    private var triggerRestoreTask: Task<Void, Never>?
    private let rawTouch = DualSenseTouchReader()
    // Motion pipeline: reports feed the fusion at sensor rate; the engines
    // read it once per output tick.
    private var fusion = MotionFusion()
    private var sampleClock = MotionSampleClock()
    private var steering = SteeringWheelEngine()
    private var gyroAim = GyroAimEngine()
    private var touchCamera = TouchpadCameraEngine()
    private var lastAimRate = MotionVector.zero
    private var lastAimRateAt: TimeInterval = 0
    private var gyroAimWasActive = false
    private var lastTickAt: TimeInterval = 0
    private var lastTouchReportAt: TimeInterval = 0
    private var touchReportsThisTick = 0
    private var lastPolledTouch: ControllerVector2?
    private var lastSentOutput: [String: Double] = [:]
    private var lastSentAt: TimeInterval = 0
    private var biasSavedAt: TimeInterval = 0
    private var savedBias = MotionVector.zero
    /// While a vibration-mode adaptive trigger is buzzing, the controller
    /// shakes exactly like game rumble does.
    private var triggerVibrationActive = false
    private var localHapticEndsAt: TimeInterval = 0

    // Live values for the settings previews (published only while visible).
    @Published private(set) var liveSteeringAngle: Double = 0
    @Published private(set) var liveSteeringOutput: Double = 0
    @Published private(set) var liveAimOutput = ControllerVector2.zero
    @Published private(set) var liveTouchOutput = ControllerVector2.zero
    @Published private(set) var gyroCalibration: MotionFusion.CalibrationState = .idle
    @Published private(set) var steeringCenterDegrees: Double = 0
    @Published private(set) var touchDiagnostics = "No finger on the touchpad"
    @Published private(set) var lastGesture = "No gesture yet"
    /// The single input owner: exactly one enhanced input system drives a
    /// stick axis at any moment, and the browser-side keyboard/mouse takeover
    /// suppresses all native motion output.
    @Published private(set) var inputOwner = MotionInputOwner.none.rawValue
    @Published private(set) var outputRateHz: Double = 0
    @Published private(set) var motionReportRateHz: Double = 0
    private var outputSamplesThisSecond = 0
    private var outputRateWindowStart: TimeInterval = 0
    /// Set from the browser bridge while a keyboard/mouse input path owns the
    /// stream (pointer lock or a virtual controller). Native motion engines
    /// release to neutral and stop producing stream output until it clears.
    @Published private(set) var mkbStreamActive = false
    private(set) var mkbStreamIsEmulated = false

    func setMKBStreamActive(_ active: Bool, emulated: Bool) {
        guard mkbStreamActive != active || mkbStreamIsEmulated != emulated else { return }
        mkbStreamActive = active
        mkbStreamIsEmulated = emulated
        if active {
            steering.release()
            gyroAim.reset(); touchCamera.reset()
        }
    }

    private static let steeringCenterKey = "motion.steeringCenterBank.v2"
    private func biasKey(for controller: GCController?) -> String {
        "motion.gyroBias.v1." + (controller?.vendorName ?? "controller")
    }

    /// Makes the current physical bank the straight-ahead position and
    /// remembers it on this Mac. Reads the orientation now, so it works from
    /// any mode; without fresh motion data it does nothing.
    func recenterSteering() {
        guard let gravity = fusion.gravity, ProcessInfo.processInfo.systemUptime - lastMotionReportAt < 0.25 else { return }
        steering.centerBank = SteeringGeometry.bank(gravity: gravity)
        steering.recenter()
        defaults.set(steering.centerBank, forKey: Self.steeringCenterKey)
        steeringCenterDegrees = steering.centerBank * 180 / .pi
    }



    /// Returns straight-ahead to a level controller (the default).
    func resetSteeringCenter() {
        steering.centerBank = 0
        defaults.removeObject(forKey: Self.steeringCenterKey)
        steeringCenterDegrees = 0
    }

    /// Measures the gyroscope's resting offset; the controller must be still.
    func calibrateGyro() {
        guard controller?.motion != nil else { return }
        controller?.motion?.sensorsActive = true
        fusion.beginCalibration(duration: 1.5)
        gyroCalibration = fusion.calibration
    }

    /// Kept for shortcuts and older call sites: recenter steering and restart
    /// aiming from rest.
    func centerGyro() {
        switch enhancements.gyroMode {
        case .steering: recenterSteering()
        default: break
        }
        gyroAim.reset()
        touchCamera.reset()
    }

    private func ingestMotion(_ motion: GCMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        lastMotionReportAt = now
        let dt = sampleClock.step(arrival: now)
        let r = motion.rotationRate
        let acceleration: MotionVector
        if motion.hasGravityAndUserAcceleration {
            let g = motion.gravity, u = motion.userAcceleration
            acceleration = MotionVector(g.x + u.x, g.y + u.y, g.z + u.z)
        } else {
            let a = motion.acceleration
            acceleration = MotionVector(a.x, a.y, a.z)
        }
        let rate = motion.hasRotationRate ? MotionVector(r.x, r.y, r.z) : .zero
        fusion.ingest(rotationRate: rate, acceleration: acceleration, dt: dt, vibrating: isVibrating(at: now))
        if case .measuring = gyroCalibration {
            if fusion.calibration != gyroCalibration { gyroCalibration = fusion.calibration }
            if fusion.calibration == .succeeded { saveBias(force: true) }
        }
    }

    private func isVibrating(at now: TimeInterval) -> Bool {
        guard enhancements.effectiveSteeringRumbleGuard else { return false }
        return now < streamRumbleEndsAt || now < triggerFeedbackEndsAt || now < localHapticEndsAt || triggerVibrationActive
    }

    private func loadBias(for controller: GCController) {
        let values = defaults.array(forKey: biasKey(for: controller)) as? [Double] ?? []
        let bias = values.count == 3 ? MotionVector(values[0], values[1], values[2]) : .zero
        fusion = MotionFusion(bias: bias)
        savedBias = fusion.bias
        sampleClock.reset()
    }

    /// Persists the learned bias occasionally (it changes slowly).
    private func saveBias(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (now - biasSavedAt > 20 && simd_length(fusion.bias - savedBias) > 0.002) else { return }
        biasSavedAt = now
        savedBias = fusion.bias
        defaults.set([fusion.bias.x, fusion.bias.y, fusion.bias.z], forKey: biasKey(for: controller))
    }

    func resetRumbleDiagnostics() {
        rumbleCounts = (0, 0)
        rumbleEventCount = 0; triggerRumbleEventCount = 0
        rumbleChannels = "No stream rumble received"
    }

    func stopStreamRumble() {
        stopRumblePlayers()
        streamRumbleEndsAt = 0
        triggerRestoreTask?.cancel(); triggerRestoreTask = nil
        if triggerFeedbackEndsAt > 0 { applyAdaptiveTriggerSettings() }
        triggerFeedbackEndsAt = 0
        lastGameTriggerLevels = ControllerVector2(x: -1, y: -1)
    }

    func recordRumble(left: Float, right: Float, leftTrigger: Float, rightTrigger: Float) {
        rumbleCounts.all += 1
        if leftTrigger > 0 || rightTrigger > 0 { rumbleCounts.trigger += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        guard controllerToolsActive, now - lastRumblePublishAt >= 0.5 else { return }
        lastRumblePublishAt = now
        rumbleEventCount = rumbleCounts.all; triggerRumbleEventCount = rumbleCounts.trigger
        rumbleChannels = String(format: "L %.0f · R %.0f · L2 %.0f · R2 %.0f%%", left * 100, right * 100, leftTrigger * 100, rightTrigger * 100)
    }

    func testStreamRumble() {
        receiveStreamRumble(left: 0.25, right: 0.25, leftTrigger: 0, rightTrigger: 0, duration: 0.8, isTest: true)
    }

    func receiveStreamRumble(left: Float, right: Float, leftTrigger: Float, rightTrigger: Float, duration: Double, isTest: Bool = false) {
        guard streamInputEnabled || isTest else { return }
        let e = enhancements
        let seconds = duration.isFinite ? min(max(duration, 0), 2) : 0.15
        guard seconds > 0, settings.haptics.mode != .off else { stopStreamRumble(); return }
        let now = ProcessInfo.processInfo.systemUptime
        streamRumbleEndsAt = now + seconds
        let gain = max(settings.haptics.intensityMultiplier, 0)
        // Xbox controllers have a heavy low-frequency motor in the left grip
        // and a light high-frequency one in the right. Each grip of the
        // DualSense plays its own motor, with some of the other mixed in so
        // the whole body still rumbles the way an Xbox controller does.
        let low = min(e.rumble(left, global: globalRumbleGain) * gain, 1)
        let high = min(e.rumble(right, global: globalRumbleGain) * gain, 1)
        let highShare = low + high > 0 ? high / (low + high) : 0
        let texture = (min(max(settings.haptics.sharpness, 0), 1) - 0.5) * 0.4
        func clampUnit(_ value: Float) -> Float { min(max(value, 0), 1) }
        var targets: [HapticLocality: (intensity: Float, sharpness: Float)] = [:]
        let locality = settings.haptics.preferredLocality
        if (locality == .default || locality == .handles || locality == .all),
           hapticEngines[.leftHandle] != nil, hapticEngines[.rightHandle] != nil {
            targets[.leftHandle] = (clampUnit(low + 0.35 * high), clampUnit(0.15 + 0.25 * highShare + texture))
            targets[.rightHandle] = (clampUnit(high + 0.5 * low), clampUnit(0.35 + 0.4 * highShare + texture))
        } else {
            targets[locality] = (clampUnit(max(low, high) + 0.25 * min(low, high)), clampUnit(0.2 + 0.5 * highShare + texture))
        }
        for (channel, level) in targets { setRumble(level, on: channel) }
        if e.gameDrivenTriggers, let pad = controller?.extendedGamepad as? GCDualSenseGamepad {
            let levels = ControllerVector2(x: e.rumble(leftTrigger, global: globalRumbleGain), y: e.rumble(rightTrigger, global: globalRumbleGain))
            if levels != lastGameTriggerLevels {
                if levels.x <= 0 || levels.y <= 0 { applyAdaptiveTriggerSettings() }
                if !e.leftLock, levels.x > 0 { pad.leftTrigger.setModeVibrationWithStartPosition(0.1, amplitude: levels.x, frequency: 0.5) }
                if !e.rightLock, levels.y > 0 { pad.rightTrigger.setModeVibrationWithStartPosition(0.1, amplitude: levels.y, frequency: 0.5) }
                lastGameTriggerLevels = levels
            }
            triggerFeedbackEndsAt = now + seconds
        }
    }

    var onNativeInputState: SnapshotHandler?
    /// Restores the user's light-bar color after a temporary flash.
    var onLightRestore: (() -> Void)?
    var onShortcutAction: ActionHandler?
    var onMacroButtonAction: MacroButtonHandler?
    var onMacroReset: MacroResetHandler?

    private let defaults: UserDefaults
    private let persistenceKey: String
    private weak var controller: GCController?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var hapticEngines: [HapticLocality: CHHapticEngine] = [:]
    private var macroTasks: [UUID: Task<Void, Never>] = [:]
    private var previousSnapshot = ControllerInputSnapshot.empty
    private var shortcutRuntime: [UUID: ShortcutRuntimeState] = [:]
    private var touchRuntime = TouchRuntimeState()
    private var calibrationSession: CalibrationSession?
    private var isApplyingSettings = false
    private var controllerToolsActive = false
    private var lastLEDColor: ControllerLEDColor?
    /// Runs the "your game is ready" lightbar pulse sequence; non-nil means
    /// the flash owns the LED until it finishes and restores the policy color.
    private var readyAlertTask: Task<Void, Never>?

    private struct ShortcutRuntimeState {
        var wasChordPressed = false
        var pressedAt: TimeInterval?
        var lastPressedAt: TimeInterval?
        var didFireHold = false
    }

    private struct TouchRuntimeState {
        var beganAt: TimeInterval?
        var startPosition = ControllerVector2.zero
        var currentPosition = ControllerVector2.zero
        var primaryActive = false
        var secondaryActive = false
        var secondFingerSeen = false
        var swipeEmitted = false
        var lastTapAt: TimeInterval?
        var pendingTapTask: Task<Void, Never>?
        var fallbackExpiryTasks: [Int: Task<Void, Never>] = [:]
    }

    private struct CalibrationSession {
        var kind: ControllerCalibrationKind
        var duration: TimeInterval
        var startedAt: TimeInterval
        var sampleCount = 0
        var leftSum = ControllerVector2.zero
        var rightSum = ControllerVector2.zero
        var leftMinimum = ControllerVector2(x: 1, y: 1)
        var leftMaximum = ControllerVector2(x: -1, y: -1)
        var rightMinimum = ControllerVector2(x: 1, y: 1)
        var rightMaximum = ControllerVector2(x: -1, y: -1)
        var leftTriggerMinimum: Float = 1
        var leftTriggerMaximum: Float = 0
        var rightTriggerMinimum: Float = 1
        var rightTriggerMaximum: Float = 0
    }

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "nativeController.settings.v1",
        automaticallyAttach: Bool = true
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        if let data = defaults.data(forKey: persistenceKey),
           var saved = try? JSONDecoder().decode(ControllerSettings.self, from: data) {
            // v2 adds native default gestures without overwriting an existing
            // customized mapping set.
            let version = defaults.integer(forKey: "nativeController.settingsVersion")
            if version < 2, saved.touchpad.mappings.isEmpty {
                saved.touchpad.mappings = TouchpadSettings.default.mappings
            }
            settings = saved
        } else {
            settings = .default
        }
        defaults.set(4, forKey: "nativeController.settingsVersion")
        let center = defaults.double(forKey: Self.steeringCenterKey)
        if center.isFinite, abs(center) < .pi / 2 {
            steering.centerBank = center
            steeringCenterDegrees = center * 180 / .pi
        }
        registerForControllerNotifications()
        if automaticallyAttach {
            attach(to: GCController.current ?? GCController.controllers().first)
        }
    }

    deinit {
        pollTimer?.invalidate()
        readyAlertTask?.cancel()
        touchRuntime.pendingTapTask?.cancel()
        macroTasks.values.forEach { $0.cancel() }
        observers.forEach(NotificationCenter.default.removeObserver)
        if let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad {
            dualSense.leftTrigger.setModeOff()
            dualSense.rightTrigger.setModeOff()
        }
        hapticEngines.values.forEach { $0.stop(completionHandler: nil) }
    }

    // MARK: - Attachment and lifecycle

    func attach(to controller: GCController?) {
        if self.controller === controller {
            selectedController = controller
            if controller != nil, pollTimer == nil { startPolling() }
            return
        }
        detach()
        guard let controller else { return }

        self.controller = controller
        selectedController = controller
        controller.handlerQueue = .main
        gyroAvailable = controller.motion?.hasRotationRate == true
        loadBias(for: controller)
        controller.motion?.valueChangedHandler = { [weak self] motion in
            MainActor.assumeIsolated { self?.ingestMotion(motion) }
        }
        controller.motion?.sensorsActive = enhancements.gyroEnabled
        descriptor = makeDescriptor(for: controller)
        capabilities = makeCapabilities(for: controller)
        configureInputHandlers(for: controller)
        configureTouchpadHandlers(for: controller)
        configureRawTouch()
        rebuildHapticEngines(for: controller)
        applyAdaptiveTriggerSettings()
        applyLEDPolicy()
        publishCurrentSnapshot()
        startPolling()
    }

    func detach() {
        stopStreamRumble()
        pollTimer?.invalidate()
        pollTimer = nil
        readyAlertTask?.cancel()
        readyAlertTask = nil
        touchRuntime.pendingTapTask?.cancel()
        touchRuntime.fallbackExpiryTasks.values.forEach { $0.cancel() }
        touchRuntime = TouchRuntimeState()
        resetMacros()
        calibrationSession = nil
        calibrationProgress = nil

        if let controller {
            controller.extendedGamepad?.valueChangedHandler = nil
            if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
                dualSense.touchpadPrimary.valueChangedHandler = nil
                dualSense.touchpadSecondary.valueChangedHandler = nil
                dualSense.leftTrigger.setModeOff()
                dualSense.rightTrigger.setModeOff()
            }
            for touchpad in controller.physicalInputProfile.allTouchpads {
                touchpad.touchDown = nil
                touchpad.touchMoved = nil
                touchpad.touchUp = nil
            }
        }

        stopHapticEngines()
        if controller != nil { saveBias(force: true) }
        controller?.motion?.valueChangedHandler = nil
        controller?.motion?.sensorsActive = false
        lastMotionReportAt = 0
        gyroAvailable = false
        steering.reset(); gyroAim.reset(); touchCamera.reset()
        fusion.cancelCalibration(); gyroCalibration = .idle
        fusion.resetOrientation(); sampleClock.reset()
        rawTouch.stop()
        lastPolledTouch = nil
        rapidFireStartedAt = nil
        self.controller = nil
        selectedController = nil
        descriptor = nil
        capabilities = .unavailable
        snapshot = .empty
        previousSnapshot = .empty
        shortcutRuntime.removeAll()
    }

    func attachFirstAvailableController() {
        attach(to: GCController.current ?? GCController.controllers().first)
    }

    func recheckMotionSensors() {
        if controller == nil { attachFirstAvailableController() }
        guard let controller else { return }
        gyroAvailable = controller.motion?.hasRotationRate == true
        if enhancements.gyroEnabled {
            controller.motion?.sensorsActive = true
        }
    }

    /// Raw DualSense touch reports carry every finger sample (GameController
    /// coalesces them); they feed the touchpad camera directly.
    private func configureRawTouch() {
        guard enhancements.touchpadAimEnabled, controller?.extendedGamepad is GCDualSenseGamepad else {
            rawTouch.onReport = nil
            rawTouch.stop()
            return
        }
        rawTouch.onReport = { [weak self] points, time in
            self?.feedTouch(points.first ?? .inactive, at: time)
        }
        rawTouch.start()
    }

    private func feedTouch(_ point: ControllerTouchPoint, at time: TimeInterval) {
        guard enhancements.touchpadAimEnabled else { return }
        lastTouchReportAt = time
        touchReportsThisTick += 1
        if point.isActive {
            touchCamera.report(position: (Double(point.position.x) * TouchpadCameraEngine.halfWidth,
                                          Double(point.position.y) * TouchpadCameraEngine.halfHeight), at: time)
        } else if touchCamera.fingerDown {
            touchCamera.lift()
        }
    }

    /// One output tick: 120 Hz keeps motion and touch within ~8 ms of the
    /// hand while staying far below the sensors' own report rate.
    func startPolling(interval: TimeInterval = 1.0 / 120.0) {
        guard pollTimer == nil else { return }
        let safeInterval = min(max(interval, 1.0 / 240.0), 0.25)
        pollTimer = Timer(timeInterval: safeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishCurrentSnapshot() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
    }

    /// High-rate SwiftUI updates are only needed while a live test page is
    /// visible. Elsewhere the published snapshot is throttled so the Settings
    /// window is not re-rendered dozens of times per second.
    private(set) var highRateUIDetail = false
    private var lastPublishedAt: TimeInterval = 0

    func setHighRateUIDetail(_ enabled: Bool) {
        highRateUIDetail = enabled
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Settings persistence

    func reloadSettings() {
        guard let data = defaults.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode(ControllerSettings.self, from: data) else { return }
        settings = saved
    }

    func resetSettings() {
        settings = .default
    }

    func setControllerToolsActive(_ active: Bool) {
        controllerToolsActive = active
        if !active { cancelCalibration() }
    }

    func updateSettings(_ update: (inout ControllerSettings) -> Void) {
        var copy = settings
        update(&copy)
        settings = copy
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else {
            lastError = "Could not encode controller settings."
            return
        }
        defaults.set(data, forKey: persistenceKey)
    }

    private func applySettingsToAttachedController(previous: ControllerSettings) {
        guard !isApplyingSettings else { return }
        let old = previous.enhancements ?? ControllerEnhancements()
        if enhancements.gyroMode != old.gyroMode {
            steering.reset(); gyroAim.reset()
        }
        if enhancements.touchpadAimEnabled != old.touchpadAimEnabled { touchCamera.reset() }
        configureRawTouch()
        controller?.motion?.sensorsActive = enhancements.gyroEnabled
        isApplyingSettings = true
        triggerRestoreTask?.cancel(); triggerRestoreTask = nil
        defer { isApplyingSettings = false }
        if settings.touchpad != previous.touchpad || enhancements.touchpadAimEnabled != (previous.enhancements?.touchpadAimEnabled ?? false) {
            configureTouchpadHandlers(for: controller)
        }
        if settings.haptics.mode != previous.haptics.mode || settings.haptics.preferredLocality != previous.haptics.preferredLocality {
            stopStreamRumble()
            rebuildHapticEngines(for: controller)
        }
        if settings.adaptiveTriggers != previous.adaptiveTriggers || settings.enhancements?.leftLock != previous.enhancements?.leftLock || settings.enhancements?.rightLock != previous.enhancements?.rightLock || settings.enhancements?.lockPosition != previous.enhancements?.lockPosition {
            applyAdaptiveTriggerSettings()
        }
        if settings.led != previous.led { applyLEDPolicy() }
    }

    // MARK: - Input snapshots

    func publishCurrentSnapshot() {
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if streamRumbleEndsAt > 0 && timestamp >= streamRumbleEndsAt { stopStreamRumble() }
        let rawLeftStick = ControllerVector2(x: gamepad.leftThumbstick.xAxis.value, y: gamepad.leftThumbstick.yAxis.value)
        let rawRightStick = ControllerVector2(x: gamepad.rightThumbstick.xAxis.value, y: gamepad.rightThumbstick.yAxis.value)
        let rawLeftTrigger = gamepad.leftTrigger.value
        let rawRightTrigger = gamepad.rightTrigger.value
        let dualSense = gamepad as? GCDualSenseGamepad
        if let dualSense { updateTriggerEnvelopes(dualSense, at: timestamp) }

        let next = ControllerInputSnapshot(
            timestamp: timestamp,
            leftStick: settings.calibration.leftStick.apply(to: rawLeftStick),
            rightStick: settings.calibration.rightStick.apply(to: rawRightStick),
            leftTrigger: settings.calibration.leftTrigger.apply(to: rawLeftTrigger),
            rightTrigger: settings.calibration.rightTrigger.apply(to: rawRightTrigger),
            buttons: buttonsSnapshot(from: gamepad, dualSense: dualSense),
            primaryTouch: dualSense.map { touchPoint(from: $0.touchpadPrimary, index: 0) } ?? .inactive,
            secondaryTouch: dualSense.map { touchPoint(from: $0.touchpadSecondary, index: 1) } ?? .inactive,
            battery: batterySnapshot(from: controller)
        )

        let shouldPublishToUI = controllerToolsActive && (timestamp - lastPublishedAt) >= (highRateUIDetail ? 1.0 / 30.0 : 0.25)
        if shouldPublishToUI {
            if rumbleEventCount != rumbleCounts.all { rumbleEventCount = rumbleCounts.all }
            if triggerRumbleEventCount != rumbleCounts.trigger { triggerRumbleEventCount = rumbleCounts.trigger }
            snapshot = next
            lastPublishedAt = timestamp
        }
        let tickDT = lastTickAt > 0 ? min(max(timestamp - lastTickAt, 0.001), 0.1) : 1.0 / 120
        lastTickAt = timestamp
        let e = enhancements
        let drained = fusion.drainRotation()
        if drained.duration > 0 {
            lastAimRate = drained.rate
            lastAimRateAt = timestamp
        }
        let motionFresh = timestamp - lastMotionReportAt < 0.1
        if case .measuring = gyroCalibration, timestamp - lastMotionReportAt > 1 {
            // Motion reports stopped mid-calibration: give the button back.
            fusion.cancelCalibration()
            gyroCalibration = .failedMoved
        }
        if e.gyroEnabled, let motion = controller.motion, !motion.sensorsActive { motion.sensorsActive = true }

        // Steering reads the fused orientation every tick so its preview stays
        // live in Settings even before a stream starts.
        if e.gyroMode == .steering, motionFresh {
            steering.configure(e.steeringConfiguration)
            steering.update(gravity: fusion.predictedGravity(after: timestamp - lastMotionReportAt), dt: tickDT)
        } else {
            steering.release()
        }

        // Touch: raw reports arrive through feedTouch. Without them, follow
        // the polled position (GameController touch callbacks).
        if e.touchpadAimEnabled {
            touchCamera.configure(e.touchpadConfiguration)
            if touchReportsThisTick == 0, timestamp - lastTouchReportAt > 0.05 {
                if next.primaryTouch.isActive {
                    if lastPolledTouch != next.primaryTouch.position || !touchCamera.fingerDown {
                        feedTouch(next.primaryTouch, at: timestamp)
                        lastTouchReportAt = 0
                    }
                    lastPolledTouch = next.primaryTouch.position
                } else {
                    if touchCamera.fingerDown { touchCamera.lift() }
                    lastPolledTouch = nil
                }
            }
            touchReportsThisTick = 0
        } else if touchCamera.fingerDown {
            touchCamera.reset()
        }

        var owner = e.gyroEnabled ? e.gyroMode.owner : MotionInputOwner.physical
        if mkbStreamActive { owner = mkbStreamIsEmulated ? .mkbEmulated : .mkbNative }

        // Keyboard/mouse owns the whole input path while active; native motion
        // engines stay released to neutral so nothing fights over an axis.
        let wantsStreamInput = !mkbStreamActive &&
            (applyCalibrationToStream || e.gyroEnabled || e.touchpadAimEnabled || e.rapidFireEnabled)
        var output: [String: Double] = [:]
        if wantsStreamInput {
            if applyCalibrationToStream {
                output = ["LeftTrigger": Double(next.leftTrigger), "RightTrigger": Double(next.rightTrigger),
                          "LeftThumbXAxis": Double(next.leftStick.x), "LeftThumbYAxis": Double(next.leftStick.y),
                          "RightThumbXAxis": Double(next.rightStick.x), "RightThumbYAxis": Double(next.rightStick.y)]
            }
            switch e.gyroMode {
            case .steering:
                // The wheel owns the left stick's X axis; the physical stick
                // (with its calibrated dead zone, so drift never adds in) still
                // works on top, and its Y axis passes through untouched.
                let wheel = steering.available ? steering.output : 0
                output["LeftThumbXAxis"] = min(max(Double(next.leftStick.x) + wheel, -1), 1)
                output["LeftThumbYAxis"] = Double(applyCalibrationToStream ? next.leftStick.y : rawLeftStick.y)
                gyroAim.reset()
            case .aiming:
                let active = e.effectiveGyroActivation == .always || next.leftTrigger > 0.3
                if active && !gyroAimWasActive { gyroAim.reset() }
                gyroAimWasActive = active
                if active, motionFresh {
                    gyroAim.configure(e.gyroAimConfiguration)
                    // Sensors report slower than the tick (~65 Hz over
                    // Bluetooth, with occasional late reports): hold the last
                    // measured speed across the gap instead of flickering to
                    // zero, which the camera would show as a stutter.
                    let hold = max(3 * sampleClock.nominalInterval, 0.05)
                    let rate = timestamp - lastAimRateAt < hold ? lastAimRate : .zero
                    let result = gyroAim.sample(rate: rate, gravity: fusion.gravity, dt: tickDT)
                    output["gyroX"] = Double(result.coarse.x)
                    output["gyroY"] = Double(result.coarse.y)
                    output["gyroFineX"] = Double(result.fine.x)
                    output["gyroFineY"] = Double(result.fine.y)
                } else {
                    gyroAim.reset()
                    output["gyroX"] = 0; output["gyroY"] = 0
                    output["gyroFineX"] = 0; output["gyroFineY"] = 0
                }
                output["gyroAxisBase"] = ControllerAimStick.right.axisBase
            case .off:
                gyroAim.reset()
            }
            if e.touchpadAimEnabled {
                // Steering owns the left stick, so touch then always drives the
                // right stick.
                let touchStick: ControllerAimStick = e.gyroMode == .steering ? .right : (e.touchpadStick ?? .right)
                output["touchAxisBase"] = touchStick.axisBase
                output["touchpadAim"] = 1
                let touch = touchCamera.tick(now: timestamp, dt: tickDT)
                if touchCamera.fingerDown {
                    output["touchActive"] = 1
                    output["touchX"] = Double(touch.coarse.x)
                    output["touchY"] = Double(touch.coarse.y)
                }
            }
            if e.rapidFireEnabled, rawRightTrigger > 0.5 {
                if rapidFireStartedAt == nil { rapidFireStartedAt = timestamp }
                let phase = (timestamp - (rapidFireStartedAt ?? timestamp)) * Double(min(max(e.rapidFireRate, 2), 15))
                output["RightTrigger"] = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0
            } else { rapidFireStartedAt = nil }
            output["nativeControllerCount"] = Double(GCController.controllers().count)
        } else {
            steering.release(); gyroAim.reset()
            if touchCamera.fingerDown { touchCamera.reset() }
        }

        // Delivery: changed values go out immediately; unchanged values are
        // refreshed well inside the page's 200 ms freshness window, and one
        // empty update releases everything when enhancements switch off.
        if streamInputEnabled && (wantsStreamInput || sentStreamInput) {
            let changed = output != lastSentOutput
            if changed || timestamp - lastSentAt >= 0.08 {
                lastSentOutput = output
                lastSentAt = timestamp
                sentStreamInput = wantsStreamInput
                outputSamplesThisSecond += 1
                onStreamInput?(output)
            }
        }
        if timestamp - lastStreamInputAt >= 1 {
            outputRateHz = Double(outputSamplesThisSecond) / max(timestamp - lastStreamInputAt, 1)
            outputSamplesThisSecond = 0
            lastStreamInputAt = timestamp
            saveBias()
        }

        if shouldPublishToUI {
            if inputOwner != owner.rawValue { inputOwner = owner.rawValue }
            let status: String
            if mkbStreamActive {
                status = mkbStreamIsEmulated ? "Keyboard & mouse is in control (virtual controller)" : "Keyboard & mouse is in control"
            } else if !e.gyroEnabled {
                status = "Motion controls are off"
            } else if controller.motion == nil {
                status = "This controller has no motion sensors"
            } else {
                status = motionFresh ? "Motion sensors active" : "Waiting for motion sensors — reconnect the controller"
            }
            if motionStatus != status { motionStatus = status }
            let angle = steering.available ? steering.angle * 180 / .pi : 0
            if abs(liveSteeringAngle - angle) > 0.05 { liveSteeringAngle = angle }
            if liveSteeringOutput != steering.output { liveSteeringOutput = steering.output }
            if liveAimOutput != gyroAim.output { liveAimOutput = gyroAim.output }
            if liveTouchOutput != touchCamera.output { liveTouchOutput = touchCamera.output }
            if e.touchpadAimEnabled {
                touchDiagnostics = touchCamera.fingerDown
                    ? String(format: "Finger speed %.0f px/s · Stick %+.2f, %+.2f",
                             (touchCamera.velocity.x * touchCamera.velocity.x + touchCamera.velocity.y * touchCamera.velocity.y).squareRoot(),
                             touchCamera.output.x, touchCamera.output.y)
                    : "No finger on the touchpad"
            }
            let reportRate = 1 / max(sampleClock.nominalInterval, 0.0005)
            if abs(motionReportRateHz - reportRate) > 2 { motionReportRateHz = motionFresh ? reportRate : 0 }
        }
        onNativeInputState?(next)
        processShortcuts(current: next, previous: previousSnapshot)
        sampleCalibration(
            timestamp: timestamp,
            leftStick: rawLeftStick,
            rightStick: rawRightStick,
            leftTrigger: rawLeftTrigger,
            rightTrigger: rawRightTrigger
        )
        previousSnapshot = next
        if shouldPublishToUI { applyLEDPolicy() }
        // The battery-driven LED policy (dim/red/off-when-low) must also keep
        // working while streaming with the settings window closed, where UI
        // publishing is throttled off. The policy de-duplicates internally, so
        // a slow periodic re-check costs nothing when nothing changed.
        if timestamp - lastLEDCheckAt >= 2 {
            lastLEDCheckAt = timestamp
            applyLEDPolicy()
        }
    }

    private var lastLEDCheckAt: TimeInterval = 0

    private func buttonsSnapshot(from gamepad: GCExtendedGamepad, dualSense: GCDualSenseGamepad?) -> ControllerButtonsSnapshot {
        ControllerButtonsSnapshot(
            a: buttonState(gamepad.buttonA),
            b: buttonState(gamepad.buttonB),
            x: buttonState(gamepad.buttonX),
            y: buttonState(gamepad.buttonY),
            menu: buttonState(gamepad.buttonMenu),
            options: buttonState(gamepad.buttonOptions),
            home: buttonState(gamepad.buttonHome),
            leftShoulder: buttonState(gamepad.leftShoulder),
            rightShoulder: buttonState(gamepad.rightShoulder),
            leftStick: buttonState(gamepad.leftThumbstickButton),
            rightStick: buttonState(gamepad.rightThumbstickButton),
            dpadUp: buttonState(gamepad.dpad.up),
            dpadDown: buttonState(gamepad.dpad.down),
            dpadLeft: buttonState(gamepad.dpad.left),
            dpadRight: buttonState(gamepad.dpad.right),
            touchpad: buttonState(dualSense?.touchpadButton)
        )
    }

    private func buttonState(_ button: GCControllerButtonInput?) -> ControllerButtonState {
        guard let button else { return .released }
        return ControllerButtonState(value: button.value, isPressed: button.isPressed)
    }

    private func touchPoint(from touchpad: GCControllerDirectionPad, index: Int = 0) -> ControllerTouchPoint {
        if enhancements.touchpadAimEnabled {
            if let point = rawTouch.point(index) { return point }
            if rawTouch.hasReports { return .inactive }
        }
        // Poll contact state directly: WebKit can replace shared controller callbacks.
        if let contact = controller?.physicalInputProfile.allTouchpads.first(where: { $0.touchSurface === touchpad }) {
            return ControllerTouchPoint(isActive: contact.touchState != .up,
                position: ControllerVector2(x: touchpad.xAxis.value, y: touchpad.yAxis.value))
        }
        return ControllerTouchPoint(
            isActive: index == 0 ? touchRuntime.primaryActive : touchRuntime.secondaryActive,
            position: index == 0 ? touchRuntime.currentPosition : ControllerVector2(x: touchpad.xAxis.value, y: touchpad.yAxis.value)
        )
    }

    private func batterySnapshot(from controller: GCController) -> ControllerBatterySnapshot? {
        guard let battery = controller.battery else { return nil }
        let state: ControllerBatterySnapshot.State
        switch battery.batteryState {
        case .unknown: state = .unknown
        case .discharging: state = .discharging
        case .charging: state = .charging
        case .full: state = .full
        @unknown default: state = .unknown
        }
        return ControllerBatterySnapshot(level: min(max(battery.batteryLevel, 0), 1), state: state)
    }

    // MARK: - Calibration sessions

    func beginCalibration(_ kind: ControllerCalibrationKind, duration: TimeInterval = 2) {
        guard controller?.extendedGamepad != nil else {
            lastError = "No extended game controller is attached."
            return
        }
        let safeDuration = min(max(duration, 0.25), 30)
        calibrationSession = CalibrationSession(
            kind: kind,
            duration: safeDuration,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        calibrationProgress = ControllerCalibrationProgress(kind: kind, progress: 0, sampleCount: 0)
        startPolling()
    }

    func cancelCalibration() {
        calibrationSession = nil
        calibrationProgress = nil
    }

    private func sampleCalibration(
        timestamp: TimeInterval,
        leftStick: ControllerVector2,
        rightStick: ControllerVector2,
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        guard var session = calibrationSession else { return }
        session.sampleCount += 1
        session.leftSum.x += leftStick.x
        session.leftSum.y += leftStick.y
        session.rightSum.x += rightStick.x
        session.rightSum.y += rightStick.y
        session.leftMinimum.x = min(session.leftMinimum.x, leftStick.x)
        session.leftMinimum.y = min(session.leftMinimum.y, leftStick.y)
        session.leftMaximum.x = max(session.leftMaximum.x, leftStick.x)
        session.leftMaximum.y = max(session.leftMaximum.y, leftStick.y)
        session.rightMinimum.x = min(session.rightMinimum.x, rightStick.x)
        session.rightMinimum.y = min(session.rightMinimum.y, rightStick.y)
        session.rightMaximum.x = max(session.rightMaximum.x, rightStick.x)
        session.rightMaximum.y = max(session.rightMaximum.y, rightStick.y)
        session.leftTriggerMinimum = min(session.leftTriggerMinimum, leftTrigger)
        session.leftTriggerMaximum = max(session.leftTriggerMaximum, leftTrigger)
        session.rightTriggerMinimum = min(session.rightTriggerMinimum, rightTrigger)
        session.rightTriggerMaximum = max(session.rightTriggerMaximum, rightTrigger)

        let elapsed = timestamp - session.startedAt
        let progress = min(max(elapsed / session.duration, 0), 1)
        calibrationSession = session
        calibrationProgress = ControllerCalibrationProgress(kind: session.kind, progress: progress, sampleCount: session.sampleCount)
        guard progress >= 1 else { return }
        finishCalibration(session)
    }

    private func finishCalibration(_ session: CalibrationSession) {
        guard session.sampleCount > 0 else {
            cancelCalibration()
            return
        }
        var newSettings = settings
        switch session.kind {
        case .stickCenters:
            let divisor = Float(session.sampleCount)
            newSettings.calibration.leftStick.center = ControllerVector2(
                x: session.leftSum.x / divisor,
                y: session.leftSum.y / divisor
            )
            newSettings.calibration.rightStick.center = ControllerVector2(
                x: session.rightSum.x / divisor,
                y: session.rightSum.y / divisor
            )
        case .stickFullRange:
            newSettings.calibration.leftStick.minimum = session.leftMinimum
            newSettings.calibration.leftStick.maximum = session.leftMaximum
            newSettings.calibration.rightStick.minimum = session.rightMinimum
            newSettings.calibration.rightStick.maximum = session.rightMaximum
        case .triggers:
            newSettings.calibration.leftTrigger.minimum = session.leftTriggerMinimum
            newSettings.calibration.leftTrigger.maximum = max(session.leftTriggerMaximum, session.leftTriggerMinimum + 0.001)
            newSettings.calibration.rightTrigger.minimum = session.rightTriggerMinimum
            newSettings.calibration.rightTrigger.maximum = max(session.rightTriggerMaximum, session.rightTriggerMinimum + 0.001)
        }
        calibrationSession = nil
        calibrationProgress = nil
        settings = newSettings
    }

    private var leftTriggerEnvelope = ControllerTriggerEnvelope()
    private var rightTriggerEnvelope = ControllerTriggerEnvelope()
    private var leftTriggerBoost: Float = 0
    private var rightTriggerBoost: Float = 0

    private func updateTriggerEnvelopes(_ gamepad: GCDualSenseGamepad, at now: Double) {
        let t = settings.adaptiveTriggers
        func buzzes(_ preset: AdaptiveTriggerPreset, locked: Bool, pressure: Float) -> Bool {
            guard !locked, pressure > 0.05 else { return false }
            switch preset {
            case .automatic, .machineGun, .heartbeat, .galloping: return true
            default: return false
            }
        }
        triggerVibrationActive = buzzes(t.leftPreset, locked: enhancements.leftLock, pressure: gamepad.leftTrigger.value)
            || buzzes(t.rightPreset, locked: enhancements.rightLock, pressure: gamepad.rightTrigger.value)
        let left = leftTriggerEnvelope.sample(preset: enhancements.leftLock ? .off : t.leftPreset, pressure: gamepad.leftTrigger.value, now: now)
        let right = rightTriggerEnvelope.sample(preset: enhancements.rightLock ? .off : t.rightPreset, pressure: gamepad.rightTrigger.value, now: now)
        for (event, locality) in [(left, HapticLocality.leftHandle), (right, HapticLocality.rightHandle)] where event.intensity > 0 {
            playTestPulse(intensity: event.intensity, sharpness: 0.85, duration: event.duration, locality: locality)
        }
        if left.forceBoost != leftTriggerBoost {
            leftTriggerBoost = left.forceBoost
        }
        if right.forceBoost != rightTriggerBoost {
            rightTriggerBoost = right.forceBoost
        }
    }

    // MARK: - Adaptive triggers

    func applyAdaptiveTriggerSettings() {
        leftTriggerEnvelope = ControllerTriggerEnvelope(); rightTriggerEnvelope = ControllerTriggerEnvelope()
        leftTriggerBoost = 0; rightTriggerBoost = 0
        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyAdaptiveTrigger(dualSense.leftTrigger, preset: settings.adaptiveTriggers.leftPreset)
        applyAdaptiveTrigger(dualSense.rightTrigger, preset: settings.adaptiveTriggers.rightPreset)
        let e = enhancements
        let position = min(max(e.lockPosition, 0.05), 0.95)
        if e.leftLock { dualSense.leftTrigger.setModeFeedbackWithStartPosition(position, resistiveStrength: 1) }
        if e.rightLock { dualSense.rightTrigger.setModeFeedbackWithStartPosition(position, resistiveStrength: 1) }
    }

    /// DualSenseX default-menu mapping. DSX raw values convert to Apple's
    /// normalized scales as positions ×9 zones, strengths ×8, frequencies ÷255.
    private func applyAdaptiveTrigger(_ trigger: GCDualSenseAdaptiveTrigger, preset: AdaptiveTriggerPreset) {
        switch preset {
        case .off:
            trigger.setModeOff()
        case .pistol:
            trigger.setModeWeaponWithStartPosition(0.25, endPosition: 0.40, resistiveStrength: 0.85)
        case .sniper:
            trigger.setModeWeaponWithStartPosition(0.50, endPosition: 0.60, resistiveStrength: 1.0)
        case .automatic:
            trigger.setModeVibrationWithStartPosition(0, amplitude: 0.90, frequency: 0.12)
        case .machineGun:
            trigger.setModeVibrationWithStartPosition(0, amplitude: 1.0, frequency: 0.05)
        case .bow:
            applySlopeFeedback(trigger, start: 0.10, end: 0.90, startStrength: 0.10, endStrength: 0.95)
        case .accelerator:
            // A progressive pedal: light at the top of travel, firmer toward
            // full throttle, so partial throttle is easy to hold.
            applySlopeFeedback(trigger, start: 0.0, end: 0.9, startStrength: 0.12, endStrength: 0.5)
        case .brake:
            applyResistanceZones(trigger, levels: [0.05, 0.10, 0.20, 0.30, 0.45, 0.65, 0.85, 0.95, 1.0, 1.0], fallback: 0.80)
        case .twoStage:
            applyResistanceZones(trigger, levels: [0.10, 0.10, 0.10, 0.10, 0.10, 0.90, 1.0, 1.0, 0.0, 0.0], fallback: 0.50)
        case .stiffSpring:
            trigger.setModeFeedbackWithStartPosition(0, resistiveStrength: 0.85)
        case .softSpring:
            trigger.setModeFeedbackWithStartPosition(0, resistiveStrength: 0.25)
        case .heartbeat:
            trigger.setModeVibrationWithStartPosition(0, amplitude: 0.60, frequency: 0.03)
        case .galloping:
            trigger.setModeVibrationWithStartPosition(0.2, amplitude: 0.70, frequency: 0.06)
        case .choppy:
            applyResistanceZones(trigger, levels: [0.8, 0.1, 0.8, 0.1, 0.8, 0.1, 0.8, 0.1, 0.8, 0.1], fallback: 0.45)
        }
    }

    private func applyResistanceZones(_ trigger: GCDualSenseAdaptiveTrigger, levels: [Float], fallback: Float) {
        guard levels.count == 10 else { trigger.setModeOff(); return }
        if #available(macOS 12.3, *) {
            let zones = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths(values: (
                levels[0], levels[1], levels[2], levels[3], levels[4],
                levels[5], levels[6], levels[7], levels[8], levels[9]
            ))
            trigger.setModeFeedback(resistiveStrengths: zones)
        } else {
            trigger.setModeFeedbackWithStartPosition(0, resistiveStrength: min(max(fallback, 0), 1))
        }
    }

    private func applySlopeFeedback(_ trigger: GCDualSenseAdaptiveTrigger, start: Float, end: Float, startStrength: Float, endStrength: Float) {
        if #available(macOS 12.3, *) {
            trigger.setModeSlopeFeedback(startPosition: start, endPosition: end, startStrength: startStrength, endStrength: endStrength)
        } else {
            trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: startStrength)
        }
    }

    // MARK: - Haptics

    func playTestPulse(
        intensity: Float? = nil,
        sharpness: Float? = nil,
        duration: TimeInterval = 0.12,
        locality: HapticLocality? = nil,
        sustained: Bool = false
    ) {
        guard settings.haptics.mode != .off else { return }
        let target = locality ?? settings.haptics.preferredLocality
        guard let engine = engine(for: target) else {
            lastError = "The selected controller haptic locality is unavailable."
            return
        }
        let requestedIntensity = intensity ?? 0.7
        let multiplier = max(settings.haptics.intensityMultiplier, 0)
        let finalIntensity = min(max(requestedIntensity * multiplier, 0), 1)
        let finalSharpness = min(max(sharpness ?? settings.haptics.sharpness, 0), 1)
        let finalDuration = min(max(duration, 0.01), 2)

        do {
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: finalIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: finalSharpness),
            ]
            let event = CHHapticEvent(
                eventType: !sustained && finalDuration <= 0.08 ? .hapticTransient : .hapticContinuous,
                parameters: parameters,
                relativeTime: 0,
                duration: finalDuration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            localHapticEndsAt = max(localHapticEndsAt, ProcessInfo.processInfo.systemUptime + finalDuration + 0.05)
        } catch {
            lastError = "Haptic playback failed: \(error.localizedDescription)"
        }
    }

    func stopHaptics() {
        stopStreamRumble()
        stopHapticEngines()
        rebuildHapticEngines(for: controller)
    }

    private func rebuildHapticEngines(for controller: GCController?) {
        stopHapticEngines()
        guard settings.haptics.mode != .off, let haptics = controller?.haptics else { return }
        for locality in HapticLocality.allCases where supports(locality, on: haptics) {
            guard let engine = haptics.createEngine(withLocality: gcLocality(for: locality)) else { continue }
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            // A controller that sleeps or reconnects stops its engine; drop
            // the players so the next rumble rebuilds them instead of failing.
            // Only the engine currently in use may discard its players, and it
            // stops them rather than dropping a player that is still looping.
            engine.stoppedHandler = { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self, let engine, self.hapticEngines[locality] === engine else { return }
                    if let player = self.rumblePlayers.removeValue(forKey: locality) { try? player.stop(atTime: CHHapticTimeImmediate) }
                    self.rumbleLevels[locality] = nil
                }
            }
            engine.resetHandler = { [weak self, weak engine] in
                Task { @MainActor in
                    guard let self, let engine, self.hapticEngines[locality] === engine else { return }
                    if let player = self.rumblePlayers.removeValue(forKey: locality) { try? player.stop(atTime: CHHapticTimeImmediate) }
                    self.rumbleLevels[locality] = nil
                    try? engine.start()
                }
            }
            hapticEngines[locality] = engine
        }
    }

    /// Drives one continuous rumble channel, creating its looping player on
    /// demand and sending only changed parameters.
    private func setRumble(_ level: (intensity: Float, sharpness: Float), on channel: HapticLocality) {
        if level.intensity <= 0.003 {
            if let player = rumblePlayers.removeValue(forKey: channel) { try? player.stop(atTime: CHHapticTimeImmediate) }
            rumbleLevels[channel] = nil
            return
        }
        guard let engine = engine(for: channel) else { return }
        do {
            var player = rumblePlayers[channel]
            if player == nil {
                try engine.start()
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: 0, duration: 1)
                let created = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                created.loopEnabled = true
                try created.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                try created.start(atTime: CHHapticTimeImmediate)
                rumblePlayers[channel] = created
                player = created
                rumbleLevels[channel] = nil
            }
            if let last = rumbleLevels[channel], abs(last.intensity - level.intensity) < 0.005, abs(last.sharpness - level.sharpness) < 0.01 { return }
            // Sharpness control is relative to the pattern's 0.5 base.
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level.intensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: level.sharpness - 0.5, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
            rumbleLevels[channel] = level
        } catch {
            if let player = rumblePlayers.removeValue(forKey: channel) { try? player.stop(atTime: CHHapticTimeImmediate) }
            rumbleLevels[channel] = nil
            let message = "Rumble failed: \(error.localizedDescription)"
            if lastError != message { lastError = message }
        }
    }

    private func stopRumblePlayers() {
        rumblePlayers.values.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
        rumblePlayers.removeAll()
        rumbleLevels.removeAll()
    }

    private func engine(for locality: HapticLocality) -> CHHapticEngine? {
        hapticEngines[locality] ?? hapticEngines[.default]
    }

    private func stopHapticEngines() {
        stopRumblePlayers()
        hapticEngines.values.forEach { $0.stop(completionHandler: nil) }
        hapticEngines.removeAll()
    }

    // MARK: - Touchpad gestures

    private func configureTouchpadHandlers(for controller: GCController?) {
        guard let controller else { return }
        for touchpad in controller.physicalInputProfile.allTouchpads {
            touchpad.touchDown = nil
            touchpad.touchMoved = nil
            touchpad.touchUp = nil
        }
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            dualSense.touchpadPrimary.valueChangedHandler = nil
            dualSense.touchpadSecondary.valueChangedHandler = nil
        }
        touchRuntime.pendingTapTask?.cancel()
        touchRuntime.fallbackExpiryTasks.values.forEach { $0.cancel() }
        touchRuntime = TouchRuntimeState()
        guard settings.touchpad.isEnabled || enhancements.touchpadAimEnabled else { return }

        // NSSet iteration was assigning fingers arbitrarily on every reconfigure.
        var touchpads = controller.physicalInputProfile.touchpads.sorted { $0.key < $1.key }.map(\.value)
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad,
           let primary = touchpads.firstIndex(where: { $0.touchSurface === dualSense.touchpadPrimary }) {
            touchpads.swapAt(0, primary)
        }
        if !touchpads.isEmpty {
            for (index, touchpad) in touchpads.prefix(2).enumerated() {
                configureTouchpad(touchpad, index: index)
            }
        } else if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            // Some macOS/connection combinations expose DualSense coordinates
            // but not GCControllerTouchpad down/up events. Fall back to coordinate
            // changes from the two contact pads and use click as an explicit tap.
            dualSense.touchpadPrimary.valueChangedHandler = { [weak self] pad, x, y in
                MainActor.assumeIsolated { self?.handleFallbackTouch(index: 0, x: x, y: y, moved: pad.valueChangedHandler != nil) }
            }
            dualSense.touchpadSecondary.valueChangedHandler = { [weak self] pad, x, y in
                MainActor.assumeIsolated { self?.handleFallbackTouch(index: 1, x: x, y: y, moved: pad.valueChangedHandler != nil) }
            }
            dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.emitGesture(.tap) }
            }
        }
    }

    private func configureTouchpad(_ touchpad: GCControllerTouchpad?, index: Int) {
        guard let touchpad else { return }
        touchpad.reportsAbsoluteTouchSurfaceValues = true
        touchpad.touchDown = { [weak self] _, x, y, _, _ in
            MainActor.assumeIsolated { self?.handleTouch(index: index, phase: .down, x: x, y: y) }
        }
        touchpad.touchMoved = { [weak self] _, x, y, _, _ in
            MainActor.assumeIsolated { self?.handleTouch(index: index, phase: .moving, x: x, y: y) }
        }
        touchpad.touchUp = { [weak self] _, x, y, _, _ in
            MainActor.assumeIsolated { self?.handleTouch(index: index, phase: .up, x: x, y: y) }
        }
    }

    private func handleFallbackTouch(index: Int, x: Float, y: Float, moved: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let position = ControllerVector2(x: x, y: y)
        if index == 0 {
            if !touchRuntime.primaryActive {
                touchRuntime.pendingTapTask?.cancel()
                touchRuntime.beganAt = now
                touchRuntime.swipeEmitted = false
                touchRuntime.startPosition = position
            }
            touchRuntime.primaryActive = true
            touchRuntime.currentPosition = position
        } else {
            touchRuntime.secondaryActive = true
            touchRuntime.secondFingerSeen = true
        }
        // Direction-pad fallback has no true up event; coalesce expiry work per
        // contact so a coordinate stream cannot create an unbounded task pile.
        touchRuntime.fallbackExpiryTasks[index]?.cancel()
        touchRuntime.fallbackExpiryTasks[index] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.touchRuntime.fallbackExpiryTasks[index] = nil
                if index == 0, self.touchRuntime.primaryActive {
                    self.finishPrimaryTouch(at: ProcessInfo.processInfo.systemUptime, endPosition: self.touchRuntime.currentPosition)
                    self.touchRuntime.primaryActive = false
                } else if index == 1 {
                    self.touchRuntime.secondaryActive = false
                }
                self.publishCurrentSnapshot()
            }
        }
        recognizeSwipe()
        _ = moved
    }

    private func handleTouch(index: Int, phase: GCControllerTouchpad.TouchState, x: Float, y: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let position = ControllerVector2(x: x, y: y)

        if index == 0 {
            switch phase {
            case .down:
                touchRuntime.pendingTapTask?.cancel()
                touchRuntime.beganAt = now
                touchRuntime.swipeEmitted = false
                touchRuntime.startPosition = position
                touchRuntime.currentPosition = position
                touchRuntime.primaryActive = true
                touchRuntime.secondFingerSeen = touchRuntime.secondaryActive
            case .moving:
                touchRuntime.primaryActive = true
                touchRuntime.currentPosition = position
            case .up:
                finishPrimaryTouch(at: now, endPosition: touchRuntime.currentPosition)
                touchRuntime.primaryActive = false
            @unknown default:
                break
            }
        } else {
            switch phase {
            case .down, .moving:
                touchRuntime.secondaryActive = true
                touchRuntime.secondFingerSeen = true
            case .up:
                touchRuntime.secondaryActive = false
            @unknown default:
                break
            }
        }
        recognizeSwipe()
    }

    private func recognizeSwipe() {
        guard touchRuntime.primaryActive, !touchRuntime.swipeEmitted else { return }
        let dx = touchRuntime.currentPosition.x - touchRuntime.startPosition.x
        let dy = touchRuntime.currentPosition.y - touchRuntime.startPosition.y
        guard max(abs(dx), abs(dy)) >= settings.touchpad.swipeMinimumDistance else { return }
        touchRuntime.swipeEmitted = true
        touchRuntime.pendingTapTask?.cancel()
        emitGesture(abs(dx) > abs(dy) ? (dx > 0 ? .swipeRight : .swipeLeft) : (dy > 0 ? .swipeUp : .swipeDown))
    }

    private func finishPrimaryTouch(at timestamp: TimeInterval, endPosition: ControllerVector2) {
        if touchRuntime.swipeEmitted {
            touchRuntime.beganAt = nil; touchRuntime.secondFingerSeen = false; return
        }
        guard let beganAt = touchRuntime.beganAt else { return }
        let duration = timestamp - beganAt
        let deltaX = endPosition.x - touchRuntime.startPosition.x
        let deltaY = endPosition.y - touchRuntime.startPosition.y
        let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
        let config = settings.touchpad

        if distance >= config.swipeMinimumDistance {
            if abs(deltaX) > abs(deltaY) {
                emitGesture(deltaX > 0 ? .swipeRight : .swipeLeft)
            } else {
                emitGesture(deltaY > 0 ? .swipeUp : .swipeDown)
            }
        } else if touchRuntime.secondFingerSeen, duration <= config.tapMaximumDuration,
                  distance < 0.12 {
            emitGesture(.twoFingerTap)
        } else if duration >= config.longPressDuration {
            emitGesture(.longPress)
        } else if duration <= config.tapMaximumDuration {
            registerTap(at: timestamp)
        }

        touchRuntime.beganAt = nil
        touchRuntime.secondFingerSeen = false
    }

    private func registerTap(at timestamp: TimeInterval) {
        let interval = settings.touchpad.doubleTapInterval
        if let previous = touchRuntime.lastTapAt, timestamp - previous <= interval {
            touchRuntime.pendingTapTask?.cancel()
            touchRuntime.pendingTapTask = nil
            touchRuntime.lastTapAt = nil
            emitGesture(.doubleTap)
            return
        }
        touchRuntime.lastTapAt = timestamp
        touchRuntime.pendingTapTask?.cancel()
        touchRuntime.pendingTapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.touchRuntime.lastTapAt = nil
                self.touchRuntime.pendingTapTask = nil
                self.emitGesture(.tap)
            }
        }
    }

    private func emitGesture(_ gesture: TouchpadGesture) {
        guard settings.touchpad.isEnabled, !enhancements.touchpadAimEnabled else { return }
        guard let mapping = settings.touchpad.mappings.first(where: { $0.isEnabled && $0.gesture == gesture }) else { return }

        if lastGesture != gesture.rawValue { lastGesture = gesture.rawValue }
        dispatch(action: mapping.action)
    }

    // MARK: - Shortcuts and macros

    private func processShortcuts(current: ControllerInputSnapshot, previous: ControllerInputSnapshot) {
        let now = current.timestamp
        for shortcut in settings.shortcuts.shortcuts where shortcut.isEnabled && !shortcut.controls.isEmpty {
            var runtime = shortcutRuntime[shortcut.id] ?? ShortcutRuntimeState()
            let chordPressed = shortcut.controls.allSatisfy { self.isPressed($0, in: current) }
            let wasPressed = shortcut.controls.allSatisfy { self.isPressed($0, in: previous) }

            switch shortcut.activation {
            case .press:
                if chordPressed && !wasPressed { dispatch(action: shortcut.action) }
            case .release:
                if !chordPressed && wasPressed { dispatch(action: shortcut.action) }
            case .hold(let seconds):
                if chordPressed {
                    if runtime.pressedAt == nil { runtime.pressedAt = now }
                    if !runtime.didFireHold, now - (runtime.pressedAt ?? now) >= max(seconds, 0) {
                        runtime.didFireHold = true
                        dispatch(action: shortcut.action)
                    }
                } else {
                    runtime.pressedAt = nil
                    runtime.didFireHold = false
                }
            case .doublePress(let maximumInterval):
                if chordPressed && !wasPressed {
                    if let previousPress = runtime.lastPressedAt,
                       now - previousPress <= max(maximumInterval, 0.05) {
                        dispatch(action: shortcut.action)
                        runtime.lastPressedAt = nil
                    } else {
                        runtime.lastPressedAt = now
                    }
                }
            }
            runtime.wasChordPressed = chordPressed
            shortcutRuntime[shortcut.id] = runtime
        }
    }

    private func isPressed(_ control: ControllerControl, in snapshot: ControllerInputSnapshot) -> Bool {
        switch control {
        case .leftTrigger: return snapshot.leftTrigger > 0.5
        case .rightTrigger: return snapshot.rightTrigger > 0.5
        default: return snapshot.buttons[control].isPressed
        }
    }

    private func dispatch(action: ControllerNativeAction) {
        switch action {
        case .none:
            return
        default:
            onShortcutAction?(action)
        }
    }

    /// Identifies an execution, not a saved macro: restarting the same UUID must
    /// not let the cancelled task clear the replacement task or its button output.
    private var macroExecutionToken: UUID?

    func runMacro(id: UUID) {
        guard let macro = settings.macros.first(where: { $0.id == id }) else { return }
        do {
            try macro.validate()
        } catch {
            lastError = error.localizedDescription
            return
        }
        resetMacros()
        let token = UUID()
        macroExecutionToken = token
        macroTasks[id] = Task { @MainActor [weak self] in
            defer {
                if self?.macroExecutionToken == token {
                    self?.macroExecutionToken = nil
                    self?.macroTasks[id] = nil
                    self?.onMacroReset?()
                }
            }
            for step in macro.steps {
                guard !Task.isCancelled, self?.macroExecutionToken == token else { return }
                if step.delayMilliseconds > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(step.delayMilliseconds) * 1_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, self?.macroExecutionToken == token else { return }
                self?.executeMacroStep(step)
                // Haptic durations count toward the two-second sequence budget.
                if case .haptic(_, _, let duration) = step.action, duration > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000) }
                    catch { return }
                }
            }
        }
    }

    func cancelMacro(id: UUID) {
        guard let task = macroTasks.removeValue(forKey: id) else { return }
        macroExecutionToken = nil
        task.cancel()
        onMacroReset?()
    }

    func resetMacros() {
        macroExecutionToken = nil
        macroTasks.values.forEach { $0.cancel() }
        macroTasks.removeAll()
        onMacroReset?()
    }

    private func executeMacroStep(_ step: ControllerMacroStep) {
        switch step.action {
        case .button(let control, let isPressed):
            onMacroButtonAction?(control, isPressed)
        case .haptic(let intensity, let sharpness, let durationMilliseconds):
            playTestPulse(
                intensity: intensity,
                sharpness: sharpness,
                duration: Double(durationMilliseconds) / 1_000
            )
        case .nativeAction(let action):
            guard case .macro = action else {
                dispatch(action: action)
                return
            }
            lastError = ControllerMacroValidationError.nestedMacro.localizedDescription
        }
    }

    // MARK: - LED

    func applyLEDPolicy() {
        // A queued alert flash owns the lightbar until it restores the policy
        // colour itself; re-applying mid-flash would cancel the pulses.
        guard readyAlertTask == nil else { return }
        guard let light = controller?.light else { return }
        let config = settings.led
        let battery = controller.flatMap(batterySnapshot(from:))
        var color: ControllerLEDColor

        switch config.mode {
        case .system:
            return
        case .off:
            color = .off
        case .fixedColor:
            color = config.color.clamped
        case .batteryLevel:
            let level = battery?.level ?? 1
            color = ControllerLEDColor(red: 1 - level, green: level, blue: 0)
        }

        if let battery,
           battery.state == .discharging,
           battery.level <= min(max(config.lowBatteryThreshold, 0), 1) {
            switch config.batteryPolicy {
            case .ignore:
                break
            case .dimWhenLow:
                color.red *= 0.25
                color.green *= 0.25
                color.blue *= 0.25
            case .redWhenLow:
                color = ControllerLEDColor(red: 1, green: 0, blue: 0)
            case .turnOffWhenLow:
                color = .off
            }
        }

        let brightness = min(max(config.brightness, 0), 1)
        let effective = ControllerLEDColor(red: color.red * brightness, green: color.green * brightness, blue: color.blue * brightness)
        guard effective != lastLEDColor else { return }
        lastLEDColor = effective
        light.color = GCColor(red: effective.red, green: effective.green, blue: effective.blue)
    }

    /// The "your game is ready" attention alert: three light-green lightbar
    /// pulses paired with a haptic blip each, then the user's LED policy
    /// colour is restored. Safe when no controller or lightbar is present —
    /// the notification half of the alert still fires in that case.
    func readyAlertFlash() {
        guard readyAlertTask == nil else { return }
        readyAlertTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let green = GCColor(red: 0.2, green: 0.95, blue: 0.35)
            for pulse in 0..<3 {
                self.controller?.light?.color = green
                self.playTestPulse(intensity: 0.8, sharpness: 0.4, duration: 0.12)
                try? await Task.sleep(nanoseconds: 260_000_000)
                if pulse < 2 {
                    self.controller?.light?.color = GCColor(red: 1, green: 1, blue: 1)
                    try? await Task.sleep(nanoseconds: 260_000_000)
                }
            }
            // Release the LED guard first, then let the policy write through
            // the de-dup memo: clearing it forces applyLEDPolicy to re-set
            // whatever colour the user actually chose.
            self.readyAlertTask = nil
            self.lastLEDColor = nil
            self.applyLEDPolicy()
            self.onLightRestore?()
        }
    }

    // MARK: - Framework adapters

    private func registerForControllerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let connected = note.object as? GCController else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controller == nil { self.attach(to: connected) }
                else if self.pollTimer == nil { self.startPolling() }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let disconnected = note.object as? GCController else { return }
            MainActor.assumeIsolated {
                guard let self, self.controller === disconnected else { return }
                self.detach()
                self.attachFirstAvailableController()
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
            guard let current = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(to: current) }
        })
    }

    private func configureInputHandlers(for controller: GCController) {
        // A single fixed-rate publisher owns snapshots. Hardware callbacks
        // previously duplicated full snapshot work on top of the 60 Hz timer.
        controller.extendedGamepad?.valueChangedHandler = nil
    }

    private func makeDescriptor(for controller: GCController) -> ControllerDescriptor {
        let index: Int?
        switch controller.playerIndex {
        case .index1: index = 1
        case .index2: index = 2
        case .index3: index = 3
        case .index4: index = 4
        case .indexUnset: index = nil
        @unknown default: index = nil
        }
        return ControllerDescriptor(
            id: String(ObjectIdentifier(controller).hashValue),
            vendorName: controller.vendorName ?? "Game Controller",
            productCategory: controller.productCategory,
            playerIndex: index,
            isAttachedToDevice: controller.isAttachedToDevice
        )
    }

    private func makeCapabilities(for controller: GCController) -> ControllerCapabilities {
        let gamepad = controller.extendedGamepad
        let dualSense = gamepad as? GCDualSenseGamepad
        let hapticLocalities = HapticLocality.allCases.filter { locality in
            guard let haptics = controller.haptics else { return false }
            return supports(locality, on: haptics)
        }
        return ControllerCapabilities(
            hasExtendedGamepad: gamepad != nil,
            hasTouchpad: dualSense != nil,
            supportsTwoFingerTouch: dualSense != nil,
            hasAdaptiveTriggers: dualSense != nil,
            hasHaptics: controller.haptics != nil,
            hapticLocalities: hapticLocalities,
            hasLight: controller.light != nil,
            hasBattery: controller.battery != nil,
            hasMenuButton: gamepad != nil,
            hasOptionsButton: gamepad?.buttonOptions != nil,
            hasHomeButton: gamepad?.buttonHome != nil,
            hasThumbstickButtons: gamepad?.leftThumbstickButton != nil && gamepad?.rightThumbstickButton != nil
        )
    }

    private func gcLocality(for locality: HapticLocality) -> GCHapticsLocality {
        switch locality {
        case .default: return .default
        case .all: return .all
        case .handles: return .handles
        case .leftHandle: return .leftHandle
        case .rightHandle: return .rightHandle
        case .triggers: return .triggers
        case .leftTrigger: return .leftTrigger
        case .rightTrigger: return .rightTrigger
        }
    }

    private func supports(_ locality: HapticLocality, on haptics: GCDeviceHaptics) -> Bool {
        haptics.supportedLocalities.contains(gcLocality(for: locality))
    }
}
