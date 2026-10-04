//
//  ControllerModels.swift
//  Mac XCloud
//
//  Typed, persistable models used by the native controller feature layer.
//

import Foundation

// MARK: - Controller identity and capabilities

struct ControllerDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var vendorName: String
    var productCategory: String
    var playerIndex: Int?
    var isAttachedToDevice: Bool

    init(
        id: String = UUID().uuidString,
        vendorName: String = "Game Controller",
        productCategory: String = "Game Controller",
        playerIndex: Int? = nil,
        isAttachedToDevice: Bool = false
    ) {
        self.id = id
        self.vendorName = vendorName
        self.productCategory = productCategory
        self.playerIndex = playerIndex
        self.isAttachedToDevice = isAttachedToDevice
    }
}

struct ControllerCapabilities: Codable, Equatable, Sendable {
    var hasExtendedGamepad: Bool
    var hasTouchpad: Bool
    var supportsTwoFingerTouch: Bool
    var hasAdaptiveTriggers: Bool
    var hasHaptics: Bool
    var hapticLocalities: [HapticLocality]
    var hasLight: Bool
    var hasBattery: Bool
    var hasMenuButton: Bool
    var hasOptionsButton: Bool
    var hasHomeButton: Bool
    var hasThumbstickButtons: Bool

    static let unavailable = ControllerCapabilities(
        hasExtendedGamepad: false,
        hasTouchpad: false,
        supportsTwoFingerTouch: false,
        hasAdaptiveTriggers: false,
        hasHaptics: false,
        hapticLocalities: [],
        hasLight: false,
        hasBattery: false,
        hasMenuButton: false,
        hasOptionsButton: false,
        hasHomeButton: false,
        hasThumbstickButtons: false
    )
}

// MARK: - Input snapshot

struct ControllerVector2: Codable, Equatable, Sendable {
    var x: Float
    var y: Float

    static let zero = ControllerVector2(x: 0, y: 0)

    var magnitude: Float { (x * x + y * y).squareRoot() }
}

struct ControllerButtonState: Codable, Equatable, Sendable {
    var value: Float
    var isPressed: Bool

    init(value: Float = 0, isPressed: Bool? = nil) {
        self.value = min(max(value, 0), 1)
        self.isPressed = isPressed ?? (value > 0.5)
    }

    static let released = ControllerButtonState()
}

struct ControllerButtonsSnapshot: Codable, Equatable, Sendable {
    var a: ControllerButtonState = .released
    var b: ControllerButtonState = .released
    var x: ControllerButtonState = .released
    var y: ControllerButtonState = .released
    var menu: ControllerButtonState = .released
    var options: ControllerButtonState = .released
    var home: ControllerButtonState = .released
    var leftShoulder: ControllerButtonState = .released
    var rightShoulder: ControllerButtonState = .released
    var leftStick: ControllerButtonState = .released
    var rightStick: ControllerButtonState = .released
    var dpadUp: ControllerButtonState = .released
    var dpadDown: ControllerButtonState = .released
    var dpadLeft: ControllerButtonState = .released
    var dpadRight: ControllerButtonState = .released
    var touchpad: ControllerButtonState = .released

    static let released = ControllerButtonsSnapshot()

    subscript(control: ControllerControl) -> ControllerButtonState {
        switch control {
        case .buttonA: return a
        case .buttonB: return b
        case .buttonX: return x
        case .buttonY: return y
        case .menu: return menu
        case .options: return options
        case .home: return home
        case .leftShoulder: return leftShoulder
        case .rightShoulder: return rightShoulder
        case .leftStickButton: return leftStick
        case .rightStickButton: return rightStick
        case .dpadUp: return dpadUp
        case .dpadDown: return dpadDown
        case .dpadLeft: return dpadLeft
        case .dpadRight: return dpadRight
        case .touchpadButton: return touchpad
        case .leftTrigger, .rightTrigger: return .released
        }
    }
}

struct ControllerTouchPoint: Codable, Equatable, Sendable {
    var isActive: Bool
    var position: ControllerVector2

    static let inactive = ControllerTouchPoint(isActive: false, position: .zero)
}

struct ControllerBatterySnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case unknown
        case discharging
        case charging
        case full
    }

    var level: Float
    var state: State
}

struct ControllerInputSnapshot: Codable, Equatable, Sendable {
    var timestamp: TimeInterval
    var leftStick: ControllerVector2
    var rightStick: ControllerVector2
    var leftTrigger: Float
    var rightTrigger: Float
    var buttons: ControllerButtonsSnapshot
    var primaryTouch: ControllerTouchPoint
    var secondaryTouch: ControllerTouchPoint
    var battery: ControllerBatterySnapshot?

    static let empty = ControllerInputSnapshot(
        timestamp: 0,
        leftStick: .zero,
        rightStick: .zero,
        leftTrigger: 0,
        rightTrigger: 0,
        buttons: .released,
        primaryTouch: .inactive,
        secondaryTouch: .inactive,
        battery: nil
    )
}

// MARK: - Calibration and response curves

enum ResponseCurve: Codable, Equatable, Hashable, Sendable {
    case linear
    case exponential(exponent: Float)
    case sCurve(strength: Float)
    case custom(points: [ResponseCurvePoint])

    func apply(to input: Float) -> Float {
        let value = min(max(input, 0), 1)
        switch self {
        case .linear:
            return value
        case .exponential(let exponent):
            return powf(value, min(max(exponent, 0.1), 5))
        case .sCurve(let strength):
            let blend = min(max(strength, 0), 1)
            let smooth = value * value * (3 - 2 * value)
            return value + (smooth - value) * blend
        case .custom(let points):
            let normalized = ResponseCurvePoint.normalized(points)
            guard let upperIndex = normalized.firstIndex(where: { $0.input >= value }) else {
                return normalized.last?.output ?? value
            }
            guard upperIndex > 0 else { return normalized[upperIndex].output }
            let lower = normalized[upperIndex - 1]
            let upper = normalized[upperIndex]
            let width = max(upper.input - lower.input, 0.0001)
            let fraction = (value - lower.input) / width
            return lower.output + ((upper.output - lower.output) * fraction)
        }
    }
}

