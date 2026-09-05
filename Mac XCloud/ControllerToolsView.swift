import SwiftUI

enum ControllerToolSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case test = "Test"
    case calibration = "Calibration"
    case triggers = "Triggers & Haptics"
    case touchpad = "Touchpad"
    case presets = "Input Presets"
    case shortcuts = "Shortcuts & Macros"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gamecontroller"
        case .test: "gauge.with.dots.needle.67percent"
        case .calibration: "scope"
        case .triggers: "waveform"
        case .touchpad: "hand.point.up.left"
        case .presets: "square.stack.3d.up"
        case .shortcuts: "command"
        }
    }
}

struct ControllerToolsView: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var service: ControllerFeatureService
    let section: ControllerToolSection

    var body: some View {
        sectionDetail
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                service.setControllerToolsActive(true)
                service.startPolling()
            }
            .onDisappear {
                service.setControllerToolsActive(false)
            }
    }

    private var sectionDetail: some View {
        SettingsPage {
            switch section {
            case .overview: overview
            case .test: test
            case .calibration: calibration
            case .triggers: triggers
            case .touchpad: touchpad
            case .presets: presets
            case .shortcuts: shortcuts
            }
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
            SettingsGroup("Controller Overview") {
                if let d = service.descriptor {
                    SettingsRow("Controller") { Text(d.vendorName).foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Category") { Text(d.productCategory).foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Input preset") { Text(browser.inputPresets.activePreset.name).foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Battery") { Text(batteryText).foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Adaptive triggers") { Text(service.capabilities.hasAdaptiveTriggers ? "Available" : "Unavailable").foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Touchpad") { Text(service.capabilities.hasTouchpad ? "Available" : "Unavailable").foregroundStyle(.secondary) }
                    Divider()
                    SettingsRow("Haptics") { Text(service.capabilities.hasHaptics ? "Available" : "Unavailable").foregroundStyle(.secondary) }
                } else {
                    SettingsRow("No Controller", note: "Connect a controller to use these tools.") {
                        SettingsSymbol(name: "gamecontroller", color: .purple)
                    }
                }
            }
            SettingsGroup("Controller Settings") {
                ForEach(Array(SettingsCategory.controllerRows.enumerated()), id: \.element.id) { index, def in
                    ControllerSettingRow(model: browser.settingsModel, def: def)
                    if index < SettingsCategory.controllerRows.count - 1 { Divider() }
                }
            }
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Native Controller Test") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 30) {
                        stick("Left Stick", value: service.snapshot.leftStick)
                        stick("Right Stick", value: service.snapshot.rightStick)
                    }
                    HStack(spacing: 20) {
                        trigger("L2", value: service.snapshot.leftTrigger)
                        trigger("R2", value: service.snapshot.rightTrigger)
                    }
                    buttonGrid
                }
            }
            SettingsGroup("Test Outputs") {
                HStack {
                    Button("Pulse Left") { service.playTestPulse(locality: .leftHandle) }
                    Button("Pulse Right") { service.playTestPulse(locality: .rightHandle) }
                    Button("Pulse Both") { service.playTestPulse(locality: .handles) }
                    Spacer()
                    Button("Reset Outputs") { service.stopHaptics(); service.updateSettings { $0.adaptiveTriggers = .default } }
                }.settingsRow()
            }
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate with the game paused. Center sampling measures drift, full range measures stick travel, and trigger calibration measures resting and maximum values.")
                .foregroundStyle(.secondary)
            SettingsGroup("Calibration & Drift Correction") {
                if let p = service.calibrationProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: p.progress) { Text(p.kind.rawValue.capitalized) }
                        Text("Samples: \(p.sampleCount)").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel", action: service.cancelCalibration)
                    }
                } else {
                    SettingsRow("1. Stick centers") {
                        Button("Calibrate Centers") { service.beginCalibration(.stickCenters, duration: 3) }
                    }
                    Divider()
                    SettingsRow("2. Stick travel") {
                        Button("Calibrate Full Range") { service.beginCalibration(.stickFullRange, duration: 5) }
                    }
                    Divider()
                    SettingsRow("3. Trigger range") {
                        Button("Calibrate Triggers") { service.beginCalibration(.triggers, duration: 4) }
                    }
                }
            }
            SettingsGroup("Current Correction") {
                calibrationSummary("Left", service.settings.calibration.leftStick)
                Divider()
                calibrationSummary("Right", service.settings.calibration.rightStick)
                Divider()
                HStack {
                    Spacer()
                    Button("Reset Calibration") { service.updateSettings { $0.calibration = .default } }
                }.settingsRow()
            }
        }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adaptive-trigger effects are synthetic category presets. xCloud does not transmit the original PS5 game-authored trigger effects.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsGroup("Adaptive Triggers") {
                SettingsRow("Left trigger") {
                    AdaptiveTriggerPresetSelector(title: "Left trigger", side: .left, service: service, store: browser.inputPresets)
                }
                Divider()
                SettingsRow("Right trigger") {
                    AdaptiveTriggerPresetSelector(title: "Right trigger", side: .right, service: service, store: browser.inputPresets)
                }
            }
            Text("Pedal presets hold resistance through full pull; braking is lighter than acceleration. Built-in effects are approximations, not vehicle telemetry. Custom selections keep a snapshot even if their library entry changes or is deleted.")
                .font(.caption).foregroundStyle(.secondary)
            AdaptiveTriggerPresetManager(service: service, store: browser.inputPresets)
            SettingsGroup("Haptics") {
                SettingsRow("Haptic mode") {
                    Picker("Haptic mode", selection: hapticMode) {
                        ForEach(HapticMode.allCases, id: \.self) { Text($0.rawValue.humanized).tag($0) }
                    }.settingsPicker()
                }
                Divider()
                valueSlider("Haptic gain", value: hapticGain, range: 0...2, format: { String(format: "%.1fx", $0) })
                Divider()
                valueSlider("Sharpness", value: hapticSharpness, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
                Divider()
                HStack {
                    Button("Test Soft") { service.playTestPulse(intensity: 0.35, sharpness: 0.15) }
                    Button("Test Strong") { service.playTestPulse(intensity: 1, sharpness: 0.75, duration: 0.25) }
                    Spacer()
                    Button("Stop", action: service.stopHaptics)
                }.settingsRow()
            }
        }
    }

    private var touchpad: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Touchpad") {
                SettingsRow("Enable touchpad gestures") {
                    Toggle("Enable touchpad gestures", isOn: touchpadEnabled).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                TouchpadGestureDemo()
                    .frame(maxWidth: 300)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                Text("The animation demonstrates two-finger swipe behavior. Gestures are recognized natively and mapped to the selected action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup("Gesture Actions") {
                ForEach(Array(TouchpadGesture.allCases.enumerated()), id: \.element) { index, gesture in
                    if index > 0 { Divider() }
                    SettingsRow(gesture.rawValue.humanized) {
                        Picker(gesture.rawValue.humanized, selection: touchpadAction(for: gesture)) {
                            Text("None").tag(ControllerNativeAction.none)
                            Text("Open Settings").tag(ControllerNativeAction.toggleSettings)
                            Text("Toggle Fullscreen").tag(ControllerNativeAction.toggleFullscreen)
                            Text("Toggle Stats").tag(ControllerNativeAction.toggleStats)
                            Text("Screenshot").tag(ControllerNativeAction.screenshot)
                            Text("Mute").tag(ControllerNativeAction.mute)
                        }.settingsPicker()
                    }
                }
            }
        }
    }

    private var presets: some View {
        InputPresetManagerView(store: browser.inputPresets)
    }

    private var shortcuts: some View {
        ShortcutMacroEditor(service: service, installDefaults: installDefaultShortcuts)
    }

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
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .semibold)).padding(.vertical, 8)
            SettingsRow("Center") { Text(String(format: "%.4f, %.4f", c.center.x, c.center.y)).monospacedDigit() }
            SettingsRow("Inner deadzone") { Text(String(format: "%.2f", c.innerDeadzone)).monospacedDigit() }
            SettingsRow("Outer deadzone") { Text(String(format: "%.2f", c.outerDeadzone)).monospacedDigit() }
        }
    }

    private var hapticMode: Binding<HapticMode> { Binding(get: { service.settings.haptics.mode }, set: { value in service.updateSettings { $0.haptics.mode = value } }) }
    private var hapticGain: Binding<Double> { Binding(get: { Double(service.settings.haptics.intensityMultiplier) }, set: { value in service.updateSettings { $0.haptics.intensityMultiplier = Float(value) } }) }
    private var hapticSharpness: Binding<Double> { Binding(get: { Double(service.settings.haptics.sharpness) }, set: { value in service.updateSettings { $0.haptics.sharpness = Float(value) } }) }
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
        SettingsRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).frame(width: 168).accessibilityLabel(label)
                Text(format(value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }

    private func installDefaultShortcuts() {
        let shortcut = ControllerShortcut(name: "Open Settings", controls: [.leftStickButton, .rightStickButton], activation: .hold(seconds: 0.65), action: .toggleSettings)
        service.updateSettings { settings in
            // Never replace user mappings or install a conflicting duplicate chord.
            guard !settings.shortcuts.shortcuts.contains(where: {
                $0.controls == shortcut.controls && $0.activation == shortcut.activation
            }) else { return }
            settings.shortcuts.shortcuts.append(shortcut)
        }
    }
}

