import SwiftUI

enum ControllerToolSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case test = "Test"
    case calibration = "Calibration"
    case triggers = "Triggers & Haptics"
    case motion = "Motion & Touchpad"
    case presets = "Presets"
    case shortcuts = "Shortcuts & Macros"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gamecontroller"
        case .test: "gauge.with.dots.needle.67percent"
        case .calibration: "scope"
        case .triggers: "waveform"
        case .motion: "gyroscope"
        case .presets: "square.stack.3d.up"
        case .shortcuts: "command"
        }
    }
}

struct ControllerToolsView: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var service: ControllerFeatureService
    @State private var section: ControllerToolSection = .presets

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(ControllerToolSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                Group {
                    switch section {
                    case .overview: overview
                    case .test: test
                    case .calibration: calibration
                    case .triggers: triggers
                    case .motion: motion
                    case .presets: presets
                    case .shortcuts: shortcuts
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Controller Tools")
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            browser.setGamepadPollingPaused(true)
            service.setControllerToolsActive(true)
            service.startPolling()
        }
        .onDisappear {
            service.setControllerToolsActive(false)
            browser.setGamepadPollingPaused(false)
        }
    }

    private var batteryText: String {
        guard let battery = service.snapshot.battery else { return "Unavailable" }
        let suffix: String
        switch battery.state {
        case .charging: suffix = " · Charging"
        case .full: suffix = " · Full"
        case .discharging: suffix = ""
        case .unknown: suffix = " · Unknown"
        }
        return "\(Int(battery.level * 100))%\(suffix)"
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Controller Overview")
            if let d = service.descriptor {
                GroupBox {
                    LabeledContent("Controller", value: d.vendorName)
                    LabeledContent("Category", value: d.productCategory)
                    LabeledContent("Battery", value: batteryText)
                    LabeledContent("Adaptive triggers", value: service.capabilities.hasAdaptiveTriggers ? "Available" : "Unavailable")
                    LabeledContent("Motion", value: service.capabilities.hasMotion ? "Available" : "Unavailable")
                    LabeledContent("Touchpad", value: service.capabilities.hasTouchpad ? "Available" : "Unavailable")
                    LabeledContent("Haptics", value: service.capabilities.hasHaptics ? "Available" : "Unavailable")
                }
            } else {
                ContentUnavailableView("No Controller", systemImage: "gamecontroller", description: Text("Connect a controller to use these tools."))
            }
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Native Controller Test")
            HStack(spacing: 30) {
                stick("Left Stick", value: service.snapshot.leftStick)
                stick("Right Stick", value: service.snapshot.rightStick)
            }
            HStack(spacing: 20) {
                trigger("L2", value: service.snapshot.leftTrigger)
                trigger("R2", value: service.snapshot.rightTrigger)
            }
            buttonGrid
            if let motion = service.snapshot.motion {
                GroupBox("Motion") {
                    LabeledContent("Rotation", value: String(format: "%.2f, %.2f, %.2f rad/s", motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z))
                    LabeledContent("Gravity", value: String(format: "%.2f, %.2f, %.2f g", motion.gravity.x, motion.gravity.y, motion.gravity.z))
                }
            }
            HStack {
                Button("Pulse Left") { service.playTestPulse(locality: .leftHandle) }
                Button("Pulse Right") { service.playTestPulse(locality: .rightHandle) }
                Button("Pulse Both") { service.playTestPulse(locality: .handles) }
                Button("Reset Outputs") { service.stopHaptics(); service.updateSettings { $0.adaptiveTriggers = .default } }
            }
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Calibration & Drift Correction")
            Text("Calibrate with the game paused. Center sampling measures drift, full range measures stick travel, and trigger calibration measures resting and maximum values.")
                .foregroundStyle(.secondary)
            if let p = service.calibrationProgress {
                ProgressView(value: p.progress) { Text(p.kind.rawValue.capitalized) }
                Text("Samples: \(p.sampleCount)").font(.caption).foregroundStyle(.secondary)
                Button("Cancel", action: service.cancelCalibration)
            } else {
                HStack {
                    Button("1. Calibrate Centers") { service.beginCalibration(.stickCenters, duration: 3) }
                    Button("2. Calibrate Full Range") { service.beginCalibration(.stickFullRange, duration: 5) }
                    Button("3. Calibrate Triggers") { service.beginCalibration(.triggers, duration: 4) }
                }
            }
            GroupBox("Current correction") {
                calibrationSummary("Left", service.settings.calibration.leftStick)
                Divider()
                calibrationSummary("Right", service.settings.calibration.rightStick)
            }
            Button("Reset Calibration") { service.updateSettings { $0.calibration = .default } }
        }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Adaptive Triggers & Haptics")
            Text("Adaptive-trigger effects are synthetic category presets. xCloud does not transmit the original PS5 game-authored trigger effects.")
                .font(.callout).foregroundStyle(.orange)
            Picker("Left trigger", selection: triggerPreset(.left)) {
                ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { Text($0.rawValue.humanized).tag($0) }
            }
            Picker("Right trigger", selection: triggerPreset(.right)) {
                ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { Text($0.rawValue.humanized).tag($0) }
            }
            Divider()
            Picker("Haptic mode", selection: hapticMode) {
                ForEach(HapticMode.allCases, id: \.self) { Text($0.rawValue.humanized).tag($0) }
            }
            valueSlider("Haptic gain", value: hapticGain, range: 0...2, format: { String(format: "%.1fx", $0) })
            valueSlider("Sharpness", value: hapticSharpness, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
            HStack {
                Button("Test Soft") { service.playTestPulse(intensity: 0.35, sharpness: 0.15) }
                Button("Test Strong") { service.playTestPulse(intensity: 1, sharpness: 0.75, duration: 0.25) }
                Button("Stop", action: service.stopHaptics)
            }
        }
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Motion & Touchpad")
            Picker("Gyro mode", selection: gyroMode) {
                Text("Off").tag(GyroMode.off)
                Text("Aim (right stick)").tag(GyroMode.rightStick)
                Text("Aim while L2 held").tag(GyroMode.pointer)
                Text("Steering (tilt)").tag(GyroMode.raw)
            }
            valueSlider("Horizontal sensitivity", value: gyroSensitivityX, range: 0.1...3, format: { String(format: "%.1fx", $0) })
            valueSlider("Vertical sensitivity", value: gyroSensitivityY, range: 0.1...3, format: { String(format: "%.1fx", $0) })
            valueSlider("Motion deadzone", value: gyroDeadzone, range: 0...0.2, format: { String(format: "%.2f", $0) })
            Toggle("Invert horizontal", isOn: gyroInvertX)
            Toggle("Invert vertical", isOn: gyroInvertY)
            Button("Recenter Motion") { service.recenterMotion() }

            Divider()
            Toggle("Enable touchpad gestures", isOn: touchpadEnabled)
            TouchpadGestureDemo()
            ForEach(TouchpadGesture.allCases, id: \.self) { gesture in
                Picker(gesture.rawValue.humanized, selection: touchpadAction(for: gesture)) {
                    Text("None").tag(ControllerNativeAction.none)
                    Text("Open Settings").tag(ControllerNativeAction.toggleSettings)
                    Text("Toggle Fullscreen").tag(ControllerNativeAction.toggleFullscreen)
                    Text("Toggle Stats").tag(ControllerNativeAction.toggleStats)
                    Text("Screenshot").tag(ControllerNativeAction.screenshot)
                    Text("Mute").tag(ControllerNativeAction.mute)
                }
            }
            Text("The animation demonstrates two-finger swipe behavior. Gestures are recognized natively and mapped to the selected action.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Category Presets")
            Text("Choose a genre-style controller profile. These are not tied to individual games.")
                .foregroundStyle(.secondary)
            ForEach(ControllerCategoryPreset.allCases, id: \.self) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    HStack {
                        Image(systemName: presetIcon(preset))
                        VStack(alignment: .leading) {
                            Text(preset.rawValue.humanized)
                            Text(presetDescription(preset)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if service.settings.categoryPreset.selectedPreset == preset { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    .padding(8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Shortcuts & Macros")
            Text("Shortcuts support chords, holds and double-presses. Macros are limited to 16 finite steps and two seconds—no loops or turbo.")
                .foregroundStyle(.secondary)
            GroupBox("Suggested native shortcuts") {
                LabeledContent("Open Settings", value: "Hold L3 + R3")
                LabeledContent("Touchpad gesture", value: "Two-finger tap")
            }
            Button("Create Default Shortcuts") { installDefaultShortcuts() }
            Divider()
            Text("Macros").font(.headline)
            if service.settings.macros.isEmpty {
                Text("No macros configured.").foregroundStyle(.secondary)
            } else {
                ForEach(service.settings.macros) { macro in
                    HStack { Text(macro.name); Spacer(); Text("\(macro.steps.count) steps · \(macro.totalDurationMilliseconds) ms").foregroundStyle(.secondary) }
                }
            }
            Button("Create Basic Double-Tap Macro") { createSampleMacro() }
        }
    }

    private func title(_ text: String) -> some View { Text(text).font(.system(size: 24, weight: .semibold, design: .rounded)) }

    private func stick(_ label: String, value: ControllerVector2) -> some View {
        VStack {
            ZStack {
                Circle().stroke(.secondary.opacity(0.4), lineWidth: 1).frame(width: 130, height: 130)
                Circle().fill(Color.accentColor).frame(width: 16, height: 16).offset(x: CGFloat(value.x) * 55, y: CGFloat(-value.y) * 55)
            }
            Text(label).font(.caption)
            Text(String(format: "%.3f, %.3f", value.x, value.y)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func trigger(_ label: String, value: Float) -> some View {
        VStack(alignment: .leading) {
            Text(label)
            ProgressView(value: Double(value)).frame(width: 220)
            Text("\(Int(value * 100))%").font(.caption.monospaced())
        }
    }

    private var buttonGrid: some View {
        let values: [(String, Bool)] = [
            ("A", service.snapshot.buttons.a.isPressed), ("B", service.snapshot.buttons.b.isPressed),
            ("X", service.snapshot.buttons.x.isPressed), ("Y", service.snapshot.buttons.y.isPressed),
            ("LB", service.snapshot.buttons.leftShoulder.isPressed), ("RB", service.snapshot.buttons.rightShoulder.isPressed),
            ("L3", service.snapshot.buttons.leftStick.isPressed), ("R3", service.snapshot.buttons.rightStick.isPressed),
            ("Touchpad", service.snapshot.buttons.touchpad.isPressed)
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
            ForEach(values, id: \.0) { name, pressed in
                Text(name).frame(maxWidth: .infinity).padding(8).background(pressed ? Color.green.opacity(0.7) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func calibrationSummary(_ label: String, _ c: StickCalibration) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.headline)
            LabeledContent("Center", value: String(format: "%.4f, %.4f", c.center.x, c.center.y))
            LabeledContent("Inner deadzone", value: String(format: "%.2f", c.innerDeadzone))
            LabeledContent("Outer deadzone", value: String(format: "%.2f", c.outerDeadzone))
        }
    }

    private enum TriggerSide { case left, right }
    private func triggerPreset(_ side: TriggerSide) -> Binding<AdaptiveTriggerPreset> {
        Binding(get: { side == .left ? service.settings.adaptiveTriggers.leftPreset : service.settings.adaptiveTriggers.rightPreset }, set: { new in service.updateSettings { if side == .left { $0.adaptiveTriggers.leftPreset = new } else { $0.adaptiveTriggers.rightPreset = new } } })
    }
    private var hapticMode: Binding<HapticMode> { Binding(get: { service.settings.haptics.mode }, set: { value in service.updateSettings { $0.haptics.mode = value } }) }
    private var hapticGain: Binding<Double> { Binding(get: { Double(service.settings.haptics.intensityMultiplier) }, set: { value in service.updateSettings { $0.haptics.intensityMultiplier = Float(value) } }) }
    private var hapticSharpness: Binding<Double> { Binding(get: { Double(service.settings.haptics.sharpness) }, set: { value in service.updateSettings { $0.haptics.sharpness = Float(value) } }) }
    private var gyroMode: Binding<GyroMode> { Binding(get: { service.settings.gyro.mode }, set: { value in service.updateSettings { $0.gyro.mode = value } }) }
    private var gyroSensitivityX: Binding<Double> { Binding(get: { Double(service.settings.gyro.sensitivityX) }, set: { value in service.updateSettings { $0.gyro.sensitivityX = Float(value) } }) }
    private var gyroSensitivityY: Binding<Double> { Binding(get: { Double(service.settings.gyro.sensitivityY) }, set: { value in service.updateSettings { $0.gyro.sensitivityY = Float(value) } }) }
    private var gyroDeadzone: Binding<Double> { Binding(get: { Double(service.settings.gyro.deadzone) }, set: { value in service.updateSettings { $0.gyro.deadzone = Float(value) } }) }
    private var gyroInvertX: Binding<Bool> { Binding(get: { service.settings.gyro.invertX }, set: { value in service.updateSettings { $0.gyro.invertX = value } }) }
    private var gyroInvertY: Binding<Bool> { Binding(get: { service.settings.gyro.invertY }, set: { value in service.updateSettings { $0.gyro.invertY = value } }) }
    private var touchpadEnabled: Binding<Bool> { Binding(get: { service.settings.touchpad.isEnabled }, set: { value in service.updateSettings { $0.touchpad.isEnabled = value } }) }

    private func touchpadAction(for gesture: TouchpadGesture) -> Binding<ControllerNativeAction> {
        Binding(
            get: { service.settings.touchpad.mappings.first(where: { $0.gesture == gesture && $0.isEnabled })?.action ?? .none },
            set: { action in
                service.updateSettings { settings in
                    settings.touchpad.mappings.removeAll { $0.gesture == gesture }
                    if action != .none { settings.touchpad.mappings.append(TouchpadActionMapping(gesture: gesture, action: action)) }
                }
            }
        )
    }

    private func valueSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack { Text(label); Slider(value: value, in: range); Text(format(value.wrappedValue)).frame(width: 58, alignment: .trailing) }
    }

    private func applyPreset(_ preset: ControllerCategoryPreset) {
        service.updateSettings { settings in
            settings.categoryPreset.selectedPreset = preset
            switch preset {
            case .racing:
                settings.gyro.mode = .raw; settings.adaptiveTriggers.leftPreset = .brakeComfort; settings.adaptiveTriggers.rightPreset = .accelerator; settings.haptics.intensityMultiplier = 1.0
                settings.calibration.leftStick.responseCurve = .sCurve(strength: 0.28)
            case .simulation:
                settings.gyro.mode = .raw; settings.adaptiveTriggers.leftPreset = .bow; settings.adaptiveTriggers.rightPreset = .bow; settings.haptics.intensityMultiplier = 0.9
                settings.calibration.leftStick.responseCurve = .sCurve(strength: 0.45)
            case .shooter:
                settings.gyro.mode = .pointer; settings.adaptiveTriggers.leftPreset = .softResistance; settings.adaptiveTriggers.rightPreset = .automaticRecoil; settings.haptics.intensityMultiplier = 1.15
                settings.calibration.rightStick.responseCurve = .exponential(exponent: 1.25)
            case .platformer:
                settings.gyro.mode = .off; settings.adaptiveTriggers.leftPreset = .platformerEndStop; settings.adaptiveTriggers.rightPreset = .platformerEndStop; settings.haptics.intensityMultiplier = 0.9
            case .story:
                settings.gyro.mode = .off; settings.adaptiveTriggers.leftPreset = .cinematic; settings.adaptiveTriggers.rightPreset = .cinematic; settings.haptics.intensityMultiplier = 1.0
            case .custom: break
            }
        }
    }

    private func presetIcon(_ preset: ControllerCategoryPreset) -> String {
        switch preset { case .racing: "steeringwheel"; case .simulation: "airplane"; case .shooter: "scope"; case .platformer: "figure.run"; case .story: "book"; case .custom: "slider.horizontal.3" }
    }
    private func presetDescription(_ preset: ControllerCategoryPreset) -> String {
        switch preset { case .racing: "Tilt steering and progressive triggers"; case .simulation: "Smooth motion and trigger resistance"; case .shooter: "Gyro aim and weapon trigger"; case .platformer: "Light feedback, no gyro"; case .story: "Balanced comfort and haptics"; case .custom: "Your current settings" }
    }

    private func installDefaultShortcuts() {
        let shortcut = ControllerShortcut(name: "Open Settings", controls: [.leftStickButton, .rightStickButton], activation: .hold(seconds: 0.65), action: .toggleSettings)
        service.updateSettings { $0.shortcuts.shortcuts = [shortcut] }
    }

    private func createSampleMacro() {
        guard let macro = try? ControllerMacro(name: "Double A", steps: [
            ControllerMacroStep(delayMilliseconds: 0, action: .button(control: .buttonA, isPressed: true)),
            ControllerMacroStep(delayMilliseconds: 70, action: .button(control: .buttonA, isPressed: false)),
            ControllerMacroStep(delayMilliseconds: 110, action: .button(control: .buttonA, isPressed: true)),
            ControllerMacroStep(delayMilliseconds: 70, action: .button(control: .buttonA, isPressed: false)),
        ]) else { return }
        service.updateSettings { $0.macros.append(macro) }
    }
}

struct TouchpadGestureDemo: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).stroke(.secondary.opacity(0.5), lineWidth: 2).frame(height: 120)
            HStack(spacing: 30) {
                Circle().fill(Color.accentColor).frame(width: 16, height: 16).offset(x: animate ? 55 : -55)
                Circle().fill(Color.accentColor.opacity(0.75)).frame(width: 16, height: 16).offset(x: animate ? 55 : -55)
            }
            Image(systemName: "arrow.right").font(.title2).opacity(0.7)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { animate = true } }
    }
}

private extension String {
    var humanized: String { replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized }
}