struct ResponseCurvePoint: Codable, Equatable, Hashable, Sendable {
    var input: Float
    var output: Float

    fileprivate static func normalized(_ points: [ResponseCurvePoint]) -> [ResponseCurvePoint] {
        let clamped = points.map {
            ResponseCurvePoint(input: min(max($0.input, 0), 1), output: min(max($0.output, 0), 1))
        }.sorted { $0.input < $1.input }
        return clamped.isEmpty
            ? [ResponseCurvePoint(input: 0, output: 0), ResponseCurvePoint(input: 1, output: 1)]
            : clamped
    }
}

struct StickCalibration: Codable, Equatable, Sendable {
    var center: ControllerVector2
    var minimum: ControllerVector2
    var maximum: ControllerVector2
    var innerDeadzone: Float
    var outerDeadzone: Float
    var invertX: Bool
    var invertY: Bool
    var responseCurve: ResponseCurve

    static let `default` = StickCalibration(
        center: .zero,
        minimum: ControllerVector2(x: -1, y: -1),
        maximum: ControllerVector2(x: 1, y: 1),
        innerDeadzone: 0.08,
        outerDeadzone: 0.02,
        invertX: false,
        invertY: false,
        responseCurve: .linear
    )

    func apply(to rawValue: ControllerVector2) -> ControllerVector2 {
        let normalizedX = Self.normalize(rawValue.x, center: center.x, minimum: minimum.x, maximum: maximum.x)
        let normalizedY = Self.normalize(rawValue.y, center: center.y, minimum: minimum.y, maximum: maximum.y)
        let inverted = ControllerVector2(x: invertX ? -normalizedX : normalizedX, y: invertY ? -normalizedY : normalizedY)
        let magnitude = min(inverted.magnitude, 1)
        let inner = min(max(innerDeadzone, 0), 0.95)
        let outer = min(max(outerDeadzone, 0), 0.95)
        guard magnitude > inner, magnitude > 0 else { return .zero }
        let usableRange = max(1 - inner - outer, 0.01)
        let deadzonedMagnitude = min((magnitude - inner) / usableRange, 1)
        let curvedMagnitude = responseCurve.apply(to: deadzonedMagnitude)
        let scale = curvedMagnitude / magnitude
        return ControllerVector2(
            x: min(max(inverted.x * scale, -1), 1),
            y: min(max(inverted.y * scale, -1), 1)
        )
    }

    private static func normalize(_ value: Float, center: Float, minimum: Float, maximum: Float) -> Float {
        if value >= center {
            return min(max((value - center) / max(maximum - center, 0.001), 0), 1)
        }
        return max(min((value - center) / max(center - minimum, 0.001), 0), -1)
    }
}

struct TriggerCalibration: Codable, Equatable, Sendable {
    var minimum: Float
    var maximum: Float
    var deadzone: Float
    var outerDeadzone: Float
    var responseCurve: ResponseCurve

    static let `default` = TriggerCalibration(
        minimum: 0,
        maximum: 1,
        deadzone: 0.02,
        outerDeadzone: 0.02,
        responseCurve: .linear
    )

    func apply(to rawValue: Float) -> Float {
        let normalized = min(max((rawValue - minimum) / max(maximum - minimum, 0.001), 0), 1)
        let lower = min(max(deadzone, 0), 0.95)
        let upper = min(max(outerDeadzone, 0), 0.95)
        guard normalized > lower else { return 0 }
        let adjusted = min((normalized - lower) / max(1 - lower - upper, 0.01), 1)
        return responseCurve.apply(to: adjusted)
    }
}

struct ControllerCalibration: Codable, Equatable, Sendable {
    var leftStick: StickCalibration
    var rightStick: StickCalibration
    var leftTrigger: TriggerCalibration
    var rightTrigger: TriggerCalibration

    static let `default` = ControllerCalibration(
        leftStick: .default,
        rightStick: .default,
        leftTrigger: .default,
        rightTrigger: .default
    )
}

enum ControllerCalibrationKind: String, Codable, CaseIterable, Sendable {
    case stickCenters
    case stickFullRange
    case triggers
}

struct ControllerCalibrationProgress: Codable, Equatable, Sendable {
    var kind: ControllerCalibrationKind
    var progress: Double
    var sampleCount: Int
}

// MARK: - Adaptive triggers

enum AdaptiveTriggerPreset: String, CaseIterable, Sendable, Codable {
    case off
    case pistol
    case sniper
    case automatic
    case machineGun
    case bow
    case accelerator
    case brake
    case twoStage
    case stiffSpring
    case softSpring
    case heartbeat
    case galloping
    case choppy

    init(from decoder: Decoder) throws {
        self = Self.migrated(try decoder.singleValueContainer().decode(String.self))
    }

    /// Effect names written by builds before the curated catalog (1.3.7).
    nonisolated private static let legacyNames: [String: AdaptiveTriggerPreset] = [
        "verySoftTrigger": .softSpring, "softTrigger": .softSpring, "softDetent": .softSpring,
        "mediumTrigger": .stiffSpring, "resistanceTrigger": .stiffSpring, "feedback": .stiffSpring,
        "engineStrain": .stiffSpring, "doorResistance": .stiffSpring, "shield": .stiffSpring, "flashlight": .stiffSpring,
        "hardTrigger": .stiffSpring, "veryHardTrigger": .stiffSpring, "hardestTrigger": .stiffSpring, "rigidTrigger": .stiffSpring,
        "acceleration": .accelerator, "acceleratorPedal": .accelerator,
        "deceleration": .brake, "braking": .brake, "brakePedal": .brake, "hydraulicBrake": .brake, "clutchBite": .brake,
        "weapon": .pistol, "pistolFire": .pistol, "handgun": .pistol, "revolver": .pistol, "rifle": .pistol,
        "shotgunFire": .pistol, "crossbow": .pistol, "precisionBreak": .pistol,
        "sniperFire": .sniper, "gameCubeTrigger": .twoStage, "twoStagePull": .twoStage, "stagedWall": .twoStage,
        "smgFire": .automatic, "automaticWeapon": .automatic, "automaticGun": .automatic, "vibration": .automatic,
        "vibrateTriggerPulse": .automatic, "vibrateTriggerTenIntensity": .automatic, "vibrateTriggerCustomIntensity": .automatic,
        "progressiveRecoil": .machineGun,
        "bowAndArrow": .bow, "bowDraw": .bow, "archery": .bow, "bowTrigger": .bow, "fishing": .bow,
        "choppyTrigger": .choppy, "chainsaw": .choppy, "motorStart": .choppy, "electricShock": .choppy,
        "rain": .choppy, "triggerJam": .choppy,
    ]

