//
//  ControllerFeatureService.swift
//  Xbox Cloud Gaming
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

    @Published private(set) var descriptor: ControllerDescriptor?
    @Published private(set) var capabilities = ControllerCapabilities.unavailable
    @Published private(set) var snapshot = ControllerInputSnapshot.empty
    @Published private(set) var calibrationProgress: ControllerCalibrationProgress?
    @Published private(set) var lastError: String?
    @Published var settings: ControllerSettings {
        didSet {
            persistSettings()
            applySettingsToAttachedController()
        }
    }

    var onNativeInputState: SnapshotHandler?
    var onShortcutAction: ActionHandler?
    var onMacroButtonAction: MacroButtonHandler?

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
    private var gyroBaselineGravityX: Double = 0
    private var filteredGyro = ControllerVector2.zero
    private var lastGyroTimestamp: TimeInterval?

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
        var lastTapAt: TimeInterval?
        var pendingTapTask: Task<Void, Never>?
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
            if defaults.integer(forKey: "nativeController.settingsVersion") < 2,
               saved.touchpad.mappings.isEmpty {
                saved.touchpad.mappings = TouchpadSettings.default.mappings
            }
            settings = saved
        } else {
            settings = .default
        }
        defaults.set(2, forKey: "nativeController.settingsVersion")
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
        if let motion = controller?.motion, motion.sensorsRequireManualActivation {
            motion.sensorsActive = false
        }
        if let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad {
            dualSense.leftTrigger.setModeOff()
            dualSense.rightTrigger.setModeOff()
        }
        hapticEngines.values.forEach { $0.stop(completionHandler: nil) }
    }

    // MARK: - Attachment and lifecycle

    func attach(to controller: GCController?) {
        guard self.controller !== controller else { return }
        detach()
        guard let controller else { return }

        self.controller = controller
        controller.handlerQueue = .main
        descriptor = makeDescriptor(for: controller)
        capabilities = makeCapabilities(for: controller)
        configureInputHandlers(for: controller)
        configureTouchpadHandlers(for: controller)
        configureMotion(for: controller)
        rebuildHapticEngines(for: controller)
        applyAdaptiveTriggerSettings()
        applyLEDPolicy()
        publishCurrentSnapshot()
    }

    func detach() {
        pollTimer?.invalidate()
        pollTimer = nil
        touchRuntime.pendingTapTask?.cancel()
        touchRuntime = TouchRuntimeState()
        macroTasks.values.forEach { $0.cancel() }
        macroTasks.removeAll()
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
            if let motion = controller.motion {
                motion.valueChangedHandler = nil
                if motion.sensorsRequireManualActivation {
                    motion.sensorsActive = false
                }
            }
        }

        stopHapticEngines()
        self.controller = nil
        descriptor = nil
        capabilities = .unavailable
        snapshot = .empty
        previousSnapshot = .empty
        shortcutRuntime.removeAll()
    }

    func attachFirstAvailableController() {
        attach(to: GCController.current ?? GCController.controllers().first)
    }

    func startPolling(interval: TimeInterval = 1.0 / 120.0) {
        guard pollTimer == nil else { return }
        let safeInterval = min(max(interval, 1.0 / 240.0), 0.25)
        pollTimer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishCurrentSnapshot() }
        }
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
        configureMotion(for: controller)
    }

    func recenterMotion() {
        gyroBaselineGravityX = snapshot.motion?.gravity.x ?? 0
        filteredGyro = .zero
        lastGyroTimestamp = nil
    }

    var processedGyroOutput: ControllerVector2 { filteredGyro }

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

    private func applySettingsToAttachedController() {
        guard !isApplyingSettings else { return }
        isApplyingSettings = true
        defer { isApplyingSettings = false }
        configureMotion(for: controller)
        configureTouchpadHandlers(for: controller)
        rebuildHapticEngines(for: controller)
        applyAdaptiveTriggerSettings()
        applyLEDPolicy()
    }

    // MARK: - Input snapshots

    func publishCurrentSnapshot() {
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let rawLeftStick = ControllerVector2(x: gamepad.leftThumbstick.xAxis.value, y: gamepad.leftThumbstick.yAxis.value)
        let rawRightStick = ControllerVector2(x: gamepad.rightThumbstick.xAxis.value, y: gamepad.rightThumbstick.yAxis.value)
        let rawLeftTrigger = gamepad.leftTrigger.value
        let rawRightTrigger = gamepad.rightTrigger.value
        let dualSense = gamepad as? GCDualSenseGamepad

        var next = ControllerInputSnapshot(
            timestamp: timestamp,
            leftStick: settings.calibration.leftStick.apply(to: rawLeftStick),
            rightStick: settings.calibration.rightStick.apply(to: rawRightStick),
            leftTrigger: settings.calibration.leftTrigger.apply(to: rawLeftTrigger),
            rightTrigger: settings.calibration.rightTrigger.apply(to: rawRightTrigger),
            buttons: buttonsSnapshot(from: gamepad, dualSense: dualSense),
            primaryTouch: dualSense.map { touchPoint(from: $0.touchpadPrimary, index: 0) } ?? .inactive,
            secondaryTouch: dualSense.map { touchPoint(from: $0.touchpadSecondary, index: 1) } ?? .inactive,
            motion: motionSnapshot(from: controller.motion),
            battery: batterySnapshot(from: controller)
        )

        if settings.gyro.mode == .off && !controllerToolsActive {
            next.motion = nil
        }
        updateFilteredGyro(from: next.motion, timestamp: timestamp)

        snapshot = next
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
        applyLEDPolicy()
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
        ControllerTouchPoint(
            isActive: index == 0 ? touchRuntime.primaryActive : touchRuntime.secondaryActive,
            position: ControllerVector2(x: touchpad.xAxis.value, y: touchpad.yAxis.value)
        )
    }

    private func motionSnapshot(from motion: GCMotion?) -> ControllerMotionSnapshot? {
        guard let motion else { return nil }
        let acceleration = motion.acceleration
        let gravity = motion.gravity
        let userAcceleration = motion.userAcceleration
        let rotation = motion.rotationRate
        let attitude = motion.attitude
        return ControllerMotionSnapshot(
            acceleration: ControllerVector3(x: acceleration.x, y: acceleration.y, z: acceleration.z),
            gravity: ControllerVector3(x: gravity.x, y: gravity.y, z: gravity.z),
            userAcceleration: ControllerVector3(x: userAcceleration.x, y: userAcceleration.y, z: userAcceleration.z),
            rotationRate: ControllerVector3(x: rotation.x, y: rotation.y, z: rotation.z),
            attitude: ControllerQuaternion(x: attitude.x, y: attitude.y, z: attitude.z, w: attitude.w)
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

    // MARK: - Motion

    func setMotionEnabled(_ enabled: Bool) {
        updateSettings { $0.gyro.mode = enabled ? .raw : .off }
    }

    private func configureMotion(for controller: GCController?) {
        guard let motion = controller?.motion else { return }
        let shouldEnable = settings.gyro.mode != .off || controllerToolsActive
        motion.valueChangedHandler = shouldEnable ? { [weak self] _ in
            MainActor.assumeIsolated { self?.publishCurrentSnapshot() }
        } : nil
        if motion.sensorsRequireManualActivation {
            motion.sensorsActive = shouldEnable
        }
    }

    private func updateFilteredGyro(from motion: ControllerMotionSnapshot?, timestamp: TimeInterval) {
        guard let motion, settings.gyro.mode != .off else {
            filteredGyro = .zero
            lastGyroTimestamp = timestamp
            return
        }
        let dt = min(max(timestamp - (lastGyroTimestamp ?? timestamp), 1.0 / 240.0), 0.1)
        lastGyroTimestamp = timestamp
        let target: ControllerVector2
        switch settings.gyro.mode {
        case .raw:
            target = ControllerVector2(
                x: Float((motion.gravity.x - gyroBaselineGravityX) * Double(settings.gyro.sensitivityX)),
                y: 0
            )
        case .rightStick, .pointer:
            target = ControllerVector2(
                x: Float(motion.rotationRate.y * Double(settings.gyro.sensitivityX) * dt * 7.5),
                y: Float(-motion.rotationRate.x * Double(settings.gyro.sensitivityY) * dt * 7.5)
            )
        case .off:
            target = .zero
        }
        let magnitude = target.magnitude
        let deadzone = settings.gyro.deadzone
        let deadzoned = magnitude < deadzone ? ControllerVector2.zero : target
        let alpha = Float(1 - exp(-dt * 16))
        filteredGyro.x += (deadzoned.x - filteredGyro.x) * alpha
        filteredGyro.y += (deadzoned.y - filteredGyro.y) * alpha
        filteredGyro.x = min(max(settings.gyro.invertX ? -filteredGyro.x : filteredGyro.x, -1), 1)
        filteredGyro.y = min(max(settings.gyro.invertY ? -filteredGyro.y : filteredGyro.y, -1), 1)
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

    // MARK: - Adaptive triggers

    func applyAdaptiveTriggerSettings() {
        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        applyAdaptiveTrigger(
            dualSense.leftTrigger,
            preset: settings.adaptiveTriggers.leftPreset,
            custom: settings.adaptiveTriggers.leftCustom
        )
        applyAdaptiveTrigger(
            dualSense.rightTrigger,
            preset: settings.adaptiveTriggers.rightPreset,
            custom: settings.adaptiveTriggers.rightCustom
        )
    }

    private func applyAdaptiveTrigger(
        _ trigger: GCDualSenseAdaptiveTrigger,
        preset: AdaptiveTriggerPreset,
        custom: AdaptiveTriggerCustomParameters
    ) {
        switch preset {
        case .off:
            trigger.setModeOff()
        case .softResistance:
            trigger.setModeFeedbackWithStartPosition(0.25, resistiveStrength: 0.25)
        case .firmResistance:
            trigger.setModeFeedbackWithStartPosition(0.2, resistiveStrength: 0.75)
        case .weapon:
            trigger.setModeWeaponWithStartPosition(0.2, endPosition: 0.55, resistiveStrength: 0.8)
        case .automaticRecoil:
            trigger.setModeVibrationWithStartPosition(0.18, amplitude: 0.78, frequency: 0.72)
        case .burstPulse:
            trigger.setModeVibrationWithStartPosition(0.24, amplitude: 0.58, frequency: 0.32)
        case .bow:
            applyCustomAdaptiveTrigger(
                trigger,
                parameters: AdaptiveTriggerCustomParameters(
                    mode: .slopeFeedback,
                    startPosition: 0.1,
                    endPosition: 0.9,
                    startStrength: 0.15,
                    endStrength: 0.95,
                    amplitude: 0,
                    frequency: 0
                )
            )
        case .accelerator:
            trigger.setModeSlopeFeedback(startPosition: 0.12, endPosition: 0.95, startStrength: 0.04, endStrength: 0.34)
        case .brakeComfort:
            trigger.setModeSlopeFeedback(startPosition: 0.08, endPosition: 0.92, startStrength: 0.06, endStrength: 0.48)
        case .brakeFirm:
            trigger.setModeSlopeFeedback(startPosition: 0.08, endPosition: 0.90, startStrength: 0.10, endStrength: 0.68)
        case .absPulse:
            trigger.setModeVibrationWithStartPosition(0.62, amplitude: 0.5, frequency: 0.82)
        case .platformerEndStop:
            trigger.setModeFeedbackWithStartPosition(0.78, resistiveStrength: 0.22)
        case .cinematic:
            trigger.setModeSlopeFeedback(startPosition: 0.15, endPosition: 0.95, startStrength: 0.03, endStrength: 0.18)
        case .vibration:
            trigger.setModeVibrationWithStartPosition(0.2, amplitude: 0.6, frequency: 0.55)
        case .custom:
            applyCustomAdaptiveTrigger(trigger, parameters: custom)
        }
    }

    private func applyCustomAdaptiveTrigger(
        _ trigger: GCDualSenseAdaptiveTrigger,
        parameters: AdaptiveTriggerCustomParameters
    ) {
        let value = parameters.clamped
        switch value.mode {
        case .off:
            trigger.setModeOff()
        case .feedback:
            trigger.setModeFeedbackWithStartPosition(value.startPosition, resistiveStrength: value.startStrength)
        case .weapon:
            trigger.setModeWeaponWithStartPosition(
                value.startPosition,
                endPosition: value.endPosition,
                resistiveStrength: value.startStrength
            )
        case .vibration:
            trigger.setModeVibrationWithStartPosition(
                value.startPosition,
                amplitude: value.amplitude,
                frequency: value.frequency
            )
        case .slopeFeedback:
            if #available(macOS 12.3, iOS 15.4, tvOS 15.4, visionOS 1.0, *) {
                trigger.setModeSlopeFeedback(
                    startPosition: value.startPosition,
                    endPosition: value.endPosition,
                    startStrength: value.startStrength,
                    endStrength: value.endStrength
                )
            } else {
                trigger.setModeFeedbackWithStartPosition(value.startPosition, resistiveStrength: value.startStrength)
            }
        }
    }

    // MARK: - Haptics

    func playTestPulse(
        intensity: Float? = nil,
        sharpness: Float? = nil,
        duration: TimeInterval = 0.12,
        locality: HapticLocality? = nil
    ) {
        guard settings.haptics.mode != .off else { return }
        let target = locality ?? settings.haptics.preferredLocality
        guard let engine = engine(for: target) else {
            lastError = "The selected controller haptic locality is unavailable."
            return
        }
        let requestedIntensity = intensity ?? 0.7
        let multiplier = settings.haptics.mode == .amplified
            ? max(settings.haptics.intensityMultiplier, 1)
            : min(settings.haptics.intensityMultiplier, 1)
        let finalIntensity = min(max(requestedIntensity * multiplier, 0), 1)
        let finalSharpness = min(max(sharpness ?? settings.haptics.sharpness, 0), 1)
        let finalDuration = min(max(duration, 0.01), 2)

        do {
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: finalIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: finalSharpness),
            ]
            let event = CHHapticEvent(
                eventType: finalDuration <= 0.08 ? .hapticTransient : .hapticContinuous,
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
        touchRuntime = TouchRuntimeState()
        guard settings.touchpad.isEnabled else { return }

        let touchpads = controller.physicalInputProfile.allTouchpads
        if !touchpads.isEmpty {
            for (index, touchpad) in touchpads.prefix(2).enumerated() {
                configureTouchpad(touchpad, index: index)
            }
        } else if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            // Some macOS/connection combinations expose DualSense coordinates
            // but not GCControllerTouchpad down/up events. Fall back to motion
            // of the two contact pads and use touchpad click as an explicit tap.
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
                touchRuntime.startPosition = position
            }
            touchRuntime.primaryActive = true
            touchRuntime.currentPosition = position
        } else {
            touchRuntime.secondaryActive = true
            touchRuntime.secondFingerSeen = true
        }
        // Direction-pad fallback has no true up event; expire an inferred
        // contact shortly after coordinate changes stop.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            await MainActor.run {
                guard let self else { return }
                if index == 0, self.touchRuntime.primaryActive {
                    self.finishPrimaryTouch(at: ProcessInfo.processInfo.systemUptime, endPosition: self.touchRuntime.currentPosition)
                    self.touchRuntime.primaryActive = false
                } else if index == 1 {
                    self.touchRuntime.secondaryActive = false
                }
                self.publishCurrentSnapshot()
            }
        }
        publishCurrentSnapshot()
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
                touchRuntime.startPosition = position
                touchRuntime.currentPosition = position
                touchRuntime.primaryActive = true
                touchRuntime.secondFingerSeen = touchRuntime.secondaryActive
            case .moving:
                touchRuntime.primaryActive = true
                touchRuntime.currentPosition = position
            case .up:
                touchRuntime.currentPosition = position
                finishPrimaryTouch(at: now, endPosition: position)
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
        publishCurrentSnapshot()
    }

    private func finishPrimaryTouch(at timestamp: TimeInterval, endPosition: ControllerVector2) {
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
        guard let mapping = settings.touchpad.mappings.first(where: { $0.isEnabled && $0.gesture == gesture }) else { return }
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
        case .macro(let id):
            runMacro(id: id)
        default:
            onShortcutAction?(action)
        }
    }

    func runMacro(id: UUID) {
        guard let macro = settings.macros.first(where: { $0.id == id }) else { return }
        do {
            try macro.validate()
        } catch {
            lastError = error.localizedDescription
            return
        }
        macroTasks[id]?.cancel()
        macroTasks[id] = Task { [weak self] in
            for step in macro.steps {
                guard !Task.isCancelled else { return }
                if step.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delayMilliseconds) * 1_000_000)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.executeMacroStep(step) }
            }
            await MainActor.run { self?.macroTasks[id] = nil }
        }
    }

    func cancelMacro(id: UUID) {
        macroTasks[id]?.cancel()
        macroTasks[id] = nil
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
            dispatch(action: action)
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
        light.color = GCColor(
            red: color.red * brightness,
            green: color.green * brightness,
            blue: color.blue * brightness
        )
    }

    // MARK: - Framework adapters

    private func registerForControllerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let connected = note.object as? GCController else { return }
            MainActor.assumeIsolated {
                if self?.controller == nil { self?.attach(to: connected) }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let disconnected = note.object as? GCController else { return }
            MainActor.assumeIsolated {
                guard self?.controller === disconnected else { return }
                self?.detach()
                self?.attachFirstAvailableController()
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] note in
            guard let current = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(to: current) }
        })
    }

    private func configureInputHandlers(for controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publishCurrentSnapshot() }
        }
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
        let motion = controller.motion
        let dualSense = gamepad as? GCDualSenseGamepad
        let hapticLocalities = HapticLocality.allCases.filter { locality in
            guard let haptics = controller.haptics else { return false }
            return supports(locality, on: haptics)
        }
        return ControllerCapabilities(
            hasExtendedGamepad: gamepad != nil,
            hasMotion: motion != nil,
            hasAttitude: motion?.hasAttitude ?? false,
            hasRotationRate: motion?.hasRotationRate ?? false,
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
