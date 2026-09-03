//
//  ControllerInputService.swift
//  Mac XCloud
//
//  Polls GCController for app-level input that doesn't belong to the game:
//  double-pressing the Home/PS button toggles the settings overlay, and while
//  the overlay is open the d-pad/stick/A/B drive it.
//

import Combine
import GameController

@MainActor
final class ControllerInputService: ObservableObject {
    var onToggleOverlay: (() -> Void)?
    var onNavigate: ((Int) -> Void)?    // -1 up / +1 down
    var onAdjust: ((Int) -> Void)?      // -1 left / +1 right
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSwitchCategory: ((Int) -> Void)?   // -1 left bumper / +1 right bumper
    /// Fires when a controller connects/disconnects (true = connected).
    var onPresenceChange: ((Bool) -> Void)?
    /// When nil or false, UI navigation/activation input is ignored (e.g. the
    /// settings window is closed) — only the Home double-press stays active.
    var isUIInputEnabled: (() -> Bool)?
    /// The global Settings shortcut is allowed only while the stream owns input.
    var isSettingsShortcutEnabled: (() -> Bool)?

    @Published private(set) var controllerName: String?
    @Published private(set) var supportsLED = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var batteryStateText: String?

    private var timer: Timer?
    private var lastMetadataRefresh: TimeInterval = 0
    private var l3r3HoldStarted: TimeInterval?
    private var l3r3Triggered = false
    private var previous = ButtonState()

    private struct ButtonState {
        var home = false
        var dpadUp = false
        var dpadDown = false
        var dpadLeft = false
        var dpadRight = false
        var stickUp = false
        var stickDown = false
        var stickLeft = false
        var stickRight = false
        var a = false
        var b = false
        var lb = false
        var rb = false
    }

    func start() {
        guard timer == nil else { return }
        refreshControllerInfo()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - LED

    func setLED(_ preset: LEDColor) {
        setLED(r: preset.red, g: preset.green, b: preset.blue)
    }

    func setLED(r: Double, g: Double, b: Double) {
        guard let controller = GCController.controllers().first, let light = controller.light else { return }
        light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
    }

    private func refreshControllerInfo() {
        let controllers = GCController.controllers()
        if let controller = controllers.first {
            let nextName = controller.vendorName ?? "Game Controller"
            if controllerName != nextName { controllerName = nextName }
            let nextLED = controller.light != nil
            if supportsLED != nextLED { supportsLED = nextLED }
            if let battery = controller.battery {
                let nextPercent = Int((battery.batteryLevel * 100).rounded())
                let nextState: String
                switch battery.batteryState {
                case .charging: nextState = "Charging"
                case .discharging: nextState = "Battery"
                case .full: nextState = "Full"
                case .unknown: nextState = "Battery"
                @unknown default: nextState = "Battery"
                }
                if batteryPercent != nextPercent { batteryPercent = nextPercent }
                if batteryStateText != nextState { batteryStateText = nextState }
            } else {
                if batteryPercent != nil { batteryPercent = nil }
                if batteryStateText != nil { batteryStateText = nil }
            }
        } else {
            if controllerName != nil { controllerName = nil }
            if supportsLED { supportsLED = false }
            if batteryPercent != nil { batteryPercent = nil }
            if batteryStateText != nil { batteryStateText = nil }
        }
        let hasController = !controllers.isEmpty
        if hasController != lastPresenceState {
            lastPresenceState = hasController
            onPresenceChange?(hasController)
        }
    }

    private var lastPresenceState = false

    // MARK: - Polling

    private func poll() {
        guard let pad = GCController.controllers().first?.extendedGamepad else {
            previous = ButtonState()
            refreshControllerInfo()
            return
        }
        let now = CACurrentMediaTime()
        if now - lastMetadataRefresh >= 1 {
            lastMetadataRefresh = now
            refreshControllerInfo()
        }

        let homePressed = pad.buttonHome?.isPressed ?? false

        // Deliberate global shortcut: hold L3 + R3 together for 0.65 seconds.
        // This avoids the PS/Home button, which Xbox reserves for its Guide.
        let l3r3Pressed = (pad.leftThumbstickButton?.isPressed ?? false) && (pad.rightThumbstickButton?.isPressed ?? false)
        if l3r3Pressed {
            if l3r3HoldStarted == nil { l3r3HoldStarted = now }
            if !l3r3Triggered, let started = l3r3HoldStarted,
               now - started >= 0.65, isSettingsShortcutEnabled?() == true {
                l3r3Triggered = true
                onToggleOverlay?()
            }
        } else {
            l3r3HoldStarted = nil
            l3r3Triggered = false
        }

        // Overlay navigation, one step per press — only while UI is visible.
        let stick = pad.leftThumbstick.xAxis.value
        let stickY = pad.leftThumbstick.yAxis.value
        let up = pad.dpad.up.isPressed || stickY > 0.55
        let down = pad.dpad.down.isPressed || stickY < -0.55
        let left = pad.dpad.left.isPressed || stick < -0.55
        let right = pad.dpad.right.isPressed || stick > 0.55

        let uiActive = isUIInputEnabled?() ?? false
        if uiActive {
            if up, !previous.dpadUp, !previous.stickUp { onNavigate?(-1) }
            if down, !previous.dpadDown, !previous.stickDown { onNavigate?(1) }
            if left, !previous.dpadLeft, !previous.stickLeft { onAdjust?(-1) }
            if right, !previous.dpadRight, !previous.stickRight { onAdjust?(1) }
            if pad.buttonA.isPressed, !previous.a { onActivate?() }
            if pad.buttonB.isPressed, !previous.b { onCancel?() }
            if pad.leftShoulder.isPressed, !previous.lb { onSwitchCategory?(-1) }
            if pad.rightShoulder.isPressed, !previous.rb { onSwitchCategory?(1) }
        }

        previous = ButtonState(home: homePressed,
                               dpadUp: up, dpadDown: down, dpadLeft: left, dpadRight: right,
                               stickUp: stickY > 0.55, stickDown: stickY < -0.55,
                               stickLeft: stick < -0.55, stickRight: stick > 0.55,
                               a: pad.buttonA.isPressed, b: pad.buttonB.isPressed,
                               lb: pad.leftShoulder.isPressed, rb: pad.rightShoulder.isPressed)
    }
}

struct LEDColor: Identifiable, Equatable {
    let id: String
    let label: String
    let red: Double
    let green: Double
    let blue: Double

    static let all: [LEDColor] = [
        LEDColor(id: "off", label: "Off", red: 0, green: 0, blue: 0),
        LEDColor(id: "white", label: "White", red: 1, green: 1, blue: 1),
        LEDColor(id: "red", label: "Red", red: 1, green: 0, blue: 0),
        LEDColor(id: "green", label: "Green", red: 0, green: 1, blue: 0),
        LEDColor(id: "blue", label: "Blue", red: 0, green: 0, blue: 1),
        LEDColor(id: "cyan", label: "Cyan", red: 0, green: 1, blue: 1),
        LEDColor(id: "magenta", label: "Magenta", red: 1, green: 0, blue: 1),
        LEDColor(id: "yellow", label: "Yellow", red: 1, green: 1, blue: 0),
        LEDColor(id: "orange", label: "Orange", red: 1, green: 0.5, blue: 0),
        LEDColor(id: "purple", label: "Purple", red: 0.5, green: 0, blue: 1),
    ]
}