    nonisolated static func migrated(_ value: String) -> Self {
        if let current = Self(rawValue: value) { return current }
        if let mapped = legacyNames[value] { return mapped }
        let legacy = value.lowercased()
        if legacy.contains("gun") || legacy.contains("pistol") || legacy.contains("sniper") || legacy.contains("shotgun") {
            return legacy.contains("automatic") || legacy.contains("machine") || legacy.contains("smg") ? .automatic : .pistol
        }
        if legacy.contains("bow") || legacy.contains("archery") { return .bow }
        if legacy.contains("accel") || legacy.contains("gas") { return .accelerator }
        if legacy.contains("brake") || legacy.contains("clutch") { return .brake }
        if legacy.contains("twostage") || legacy.contains("staged") || legacy.contains("detent") { return .twoStage }
        return .off
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AdaptiveTriggerPreset {
    var htmlName: String {
        switch self {
        case .off: "Off"
        case .pistol: "Pistol / Rifle"
        case .sniper: "Sniper (Heavy Break)"
        case .automatic: "Automatic Weapon (Fast)"
        case .machineGun: "Heavy Machine Gun (Slow)"
        case .bow: "Bow & Arrow"
        case .accelerator: "Accelerator Pedal"
        case .brake: "Brake Pedal"
        case .twoStage: "Two-Stage (Aim & Fire)"
        case .stiffSpring: "Stiff Spring (Heavy)"
        case .softSpring: "Soft Spring (Light)"
        case .heartbeat: "Heartbeat Pulse"
        case .galloping: "Galloping / Footsteps"
        case .choppy: "Choppy / Grinding"
        }
    }

    static let recommendedCatalog: [AdaptiveTriggerPreset] = [
        .off, .pistol, .sniper, .automatic, .machineGun, .bow, .twoStage,
        .accelerator, .brake, .stiffSpring, .softSpring, .heartbeat, .galloping, .choppy
    ]
}

enum AdaptiveTriggerEffectMode: String, Codable, CaseIterable, Sendable {
    case off
    case feedback
    case weapon
    case vibration
    case slopeFeedback
    case resistanceCurve
    case vibrationRamp
    case twoStageFeedback
    case detent

    var hasEndPosition: Bool {
        self == .weapon || self == .slopeFeedback || self == .resistanceCurve || self == .vibrationRamp || self == .twoStageFeedback || self == .detent
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .feedback: return "Constant resistance"
        case .weapon: return "Break & release"
        case .vibration: return "Vibration"
        case .slopeFeedback: return "Linear resistance"
        case .resistanceCurve: return "Smooth resistance curve"
        case .vibrationRamp: return "Travel-based vibration"
        case .twoStageFeedback: return "Two-stage resistance"
        case .detent: return "Detent & release"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "No motor resistance; the trigger keeps its physical spring."
        case .feedback: return "Constant resistance after the start position, held through full pull."
        case .weapon: return "Resistance between two positions, then a deliberate release at the breakpoint."
        case .vibration: return "A steady vibration after the start position. Frequency is relative, not Hz."
        case .slopeFeedback: return "Linear resistance between start and end; feedback ends beyond the end position."
        case .resistanceCurve: return "Smoothly builds resistance across ten travel zones and holds the ending force through full pull."
        case .twoStageFeedback: return "First-stage resistance begins at start; second-stage resistance begins at end and holds through full pull."
        case .detent: return "Resistance rises toward the end position, then releases to the ending force. Uses ten hardware travel zones."
        case .vibrationRamp: return "Vibration grows with trigger travel and holds its peak beyond the ramp end. Frequency is relative, not Hz."
        }
    }
}

struct AdaptiveTriggerCustomParameters: Codable, Equatable, Sendable {
    var mode: AdaptiveTriggerEffectMode
    var startPosition: Float
    var endPosition: Float
    var startStrength: Float
    var endStrength: Float
    var amplitude: Float
    var frequency: Float

    static let `default` = AdaptiveTriggerCustomParameters(
        mode: .feedback,
        startPosition: 0.25,
        endPosition: 0.85,
        startStrength: 0.35,
        endStrength: 0.85,
        amplitude: 0.5,
        frequency: 0.5
    )

    var clamped: AdaptiveTriggerCustomParameters {
        var value = self
        func unit(_ input: Float, fallback: Float) -> Float {
            min(max(input.isFinite ? input : fallback, 0), 1)
        }
        value.startPosition = unit(startPosition, fallback: Self.default.startPosition)
        value.endPosition = unit(endPosition, fallback: Self.default.endPosition)
        // Only bounded effects require end > start. Leave room for a valid end.
        if mode.hasEndPosition {
            value.startPosition = min(value.startPosition, 0.99)
            value.endPosition = max(value.endPosition, value.startPosition + 0.01)
        }
        value.startStrength = unit(startStrength, fallback: Self.default.startStrength)
        value.endStrength = unit(endStrength, fallback: Self.default.endStrength)
        value.amplitude = unit(amplitude, fallback: Self.default.amplitude)
        value.frequency = unit(frequency, fallback: Self.default.frequency)
        return value
    }