/// Compact renderer for the three Better xCloud controller preferences that
/// moved from the obsolete Controller Tools settings category to Overview.
private struct ControllerSettingRow: View {
    @ObservedObject var model: SettingsModel
    let def: SettingDef

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.label).font(.system(size: 13))
                if let note = def.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control.frame(width: controlWidth, alignment: .trailing).accessibilityLabel(def.label)
        }
        .settingsRow()
    }

    private var controlWidth: CGFloat {
        if case .range = def.kind { return 240 }
        return 180
    }

    @ViewBuilder
    private var control: some View {
        switch def.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { model.isOn(def) },
                set: { model.setToggle(def, desired: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        case .range(let minimum, let maximum, let step, _, let format):
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { model.rangeValue(def) ?? minimum },
                    set: { model.setRange(def, value: $0) }
                ), in: minimum...maximum, step: step)
                .frame(width: 168)
                Text(format(model.rangeValue(def) ?? minimum))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
        case .ledColor:
            HStack(spacing: 8) {
                Menu {
                    ForEach(Array(LEDColor.all.enumerated()), id: \.offset) { index, color in
                        Button {
                            model.ledColorIndex = index
                        } label: {
                            if model.ledColorIndex == index {
                                Label(color.label, systemImage: "checkmark")
                            } else {
                                Text(color.label)
                            }
                        }
                    }
                } label: {
                    Text(LEDColor.all.indices.contains(model.ledColorIndex) ? LEDColor.all[model.ledColorIndex].label : "LED")
                        .lineLimit(1)
                }
                ColorPicker("", selection: Binding(
                    get: { model.customLEDColor },
                    set: { model.customLEDColor = $0 }
                ), supportsOpacity: false)
                .labelsHidden()
                .fixedSize()
            }
        default:
            EmptyView()
        }
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
    var humanized: String {
        let withSpaces = unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty { result.append(" ") }
            result.append(Character(scalar))
        }
        return withSpaces.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
