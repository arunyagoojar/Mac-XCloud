//
//  ControllerSettingsPages.swift
//  Mac XCloud
//
//  Settings pages for everything you hold: the controller itself, motion
//  controls, the touchpad, keyboard & mouse, shortcuts and game profiles.
//  Each page leads with the one or two choices most people need, shows a
//  live preview where it helps, and keeps fine-tuning under "Advanced".
//

import SwiftUI

// MARK: - Shared bindings

@MainActor
private extension ControllerFeatureService {
    func enhancement<T>(_ key: WritableKeyPath<ControllerEnhancements, T>) -> Binding<T> {
        Binding(get: { self.enhancements[keyPath: key] }, set: { value in
            self.updateSettings {
                var copy = $0.enhancements ?? ControllerEnhancements()
                copy[keyPath: key] = value
                $0.enhancements = copy
            }
        })
    }

    /// Edits an optional Float field through a Double binding showing the
    /// effective (default-filled) value.
    func tuning(_ key: WritableKeyPath<ControllerEnhancements, Float?>, effective: @escaping (ControllerEnhancements) -> Float) -> Binding<Double> {
        Binding(get: { Double(effective(self.enhancements)) }, set: { value in
            self.updateSettings {
                var copy = $0.enhancements ?? ControllerEnhancements()
                copy[keyPath: key] = Float(value)
                $0.enhancements = copy
            }
        })
    }

    func flag(_ key: WritableKeyPath<ControllerEnhancements, Bool?>, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { self.enhancements[keyPath: key] ?? fallback }, set: { value in
            self.updateSettings {
                var copy = $0.enhancements ?? ControllerEnhancements()
                copy[keyPath: key] = value
                $0.enhancements = copy
            }
        })
    }
}

private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

// MARK: - Controller