    func level(at position: Float) -> Float {
        let value = clamped
        guard position >= value.startPosition else { return 0 }
        let progress = min(max((position - value.startPosition) / max(0.01, value.endPosition - value.startPosition), 0), 1)
        switch value.mode {
        case .off: return 0
        case .feedback: return value.startStrength
        case .weapon: return position < value.endPosition ? value.startStrength : 0
        case .vibration: return value.amplitude
        case .slopeFeedback:
            return position <= value.endPosition ? value.startStrength + (value.endStrength - value.startStrength) * progress : 0
        case .resistanceCurve:
            let smooth = progress * progress * (3 - 2 * progress)
            return value.startStrength + (value.endStrength - value.startStrength) * smooth
        case .twoStageFeedback:
            return position < value.endPosition ? value.startStrength : value.endStrength
        case .detent:
            return position < value.endPosition ? value.startStrength * progress : value.endStrength
        case .vibrationRamp:
            return value.amplitude * progress
        }
    }

    var travelLevels: [Float] { (0..<10).map { level(at: Float($0) / 9) } }
}

enum AdaptiveTriggerSide: String, CaseIterable, Sendable {
    case left, right
}

/// A library reference is selection metadata; the applied effect is always a snapshot.
enum AdaptiveTriggerSelection: Hashable, Sendable {
    case builtIn(AdaptiveTriggerPreset)
    case custom(UUID)
    case currentCustomSnapshot
}


struct AdaptiveTriggerSettings: Codable, Equatable, Sendable {
    var leftPreset: AdaptiveTriggerPreset
    var rightPreset: AdaptiveTriggerPreset

    static let `default` = AdaptiveTriggerSettings(
        leftPreset: .off,
        rightPreset: .off
    )

    private enum CodingKeys: String, CodingKey {
        case leftPreset, rightPreset
    }

    init(leftPreset: AdaptiveTriggerPreset, rightPreset: AdaptiveTriggerPreset) {
        self.leftPreset = leftPreset
        self.rightPreset = rightPreset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftPreset = try container.decodeIfPresent(AdaptiveTriggerPreset.self, forKey: .leftPreset) ?? .off
        rightPreset = try container.decodeIfPresent(AdaptiveTriggerPreset.self, forKey: .rightPreset) ?? .off
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leftPreset, forKey: .leftPreset)
        try container.encode(rightPreset, forKey: .rightPreset)
    }

    mutating func select(_ preset: AdaptiveTriggerPreset, for side: AdaptiveTriggerSide) {
        if side == .left {
            leftPreset = preset
        } else {
            rightPreset = preset
        }
    }
}

// MARK: - Haptics

enum HapticMode: String, Codable, CaseIterable, Sendable {
    case off
    case standard
    case amplified
}

enum HapticLocality: String, Codable, CaseIterable, Sendable {
    case `default`
    case all
    case handles
    case leftHandle
    case rightHandle
    case triggers
    case leftTrigger
    case rightTrigger
}

struct HapticSettings: Codable, Equatable, Sendable {
    var mode: HapticMode
    var intensityMultiplier: Float
    var sharpness: Float
    var preferredLocality: HapticLocality

    static let `default` = HapticSettings(
        mode: .standard,
        intensityMultiplier: 1,
        sharpness: 0.5,
        preferredLocality: .default
    )
}

// MARK: - Touchpad gestures and actions

enum TouchpadGesture: String, Codable, CaseIterable, Sendable {
    case tap
    case doubleTap
    case longPress
    case swipeUp
    case swipeDown
    case swipeLeft
    case swipeRight
    case twoFingerTap
}

enum ControllerNativeAction: Codable, Equatable, Hashable, Sendable {
    case none
    case toggleSettings
    case toggleFullscreen
    case screenshot
    case toggleStats
    case volumeUp
    case volumeDown
    case mute
    case custom(identifier: String)
    case macro(id: UUID)
}

struct TouchpadActionMapping: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var gesture: TouchpadGesture
    var action: ControllerNativeAction
    var isEnabled: Bool

    init(id: UUID = UUID(), gesture: TouchpadGesture, action: ControllerNativeAction, isEnabled: Bool = true) {
        self.id = id
        self.gesture = gesture
        self.action = action
        self.isEnabled = isEnabled
    }
}

struct TouchpadSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var tapMaximumDuration: TimeInterval
    var doubleTapInterval: TimeInterval
    var longPressDuration: TimeInterval
    var swipeMinimumDistance: Float
    var mappings: [TouchpadActionMapping]

    static let `default` = TouchpadSettings(
        isEnabled: true,
        tapMaximumDuration: 0.25,
        doubleTapInterval: 0.32,
        longPressDuration: 0.65,
        swipeMinimumDistance: 0.45,
        mappings: [
            TouchpadActionMapping(gesture: .twoFingerTap, action: .toggleSettings),
            TouchpadActionMapping(gesture: .swipeUp, action: .toggleStats),
            TouchpadActionMapping(gesture: .swipeDown, action: .toggleFullscreen),
        ]
    )
}

// MARK: - Category presets

enum ControllerCategoryPreset: String, Codable, CaseIterable, Sendable {
    case custom
    case racing
    case simulation
    case shooter
    case platformer
    case story
}

struct ControllerCategoryPresetSettings: Codable, Equatable, Sendable {
    var selectedPreset: ControllerCategoryPreset
    var applyStickCurves: Bool
    var applyTriggerCurves: Bool
    var applyAdaptiveTriggers: Bool
    var applyHaptics: Bool

    static let `default` = ControllerCategoryPresetSettings(
        selectedPreset: .custom,
        applyStickCurves: true,
        applyTriggerCurves: true,
        applyAdaptiveTriggers: true,
        applyHaptics: true
    )
}

// MARK: - Shortcuts and constrained macros

enum ControllerControl: String, Codable, CaseIterable, Hashable, Sendable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case menu
    case options
    case home
    case leftShoulder
    case rightShoulder
    case leftStickButton
    case rightStickButton
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case touchpadButton
    case leftTrigger
    case rightTrigger
}

enum ShortcutActivation: Codable, Equatable, Sendable {
    case press
    case release
    case hold(seconds: TimeInterval)
    case doublePress(maximumInterval: TimeInterval)
}

