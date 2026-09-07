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
        didSet { if !streamInputEnabled { rapidFireStartedAt = nil; stopStreamRumble() } }
    }
    private var lastStreamInputAt: TimeInterval = 0
    private var sentStreamInput = false
    @Published private(set) var motionPreview = ControllerVector2.zero
    @Published private(set) var motionStatus = "Gyro disabled"
    @Published var aimDeliveryStatus = "Waiting for stream input"
    private var lastMotionReportAt: TimeInterval = 0
    @Published private(set) var touchPreview = ControllerVector2.zero
    @Published private(set) var lastGesture = "No gesture yet"
    private var rumbleCounts = (all: 0, trigger: 0)
    private var lastRumblePublishAt: TimeInterval = 0
    private var rapidFireStartedAt: TimeInterval?
    private var streamHapticPlayer: CHHapticAdvancedPatternPlayer?
    private var streamRumbleEndsAt: TimeInterval = 0
    private var triggerFeedbackEndsAt: TimeInterval = 0
    private var lastStreamIntensity: Float = -1
    private var lastStreamSharpness: Float = -1
    private var lastGameTriggerLevels = ControllerVector2(x: -1, y: -1)
    private var triggerRestoreTask: Task<Void, Never>?
    private var gyroBias = ControllerVector2.zero
    private var smoothedGyro = ControllerVector2.zero
    private let rawTouch = DualSenseTouchReader()
    private var precisionGyro = ControllerPrecisionGyro()
    private var touchServo = ControllerTouchServo()
    private var flickState = ControllerFlickState()
    private var touchAimCentre: ControllerVector2?
    private var lastTouchAimSampleAt: Double?
    private var lastTouchUsedRaw = false
    private var steeringWheel = ControllerWheelState()
    private var steeringResponse = ControllerSteeringResponse()
    private var lastSteeringTarget: Float = 0
    private var lastSteeringOutput: Float = 0
    @Published private(set) var steeringPreview = "Center Gyro while driving straight"

    private func yawRate(_ motion: GCMotion) -> Float {
        let rate = motion.rotationRate, gravity = motion.gravity
        return ControllerMotionProjection.yaw(x: rate.x, y: rate.y, z: rate.z, gx: gravity.x, gy: gravity.y, gz: gravity.z)
    }

    private func updateSteering(_ motion: GCMotion, at timestamp: Double) {
        let gravity = motion.gravity, acceleration = motion.acceleration, rate = motion.rotationRate
        let input = ControllerWheelMotion.select(hasGravity: motion.hasGravityAndUserAcceleration,
            gravity: ControllerMotionVector(x: gravity.x, y: gravity.y, z: gravity.z),
            acceleration: ControllerMotionVector(x: acceleration.x, y: acceleration.y, z: acceleration.z))
        let rotation = motion.hasRotationRate
            ? ControllerMotionVector(x: rate.x, y: rate.y, z: rate.z) : .zero
        guard let angle = steeringWheel.sample(input, rate: rotation, now: timestamp, hasRate: motion.hasRotationRate) else {
            steeringResponse.reset(at: timestamp); lastSteeringTarget = 0; lastSteeringOutput = 0
            return
        }
        lastSteeringTarget = ControllerAimMath.steering(angle: angle, centre: 0,
            range: enhancements.effectiveSteeringRangeRadians, floor: enhancements.effectiveSteeringFloor,
            deadzone: (enhancements.steeringDeadzoneDegrees ?? 0) * .pi / 180,
            exponent: enhancements.steeringExponent ?? 1, inverted: enhancements.steeringInverted ?? false) * enhancements.effectiveSteeringMaximum
        lastSteeringOutput = steeringResponse.sample(target: Double(lastSteeringTarget), now: timestamp,
            smoothing: Double(enhancements.steeringSmoothing ?? 0.5))
    }

    func centerGyro() {
        guard let motion = controller?.motion else { return }
        gyroBias = ControllerVector2(x: yawRate(motion), y: Float(motion.rotationRate.x))
        updateSteering(motion, at: ProcessInfo.processInfo.systemUptime)
        steeringWheel.center()
        steeringResponse.reset(at: ProcessInfo.processInfo.systemUptime)
        lastSteeringTarget = 0; lastSteeringOutput = 0
        flickState.reset(); precisionGyro.reset()
        smoothedGyro = .zero
    }

    func resetRumbleDiagnostics() {
        rumbleCounts = (0, 0)
        rumbleEventCount = 0; triggerRumbleEventCount = 0
        rumbleChannels = "No stream rumble received"
    }

    func stopStreamRumble() {
        try? streamHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        streamHapticPlayer = nil
        lastStreamIntensity = -1; lastStreamSharpness = -1
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
        // Gain always applies; the old Normal mode silently capped amplification at 1×.
        let intensity = min(e.rumble(max(left, right), global: globalRumbleGain) * max(settings.haptics.intensityMultiplier, 0), 1)
        let seconds = duration.isFinite ? min(max(duration, 0), 2) : 0.15
        guard seconds > 0, settings.haptics.mode != .off else { stopStreamRumble(); return }
        let now = ProcessInfo.processInfo.systemUptime
        streamRumbleEndsAt = now + seconds
        if intensity <= 0 {
            try? streamHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            streamHapticPlayer = nil; lastStreamIntensity = -1
        } else if let engine = engine(for: settings.haptics.preferredLocality) {
            do {
                if streamHapticPlayer == nil {
                    try engine.start()
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0)
                    ], relativeTime: 0, duration: 1)
                    let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                    player.loopEnabled = true
                    try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                    try player.start(atTime: CHHapticTimeImmediate)
                    streamHapticPlayer = player
                    lastStreamIntensity = -1
                }
                let sharpness = min(max(right, 0), 1)
                if intensity != lastStreamIntensity || sharpness != lastStreamSharpness {
                    try streamHapticPlayer?.sendParameters([
                        CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                        CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0)
                    ], atTime: CHHapticTimeImmediate)
                    lastStreamIntensity = intensity; lastStreamSharpness = sharpness
                }
            } catch { stopStreamRumble(); let message = "Stream rumble failed: \(error.localizedDescription)"; if lastError != message { lastError = message } }
        }
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
        registerForControllerNotifications()
        if automaticallyAttach {
            attach(to: GCController.current ?? GCController.controllers().first)
        }
    }

    deinit {
        pollTimer?.invalidate()
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
        controller.motion?.valueChangedHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.lastMotionReportAt = ProcessInfo.processInfo.systemUptime }
        }
        controller.motion?.sensorsActive = enhancements.gyroEnabled
        descriptor = makeDescriptor(for: controller)
        capabilities = makeCapabilities(for: controller)
        configureInputHandlers(for: controller)
        configureTouchpadHandlers(for: controller)
        if enhancements.touchpadAimEnabled { rawTouch.start() }
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
        controller?.motion?.valueChangedHandler = nil
        controller?.motion?.sensorsActive = false
        lastMotionReportAt = 0
        gyroAvailable = false
        steeringWheel.reset(); steeringResponse.reset(); lastSteeringTarget = 0; lastSteeringOutput = 0
        rawTouch.stop(); flickState.reset(); precisionGyro.reset(); touchServo.reset()
        touchAimCentre = nil
        gyroBias = .zero; smoothedGyro = .zero; rapidFireStartedAt = nil
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

    func startPolling(interval: TimeInterval = 1.0 / 60.0) {
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
        if enhancements.gyroStick != previous.enhancements?.gyroStick || enhancements.gyroEnabled != previous.enhancements?.gyroEnabled {
            steeringWheel.reset(); steeringResponse.reset(); lastSteeringTarget = 0; lastSteeringOutput = 0
        }
        if enhancements.gyroFlickMode != previous.enhancements?.gyroFlickMode || enhancements.gyroEnabled != previous.enhancements?.gyroEnabled {
            flickState.reset(); precisionGyro.reset(); smoothedGyro = .zero
        }
        if enhancements.touchpadAimEnabled != previous.enhancements?.touchpadAimEnabled { touchAimCentre = nil; lastTouchAimSampleAt = nil; touchServo.reset() }
        if enhancements.touchpadAimEnabled { rawTouch.start() } else { rawTouch.stop() }
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

        if enhancements.gyroMode == .steering, let motion = controller.motion {
            updateSteering(motion, at: timestamp)
        }
        let shouldPublishToUI = controllerToolsActive && (timestamp - lastPublishedAt) >= (highRateUIDetail ? 1.0 / 30.0 : 0.25)
        if shouldPublishToUI {
            if rumbleEventCount != rumbleCounts.all { rumbleEventCount = rumbleCounts.all }
            if triggerRumbleEventCount != rumbleCounts.trigger { triggerRumbleEventCount = rumbleCounts.trigger }
            snapshot = next
            lastPublishedAt = timestamp
        }
        if shouldPublishToUI {
            let status: String
            if !enhancements.gyroEnabled {
                status = "Gyro disabled"
            } else {
                let modeText: String
                switch enhancements.gyroMode {
                case .steering: modeText = " · Steering wheel → Left stick"
                case .aiming: modeText = " · Aiming → Right stick"
                case .flickShift: modeText = " · Flick shifting → Right stick"
                case .off: modeText = ""
                }
                status = (timestamp - lastMotionReportAt < 1 ? "Receiving motion reports" : "No recent motion reports — reconnect controller") + modeText
            }
            if motionStatus != status { motionStatus = status }
            if let motion = controller.motion { motionPreview = ControllerVector2(x: yawRate(motion), y: Float(motion.rotationRate.x)) }
            touchPreview = next.primaryTouch.isActive ? next.primaryTouch.position : .zero
            if enhancements.gyroMode == .steering {
                steeringPreview = steeringWheel.available
                    ? String(format: "Angle %+.1f° · Target %+.0f%% · Smoothed %+.0f%% · %@",
                             steeringWheel.angle * 180 / .pi, lastSteeringTarget * 100,
                             lastSteeringOutput * 100, steeringWheel.status)
                    : steeringWheel.status
            }
        }
        let wantsStreamInput = applyCalibrationToStream || enhancements.gyroEnabled || enhancements.touchpadAimEnabled || enhancements.rapidFireEnabled
        if streamInputEnabled && (wantsStreamInput || sentStreamInput) {
            let inputDelta = timestamp - lastStreamInputAt
            lastStreamInputAt = timestamp
            sentStreamInput = wantsStreamInput
            var output: [String: Double] = [:]
            if applyCalibrationToStream {
                output = ["LeftTrigger": Double(next.leftTrigger), "RightTrigger": Double(next.rightTrigger),
                          "LeftThumbXAxis": Double(next.leftStick.x), "LeftThumbYAxis": Double(next.leftStick.y),
                          "RightThumbXAxis": Double(next.rightStick.x), "RightThumbYAxis": Double(next.rightStick.y)]
            }
            let e = enhancements
            if e.gyroEnabled, let motion = controller.motion {
                if !motion.sensorsActive { motion.sensorsActive = true }
            }
            if e.gyroEnabled, let motion = controller.motion,
               (e.gyroStick == .left) || e.gyroFlickMode == true || !e.gyroAimOnly || rawLeftTrigger > 0.25 {
                if e.gyroStick == .left {
                    let steering = steeringWheel.available ? lastSteeringOutput : 0
                    // Keep the physical stick usable when steering sensors are unavailable.
                    let baseLeftX = applyCalibrationToStream ? next.leftStick.x : rawLeftStick.x
                    let baseLeftY = applyCalibrationToStream ? next.leftStick.y : rawLeftStick.y
                    output["LeftThumbXAxis"] = min(max(Double(baseLeftX) + Double(steering), -1), 1)
                    output["LeftThumbYAxis"] = Double(baseLeftY)
                    output.removeValue(forKey: "gyroX"); output.removeValue(forKey: "gyroY")
                    output.removeValue(forKey: "gyroFineX"); output.removeValue(forKey: "gyroFineY")
                    output.removeValue(forKey: "gyroAxisBase")
                } else {
                let rate = motion.rotationRate
                let rawRate = ControllerVector2(x: -(yawRate(motion) - gyroBias.x),
                    y: (Float(rate.x) - gyroBias.y) * (e.gyroInvertY ? -1 : 1))
                smoothedGyro = precisionGyro.sample(rawRate, dt: inputDelta,
                    noise: e.effectiveGyroNoiseThreshold, sensitivity: e.gyroSensitivity, floor: e.gyroOutputFloor ?? 0.12)
                output["gyroX"] = Double(smoothedGyro.x)
                output["gyroY"] = Double(smoothedGyro.y)
                output["gyroFineX"] = Double(precisionGyro.fine.x)
                output["gyroFineY"] = Double(precisionGyro.fine.y)
                output["gyroAxisBase"] = (e.gyroStick ?? .right).axisBase
                    lastSteeringOutput = 0
                    if e.gyroFlickMode == true {
                        let pitch = ControllerAimMath.tilt(gx: motion.gravity.x, gy: motion.gravity.y, gz: motion.gravity.z).y
                        output.removeValue(forKey: "gyroFineX"); output.removeValue(forKey: "gyroFineY")
                        output["gyroX"] = 0
                        output["gyroY"] = Double(flickState.sample(rate: Float(rate.x) - gyroBias.y, angle: pitch, now: timestamp) * (e.gyroInvertY ? -1 : 1))
                    }
                }
            } else { smoothedGyro = .zero; precisionGyro.reset(); flickState.reset(); lastSteeringOutput = 0 }
            if e.touchpadAimEnabled {
                // Steering owns the left stick by definition; touch aiming must
                // not zero its axes, so it always drives the right stick then.
                let touchStick: ControllerAimStick = e.gyroStick == .left ? .right : (e.touchpadStick ?? .right)
                output["touchAxisBase"] = touchStick.axisBase
                output["touchpadAim"] = 1
                if next.primaryTouch.isActive {
                    output["touchActive"] = 1
                    let usingRaw = rawTouch.point(0) != nil
                    if usingRaw != lastTouchUsedRaw {
                        // Coordinate sources differ; rebase without a phantom jump.
                        touchServo.reset(); touchAimCentre = nil; lastTouchAimSampleAt = nil
                        lastTouchUsedRaw = usingRaw
                    }
                    let reportAt = usingRaw ? rawTouch.reportTime : timestamp
                    if lastTouchAimSampleAt != reportAt {
                        if let previous = touchAimCentre {
                            touchServo.move(dx: next.primaryTouch.position.x - previous.x,
                                dy: next.primaryTouch.position.y - previous.y,
                                sensitivity: e.touchpadSensitivity ?? 0.35, at: timestamp)
                        }
                        touchAimCentre = next.primaryTouch.position
                        lastTouchAimSampleAt = reportAt
                    }
                    let servo = touchServo.sample(dt: inputDelta, floor: e.gyroOutputFloor ?? 0.12, now: timestamp, contact: true)
                    output["touchX"] = Double(servo.x)
                    output["touchY"] = Double(servo.y)
                } else {
                    touchServo.stop()
                    touchAimCentre = nil; lastTouchAimSampleAt = nil
                }
            } else { touchServo.reset(); touchAimCentre = nil; lastTouchAimSampleAt = nil }
            output["nativeControllerCount"] = Double(GCController.controllers().count)
            if e.rapidFireEnabled, rawRightTrigger > 0.5 {
                if rapidFireStartedAt == nil { rapidFireStartedAt = timestamp }
                let phase = (timestamp - (rapidFireStartedAt ?? timestamp)) * Double(min(max(e.rapidFireRate, 2), 15))
                output["RightTrigger"] = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0
            } else { rapidFireStartedAt = nil }
            onStreamInput?(output)
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
    }

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
        let left = leftTriggerEnvelope.sample(preset: enhancements.leftLock ? .off : t.leftPreset, pressure: gamepad.leftTrigger.value, now: now)
        let right = rightTriggerEnvelope.sample(preset: enhancements.rightLock ? .off : t.rightPreset, pressure: gamepad.rightTrigger.value, now: now)
        for (event, locality) in [(left, HapticLocality.leftHandle), (right, HapticLocality.rightHandle)] where event.intensity > 0 {
            playTestPulse(intensity: event.intensity, sharpness: 0.7, duration: event.duration, locality: locality, sustained: true)
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
            trigger.setModeFeedbackWithStartPosition(0, resistiveStrength: 0.35)
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
            engine.stoppedHandler = { _ in }
            hapticEngines[locality] = engine
        }
    }

    private func engine(for locality: HapticLocality) -> CHHapticEngine? {
        hapticEngines[locality] ?? hapticEngines[.default]
    }

    private func stopHapticEngines() {
        try? streamHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        streamHapticPlayer = nil
        lastStreamIntensity = -1
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
