import SwiftUI

struct ControllerEnhancementsView: View {
    @ObservedObject var service: ControllerFeatureService
    let section: ControllerToolSection
    @State private var showDiagnostics = false
    var body: some View {
        switch section {
        case .triggers: triggers
        case .calibration: calibration
        case .touchpad: touchpadAim
        case .gyro: gyro
        case .steering: steeringPanel
        case .shortcuts: rapidFire
        default: EmptyView()
        }
    }
    private func value<T>(_ key: WritableKeyPath<ControllerEnhancements, T>) -> Binding<T> {
        Binding(get: { service.enhancements[keyPath: key] }, set: { v in service.updateSettings {
            var copy = $0.enhancements ?? ControllerEnhancements()
            copy[keyPath: key] = v; $0.enhancements = copy
        } })
    }
    private func toggle(_ title: String, _ key: WritableKeyPath<ControllerEnhancements, Bool>, note: String? = nil) -> some View {
        SettingsRow(title, note: note) { Toggle(title, isOn: value(key)).labelsHidden().toggleStyle(.switch) }
    }
    private func slider(_ title: String, _ binding: Binding<Float>, range: ClosedRange<Float>) -> some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range).frame(width: 168).accessibilityLabel(title)
                Text(String(format: range.upperBound <= 0.05 ? "%.3f" : "%.2f", binding.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
    private func stickPicker(_ title: String, _ key: WritableKeyPath<ControllerEnhancements, ControllerAimStick?>) -> some View {
        SettingsRow(title) {
            Picker(title, selection: Binding<ControllerAimStick>(get: { service.enhancements[keyPath: key] ?? .right }, set: { selected in
                service.updateSettings { settings in
                    var e = settings.enhancements ?? ControllerEnhancements(); e[keyPath: key] = selected; settings.enhancements = e
                }
            })) {
                ForEach(ControllerAimStick.allCases, id: \.self) { stick in Text(stick.title).tag(stick) }
            }.settingsPicker()
        }
    }
    private var triggers: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Trigger Stops") {
                toggle("Left trigger stop", \.leftLock)
                Divider()
                toggle("Right trigger stop", \.rightLock)
                Divider()
                slider("Stop position", value(\.lockPosition), range: 0.05...0.95)
                Text("No motor resistance before the stop, maximum resistance after it. This emulates a stop; it cannot physically shorten travel. Turning it off restores the selected effect.").font(.caption).foregroundStyle(.secondary).settingsRow()
            }
            SettingsGroup("Stream Rumble") {
                slider("Global gain (this Mac)", $service.globalRumbleGain, range: 0...2)
                Divider()
                slider("Profile gain", value(\.rumbleGain), range: 0...2)
                Divider()
                slider("Intensity curve", value(\.rumbleExponent), range: 0.25...4)
                ResponsePreview(label: "Incoming rumble → output strength") { service.enhancements.rumble($0, global: service.globalRumbleGain) }.settingsRow()
                HStack {
                    Text("Uses a 25% signal so amplification has room to increase.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Rumble Curve", action: service.testStreamRumble)
                    Button("Stop", action: service.stopHaptics)
                }.settingsRow()
                Divider()
                toggle("Use game trigger rumble", \.gameDrivenTriggers, note: "Experimental: converts Xbox trigger vibration into DualSense vibration. Your preset resumes after each event; trigger stops take priority.")
                Divider()
                SettingsRow("Rumble events / trigger events") { Text("\(service.rumbleEventCount) / \(service.triggerRumbleEventCount)").monospacedDigit() }
                Text(service.rumbleChannels).font(.caption.monospaced()).settingsRow()
                HStack { Spacer(); Button("Reset Counters", action: service.resetRumbleDiagnostics) }.settingsRow()
            }
        }
    }
    private var gyroModeBinding: Binding<ControllerGyroMode> {
        Binding(get: { service.enhancements.gyroMode }, set: { selected in
            service.updateSettings { settings in
                var e = settings.enhancements ?? ControllerEnhancements()
                e.setGyroMode(selected)
                settings.enhancements = e
            }
        })
    }
    private var touchpadAim: some View {
        SettingsGroup("Touchpad Aiming") {
            toggle("Touchpad aiming", \.touchpadAimEnabled, note: "Swipe to aim; lift to stop. Touchpad gestures are disabled while aiming is enabled.")
            Divider()
            stickPicker("Touchpad stick", \.touchpadStick)
                .disabled(service.enhancements.gyroMode == .steering)
            if service.enhancements.gyroMode == .steering {
                Text("Steering wheel owns the left stick, so touch aiming always drives the right stick while steering mode is active.").font(.caption).foregroundStyle(.secondary).settingsRow()
            }
            Divider()
            slider("Touchpad sensitivity", Binding(get: { service.enhancements.touchpadSensitivity ?? 0.35 }, set: { v in
                service.updateSettings { settings in
                    var e = settings.enhancements ?? ControllerEnhancements(); e.touchpadSensitivity = v; settings.enhancements = e
                }
            }), range: 0.05...3)
            Text("Higher sensitivity turns the camera further for the same swipe.").font(.caption).foregroundStyle(.secondary).settingsRow()
            Divider()
            SettingsRow("Live touch") { Text(String(format: "%.2f, %.2f", service.touchPreview.x, service.touchPreview.y)).monospacedDigit() }
            SettingsRow("Last gesture") { Text(service.lastGesture) }
        }
    }
    private var gyro: some View {
        SettingsGroup("Gyro Aiming") {
            SettingsRow("Motion sensor") { Text(service.gyroAvailable ? "Available" : "Unavailable").foregroundStyle(.secondary) }
            Divider()
            SettingsRow("Gyro mode") {
                Picker("Gyro mode", selection: gyroModeBinding) {
                    ForEach(ControllerGyroMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.settingsPicker()
            }
            gyroModeDetail
            DisclosureGroup("Live input & troubleshooting", isExpanded: $showDiagnostics) {
                SettingsRow("Sensor status") { Text(service.motionStatus).font(.caption) }
                SettingsRow("Last stream delivery") { Text(service.aimDeliveryStatus).font(.caption) }
                SettingsRow("Live gyro") { Text(String(format: "%.2f, %.2f", service.motionPreview.x, service.motionPreview.y)).monospacedDigit() }
            }.settingsRow().onChange(of: showDiagnostics) { service.setHighRateUIDetail($0) }
            SettingsRow("Drift correction", note: "Keep the controller still before centering.") {
                Button("Center Gyro", action: service.centerGyro).disabled(!service.gyroAvailable)
            }
        }
    }
    @ViewBuilder private var gyroModeDetail: some View {
        switch service.enhancements.gyroMode {
        case .off:
            Text("Motion sensors are off.").font(.caption).foregroundStyle(.secondary).settingsRow()
        case .aiming:
            toggle("Only while holding L2", \.gyroAimOnly)
            Divider()
            toggle("Invert vertical aim", \.gyroInvertY)
            Divider()
            slider("Sensitivity", value(\.gyroSensitivity), range: 0.05...2)
            Divider()
            slider("Motion noise threshold", Binding(get: { service.enhancements.effectiveGyroNoiseThreshold }, set: { v in
                service.updateSettings { settings in
                    var e = settings.enhancements ?? ControllerEnhancements(); e.gyroNoiseThreshold = v; settings.enhancements = e
                }
            }), range: 0...0.05)
            Divider()
            slider("Game dead-zone compensation", Binding(get: { service.enhancements.gyroOutputFloor ?? 0.12 }, set: { v in
                service.updateSettings { settings in
                    var e = settings.enhancements ?? ControllerEnhancements(); e.gyroOutputFloor = v; settings.enhancements = e
                }
            }), range: 0...0.4)
            Text("Raise the compensation if motion readings change but slow aiming is ignored by the game; use zero when the game's stick dead zone is zero. In the game, set the stick response curve to Linear — the standard curve exaggerates fast strokes over slow returns.").font(.caption).foregroundStyle(.secondary).settingsRow()
        case .steering:
            Text("Steering is active. Open Steering Wheel for wheel travel, smoothing and centering.").font(.caption).foregroundStyle(.secondary).settingsRow()
        case .flickShift:
            toggle("Invert flick direction", \.gyroInvertY)
            Text("Flick the controller toward you to shift up, away to shift down; the return movement is ignored. Rapid repeated shifts work — a brief pause between flicks is enough. Hold still and press Center Gyro to save your resting position.").font(.caption).foregroundStyle(.secondary).settingsRow()
        }
    }
    private func steeringValue(_ key: WritableKeyPath<ControllerEnhancements, Float?>, default fallback: Float) -> Binding<Float> {
        Binding(get: { service.enhancements[keyPath: key] ?? fallback }, set: { value(key).wrappedValue = $0 })
    }
    private var steeringPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Steering Wheel") {
                SettingsRow("Enable steering", note: "Rotate the controller like a wheel. Uses the left stick; touch aiming stays on the right.") {
                    Toggle("Enable steering", isOn: Binding(get: { service.enhancements.gyroMode == .steering }, set: { gyroModeBinding.wrappedValue = $0 ? .steering : .off })).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                slider("Full turn (degrees per side)", steeringValue(\.steeringRangeDegrees, default: 40), range: 10...120)
                    .help("Controller rotation needed to reach your maximum steering output. Smaller angles are more sensitive.")
                slider("Response curve", steeringValue(\.steeringExponent, default: 1), range: 0.5...2)
                    .help("1 is proportional. Above 1 softens the center; below 1 makes the center more sensitive. The curve remains continuous.")
                SettingsRow("Smoothing time") {
                    HStack(spacing: 8) {
                        Slider(value: steeringValue(\.steeringSmoothing, default: 0.5), in: 0...1).frame(width: 168).accessibilityLabel("Smoothing time")
                        Text(String(format: "%.0f ms", ControllerSteeringResponse.responseTime(smoothing: Double(service.enhancements.steeringSmoothing ?? 0.5)) * 1000)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Text("Higher smoothing softens changes but delays corrections. It does not change the final held angle.").font(.caption).foregroundStyle(.secondary).settingsRow()
                ResponsePreview(label: "Wheel travel → steering target") { fraction in
                    let e = service.enhancements
                    return abs(ControllerAimMath.steering(angle: fraction * e.effectiveSteeringRangeRadians, centre: 0,
                        range: e.effectiveSteeringRangeRadians, floor: e.effectiveSteeringFloor,
                        deadzone: (e.steeringDeadzoneDegrees ?? 0) * .pi / 180, exponent: e.steeringExponent ?? 1)) * e.effectiveSteeringMaximum
                }.settingsRow()
                SettingsRow("Straight-ahead position", note: "Hold the controller comfortably still, then center.") {
                    Button("Center Wheel", action: service.centerGyro).disabled(service.enhancements.gyroMode != .steering)
                }
            }
            DisclosureGroup("Advanced tuning") {
                SettingsGroup("Range & Direction") {
                    slider("Maximum steering", steeringValue(\.steeringMaximum, default: 1), range: 0.2...1)
                        .help("1 allows full stick output. Lower values limit turning strength without requiring a larger physical rotation.")
                    slider("Center dead zone (degrees)", steeringValue(\.steeringDeadzoneDegrees, default: 0), range: 0...3)
                    slider("Game dead-zone compensation", steeringValue(\.steeringFloor, default: 0.30), range: 0...0.6)
                    Text("Use zero compensation when the game's inner dead zone is zero. Excess compensation can make small turns too strong.").font(.caption).foregroundStyle(.secondary).settingsRow()
                    SettingsRow("Reverse steering") {
                        Toggle("Reverse steering", isOn: Binding(get: { service.enhancements.steeringInverted ?? false }, set: { value(\.steeringInverted).wrappedValue = $0 })).labelsHidden().toggleStyle(.switch)
                    }
                    HStack {
                        Text("Keeps turning angle and smoothing.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Response to Linear") {
                            service.updateSettings { settings in
                                var e = settings.enhancements ?? ControllerEnhancements()
                                e.steeringExponent = 1; e.steeringDeadzoneDegrees = 0; e.steeringFloor = 0; e.steeringMaximum = 1
                                settings.enhancements = e
                            }
                        }
                    }.settingsRow()
                }.padding(.top, 8)
            }
            DisclosureGroup("Live input & troubleshooting", isExpanded: $showDiagnostics) {
                SettingsGroup("Input") {
                    SettingsRow("Steering") { Text(service.steeringPreview).font(.caption.monospaced()) }
                    SettingsRow("Sensor") { Text(service.motionStatus).font(.caption) }
                    SettingsRow("Delivery") { Text(service.aimDeliveryStatus).font(.caption) }
                    Text("This sends Xbox stick input. The game determines steering assists and the car's turning radius.").font(.caption).foregroundStyle(.secondary).settingsRow()
                }.padding(.top, 8)
            }.onChange(of: showDiagnostics) { service.setHighRateUIDetail($0) }
        }
    }
    private var rapidFire: some View {
        SettingsGroup("Hold-to-Fire") {
            toggle("Rapid-fire R2", \.rapidFireEnabled, note: "Hold R2 past halfway to repeat; release to stop. Fixed macros take priority if they also target R2.")
            Divider()
            slider("Shots per second", value(\.rapidFireRate), range: 2...15)
        }
    }
    private var calibration: some View {
        SettingsGroup("Gameplay Response") {
            SettingsRow("Apply calibration to Xbox", note: "Local to this Mac, independent of profiles. Overrides Better xCloud’s mapped stick and trigger values while enabled.") {
                Toggle("Apply calibration to Xbox", isOn: $service.applyCalibrationToStream).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            slider("L2 start dead zone", calibrationValue(\.leftTrigger.deadzone), range: 0...0.8)
            Divider()
            slider("R2 start dead zone", calibrationValue(\.rightTrigger.deadzone), range: 0...0.8)
            Divider()
            stickResponse("Left stick", left: true)
            Divider()
            stickResponse("Right stick", left: false)
        }
    }
    private func calibrationValue(_ key: WritableKeyPath<ControllerCalibration, Float>) -> Binding<Float> {
        Binding(get: { service.settings.calibration[keyPath: key] }, set: { v in service.updateSettings { $0.calibration[keyPath: key] = v } })
    }
    private func stickResponse(_ title: String, left: Bool) -> some View {
        let c = left ? service.settings.calibration.leftStick : service.settings.calibration.rightStick
        return VStack(alignment: .leading) {
            SettingsRow(title + " curve") {
                Picker(title + " curve", selection: Binding<ResponseCurve>(get: {
                    left ? service.settings.calibration.leftStick.responseCurve : service.settings.calibration.rightStick.responseCurve
                }, set: { curve in service.updateSettings {
                    if left { $0.calibration.leftStick.responseCurve = curve } else { $0.calibration.rightStick.responseCurve = curve }
                } })) {
                    Text("Linear").tag(ResponseCurve.linear)
                    Text("Precise center").tag(ResponseCurve.exponential(exponent: 2))
                    Text("Quick response").tag(ResponseCurve.exponential(exponent: 0.5))
                    Text("Smooth S-curve").tag(ResponseCurve.sCurve(strength: 1))
                }.settingsPicker()
            }
            ResponsePreview(label: title + " travel → output") { c.apply(to: ControllerVector2(x: $0, y: 0)).x }.settingsRow()
        }
    }
}
struct ResponsePreview: View {
    let label: String
    let evaluate: (Float) -> Float
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                    }.stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3]))
                    Path { path in
                        for step in 0...100 {
                            let input = Float(step) / 100
                            let point = CGPoint(x: geometry.size.width * CGFloat(input), y: geometry.size.height * CGFloat(1 - min(max(evaluate(input), 0), 1)))
                            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }.stroke(Color.accentColor, lineWidth: 2)
                }
            }.frame(height: 64)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