struct ControllerShortcut: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var controls: Set<ControllerControl>
    var activation: ShortcutActivation
    var action: ControllerNativeAction
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        controls: Set<ControllerControl>,
        activation: ShortcutActivation = .press,
        action: ControllerNativeAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.controls = controls
        self.activation = activation
        self.action = action
        self.isEnabled = isEnabled
    }

    /// Validate edited shortcuts without changing the legacy Codable layout.
    func validate() throws {
        guard !controls.isEmpty else { throw ControllerShortcutValidationError.emptyChord }
        switch activation {
        case .press, .release: break
        case .hold(let seconds), .doublePress(let seconds):
            guard seconds.isFinite, (0.05...60).contains(seconds) else {
                throw ControllerShortcutValidationError.invalidTiming
            }
        }
    }
}

enum ControllerShortcutValidationError: Error, LocalizedError, Equatable {
    case emptyChord
    case invalidTiming

    var errorDescription: String? {
        switch self {
        case .emptyChord: return "Select at least one controller button."
        case .invalidTiming: return "Hold and double-press timing must be a finite number from 0.05 to 60 seconds."
        }
    }
}

struct ControllerShortcutSchema: Codable, Equatable, Sendable {
    var shortcuts: [ControllerShortcut]
    var consumeMatchedShortcuts: Bool

    static let `default` = ControllerShortcutSchema(shortcuts: [], consumeMatchedShortcuts: false)
}

enum ControllerMacroAction: Codable, Equatable, Sendable {
    case button(control: ControllerControl, isPressed: Bool)
    case haptic(intensity: Float, sharpness: Float, durationMilliseconds: Int)
    case nativeAction(ControllerNativeAction)
}

struct ControllerMacroStep: Codable, Equatable, Sendable {
    var delayMilliseconds: Int
    var action: ControllerMacroAction

    init(delayMilliseconds: Int, action: ControllerMacroAction) {
        self.delayMilliseconds = delayMilliseconds
        self.action = action
    }
}

enum ControllerMacroValidationError: Error, LocalizedError, Equatable {
    case tooManySteps(maximum: Int)
    case negativeDelay
    case durationExceeded(maximumMilliseconds: Int)
    case invalidHapticDuration
    case invalidHapticParameters
    case nestedMacro

    var errorDescription: String? {
        switch self {
        case .tooManySteps(let maximum): return "A macro can contain at most \(maximum) steps."
        case .negativeDelay: return "Macro step delays cannot be negative."
        case .durationExceeded(let maximum): return "A macro cannot exceed \(maximum) milliseconds."
        case .invalidHapticDuration: return "Haptic macro durations must be between 0 and 2000 milliseconds."
        case .invalidHapticParameters: return "Haptic intensity and sharpness must be finite numbers between 0 and 1."
        case .nestedMacro: return "Macros cannot run another macro."
        }
    }
}

struct ControllerMacro: Codable, Equatable, Identifiable, Sendable {
    static let maximumStepCount = 16
    static let maximumDurationMilliseconds = 2_000

    var id: UUID
    var name: String
    private(set) var steps: [ControllerMacroStep]

    init(id: UUID = UUID(), name: String, steps: [ControllerMacroStep]) throws {
        self.id = id
        self.name = name
        self.steps = steps
        try validate()
    }

    var totalDurationMilliseconds: Int {
        steps.reduce(0) { partial, step in
            let hapticDuration: Int
            if case .haptic(_, _, let duration) = step.action {
                hapticDuration = duration
            } else {
                hapticDuration = 0
            }
            return partial + step.delayMilliseconds + hapticDuration
        }
    }

    mutating func replaceSteps(_ newSteps: [ControllerMacroStep]) throws {
        let oldSteps = steps
        steps = newSteps
        do {
            try validate()
        } catch {
            steps = oldSteps
            throw error
        }
    }

    func validate() throws {
        guard steps.count <= Self.maximumStepCount else {
            throw ControllerMacroValidationError.tooManySteps(maximum: Self.maximumStepCount)
        }
        guard steps.allSatisfy({ $0.delayMilliseconds >= 0 }) else {
            throw ControllerMacroValidationError.negativeDelay
        }
        // Bound each component before adding it, including decoded values such as Int.max.
        var remaining = Self.maximumDurationMilliseconds
        for step in steps {
            guard step.delayMilliseconds <= remaining else {
                throw ControllerMacroValidationError.durationExceeded(maximumMilliseconds: Self.maximumDurationMilliseconds)
            }
            remaining -= step.delayMilliseconds
            if case .haptic(let intensity, let sharpness, let duration) = step.action {
                guard intensity.isFinite, sharpness.isFinite,
                      (0...1).contains(intensity), (0...1).contains(sharpness) else {
                    throw ControllerMacroValidationError.invalidHapticParameters
                }
                guard (0...Self.maximumDurationMilliseconds).contains(duration) else {
                    throw ControllerMacroValidationError.invalidHapticDuration
                }
                guard duration <= remaining else {
                    throw ControllerMacroValidationError.durationExceeded(maximumMilliseconds: Self.maximumDurationMilliseconds)
                }
                remaining -= duration
            }
            if case .nativeAction(.macro) = step.action {
                throw ControllerMacroValidationError.nestedMacro
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case id, name, steps }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decode([ControllerMacroStep].self, forKey: .steps)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: error.localizedDescription)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(steps, forKey: .steps)
    }
}

// MARK: - LED

struct ControllerLEDColor: Codable, Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float

    static let off = ControllerLEDColor(red: 0, green: 0, blue: 0)
    static let white = ControllerLEDColor(red: 1, green: 1, blue: 1)

    var clamped: ControllerLEDColor {
        ControllerLEDColor(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1)
        )
    }
}

enum ControllerLEDMode: String, Codable, CaseIterable, Sendable {
    case system
    case off
    case fixedColor
    case batteryLevel
}

enum ControllerLEDBatteryPolicy: String, Codable, CaseIterable, Sendable {
    case ignore
    case dimWhenLow
    case redWhenLow
    case turnOffWhenLow
}

