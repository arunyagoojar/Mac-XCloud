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
    /// Embedded in Settings for the 1.3.5 route. The standalone window path is
    /// intentionally retained only as a compatibility shell and is no longer
    /// opened by any app action.
    var embedded = false
    @Binding private var section: ControllerToolSection

    init(service: ControllerFeatureService, embedded: Bool = false, section: Binding<ControllerToolSection> = .constant(.presets)) {
        self.service = service
        self.embedded = embedded
        self._section = section
    }

    var body: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                NavigationView {
                    sectionSidebar
                sectionDetail
            }
                .navigationViewStyle(.columns)
                .navigationTitle("Controller Tools")
                .frame(minWidth: 860, minHeight: 600)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            service.setControllerToolsActive(true)
            service.startPolling()
        }
        .onDisappear {
            service.setControllerToolsActive(false)
        }
    }

    private var embeddedContent: some View {
        HStack(spacing: 0) {
            sectionSidebar
                .frame(minWidth: 190, idealWidth: 205, maxWidth: 225)
            Divider()
            sectionDetail
        }
    }

    private var sectionSidebar: some View {
        List {
            Section("Controller") {
                ForEach(ControllerToolSection.allCases) { item in
                    Button { section = item } label: {
                        Label {
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        } icon: {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 20, height: 20)
                        }
                        .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sectionDetail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    Group {
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
                    .padding(embedded ? 18 : 22)
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                        Text(section.rawValue)
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, embedded ? 18 : 22)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                }
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
            title("Controller Overview")
            if let d = service.descriptor {
                GroupBox {
                    HStack { Text("Controller"); Spacer(); Text(d.vendorName) }
                    HStack { Text("Category"); Spacer(); Text(d.productCategory) }
                    HStack { Text("Input preset"); Spacer(); Text(browser.inputPresets.activePreset.name) }
                    HStack { Text("Battery"); Spacer(); Text(batteryText) }
                    HStack { Text("Adaptive triggers"); Spacer(); Text(service.capabilities.hasAdaptiveTriggers ? "Available" : "Unavailable") }
                    HStack { Text("Touchpad"); Spacer(); Text(service.capabilities.hasTouchpad ? "Available" : "Unavailable") }
                    HStack { Text("Haptics"); Spacer(); Text(service.capabilities.hasHaptics ? "Available" : "Unavailable") }
                }
            } else {
                VStack { Image(systemName: "gamecontroller").font(.largeTitle); Text("No Controller"); Text("Connect a controller to use these tools.").font(.caption).foregroundStyle(.secondary) }
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
            Picker("Left trigger", selection: triggerPreset(.left)) { triggerCatalog }
            Picker("Right trigger", selection: triggerPreset(.right)) { triggerCatalog }
            AdaptiveTriggerPresetManager(service: service, store: browser.inputPresets)
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

    private var touchpad: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Touchpad")
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
        InputPresetManagerView(store: browser.inputPresets)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Shortcuts & Macros")
            Text("Shortcuts support chords, holds and double-presses. Macros are limited to 16 finite steps and two seconds—no loops or turbo.")
                .foregroundStyle(.secondary)
            GroupBox("Suggested native shortcuts") {
                HStack { Text("Open Settings"); Spacer(); Text("Hold L3 + R3") }
                HStack { Text("Touchpad gesture"); Spacer(); Text("Two-finger tap") }
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
            HStack { Text("Center"); Spacer(); Text(String(format: "%.4f, %.4f", c.center.x, c.center.y)) }
            HStack { Text("Inner deadzone"); Spacer(); Text(String(format: "%.2f", c.innerDeadzone)) }
            HStack { Text("Outer deadzone"); Spacer(); Text(String(format: "%.2f", c.outerDeadzone)) }
        }
    }

    @ViewBuilder
    private var triggerCatalog: some View {
        ForEach(AdaptiveTriggerCategory.allCases) { category in
            Section(category.rawValue) {
                ForEach(AdaptiveTriggerPreset.catalog(in: category), id: \.self) { preset in
                    Text(preset.htmlName).tag(preset)
                }
            }
        }
    }

    private enum TriggerSide { case left, right }
    private func triggerPreset(_ side: TriggerSide) -> Binding<AdaptiveTriggerPreset> {
        Binding(get: { side == .left ? service.settings.adaptiveTriggers.leftPreset : service.settings.adaptiveTriggers.rightPreset }, set: { new in
            service.updateSettings {
                if side == .left { $0.adaptiveTriggers.leftPreset = new; $0.adaptiveTriggers.leftUsesCustom = false }
                else { $0.adaptiveTriggers.rightPreset = new; $0.adaptiveTriggers.rightUsesCustom = false }
            }
        })
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
        HStack { Text(label); Slider(value: value, in: range); Text(format(value.wrappedValue)).frame(width: 58, alignment: .trailing) }
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
    var humanized: String {
        let withSpaces = unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty { result.append(" ") }
            result.append(Character(scalar))
        }
        return withSpaces.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