struct ControllerSettingsPage: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var service: ControllerFeatureService
    @ObservedObject var model: SettingsModel
    @State private var showTriggerStops = false
    @State private var showVibrationDetails = false
    @State private var showCalibration = false
    @State private var showTest = false

    var body: some View {
        SettingsPage("Controller") {
            statusCard
            if service.descriptor != nil {
                if service.capabilities.hasLight {
                    SettingsGroup("Light Bar") {
                        SettingsRow("Color") { LightBarControl(model: model) }
                    }
                }
                if service.capabilities.hasAdaptiveTriggers { triggers }
                vibration
                sticks
            }
        }
    }

    private var statusCard: some View {
        SettingsGroup {
            if let descriptor = service.descriptor {
                HStack(spacing: 14) {
                    SettingsIcon(symbol: "gamecontroller.fill", tint: .indigo, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(descriptor.vendorName).font(.system(size: 15, weight: .semibold))
                        Text(capabilitySummary).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    BatteryBadge(input: browser.controllerInput)
                }
                .padding(.vertical, 12)
            } else {
                EmptyStateView(icon: "gamecontroller", title: "No Controller Connected",
                               message: "Connect a DualSense, Xbox or other controller with a cable or Bluetooth. Its settings appear here.")
            }
        }
    }

    private var capabilitySummary: String {
        let c = service.capabilities
        var parts: [String] = []
        if c.hasAdaptiveTriggers { parts.append("Adaptive triggers") }
        if c.hasHaptics { parts.append("Haptics") }
        if service.gyroAvailable { parts.append("Motion sensors") }
        if c.hasTouchpad { parts.append("Touchpad") }
        return parts.isEmpty ? "Standard controller" : parts.joined(separator: " · ")
    }

    // MARK: Triggers

    private var triggers: some View {
        SettingsGroup("Adaptive Triggers", footer: "Resistance effects play locally on the DualSense, independent of the game.") {
            SettingsRow("Left trigger") { AdaptiveTriggerPresetSelector(title: "Left trigger", side: .left, service: service) }
            Divider()
            SettingsRow("Right trigger") { AdaptiveTriggerPresetSelector(title: "Right trigger", side: .right, service: service) }
            Divider()
            SettingsDisclosure("Trigger Stops", isExpanded: $showTriggerStops) {
                SettingsToggleRow(label: "Left trigger stop", isOn: service.enhancement(\.leftLock))
                Divider()
                SettingsToggleRow(label: "Right trigger stop", isOn: service.enhancement(\.rightLock))
                Divider()
                SettingsSliderRow(label: "Stop position", note: "A firm wall here makes short, fast trigger pulls easy.",
                                  value: Binding(get: { Double(service.enhancements.lockPosition) },
                                                 set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.lockPosition = Float(v); $0.enhancements = e } }),
                                  range: 0.05...0.95, minimumLabel: "Short", maximumLabel: "Deep")
            }
        }
    }

    // MARK: Vibration

    private var vibration: some View {
        SettingsGroup("Vibration") {
            SettingsToggleRow(label: "Vibration", isOn: Binding(
                get: { service.settings.haptics.mode != .off },
                set: { on in service.updateSettings { $0.haptics.mode = on ? .standard : .off } }))
            if service.settings.haptics.mode != .off {
                Divider()
                SettingsSliderRow(label: "Strength", value: Binding(
                    get: { Double(service.globalRumbleGain) }, set: { service.globalRumbleGain = Float($0) }),
                    range: 0.2...2, minimumLabel: "Light", maximumLabel: "Strong",
                    valueText: { percent($0) })
                if service.capabilities.hasAdaptiveTriggers {
                    Divider()
                    SettingsToggleRow(label: "Trigger rumble",
                                      note: "Plays the game's trigger vibration through the adaptive triggers.",
                                      isOn: service.enhancement(\.gameDrivenTriggers))
                }
                Divider()
                SettingsToggleRow(label: "Feel the game's sound",
                                  note: "Deep sounds like engines, impacts and explosions also play as vibration. Saved per game.",
                                  isOn: service.flag(\.audioHaptics))
                if service.enhancements.audioHaptics == true {
                    Divider()
                    SettingsSliderRow(label: "Sound vibration", value: service.tuning(\.audioHapticsStrength) { $0.effectiveAudioHapticsStrength },
                                      range: 0.1...1, minimumLabel: "Subtle", maximumLabel: "Strong")
                }
                Divider()
                SettingsDisclosure("Fine-Tune", isExpanded: $showVibrationDetails) {
                    SettingsSliderRow(label: "Response", note: "Lower makes faint rumble easier to feel.",
                                      value: Binding(get: { Double(service.enhancements.rumbleExponent) },
                                                     set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.rumbleExponent = Float(v); $0.enhancements = e } }),
                                      range: 0.4...2.5, minimumLabel: "Fuller", maximumLabel: "Punchier")
                    Divider()
                    SettingsSliderRow(label: "Texture", value: Binding(
                        get: { Double(service.settings.haptics.sharpness) },
                        set: { v in service.updateSettings { $0.haptics.sharpness = Float(v) } }),
                        range: 0...1, minimumLabel: "Deep", maximumLabel: "Crisp")
                    Divider()
                    SettingsSliderRow(label: "This game's strength", note: "Saved with the game profile, on top of Strength.",
                                      value: Binding(get: { Double(service.enhancements.rumbleGain) },
                                                     set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.rumbleGain = Float(v); $0.enhancements = e } }),
                                      range: 0...2, valueText: { percent($0) })
                    Divider()
                    SettingsRow("Try it") {
                        HStack(spacing: 6) {
                            Button("Rumble", action: service.testStreamRumble)
                            Button("Tap") { service.playTestPulse(intensity: 0.8, sharpness: 0.8, duration: 0.05) }
                            Button("Stop", action: service.stopHaptics)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Sticks

    private var sticks: some View {
        SettingsGroup("Sticks & Triggers") {
            SettingsToggleRow(label: "Custom stick response",
                              note: "Sends this Mac's calibration and response curves to the game instead of the raw sticks.",
                              isOn: Binding(get: { service.applyCalibrationToStream }, set: { service.applyCalibrationToStream = $0 }))
            if service.applyCalibrationToStream {
                Divider()
                stickCurve("Left stick", left: true)
                Divider()
                stickCurve("Right stick", left: false)
            }
            Divider()
            SettingsDisclosure("Calibrate", isExpanded: $showCalibration) {
                CalibrationPanel(service: service)
            }
            Divider()
            SettingsDisclosure("Test Controller", isExpanded: $showTest) {
                ControllerTestPanel(service: service)
            }
        }
    }

    private func stickCurve(_ title: String, left: Bool) -> some View {
        SettingsRow(title) {
            Picker(title, selection: Binding<ResponseCurve>(
                get: { left ? service.settings.calibration.leftStick.responseCurve : service.settings.calibration.rightStick.responseCurve },
                set: { curve in service.updateSettings {
                    if left { $0.calibration.leftStick.responseCurve = curve } else { $0.calibration.rightStick.responseCurve = curve }
                } })) {
                Text("Linear").tag(ResponseCurve.linear)
                Text("Precise center").tag(ResponseCurve.exponential(exponent: 2))
                Text("Quick response").tag(ResponseCurve.exponential(exponent: 0.5))
                Text("Smooth S-curve").tag(ResponseCurve.sCurve(strength: 1))
            }
            .settingsPicker()
        }
    }
}

private struct BatteryBadge: View {
    @ObservedObject var input: ControllerInputService

    var body: some View {
        if let level = input.batteryPercent {
            let charging = input.batteryStateText == "Charging"
            HStack(spacing: 5) {
                Image(systemName: symbol(level, charging: charging))
                    .foregroundStyle(level <= 20 && !charging ? Color.red : Color.secondary)
                Text(input.batteryStateText == "Full" ? "Charged" : "\(level)%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
        }
    }

    private func symbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Light bar color: a named preset or any custom color.
struct LightBarControl: View {
    @ObservedObject var model: SettingsModel
    private static let custom = -1

    var body: some View {
        HStack(spacing: 8) {
            if model.ledUsesCustomColor {
                ColorPicker("Custom color", selection: Binding(get: { model.customLEDColor }, set: { model.customLEDColor = $0 }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .help("Choose the light bar color")
            }
            Picker("Light bar color", selection: Binding(
                get: { model.ledUsesCustomColor ? Self.custom : model.ledColorIndex },
                set: { value in
                    if value == Self.custom {
                        model.ledUsesCustomColor = true
                        model.applyLightBar()
                    } else {
                        model.ledColorIndex = value
                    }
                })) {
                ForEach(Array(LEDColor.all.enumerated()), id: \.offset) { index, color in
                    Text(color.label).tag(index)
                }
                Divider()
                Text("Custom").tag(Self.custom)
            }
            .settingsPicker()
        }
    }
}

private struct CalibrationPanel: View {
    @ObservedObject var service: ControllerFeatureService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let progress = service.calibrationProgress {
                VStack(alignment: .leading, spacing: 8) {
                    Text(instruction(progress.kind)).font(.system(size: 12))
                    ProgressView(value: progress.progress)
                    HStack { Spacer(); Button("Cancel", action: service.cancelCalibration).controlSize(.small) }
                }
                .padding(.vertical, 10)
            } else {
                SettingsRow("Stick drift", note: "Leave both sticks untouched.") {
                    Button("Calibrate") { service.beginCalibration(.stickCenters, duration: 3) }.controlSize(.small)
                }
                Divider()
                SettingsRow("Stick range", note: "Rotate both sticks around their edges.") {
                    Button("Calibrate") { service.beginCalibration(.stickFullRange, duration: 5) }.controlSize(.small)
                }
                Divider()
                SettingsRow("Trigger range", note: "Press both triggers all the way, then release.") {
                    Button("Calibrate") { service.beginCalibration(.triggers, duration: 4) }.controlSize(.small)
                }
                Divider()
                SettingsSliderRow(label: "Left trigger dead zone", value: deadzone(left: true), range: 0...0.5, valueText: { percent($0) })
                Divider()
                SettingsSliderRow(label: "Right trigger dead zone", value: deadzone(left: false), range: 0...0.5, valueText: { percent($0) })
                Divider()
                SettingsRow("Restore factory calibration") {
                    Button("Reset") { service.updateSettings { $0.calibration = .default } }.controlSize(.small)
                }
            }
        }
    }

    private func deadzone(left: Bool) -> Binding<Double> {
        Binding(get: { Double(left ? service.settings.calibration.leftTrigger.deadzone : service.settings.calibration.rightTrigger.deadzone) },
                set: { v in service.updateSettings {
                    if left { $0.calibration.leftTrigger.deadzone = Float(v) } else { $0.calibration.rightTrigger.deadzone = Float(v) }
                } })
    }

    private func instruction(_ kind: ControllerCalibrationKind) -> String {
        switch kind {
        case .stickCenters: return "Measuring stick drift — don't touch the sticks…"
        case .stickFullRange: return "Rotate both sticks slowly around their full range…"
        case .triggers: return "Press both triggers fully, then let go…"
        }
    }
}

private struct ControllerTestPanel: View {
    @ObservedObject var service: ControllerFeatureService

    var body: some View {
        let s = service.snapshot
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                VStack(spacing: 6) { StickPreview(value: s.leftStick, size: 84); Text("Left stick").font(.system(size: 11)).foregroundStyle(.secondary) }
                VStack(spacing: 6) { StickPreview(value: s.rightStick, size: 84); Text("Right stick").font(.system(size: 11)).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 10) {
                    trigger("LT", s.leftTrigger)
                    trigger("RT", s.rightTrigger)
                }
            }
            HStack(spacing: 6) {
                ForEach(buttons(s), id: \.0) { name, pressed in
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 30).padding(.vertical, 4).padding(.horizontal, 4)
                        .background(pressed ? Color.accentColor : SettingsPalette.well, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(pressed ? Color.white : Color.primary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func trigger(_ name: String, _ value: Float) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            ProgressView(value: Double(value)).frame(width: 110)
        }
    }

    private func buttons(_ s: ControllerInputSnapshot) -> [(String, Bool)] {
        let b = s.buttons
        return [("A", b.a.isPressed), ("B", b.b.isPressed), ("X", b.x.isPressed), ("Y", b.y.isPressed),
                ("LB", b.leftShoulder.isPressed), ("RB", b.rightShoulder.isPressed),
                ("L3", b.leftStick.isPressed), ("R3", b.rightStick.isPressed),
                ("↑", b.dpadUp.isPressed), ("↓", b.dpadDown.isPressed), ("←", b.dpadLeft.isPressed), ("→", b.dpadRight.isPressed),
                ("Menu", b.menu.isPressed), ("View", b.options.isPressed)]
    }
}

// MARK: - Motion

struct MotionSettingsPage: View {
    @ObservedObject var service: ControllerFeatureService
    @State private var showAdvanced = false

    private var mode: Binding<ControllerGyroMode> {
        Binding(get: { service.enhancements.gyroMode }, set: { selected in
            service.updateSettings {
                var e = $0.enhancements ?? ControllerEnhancements()
                e.setGyroMode(selected)
                $0.enhancements = e
            }
        })
    }

    var body: some View {
        SettingsPage("Motion Controls", subtitle: "Use the controller's motion sensors to aim or steer.") {
            SettingsGroup(footer: modeFooter) {
                SettingsRow("Use motion for") {
                    Picker("Use motion for", selection: mode) {
                        Text("Off").tag(ControllerGyroMode.off)
                        Text("Aiming").tag(ControllerGyroMode.aiming)
                        Text("Steering").tag(ControllerGyroMode.steering)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if service.enhancements.gyroEnabled, service.motionReportRateHz > 0 {
                SettingsGroup(footer: "How often the controller sends motion data; higher is smoother. In full screen, macOS Game Mode can raise it.") {
                    SettingsRow("Motion data") {
                        Text("\(Int(service.motionReportRateHz.rounded())) times a second")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if service.descriptor != nil && !service.gyroAvailable {
                SettingsWarning(text: "This controller has no motion sensors. Motion controls need a DualSense, DualShock 4 or Switch Pro Controller.")
            } else if service.enhancements.gyroEnabled && service.descriptor != nil && service.motionReportRateHz == 0 && service.motionStatus.hasPrefix("Waiting") {
                SettingsWarning(text: "No motion data yet. Move the controller; if nothing changes, reconnect it.", symbol: "info.circle.fill", tint: .blue)
            }
            switch service.enhancements.gyroMode {
            case .off: EmptyView()
            case .aiming: aiming
            case .steering: steering
            }
        }
    }

    private var modeFooter: String {
        switch service.enhancements.gyroMode {
        case .off: return "Choose how motion should help: aiming in shooters or steering in racing games."
        case .aiming: return "Turn the controller to move the camera, like aiming with a mouse. The right stick still works alongside it."
        case .steering: return "Hold the controller like a steering wheel and turn it. Steering goes to the left stick, so it works in every racing game."
        }
    }

    // MARK: Aiming

    private var aiming: some View {
        Group {
            SettingsGroup("Aiming", footer: aimFooter) {
                SettingsRow("Aim with") {
                    Picker("Aim with", selection: Binding(
                        get: { service.enhancements.effectiveGyroOutput },
                        set: { value in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.gyroOutput = value; $0.enhancements = e } })) {
                        ForEach(GyroAimOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                SettingsRow("Active") {
                    Picker("Active", selection: Binding(
                        get: { service.enhancements.effectiveGyroActivation },
                        set: { value in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.gyroActivation = value; $0.enhancements = e } })) {
                        ForEach(GyroAimActivation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .settingsPicker()
                }
                Divider()
                if service.enhancements.effectiveGyroOutput == .mouse {
                    SettingsSliderRow(label: "Mouse speed", note: "Pair it with the game's own mouse sensitivity.",
                                      value: service.tuning(\.gyroMouseSensitivity) { $0.effectiveGyroMouseSensitivity },
                                      range: 2...40, minimumLabel: "Slow", maximumLabel: "Fast")
                    Divider()
                }
                SettingsSliderRow(label: service.enhancements.effectiveGyroOutput == .mouse ? "Stick sensitivity" : "Sensitivity",
                                  note: service.enhancements.effectiveGyroOutput == .mouse ? "In games without mouse support." : nil,
                                  value: Binding(
                    get: { Double(service.enhancements.effectiveGyroSensitivity) },
                    set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.gyroSensitivity = Float(v); $0.enhancements = e } }),
                    range: 0.25...3, minimumLabel: "Slow", maximumLabel: "Fast")
                Divider()
                SettingsRow("Live output", note: "Move the controller to see the right stick respond.") {
                    StickPreview(value: service.liveAimOutput, size: 52)
                }
                Divider()
                GyroCalibrationRow(service: service)
            }
            pauseButton
            SettingsGroup(footer: "If the slowest movements don't move the camera, raise Game dead zone until they just do.") {
                SettingsDisclosure("Advanced", isExpanded: $showAdvanced) {
                    SettingsSliderRow(label: "Smoothing", note: "Steadies slow aiming; quick turns are never delayed.",
                                      value: service.tuning(\.gyroSmoothing) { $0.effectiveGyroSmoothing },
                                      range: 0...1, minimumLabel: "Off", maximumLabel: "Heavy")
                    Divider()
                    SettingsSliderRow(label: "Acceleration", note: "Slow movements stay precise; quick turns go further.",
                                      value: service.tuning(\.gyroAcceleration) { $0.effectiveGyroAcceleration },
                                      range: 0...1, minimumLabel: "None", maximumLabel: "High")
                    Divider()
                    SettingsSliderRow(label: "Game dead zone", note: "Compensates for the game's own right-stick dead zone.",
                                      value: service.tuning(\.gyroOutputFloor) { $0.effectiveAimDeadzoneCompensation },
                                      range: 0...0.35, valueText: { percent($0) })
                    Divider()
                    SettingsSliderRow(label: "Steadiness", note: "How much hand tremor is ignored when you hold still.",
                                      value: service.tuning(\.gyroStillThreshold) { $0.effectiveGyroStillThreshold },
                                      range: 0.3...4, minimumLabel: "Less", maximumLabel: "More")
                    Divider()
                    SettingsSliderRow(label: "Response curve", note: "Match the game's stick response; most games feel best near Linear.",
                                      value: service.tuning(\.gyroResponseExponent) { $0.effectiveGyroExponent },
                                      range: 0.5...2, minimumLabel: "Quick", maximumLabel: "Precise")
                    Divider()
                    SettingsToggleRow(label: "Invert horizontal", isOn: service.flag(\.gyroInvertX))
                    Divider()
                    SettingsToggleRow(label: "Invert vertical", isOn: service.enhancement(\.gyroInvertY))
                }
            }
        }
    }

    private var aimFooter: String? {
        guard service.enhancements.effectiveGyroOutput == .mouse else { return nil }
        return service.gyroMouseAvailable
            ? "This game takes a mouse: aiming follows the controller one to one, with no stick dead zone. The game may show keyboard prompts and turn off aim assist."
            : "Games with keyboard & mouse support aim with the mouse, one to one. Other games use the right stick."
    }

    // MARK: Pause button

    private var pauseButton: some View {
        SettingsGroup("Pause Button", footer: pauseFooter) {
            SettingsRow("Pause with") {
                Picker("Pause with", selection: Binding<GyroPauseButton?>(
                    get: { service.enhancements.gyroPauseButton },
                    set: { value in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.gyroPauseButton = value; $0.enhancements = e } })) {
                    Text("None").tag(GyroPauseButton?.none)
                    Divider()
                    ForEach(GyroPauseButton.allCases, id: \.self) { Text($0.title).tag(GyroPauseButton?.some($0)) }
                }
                .settingsPicker()
            }
            if let button = service.enhancements.gyroPauseButton {
                Divider()
                SettingsRow("Pressing it") {
                    Picker("Pressing it", selection: Binding(
                        get: { service.enhancements.gyroPauseToggles ?? false },
                        set: { value in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.gyroPauseToggles = value; $0.enhancements = e } })) {
                        Text(button == .touchpadTouch ? "Pauses while touching" : "Pauses while held").tag(false)
                        Text("Turns gyro off or on").tag(true)
                    }
                    .settingsPicker()
                }
                if button.gameButtonIndex != nil {
                    Divider()
                    SettingsToggleRow(label: "Only pause gyro", note: "The button no longer does anything in the game.",
                                      isOn: service.flag(\.gyroPauseExclusive))
                }
            }
        }
    }

    private var pauseFooter: String {
        guard let button = service.enhancements.gyroPauseButton else {
            return "Pause gyro aiming to reposition your hands without moving the camera, like lifting a mouse off the desk."
        }
        if button == .touchpadTouch {
            return "Touches never reach the game, so resting a thumb on the touchpad pauses gyro without side effects."
        }
        if button == .touchpadPress {
            return "A game that uses the touchpad press still receives it."
        }
        return service.enhancements.gyroPauseExclusive == true
            ? "The button is used only to pause gyro aiming."
            : "The button still works in the game as well."
    }

    // MARK: Steering

    private var steering: some View {
        Group {
            SettingsGroup("Steering") {
                SteeringPreview(angle: service.liveSteeringAngle, output: service.liveSteeringOutput,
                                fullLock: Double(service.enhancements.effectiveSteeringAngleDegrees))
                Divider()
                SettingsSliderRow(label: "Steering range", note: "How far you turn the controller for full lock.",
                                  value: service.tuning(\.steeringAngleDegrees) { $0.effectiveSteeringAngleDegrees },
                                  range: 15...90, valueText: { "\(Int($0.rounded()))°" })
                Divider()
                SettingsSliderRow(label: "Center response", note: "Quick suits arcade racers; gentle suits simulation.",
                                  value: Binding(
                                    get: { Self.centerResponse(fromExponent: Double(service.enhancements.effectiveSteeringExponent)) },
                                    set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.steeringExponent = Float(Self.exponent(fromCenterResponse: v)); $0.enhancements = e } }),
                                  range: 0...1, minimumLabel: "Gentle", maximumLabel: "Quick")
                Divider()
                SettingsRow("Straight ahead", note: service.steeringCenterDegrees == 0
                            ? "A level controller drives straight. Recenter to use your natural hold instead."
                            : String(format: "Your hold, %.1f° %@ of level.", abs(service.steeringCenterDegrees),
                                     service.steeringCenterDegrees > 0 ? "right" : "left")) {
                    HStack(spacing: 6) {
                        if service.steeringCenterDegrees != 0 {
                            Button("Reset", action: service.resetSteeringCenter)
                                .help("Drive straight with the controller level")
                        }
                        Button("Recenter", action: service.recenterSteering)
                            .disabled(!service.gyroAvailable)
                    }
                    .controlSize(.small)
                }
            }
            SettingsGroup(footer: "Set the game's own steering dead zone to 0 where possible. If small turns still feel dead around center, raise Center boost.") {
                SettingsDisclosure("Advanced", isExpanded: $showAdvanced) {
                    SettingsSliderRow(label: "Center boost", note: "Makes the first few degrees count more, smoothly. Also covers a game's own steering dead zone.",
                                      value: service.tuning(\.steeringAntiDeadzone) { $0.effectiveSteeringAntiDeadzone },
                                      range: 0...0.35, valueText: { percent($0) })
                    Divider()
                    SettingsSliderRow(label: "Smoothing", note: "Fast turns are never delayed.",
                                      value: service.tuning(\.steeringSmoothing) { $0.effectiveSteeringSmoothing },
                                      range: 0...1, minimumLabel: "Off", maximumLabel: "Heavy")
                    Divider()
                    SettingsSliderRow(label: "Center dead band", note: "A small still zone around straight ahead.",
                                      value: service.tuning(\.steeringPhysicalDeadzone) { $0.effectiveSteeringPhysicalDeadzoneDegrees },
                                      range: 0...3, valueText: { String(format: "%.1f°", $0) })
                    Divider()
                    SettingsSliderRow(label: "Maximum steering",
                                      value: service.tuning(\.steeringMaximum) { $0.effectiveSteeringMaximum },
                                      range: 0.2...1, valueText: { percent($0) })
                    Divider()
                    SettingsToggleRow(label: "Reverse direction", isOn: service.flag(\.steeringInverted))
                    Divider()
                    SettingsToggleRow(label: "Steady during rumble",
                                      note: "Keeps vibration and adaptive-trigger buzz from moving the wheel.",
                                      isOn: service.flag(\.steeringRumbleGuard, default: true))
                }
            }
        }
    }

    /// Slider 0 (gentle, exponent 1.6) … 1 (quick, exponent 0.5), with
    /// linear (1.0) a little right of the middle.
    static func centerResponse(fromExponent e: Double) -> Double { min(max((1.6 - e) / 1.1, 0), 1) }
    static func exponent(fromCenterResponse value: Double) -> Double {
        let e = 1.6 - 1.1 * min(max(value, 0), 1)
        return abs(e - 1) < 0.04 ? 1 : e
    }

}

private struct GyroCalibrationRow: View {
    @ObservedObject var service: ControllerFeatureService

    var body: some View {
        SettingsRow("Calibrate gyro", note: note) {
            if case .measuring = service.gyroCalibration {
                ProgressView().controlSize(.small)
            } else {
                Button("Calibrate", action: service.calibrateGyro)
                    .controlSize(.small)
                    .disabled(!service.gyroAvailable)
            }
        }
    }

    private var note: String {
        switch service.gyroCalibration {
        case .idle: return idleNote
        case .measuring: return "Keep the controller still…"
        case .succeeded: return "Calibrated."
        case .failedMoved: return "The controller moved. Put it on a flat surface and try again."
        }
    }

    /// Calibration happens by itself whenever the controller rests on a
    /// table; say how the current measurement was made.
    private var idleNote: String {
        switch service.gyroBiasSource {
        case .calibrated, .rested:
            if let date = service.gyroBiasMeasuredAt {
                return "Measured \(Self.relative.localizedString(for: date, relativeTo: Date())). Updates whenever the controller rests on a table."
            }
            return "Measured. Updates whenever the controller rests on a table."
        case .held:
            return "Estimated while you play. Put the controller on a table for a few seconds for an exact measurement."
        case .none:
            return "Put the controller on a table for a few seconds; it calibrates by itself."
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// A miniature wheel turning with the controller, plus the stick output.
private struct SteeringPreview: View {
    let angle: Double
    let output: Double
    let fullLock: Double

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: SettingsSymbol.available("steeringwheel"))
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(abs(output) > 0.004 ? Color.accentColor : Color.secondary)
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(min(max(angle, -180), 180)))
                .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.9), value: angle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "%+.1f° · %d%% %@", angle, Int((abs(output) * 100).rounded()).clamped(0, 100),
                            output > 0.004 ? "right" : output < -0.004 ? "left" : ""))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let half = geometry.size.width / 2
                    ZStack(alignment: .leading) {
                        Capsule().fill(SettingsPalette.well)
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1).offset(x: half)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(abs(output) * half, 2))
                            .offset(x: output >= 0 ? half : half - abs(output) * half)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steering")
        .accessibilityValue(String(format: "%.0f degrees, %.0f percent", angle, output * 100))
    }
}

private extension Int {
    func clamped(_ lower: Int, _ upper: Int) -> Int { Swift.min(Swift.max(self, lower), upper) }
}

// MARK: - Touchpad

struct TouchpadSettingsPage: View {
    @ObservedObject var service: ControllerFeatureService
    @State private var showAdvanced = false

    var body: some View {
        SettingsPage("Touchpad", subtitle: "The DualSense touchpad can move the camera like a trackpad, or run shortcuts with gestures.") {
            if service.descriptor != nil && !service.capabilities.hasTouchpad {
                SettingsWarning(text: "This controller has no touchpad.", symbol: "info.circle.fill", tint: .blue)
            }
            SettingsGroup {
                SettingsRow("Use the touchpad for") {
                    Picker("Use the touchpad for", selection: service.enhancement(\.touchpadAimEnabled)) {
                        Text("Gestures").tag(false)
                        Text("Camera").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if service.enhancements.touchpadAimEnabled { camera } else { gestures }
        }
    }

    private var camera: some View {
        Group {
            SettingsGroup("Camera", footer: "Slide a finger to look around. Faster swipes turn further; the camera stops when your finger stops or lifts.") {
                SettingsSliderRow(label: "Sensitivity",
                                  value: service.tuning(\.touchpadSensitivity) { $0.effectiveTouchpadSensitivity },
                                  range: 0.1...1.5, minimumLabel: "Slow", maximumLabel: "Fast")
                Divider()
                SettingsSliderRow(label: "Acceleration", note: "How much faster quick swipes turn.",
                                  value: service.tuning(\.touchpadAcceleration) { $0.effectiveTouchpadAcceleration },
                                  range: 0...1, minimumLabel: "None", maximumLabel: "High")
                Divider()
                SettingsRow("Live output", note: service.touchDiagnostics) {
                    StickPreview(value: service.liveTouchOutput, size: 52)
                }
            }
            SettingsGroup {
                SettingsDisclosure("Advanced", isExpanded: $showAdvanced) {
                    SettingsSliderRow(label: "Smoothing", note: "Steadies slow strokes; fast swipes are never delayed.",
                                      value: service.tuning(\.touchpadFiltering) { $0.effectiveTouchpadSmoothing },
                                      range: 0...1, minimumLabel: "Off", maximumLabel: "Heavy")
                    Divider()
                    SettingsSliderRow(label: "Response curve",
                                      value: service.tuning(\.touchpadResponseExponent) { $0.effectiveTouchpadExponent },
                                      range: 0.5...2, minimumLabel: "Quick", maximumLabel: "Precise")
                    Divider()
                    SettingsSliderRow(label: "Game dead zone", note: "Shared with gyro aiming.",
                                      value: service.tuning(\.gyroOutputFloor) { $0.effectiveAimDeadzoneCompensation },
                                      range: 0...0.35, valueText: { percent($0) })
                    Divider()
                    SettingsToggleRow(label: "Invert vertical", isOn: service.flag(\.touchpadInvertY))
                    Divider()
                    SettingsRow("Stick", note: service.enhancements.gyroMode == .steering ? "Steering uses the left stick, so the touchpad uses the right." : nil) {
                        Picker("Stick", selection: Binding<ControllerAimStick>(
                            get: { service.enhancements.touchpadStick ?? .right },
                            set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.touchpadStick = v; $0.enhancements = e } })) {
                            ForEach(ControllerAimStick.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .settingsPicker()
                        .disabled(service.enhancements.gyroMode == .steering)
                    }
                }
            }
        }
    }

    private var gestures: some View {
        SettingsGroup("Gestures", footer: "Gestures run in Mac Xcloud. Pressing the touchpad still works as the game's View button.") {
            SettingsToggleRow(label: "Touchpad gestures", isOn: Binding(
                get: { service.settings.touchpad.isEnabled },
                set: { v in service.updateSettings { $0.touchpad.isEnabled = v } }))
            if service.settings.touchpad.isEnabled {
                ForEach(TouchpadGesture.allCases, id: \.self) { gesture in
                    Divider()
                    SettingsRow(gesture.title) {
                        Picker(gesture.title, selection: action(for: gesture)) {
                            Text("None").tag(ControllerNativeAction.none)
                            Text("Open Settings").tag(ControllerNativeAction.toggleSettings)
                            Text("Full Screen").tag(ControllerNativeAction.toggleFullscreen)
                            Text("Performance Overlay").tag(ControllerNativeAction.toggleStats)
                            Text("Screenshot").tag(ControllerNativeAction.screenshot)
                            Text("Mute").tag(ControllerNativeAction.mute)
                            ForEach(service.settings.macros) { macro in
                                Text("Macro: \(macro.name)").tag(ControllerNativeAction.macro(id: macro.id))
                            }
                        }
                        .settingsPicker()
                    }
                }
            }
        }
    }

    private func action(for gesture: TouchpadGesture) -> Binding<ControllerNativeAction> {
        Binding(
            get: { service.settings.touchpad.mappings.first(where: { $0.gesture == gesture && $0.isEnabled })?.action ?? .none },
            set: { action in
                service.updateSettings { settings in
                    settings.touchpad.mappings.removeAll { $0.gesture == gesture }
                    if action != .none { settings.touchpad.mappings.append(TouchpadActionMapping(gesture: gesture, action: action)) }
                }
            })
    }
}

extension TouchpadGesture {
    var title: String {
        switch self {
        case .tap: return "Tap"
        case .doubleTap: return "Double-tap"
        case .longPress: return "Touch and hold"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .twoFingerTap: return "Two-finger tap"
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var service: ControllerFeatureService
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage("Shortcuts & Macros", subtitle: "Controller button combinations that run app actions or short button sequences.") {
            SettingsGroup("Rapid Fire") {
                SettingsToggleRow(label: "Rapid fire on RT", note: "Holding the right trigger fires repeatedly.",
                                  isOn: service.enhancement(\.rapidFireEnabled))
                if service.enhancements.rapidFireEnabled {
                    Divider()
                    SettingsSliderRow(label: "Rate", value: Binding(
                        get: { Double(service.enhancements.rapidFireRate) },
                        set: { v in service.updateSettings { var e = $0.enhancements ?? ControllerEnhancements(); e.rapidFireRate = Float(v); $0.enhancements = e } }),
                        range: 2...15, valueText: { "\(Int($0.rounded()))/s" }, step: 1)
                }
            }
            ShortcutMacroEditor(service: service, installDefaults: installDefaultShortcuts)
            SettingsGroup("Better xCloud Profiles", footer: "Button remapping and Xbox-button shortcuts handled inside the Xbox page.") {
                editorRow(.controllerCustomization, title: "Button remapping")
                Divider()
                editorRow(.controllerShortcuts, title: "Xbox button shortcuts")
            }
        }
    }

    private func editorRow(_ kind: ProfileKind, title: String) -> some View {
        SettingsRow(title, note: kind.subtitle) {
            Button("Edit…") { model.navigate(to: .profileEditor(kind)) }.controlSize(.small)
        }
    }

    private func installDefaultShortcuts() {
        let shortcut = ControllerShortcut(name: "Open Settings", controls: [.leftStickButton, .rightStickButton], activation: .hold(seconds: 0.65), action: .toggleSettings)
        service.updateSettings { settings in
            guard !settings.shortcuts.shortcuts.contains(where: { $0.controls == shortcut.controls && $0.activation == shortcut.activation }) else { return }
            settings.shortcuts.shortcuts.append(shortcut)
        }
    }
}

// MARK: - Profiles

struct ProfilesSettingsPage: View {
    @ObservedObject var store: InputPresetStore
    @State private var suggestSetups = GameSetupPreferences.suggestionsEnabled

    var body: some View {
        SettingsPage("Game Profiles", subtitle: "Controller, motion, trigger and vibration settings are saved per game and switch automatically.") {
            SettingsGroup(footer: "The first time you play a racing game or a shooter, Mac Xcloud offers the controller setup that suits it.") {
                SettingsToggleRow(label: "Suggest a setup for new games", isOn: Binding(
                    get: { suggestSetups },
                    set: { suggestSetups = $0; GameSetupPreferences.suggestionsEnabled = $0 }))
            }
            InputPresetManagerView(store: store)
            ProfileFilesView(store: store)
        }
    }
}