struct ControllerLEDSettings: Codable, Equatable, Sendable {
    var mode: ControllerLEDMode
    var color: ControllerLEDColor
    var brightness: Float
    var batteryPolicy: ControllerLEDBatteryPolicy
    var lowBatteryThreshold: Float

    static let `default` = ControllerLEDSettings(
        mode: .system,
        color: .white,
        brightness: 1,
        batteryPolicy: .redWhenLow,
        lowBatteryThreshold: 0.2
    )
}

// MARK: - Persisted settings root

/// Settings safe to move between controllers and devices. Hardware calibration
/// remains local because centers and ranges are specific to one physical device.
struct PerPresetControllerSettings: Codable, Equatable, Sendable {
    var adaptiveTriggers: AdaptiveTriggerSettings
    var haptics: HapticSettings
    var touchpad: TouchpadSettings
    var categoryPreset: ControllerCategoryPresetSettings
    var shortcuts: ControllerShortcutSchema
    var macros: [ControllerMacro]
    var led: ControllerLEDSettings
    var enhancements: ControllerEnhancements? = nil

    static let `default` = PerPresetControllerSettings(
        adaptiveTriggers: .default,
        haptics: .default,
        touchpad: .default,
        categoryPreset: .default,
        shortcuts: .default,
        macros: [],
        led: .default
    )
}

struct ControllerSettings: Codable, Equatable, Sendable {
    var calibration: ControllerCalibration
    var adaptiveTriggers: AdaptiveTriggerSettings
    var haptics: HapticSettings
    var touchpad: TouchpadSettings
    var categoryPreset: ControllerCategoryPresetSettings
    var shortcuts: ControllerShortcutSchema
    var macros: [ControllerMacro]
    var led: ControllerLEDSettings
    var enhancements: ControllerEnhancements? = nil

    static let `default` = ControllerSettings(
        calibration: .default,
        adaptiveTriggers: .default,
        haptics: .default,
        touchpad: .default,
        categoryPreset: .default,
        shortcuts: .default,
        macros: [],
        led: .default
    )

    var perPreset: PerPresetControllerSettings {
        PerPresetControllerSettings(
            adaptiveTriggers: adaptiveTriggers,
            haptics: haptics,
            touchpad: touchpad,
            categoryPreset: categoryPreset,
            shortcuts: shortcuts,
            macros: macros,
            led: led,
            enhancements: enhancements
        )
    }

    private enum CodingKeys: String, CodingKey {
        case calibration, adaptiveTriggers, haptics, touchpad, categoryPreset, shortcuts, macros, led, enhancements
    }

    // Per-field fallback decoding: a payload written by an older or newer
    // build (missing/renamed field) keeps every section it does understand
    // instead of failing the whole decode and silently reverting the user to
    // defaults. The custom init suppresses the implicit memberwise one, so
    // declare it for the `default` factory.
    init(
        calibration: ControllerCalibration,
        adaptiveTriggers: AdaptiveTriggerSettings,
        haptics: HapticSettings,
        touchpad: TouchpadSettings,
        categoryPreset: ControllerCategoryPresetSettings,
        shortcuts: ControllerShortcutSchema,
        macros: [ControllerMacro],
        led: ControllerLEDSettings,
        enhancements: ControllerEnhancements? = nil
    ) {
        self.calibration = calibration
        self.adaptiveTriggers = adaptiveTriggers
        self.haptics = haptics
        self.touchpad = touchpad
        self.categoryPreset = categoryPreset
        self.shortcuts = shortcuts
        self.macros = macros
        self.led = led
        self.enhancements = enhancements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calibration = (try? c.decode(ControllerCalibration.self, forKey: .calibration)) ?? .default
        adaptiveTriggers = (try? c.decode(AdaptiveTriggerSettings.self, forKey: .adaptiveTriggers)) ?? .default
        haptics = (try? c.decode(HapticSettings.self, forKey: .haptics)) ?? .default
        touchpad = (try? c.decode(TouchpadSettings.self, forKey: .touchpad)) ?? .default
        categoryPreset = (try? c.decode(ControllerCategoryPresetSettings.self, forKey: .categoryPreset)) ?? .default
        shortcuts = (try? c.decode(ControllerShortcutSchema.self, forKey: .shortcuts)) ?? .default
        macros = (try? c.decode([ControllerMacro].self, forKey: .macros)) ?? []
        led = (try? c.decode(ControllerLEDSettings.self, forKey: .led)) ?? .default
        enhancements = try? c.decodeIfPresent(ControllerEnhancements.self, forKey: .enhancements)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calibration, forKey: .calibration)
        try c.encode(adaptiveTriggers, forKey: .adaptiveTriggers)
        try c.encode(haptics, forKey: .haptics)
        try c.encode(touchpad, forKey: .touchpad)
        try c.encode(categoryPreset, forKey: .categoryPreset)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(macros, forKey: .macros)
        try c.encode(led, forKey: .led)
        try c.encodeIfPresent(enhancements, forKey: .enhancements)
    }

    mutating func apply(_ preset: PerPresetControllerSettings) {
        adaptiveTriggers = preset.adaptiveTriggers
        haptics = preset.haptics
        touchpad = preset.touchpad
        categoryPreset = preset.categoryPreset
        shortcuts = preset.shortcuts
        macros = preset.macros
        led = preset.led
        enhancements = preset.enhancements
    }
}

// Optional in older profiles: absent values fall back to the current
// defaults. Every field added after the first release is optional, so a
// profile written by any earlier build still decodes.
//
// Field history worth knowing:
// • steeringRangeDegrees / steeringDeadzoneDegrees are legacy names, read
//   only to migrate user-tuned values into steeringAngleDegrees /
//   steeringPhysicalDeadzone.
// • steeringExponent keeps its meaning (response curve) but is applied with
//   a linear knee at center, so values below 1 no longer amplify noise.
// • gyroAimOnly (non-optional, always encoded) is superseded by
//   gyroActivation; profiles that never chose an activation keep the L2-only
//   behavior they had.
// • gyroOutputFloor is the right-stick dead-zone compensation shared by gyro
//   and touchpad aiming (nil = recommended default).
// • gyroNoiseThreshold / touchpadMouseMode / gyroTiltMode are retired and
//   decoded only so old files keep round-tripping.
struct ControllerEnhancements: Codable, Equatable, Sendable {
    var touchpadAimEnabled = false
    var touchpadSensitivity: Float? = nil
    var touchpadResponseExponent: Float? = nil
    var touchpadFiltering: Float? = nil
    var touchpadMouseMode: Bool? = nil
    var touchpadAcceleration: Float? = nil
    var touchpadInvertY: Bool? = nil
    var gyroEnabled = false
    var gyroTiltMode: Bool? = nil
    var gyroFlickMode: Bool? = nil
    var gyroStick: ControllerAimStick? = nil
    var touchpadStick: ControllerAimStick? = nil
    var gyroNoiseThreshold: Float? = nil
    /// Retired switch, kept because every older profile encodes it: those
    /// profiles aimed only while L2 was held and keep doing so until the user
    /// picks an activation. New profiles start with it off.
    var gyroAimOnly = false
    /// Share of full stick per rad/s. 1.0 reaches full stick near 57°/s.
    var gyroSensitivity: Float = 1.0
    var gyroResponseExponent: Float? = nil
    var gyroDeadzone: Float = 0.025
    var gyroOutputFloor: Float? = nil
    var gyroActivation: GyroAimActivation? = nil
    var gyroAcceleration: Float? = nil
    /// Angular speed (degrees/s) below which the hand counts as still.
    var gyroStillThreshold: Float? = nil
    var gyroInvertX: Bool? = nil
    var gyroSmoothing: Float? = nil
    var steeringAngleDegrees: Float? = nil
    var steeringPhysicalDeadzone: Float? = nil
    var steeringRangeDegrees: Float? = nil
    var steeringDeadzoneDegrees: Float? = nil
    var steeringExponent: Float? = nil
    var steeringInverted: Bool? = nil
    var steeringMaximum: Float? = nil
    var steeringRumbleGuard: Bool? = nil
    var steeringAntiDeadzone: Float? = nil
    var steeringSmoothing: Float? = nil
    // Retired with flick shifting; decoded so older profiles round-trip.
    var flickTriggerAngle: Float? = nil
    var flickMinimumVelocity: Float? = nil
    var gyroInvertY = false
    var rapidFireEnabled = false
    var rapidFireRate: Float = 8
    var leftLock = false
    var rightLock = false
    var lockPosition: Float = 0.3
    var rumbleGain: Float = 1
    var rumbleExponent: Float = 1
    var gameDrivenTriggers = false

    // MARK: Recommended defaults

    static let defaultSteeringAngle: Float = 40
    static let defaultAimDeadzoneCompensation: Float = 0.12

    private static func finite(_ value: Float?, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Steering

    var effectiveSteeringRumbleGuard: Bool { steeringRumbleGuard ?? true }
    var effectiveSteeringMaximum: Float { Self.finite(steeringMaximum, 1, 0.2...1) }
    /// Physical rotation per side that reaches full stick output.
    var effectiveSteeringAngleDegrees: Float {
        Self.finite(steeringAngleDegrees ?? steeringRangeDegrees, Self.defaultSteeringAngle, 10...90)
    }
    var effectiveSteeringAngleRadians: Float { effectiveSteeringAngleDegrees * .pi / 180 }
    var effectiveSteeringPhysicalDeadzoneDegrees: Float {
        Self.finite(steeringPhysicalDeadzone ?? steeringDeadzoneDegrees, 0, 0...3)
    }
    var effectiveSteeringExponent: Float { Self.finite(steeringExponent, 1, 0.4...2) }
    var effectiveSteeringAntiDeadzone: Float { Self.finite(steeringAntiDeadzone, 0, 0...0.4) }
    var effectiveSteeringSmoothing: Float { Self.finite(steeringSmoothing, 0.2, 0...1) }

    var steeringResponse: SteeringResponse.Parameters {
        SteeringResponse.Parameters(
            fullLock: Double(effectiveSteeringAngleRadians),
            exponent: Double(effectiveSteeringExponent),
            antiDeadzone: Double(effectiveSteeringAntiDeadzone),
            deadzone: Double(effectiveSteeringPhysicalDeadzoneDegrees) * .pi / 180,
            maximum: Double(effectiveSteeringMaximum),
            inverted: steeringInverted ?? false)
    }

    var steeringConfiguration: SteeringWheelEngine.Configuration {
        SteeringWheelEngine.Configuration(response: steeringResponse,
                                          smoothing: Double(effectiveSteeringSmoothing))
    }

    // MARK: Aiming (gyro + touchpad)

    var effectiveGyroActivation: GyroAimActivation { gyroActivation ?? (gyroAimOnly ? .whileAiming : .always) }
    var effectiveGyroSensitivity: Float { Self.finite(gyroSensitivity, 1, 0.1...4) }
    var effectiveGyroAcceleration: Float { Self.finite(gyroAcceleration, 0, 0...1) }
    var effectiveGyroExponent: Float { Self.finite(gyroResponseExponent, 1, 0.5...2) }
    var effectiveAimDeadzoneCompensation: Float { Self.finite(gyroOutputFloor, Self.defaultAimDeadzoneCompensation, 0...0.4) }
    var effectiveGyroStillThreshold: Float { Self.finite(gyroStillThreshold, 1.4, 0.3...5) }
    var effectiveGyroSmoothing: Float { Self.finite(gyroSmoothing, 0.5, 0...1) }

    var gyroAimConfiguration: GyroAimEngine.Configuration {
        GyroAimEngine.Configuration(
            sensitivity: Double(effectiveGyroSensitivity),
            acceleration: Double(effectiveGyroAcceleration),
            exponent: Double(effectiveGyroExponent),
            antiDeadzone: Double(effectiveAimDeadzoneCompensation),
            stillThreshold: Double(effectiveGyroStillThreshold) * .pi / 180,
            smoothing: Double(effectiveGyroSmoothing),
            invertX: gyroInvertX ?? false,
            invertY: gyroInvertY)
    }

    var effectiveTouchpadSensitivity: Float { Self.finite(touchpadSensitivity, 0.45, 0.05...3) }
    var effectiveTouchpadAcceleration: Float { Self.finite(touchpadAcceleration, 0.5, 0...1) }
    var effectiveTouchpadExponent: Float { Self.finite(touchpadResponseExponent, 1, 0.5...2) }
    var effectiveTouchpadSmoothing: Float { Self.finite(touchpadFiltering, 0.35, 0...1) }

    var touchpadConfiguration: TouchpadCameraEngine.Configuration {
        TouchpadCameraEngine.Configuration(
            sensitivity: Double(effectiveTouchpadSensitivity),
            acceleration: Double(effectiveTouchpadAcceleration),
            exponent: Double(effectiveTouchpadExponent),
            antiDeadzone: Double(effectiveAimDeadzoneCompensation),
            smoothing: Double(effectiveTouchpadSmoothing),
            maximumOutput: 1,
            invertY: touchpadInvertY ?? false)
    }

    // MARK: Modes

    var gyroMode: ControllerGyroMode {
        guard gyroEnabled else { return .off }
        if gyroStick == .left { return .steering }
        // Flick shifting was retired; profiles that used it start with motion off.
        return gyroFlickMode == true ? .off : .aiming
    }
    mutating func setGyroMode(_ mode: ControllerGyroMode) {
        gyroEnabled = mode != .off
        gyroFlickMode = nil
        gyroStick = mode == .steering ? .left : .right
    }

    func rumble(_ value: Float, global: Float) -> Float {
        guard value.isFinite, global.isFinite else { return 0 }
        return min(max(pow(min(max(value, 0), 1), min(max(rumbleExponent, 0.25), 4)) * rumbleGain * global, 0), 1)
    }
}

/// When gyro aiming drives the camera.
enum GyroAimActivation: String, Codable, CaseIterable, Sendable {
    /// Always on while the stream has focus.
    case always
    /// Only while the left trigger is held (aiming down sights).
    case whileAiming

    var title: String {
        switch self {
        case .always: return "Always"
        case .whileAiming: return "While aiming (LT)"
        }
    }
}

/// DualSense standard USB/Bluetooth touch layout documented by SDL's PS5 driver.
/// Decode only full reports. Simplified Bluetooth reports have no touch data.
enum DualSenseTouchPacket {
    static func decode(_ bytes: [UInt8]) -> [ControllerTouchPoint]? {
        let base: Int
        if bytes.count == 64 && bytes.first == 0x01 { base = 1 }
        else if bytes.count == 78 && bytes.first == 0x31 { base = 2 }
        else { return nil }
        var result: [ControllerTouchPoint] = []
        for slot in 0..<2 {
            let offset = base + 32 + slot * 4
            let active = bytes[offset] & 0x80 == 0
            let x = Int(bytes[offset+1]) | ((Int(bytes[offset+2]) & 0x0f) << 8)
            let y = (Int(bytes[offset+2]) >> 4) | (Int(bytes[offset+3]) << 4)
            guard !active || (x < 1920 && y < 1080) else { return nil }
            result.append(ControllerTouchPoint(isActive: active,
                position: active ? ControllerVector2(x: Float(x) / 1919 * 2 - 1, y: 1 - Float(y) / 1079 * 2) : .zero))
        }
        return result
    }
}


enum ControllerAimStick: String, Codable, CaseIterable, Sendable {
    case left, right
    var title: String { self == .left ? "Left stick" : "Right stick" }
    var axisBase: Double { self == .left ? 0 : 2 }
}

/// One picker drives every motion behavior; the stored fields stay per-feature
/// so existing profiles and the injected script keep working unchanged.
enum ControllerGyroMode: String, Codable, CaseIterable, Sendable {
    case off, aiming, steering
    var title: String {
        switch self {
        case .off: return "Off"
        case .aiming: return "Aiming (right stick)"
        case .steering: return "Steering wheel (left stick)"
        }
    }
    /// Which input owner the mode corresponds to (§ ownership arbitration).
    var owner: MotionInputOwner {
        switch self {
        case .off: return .physical
        case .aiming: return .gyroAim
        case .steering: return .steering
        }
    }
}

/// A subtle haptic click as a break-style trigger passes its wall, so the
/// mechanical break of the adaptive trigger is felt crisply in the grip too.
/// Nothing repeats and nothing plays without the trigger moving: effects that
/// pretend to be game events (recoil, heartbeats) belong to the game.
struct ControllerTriggerEnvelope {
    struct Output {
        var intensity: Float = 0
        var duration: Double = 0.02
        var forceBoost: Float = 0
    }
    private var preset: AdaptiveTriggerPreset = .off
    private var previous: Float = 0
    private var armed = true
    private var lastTime: Double?

    /// Pull position (0…1) of the preset's break, or nil for effects without one.
    static func breakPoint(for preset: AdaptiveTriggerPreset) -> Float? {
        switch preset {
        case .pistol: return 0.40
        case .sniper: return 0.60
        case .twoStage: return 0.85
        default: return nil
        }
    }

    mutating func sample(preset mode: AdaptiveTriggerPreset, pressure: Float, now: Double) -> Output {
        guard now.isFinite, pressure.isFinite else { self = Self(); return Output() }
        if mode != preset || lastTime.map({ now - $0 > 0.25 || now < $0 }) == true {
            self = Self(); preset = mode; previous = min(max(pressure, 0), 1)
        }
        lastTime = now
        let p = min(max(pressure, 0), 1)
        defer { previous = p }
        var result = Output()
        guard let wall = Self.breakPoint(for: mode) else { return result }
        if armed, previous < wall, p >= wall {
            result.intensity = 0.45
            armed = false
        } else if p < wall - 0.12 {
            armed = true
        }
        return result
    }
}
