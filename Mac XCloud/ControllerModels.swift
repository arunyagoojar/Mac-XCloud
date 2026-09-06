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
    case feedback
    case weapon
    case bowAndArrow
    case vibration
    case acceleration
    case deceleration
    case engineStrain
    case braking
    case pistolFire
    case shotgunFire
    case smgFire
    case sniperFire
    case galloping
    case machineGun
    case fishing
    case triggerJam
    case doorResistance
    case electricShock
    case heartbeat
    case rain
    case twoStagePull
    case softDetent
    case progressiveRecoil
    case precisionBreak
    case stagedWall
    case clutchBite
    case bowDraw
    case hydraulicBrake
    case ratchetDetents
    case acceleratorPedal, brakePedal, handgun, revolver, rifle, automaticWeapon
    case archery, crossbow, shield, chainsaw, flashlight, motorStart

    init(from decoder: Decoder) throws {
        self = Self.migrated(try decoder.singleValueContainer().decode(String.self))
    }

    static func migrated(_ value: String) -> Self {
        if let current = Self(rawValue: value) { return current }
        // One-way migration for presets saved by earlier native builds.
        return switch value {
        case "softResistance": .feedback
        case "firmResistance": .doorResistance
        case "pistolBreakpoint", "heavyPistol": .pistolFire
        case "shotgunBreak": .shotgunFire
        case "hairTrigger": .triggerJam
        case "triggerLock": .triggerJam
        case "automaticRecoil": .machineGun
        case "smgRapidPulse": .smgFire
        case "burstPulse": .machineGun
        case "flamethrower": .electricShock
        case "bow": .bowAndArrow
        case "accelerator": .acceleration
        case "brakeComfort", "brakeFirm", "absPulse": .braking
        case "platformerEndStop": .feedback
        case "cinematic": .heartbeat
        case "custom": .feedback
        default: .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AdaptiveTriggerCategory: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case racing = "Racing"
    case weapons = "Weapons"
    case specialized = "Specialized"
    case immersive = "Immersive"
    var id: String { rawValue }
}

extension AdaptiveTriggerPreset {
    var htmlName: String {
        switch self {
        case .acceleratorPedal: "Acceleration Pedal"
        case .brakePedal: "Brake Pedal"
        case .handgun: "Pistol / Handgun"
        case .revolver: "Revolver / Heavy Pistol"
        case .rifle: "Rifle"
        case .automaticWeapon: "Automatic Weapon"
        case .archery: "Bow / Archery"
        case .crossbow: "Crossbow"
        case .shield: "Shield"
        case .chainsaw: "Chainsaw"
        case .flashlight: "Flashlight / Light Tool"
        case .motorStart: "Engine / Motor Start"
        case .off: "Off"
        case .feedback: "Feedback"
        case .weapon: "Weapon"
        case .bowAndArrow: "Bow & Arrow"
        case .vibration: "Vibration"
        case .acceleration: "Acceleration"
        case .deceleration: "Deceleration"
        case .engineStrain: "Engine Strain"
        case .braking: "Braking"
        case .pistolFire: "Pistol Fire"
        case .shotgunFire: "Shotgun Fire"
        case .smgFire: "SMG Fire"
        case .sniperFire: "Sniper Fire"
        case .galloping: "Galloping"
        case .machineGun: "Machine Gun"
        case .fishing: "Fishing"
        case .triggerJam: "Trigger Jam"
        case .doorResistance: "Door Resistance"
        case .electricShock: "Electric Shock"
        case .heartbeat: "Heartbeat"
        case .rain: "Rain"
        case .twoStagePull: "Two-stage Pull"
        case .softDetent: "Soft Detent"
        case .progressiveRecoil: "Progressive Recoil"
        case .precisionBreak: "Precision Break"
        case .stagedWall: "Two-stage Wall"
        case .clutchBite: "Clutch Bite"
        case .bowDraw: "Bow Draw & Let-off"
        case .hydraulicBrake: "Hydraulic Brake"
        case .ratchetDetents: "Ratchet Detents"
        }
    }

    var category: AdaptiveTriggerCategory {
        switch self {
        case .acceleratorPedal, .brakePedal, .motorStart: .racing
        case .handgun, .revolver, .rifle, .automaticWeapon, .archery, .crossbow: .weapons
        case .shield, .chainsaw, .flashlight: .immersive
        case .off, .feedback, .weapon, .bowAndArrow, .vibration, .ratchetDetents: .standard
        case .acceleration, .deceleration, .engineStrain, .braking, .clutchBite, .hydraulicBrake: .racing
        case .pistolFire, .shotgunFire, .smgFire, .sniperFire, .twoStagePull, .softDetent, .progressiveRecoil, .precisionBreak, .stagedWall, .bowDraw: .weapons
        case .galloping, .machineGun: .specialized
        case .fishing, .triggerJam, .doorResistance, .electricShock, .heartbeat, .rain: .immersive
        }
    }

    static let recommendedCatalog: [AdaptiveTriggerPreset] = [.off, .acceleratorPedal, .brakePedal, .handgun, .revolver, .rifle, .automaticWeapon, .archery, .crossbow, .shield, .chainsaw, .flashlight, .motorStart]

    var designedResistance: [Float]? {
        if Self.recommendedCatalog.contains(self), self != .off {
            return (0..<10).map { i in
                let t = Float(i) / 9
                switch self {
                case .acceleratorPedal: return 0.10 + 0.55*t
                case .brakePedal: return 0.08 + 0.70*t*t
                case .handgun: return t < 0.33 ? 0.22 : 0.48 + 0.07*(t-0.33)/0.67
                case .revolver: return t < 0.22 ? 0.28 : 0.58 + 0.07*(t-0.22)/0.78
                case .rifle: return 0.72
                case .automaticWeapon: return 0.78
                case .archery: return 0.08 + 0.70*t*t*t
                case .crossbow: return 0.13 + 0.52*t
                case .shield: return t < 0.10 ? 0.10 : 0.70
                case .chainsaw: return t < 0.20 ? 0.30 : 0.48
                case .flashlight: return 0.08
                case .motorStart: return 0.65
                default: return 0
                }
            }
        }
        switch self {
        case .stagedWall: return [0, 0.06, 0.10, 0.14, 0.18, 0.65, 0.72, 0.78, 0.82, 0.82]
        case .clutchBite: return [0.04, 0.08, 0.18, 0.40, 0.62, 0.46, 0.28, 0.16, 0.12, 0.12]
        case .bowDraw: return [0.04, 0.10, 0.22, 0.38, 0.56, 0.72, 0.85, 0.92, 0.48, 0.30]
        case .hydraulicBrake: return [0.02, 0.03, 0.06, 0.12, 0.24, 0.40, 0.60, 0.78, 0.90, 0.95]
        case .ratchetDetents: return [0, 0.10, 0.55, 0.12, 0.65, 0.12, 0.75, 0.12, 0.80, 0.18]
        default: return nil
        }
    }

    static func catalog(in category: AdaptiveTriggerCategory) -> [AdaptiveTriggerPreset] {
        recommendedCatalog.filter { $0.category == category }
    }
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

extension AdaptiveTriggerPreset {
    /// Ten feedback zones, including the final zone: unlike slope feedback these
    /// do not terminate resistance before full pull. Braking is deliberately lighter.
    var pedalStrengths: [Float]? {
        switch self {
        case .acceleration: [0.04, 0.06, 0.09, 0.12, 0.16, 0.20, 0.24, 0.28, 0.31, 0.34]
        case .braking: [0.03, 0.04, 0.06, 0.08, 0.10, 0.12, 0.15, 0.18, 0.21, 0.24]
        case .deceleration: [0.03, 0.05, 0.07, 0.09, 0.11, 0.14, 0.17, 0.20, 0.23, 0.26]
        default: nil
        }
    }
}

struct AdaptiveTriggerSettings: Codable, Equatable, Sendable {
    var leftPreset: AdaptiveTriggerPreset
    var rightPreset: AdaptiveTriggerPreset
    var leftCustom: AdaptiveTriggerCustomParameters
    var rightCustom: AdaptiveTriggerCustomParameters
    var leftUsesCustom: Bool
    var rightUsesCustom: Bool
    var leftCustomPresetID: UUID?
    var rightCustomPresetID: UUID?

    static let `default` = AdaptiveTriggerSettings(
        leftPreset: .off,
        rightPreset: .off,
        leftCustom: .default,
        rightCustom: .default,
        leftUsesCustom: false,
        rightUsesCustom: false
    )

    private enum CodingKeys: String, CodingKey {
        case leftPreset, rightPreset, leftCustom, rightCustom, leftUsesCustom, rightUsesCustom
        case leftCustomPresetID, rightCustomPresetID
    }

    init(leftPreset: AdaptiveTriggerPreset, rightPreset: AdaptiveTriggerPreset, leftCustom: AdaptiveTriggerCustomParameters, rightCustom: AdaptiveTriggerCustomParameters, leftUsesCustom: Bool, rightUsesCustom: Bool, leftCustomPresetID: UUID? = nil, rightCustomPresetID: UUID? = nil) {
        self.leftPreset = leftPreset
        self.rightPreset = rightPreset
        self.leftCustom = leftCustom
        self.rightCustom = rightCustom
        self.leftUsesCustom = leftUsesCustom
        self.rightUsesCustom = rightUsesCustom
        self.leftCustomPresetID = leftCustomPresetID
        self.rightCustomPresetID = rightCustomPresetID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftPreset = try container.decodeIfPresent(AdaptiveTriggerPreset.self, forKey: .leftPreset) ?? .off
        rightPreset = try container.decodeIfPresent(AdaptiveTriggerPreset.self, forKey: .rightPreset) ?? .off
        // Preserve encoded snapshots verbatim, including during checksum validation.
        leftCustom = try container.decodeIfPresent(AdaptiveTriggerCustomParameters.self, forKey: .leftCustom) ?? .default
        rightCustom = try container.decodeIfPresent(AdaptiveTriggerCustomParameters.self, forKey: .rightCustom) ?? .default
        leftUsesCustom = try container.decodeIfPresent(Bool.self, forKey: .leftUsesCustom) ?? false
        rightUsesCustom = try container.decodeIfPresent(Bool.self, forKey: .rightUsesCustom) ?? false
        leftCustomPresetID = try container.decodeIfPresent(UUID.self, forKey: .leftCustomPresetID)
        rightCustomPresetID = try container.decodeIfPresent(UUID.self, forKey: .rightCustomPresetID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leftPreset, forKey: .leftPreset)
        try container.encode(rightPreset, forKey: .rightPreset)
        try container.encode(leftCustom, forKey: .leftCustom)
        try container.encode(rightCustom, forKey: .rightCustom)
        try container.encode(leftUsesCustom, forKey: .leftUsesCustom)
        try container.encode(rightUsesCustom, forKey: .rightUsesCustom)
        // Omitting absent IDs keeps existing preset checksums stable.
        try container.encodeIfPresent(leftCustomPresetID, forKey: .leftCustomPresetID)
        try container.encodeIfPresent(rightCustomPresetID, forKey: .rightCustomPresetID)
    }

    func selection(for side: AdaptiveTriggerSide, library: [CustomAdaptiveTriggerPreset]) -> AdaptiveTriggerSelection {
        let usesCustom = side == .left ? leftUsesCustom : rightUsesCustom
        guard usesCustom else { return .builtIn(side == .left ? leftPreset : rightPreset) }
        let id = side == .left ? leftCustomPresetID : rightCustomPresetID
        let snapshot = side == .left ? leftCustom : rightCustom
        if let id, let saved = library.first(where: { $0.id == id }), saved.parameters.clamped == snapshot.clamped {
            return .custom(id)
        }
        // Deleted or edited library entries never rewrite an applied/saved snapshot.
        return .currentCustomSnapshot
    }

    mutating func select(_ selection: AdaptiveTriggerSelection, for side: AdaptiveTriggerSide, library: [CustomAdaptiveTriggerPreset]) {
        switch selection {
        case .builtIn(let preset):
            if side == .left {
                leftPreset = preset; leftUsesCustom = false; leftCustomPresetID = nil
            } else {
                rightPreset = preset; rightUsesCustom = false; rightCustomPresetID = nil
            }
        case .custom(let id):
            guard let saved = library.first(where: { $0.id == id }) else { return }
            applySnapshot(saved.parameters, for: side, presetID: id)
        case .currentCustomSnapshot:
            break
        }
    }

    mutating func applySnapshot(_ parameters: AdaptiveTriggerCustomParameters, for side: AdaptiveTriggerSide, presetID: UUID? = nil) {
        if side == .left {
            leftCustom = parameters.clamped; leftUsesCustom = true; leftCustomPresetID = presetID
        } else {
            rightCustom = parameters.clamped; rightUsesCustom = true; rightCustomPresetID = presetID
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

// Optional in older profiles: absent values retain the existing behavior.
struct ControllerEnhancements: Codable, Equatable, Sendable {
    var touchpadAimEnabled = false
    var touchpadSensitivity: Float? = nil
    var touchpadMouseMode: Bool? = nil
    var gyroEnabled = false
    var gyroTiltMode: Bool? = nil // Decode legacy profiles only; no longer drives input.
    var gyroFlickMode: Bool? = nil
    var gyroStick: ControllerAimStick? = nil
    var touchpadStick: ControllerAimStick? = nil
    var gyroNoiseThreshold: Float? = nil
    var effectiveGyroNoiseThreshold: Float { gyroNoiseThreshold ?? (gyroDeadzone == 0.025 ? 0.003 : gyroDeadzone) }
    var gyroAimOnly = true
    var gyroSensitivity: Float = 0.45
    var gyroDeadzone: Float = 0.025
    var gyroOutputFloor: Float? = nil
    var steeringRangeDegrees: Float? = nil
    var steeringFloor: Float? = nil
    var steeringSmoothing: Float? = nil
    var steeringDeadzoneDegrees: Float? = nil
    var steeringExponent: Float? = nil
    var steeringInverted: Bool? = nil
    var steeringMaximum: Float? = nil
    var effectiveSteeringMaximum: Float { let value = steeringMaximum ?? 1; return value.isFinite ? min(max(value, 0.2), 1) : 1 }
    // Steering carries the stick above a game's inner dead zone at every held
    // angle; Forza-style defaults sit near 0.3, far above the aiming default.
    var effectiveSteeringFloor: Float { min(max(steeringFloor ?? 0.30, 0), 0.6) }
    var effectiveSteeringRangeRadians: Float { min(max(((steeringRangeDegrees ?? 40) * .pi) / 180, 0.1), .pi * 2 / 3) }
    var gyroInvertY = false
    var rapidFireEnabled = false
    var rapidFireRate: Float = 8
    var leftLock = false
    var rightLock = false
    var lockPosition: Float = 0.3
    var rumbleGain: Float = 1
    var rumbleExponent: Float = 1
    var gameDrivenTriggers = false

    var gyroMode: ControllerGyroMode {
        guard gyroEnabled else { return .off }
        if gyroStick == .left { return .steering }
        return gyroFlickMode == true ? .flickShift : .aiming
    }
    mutating func setGyroMode(_ mode: ControllerGyroMode) {
        gyroEnabled = mode != .off
        gyroFlickMode = mode == .flickShift
        gyroStick = mode == .steering ? .left : .right
    }

    func rumble(_ value: Float, global: Float) -> Float {
        guard value.isFinite, global.isFinite else { return 0 }
        return min(max(pow(min(max(value, 0), 1), min(max(rumbleExponent, 0.25), 4)) * rumbleGain * global, 0), 1)
    }
}

/// Project rotation onto world-up so yaw works with the controller flat or upright.
enum ControllerMotionProjection {
    static func yaw(x: Double, y: Double, z: Double, gx: Double, gy: Double, gz: Double) -> Float {
        let norm = (gx * gx + gy * gy + gz * gz).squareRoot()
        guard [x,y,z,gx,gy,gz].allSatisfy({ $0.isFinite }) else { return 0 }
        guard norm > 0.1 else { return Float(y) }
        return Float(-(x * gx + y * gy + z * gz) / norm)
    }
}

struct ControllerMotionVector {
    var x: Double
    var y: Double
    var z: Double
    static let zero = Self(x: 0, y: 0, z: 0)
    var length: Double { sqrt(x*x + y*y + z*z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct ControllerWheelMotion {
    enum Source: String {
        case gravity = "Gravity"
        case acceleration = "Accelerometer + gyro"
    }
    var vector: ControllerMotionVector
    var source: Source

    static func select(hasGravity: Bool, gravity: ControllerMotionVector,
                       acceleration: ControllerMotionVector) -> Self? {
        if hasGravity, gravity.isFinite, (0.5...1.5).contains(gravity.length) {
            return Self(vector: gravity, source: .gravity)
        }
        guard acceleration.isFinite, (0.5...1.5).contains(acceleration.length) else { return nil }
        return Self(vector: acceleration, source: .acceleration)
    }
}

/// Absolute wheel-angle estimator. Temporal smoothing belongs to the final stick output.
struct ControllerWheelState {
    private var filtered: Double?
    private var centre: Double?
    private var previousTime: Double?
    private var lastAnchorAt: Double?
    private var lastVector: ControllerMotionVector?
    private(set) var angle: Float = 0
    private(set) var status = "Waiting for steering sensors"
    private(set) var available = false
    private(set) var measuredAngle: Float = 0
    private(set) var bridgedSamples = 0
    private(set) var rejectedSamples = 0
    mutating func reset() { self = Self() }
    mutating func center() { centre = filtered; angle = 0; measuredAngle = 0 }
    mutating func sample(_ input: ControllerWheelMotion?, rate: ControllerMotionVector, now: Double,
                         hasRate: Bool = true) -> Float? {
        guard now.isFinite else { available = false; return nil }
        let dt = previousTime.map { now - $0 } ?? 0
        // A duplicate/out-of-order timestamp must not overwrite the integration clock.
        if previousTime != nil && dt <= 0 { return available ? angle : nil }
        previousTime = now
        func wrap(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
        let validRate = hasRate && rate.isFinite && rate.length < 35
        let candidate = input.flatMap { reading -> ControllerWheelMotion? in
            let v = reading.vector
            return v.isFinite && v.x*v.x + v.y*v.y > 0.04 ? reading : nil
        }
        var confidence = 0.0
        if let reading = candidate {
            confidence = reading.source == .gravity ? 1 : max(0, min(1, (0.30 - abs(reading.vector.length - 1)) / 0.22))
        }
        // Predict from the previous trusted vector when linear acceleration corrupts the current one.
        let basis = lastVector ?? candidate?.vector
        var predicted = filtered
        if validRate, let last = filtered, let v = basis, dt > 0, dt <= 0.25 {
            let planar = v.x*v.x + v.y*v.y
            if planar > 0.04 {
                let angularRate = -rate.z + (rate.y*v.y + rate.x*v.x)*v.z / planar
                if angularRate.isFinite { predicted = last + angularRate * dt }
            }
        }
        if let reading = candidate, confidence > 0 {
            let measured = atan2(reading.vector.x, -reading.vector.y)
            if confidence >= 0.75 {
                // Reliable absolute position owns the target; no rate-dependent
                // gain or smoothing bypass. Smooth after all stick mapping below.
                if reading.source == .acceleration, let prediction = predicted,
                   filtered != nil, validRate, dt > 0, dt <= 0.10 {
                    // Complementary fusion: gyro carries quick turns; absolute
                    // acceleration slowly corrects drift without injecting every
                    // hand translation into the wheel. Never move the centre.
                    let correction = wrap(measured - prediction)
                    let alpha = 1 - exp(-dt / 0.18)
                    filtered = prediction + alpha * correction
                } else {
                    filtered = measured
                }
            } else if let prediction = predicted, dt > 0, dt <= 0.25 {
                let correction = (1 - exp(-dt / 0.25)) * confidence * wrap(measured - prediction)
                let limit = max(0.002, dt * 1.5)
                filtered = prediction + min(max(correction, -limit), limit)
            } else { filtered = measured }
            if confidence >= 0.75 { lastVector = reading.vector; lastAnchorAt = now }
            else { rejectedSamples += 1 }
            status = confidence >= 0.75 ? reading.source.rawValue : "Filtering acceleration disturbance"
        } else {
            rejectedSamples += 1
            guard let prediction = predicted, let anchor = lastAnchorAt,
                  now - anchor <= 0.20, dt > 0, dt <= 0.25, validRate else {
                available = false
                status = "Steering sensors unavailable — hold controller face toward you"
                return nil
            }
            filtered = prediction
            bridgedSamples += 1
            status = "Bridging brief sensor disturbance"
        }
        // Never reset the saved centre on a dropout, reversal, or sensor-source change.
        guard let current = filtered else { available = false; return nil }
        if centre == nil { centre = current }
        angle = Float(wrap(current - (centre ?? current)))
        if let reading = candidate, confidence > 0 {
            measuredAngle = Float(wrap(atan2(reading.vector.x, -reading.vector.y) - (centre ?? current)))
        }
        available = true
        return angle
    }
}

/// Time-weighted moving average of the final stick target. A held step ramps
/// evenly across one window, without spring acceleration or amplitude thresholds.
/// The maximum retained history is 150 ms (normally nine 60 Hz input intervals).
struct ControllerSteeringResponse {
    private struct Interval {
        var start: Double
        var end: Double
        var value: Double
    }
    private var history: [Interval] = []
    private(set) var output: Double = 0
    private var previousTime: Double?
    static func responseTime(smoothing: Double) -> Double {
        let amount = smoothing.isFinite ? min(max(smoothing, 0), 1) : 0.5
        return 0.030 + 0.120 * amount
    }
    mutating func reset(at now: Double? = nil) {
        history.removeAll(keepingCapacity: true)
        output = 0; previousTime = now
    }
    mutating func sample(target: Double, now: Double, smoothing: Double) -> Float {
        guard target.isFinite, now.isFinite else { reset(); return 0 }
        guard let previous = previousTime else { previousTime = now; return Float(output) }
        let dt = now - previous
        guard dt > 0 else { return Float(output) }
        previousTime = now
        if dt > 0.25 { reset(at: now); return 0 }
        let goal = min(max(target, -1), 1)
        // Weight by elapsed time, not packet count, so uneven poll intervals do
        // not change sensitivity. Equal adjacent targets share one interval.
        if let last = history.last, last.value == goal {
            history[history.count - 1].end = now
        } else {
            history.append(Interval(start: previous, end: now, value: goal))
        }
        let oldest = now - 0.150
        history.removeAll { $0.end <= oldest }
        if !history.isEmpty { history[0].start = max(history[0].start, oldest) }
        let window = Self.responseTime(smoothing: smoothing)
        let beginning = now - window
        var integral = 0.0
        for interval in history {
            let duration = max(0, interval.end - max(interval.start, beginning))
            integral += interval.value * duration
        }
        // Before the first report/reset, the implicit history is neutral.
        // Positive weights cannot overshoot or add momentum beyond the targets.
        output = min(max(integral / window, -1), 1)
        return Float(output)
    }
}

/// Neutral-preserving conversion shared by touch and gyro. No resistance floor at rest.
enum ControllerAimMath {
    static func touchGain(_ velocity: Float, sensitivity: Float, floor: Float) -> Float {
        guard velocity.isFinite, sensitivity.isFinite else { return 0 }
        // Linear velocity → stick mapping; the only ceiling is full stick. The old
        // nested saturation curve compressed every sensitivity above ~0.4 stick.
        let scaled = velocity * min(max(sensitivity, 0.05), 3)
        let magnitude = min(abs(scaled), 1)
        guard magnitude > 0 else { return 0 }
        let offset = min(max(floor, 0), 0.4)
        return (scaled < 0 ? -1 : 1) * (offset + (1 - offset) * magnitude)
    }
    static func steering(angle: Float, centre: Float, range: Float, floor: Float, deadzone: Float = 0, exponent: Float = 1, inverted: Bool = false) -> Float {
        guard angle.isFinite, centre.isFinite else { return 0 }
        let delta = atan2(sin(angle - centre), cos(angle - centre))
        guard range.isFinite, floor.isFinite, deadzone.isFinite, exponent.isFinite else { return 0 }
        let span = min(max(range, 0.1), .pi * 2 / 3)
        let neutral = min(max(deadzone, 0), span * 0.25)
        let travel = max(abs(delta) - neutral, 0)
        let amount = pow(min(travel / (span - neutral), 1), min(max(exponent, 0.5), 2))
        let offset = min(max(floor, 0), 0.6)
        // Fade optional game dead-zone compensation across the first half degree.
        let entry = min(travel / (.pi / 360), 1)
        return (inverted ? -1 : 1) * (delta < 0 ? -1 : 1) * (offset * entry + (1 - offset) * amount)
    }

    static func trackpad(current: ControllerVector2, previous: ControllerVector2, dt: Double, sensitivity: Float) -> ControllerVector2 {
        guard dt.isFinite, dt > 0, dt < 0.1 else { return .zero }
        let gain = min(max(sensitivity, 0.05), 1) / Float(dt)
        func velocity(_ delta: Float) -> Float {
            guard delta.isFinite else { return 0 }
            let scaled = delta * gain
            return scaled / (1 + abs(scaled))
        }
        return ControllerVector2(x: velocity(current.x - previous.x), y: velocity(current.y - previous.y))
    }

    static func axis(_ value: Float, deadzone: Float) -> Float {
        guard value.isFinite else { return 0 }
        let d = min(max(deadzone, 0), 0.95)
        guard abs(value) > d else { return 0 }
        return (value < 0 ? -1 : 1) * min((abs(value) - d) / (1 - d), 1)
    }
    static func smooth(_ target: Float, previous: Float, dt: Double) -> Float {
        guard target.isFinite, target != 0 else { return 0 }
        let alpha = Float(1 - exp(-min(max(dt, 0.001), 0.1) / 0.008))
        return previous + (target - previous) * alpha
    }
    static func tilt(gx: Double, gy: Double, gz: Double) -> ControllerVector2 {
        guard [gx,gy,gz].allSatisfy({ $0.isFinite }) else { return .zero }
        return ControllerVector2(x: Float(atan2(gx, sqrt(gy*gy+gz*gz))), y: Float(atan2(gy, -gz)))
    }
    static func tiltDelta(_ value: Float, centre: Float) -> Float {
        let delta = atan2(sin(value - centre), cos(value - centre))
        // Three degrees of neutral travel, full stick at twenty degrees.
        return axis(delta / (.pi / 9), deadzone: 0.15)
    }
}

/// Speed-adaptive low-pass filtering following Casiez et al.'s 1€ algorithm.
struct ControllerAdaptiveFilter {
    private var value: Float = 0
    private var raw: Float = 0
    private var derivative: Float = 0
    mutating func reset() { value = 0; raw = 0; derivative = 0 }
    mutating func sample(_ next: Float, dt: Double, minimum: Float = 8, beta: Float = 4, neutralImmediately: Bool = true) -> Float {
        guard next.isFinite else { reset(); return 0 }
        if next == 0 && neutralImmediately { reset(); return 0 }
        let step = Float(min(max(dt, 0.001), 0.05))
        func alpha(_ cutoff: Float) -> Float { 1 / (1 + 1 / (2 * .pi * cutoff * step)) }
        derivative += alpha(1) * ((next - raw) / step - derivative)
        raw = next
        value += alpha(minimum + beta * abs(derivative)) * (next - value)
        return value
    }
}

/// One vertical pulse, followed by return-to-neutral suppression.
struct ControllerFlickState {
    private var neutral: Float?
    private var blocked = false
    private var quietSince: Double?
    private var pulseUntil: Double = 0
    private var direction: Float = 0
    mutating func reset() { self = Self() }
    mutating func sample(rate: Float, angle: Float, now: Double) -> Float {
        guard rate.isFinite, angle.isFinite, now.isFinite else { reset(); return 0 }
        guard let neutral else {
            if abs(rate) < 0.2 { self.neutral = angle }
            return 0
        }
        if now < pulseUntil { return direction }
        if blocked {
            // Rearm on rate decay alone: repeated shifts must not wait for a
            // full return to the neutral tilt and a long settle.
            if abs(rate) < 0.35 {
                if quietSince == nil { quietSince = now }
                if now - (quietSince ?? now) >= 0.05 { blocked = false; quietSince = nil }
            } else { quietSince = nil }
            return 0
        }
        if abs(rate) >= 1.5 {
            direction = rate > 0 ? 1 : -1
            // A stroke moving back toward neutral is the return after a flick,
            // never a shift; a deliberate opposite flick crosses neutral while
            // still fast and fires there.
            if angle * direction >= -0.03 {
                pulseUntil = now + 0.08
                blocked = true
                return direction
            }
            return 0
        }
        return 0
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
    case off, aiming, steering, flickShift
    var title: String {
        switch self {
        case .off: return "Off"
        case .aiming: return "Aiming (right stick)"
        case .steering: return "Steering wheel (left stick)"
        case .flickShift: return "Flick shifting"
        }
    }
}

/// Filter raw rates first; a radial hysteresis gate separates rest from slow aim.
/// Filters stay warm through brief pauses so the return stroke responds exactly
/// as fast as the stroke that entered the turn; only a sustained rest resets.
struct ControllerPrecisionGyro {
    private var xFilter = ControllerAdaptiveFilter()
    private var yFilter = ControllerAdaptiveFilter()
    private var active = false
    private var restTime: Double = 0
    private(set) var fine = ControllerVector2.zero
    mutating func reset() { self = Self() }
    mutating func sample(_ rate: ControllerVector2, dt: Double, noise: Float, sensitivity: Float, floor: Float) -> ControllerVector2 {
        guard rate.x.isFinite, rate.y.isFinite, dt.isFinite else { reset(); return .zero }
        let threshold = min(max(noise, 0), 0.1)
        let rawLength = sqrt(rate.x*rate.x + rate.y*rate.y)
        if rawLength <= threshold * 0.5 {
            // Output releases immediately, but the filters keep decaying so a
            // hard reset can no longer lag the next stroke's onset.
            _ = xFilter.sample(rate.x, dt: dt, minimum: 3.5, beta: 7, neutralImmediately: false)
            _ = yFilter.sample(rate.y, dt: dt, minimum: 3.5, beta: 7, neutralImmediately: false)
            restTime += dt
            if restTime >= 0.3 { reset() }
            active = false; fine = .zero
            return .zero
        }
        restTime = 0
        let x = xFilter.sample(rate.x, dt: dt, minimum: 3.5, beta: 7, neutralImmediately: false)
        let y = yFilter.sample(rate.y, dt: dt, minimum: 3.5, beta: 7, neutralImmediately: false)
        let length = sqrt(x*x + y*y)
        if length <= (active ? threshold * 0.65 : threshold) || length < 0.00001 {
            restTime += dt
            if restTime >= 0.3 { reset() }
            active = false; fine = .zero; return .zero
        }
        restTime = 0
        active = true
        // Do not amplify orthogonal-axis noise when overcoming the game's stick dead zone.
        func clean(_ value: Float) -> Float {
            let magnitude = max(abs(value) - threshold * 0.65, 0)
            return value < 0 ? -magnitude : magnitude
        }
        let cx = clean(x), cy = clean(y), cleanLength = sqrt(cx*cx + cy*cy)
        guard cleanLength > 0.00001 else { fine = .zero; return .zero }
        let speed = min(max(cleanLength * sensitivity, 0), 1)
        fine = ControllerVector2(x: cx / cleanLength * speed, y: cy / cleanLength * speed)
        let compensation = min(max(floor, 0), 0.4)
        // Fade the dead-zone carrier in over roughly two frames: the old fixed
        // step from zero to the full carrier read as a twitch on every stroke.
        let entry = min(max((cleanLength - threshold) / (threshold * 0.5 + 0.0001), 0), 1)
        let magnitude = compensation * entry + (1 - compensation * entry) * speed
        return ControllerVector2(x: cx / cleanLength * magnitude, y: cy / cleanLength * magnitude)
    }
}

/// Mouse-style touch aiming. Finger travel accumulates into a target and a
/// proportional servo drives the stick toward it, so output is a smooth
/// function of the accumulated undelivered motion — sensor noise averages out
/// instead of being differentiated into velocity jitter. Short edge flicks
/// deliver exact travel, and a stationary or lifted finger stops the camera.
struct ControllerTouchServo {
    /// Higher responsiveness = shorter glide after the finger stops.
    static let responsiveness: Float = 20
    private(set) var target = ControllerVector2.zero
    private(set) var delivered = ControllerVector2.zero
    private(set) var output = ControllerVector2.zero
    private var lastMotionAt: Double = -.infinity
    mutating func reset() { self = Self() }
    mutating func move(dx: Float, dy: Float, sensitivity: Float, at now: Double) {
        guard [dx, dy].allSatisfy({ $0.isFinite }) else { return }
        let gain = min(max(sensitivity, 0.05), 3)
        target.x = min(max(target.x + dx * gain, -1.2), 1.2)
        target.y = min(max(target.y + dy * gain, -1.2), 1.2)
        // Sub-pixel shivers must not keep a resting finger "moving", but every
        // real drag — even a very slow one — counts as motion.
        if abs(dx) > 0.0005 || abs(dy) > 0.0005 { lastMotionAt = now }
    }
    /// Ends the current motion: the camera stops exactly where delivery stands.
    mutating func stop() { target = delivered }
    mutating func sample(dt: Double, floor: Float, now: Double, contact: Bool) -> ControllerVector2 {
        var rem = ControllerVector2(x: min(max(target.x - delivered.x, -1.2), 1.2),
                                    y: min(max(target.y - delivered.y, -1.2), 1.2))
        // A resting finger flushes once the glide has effectively finished, so
        // the stop is smooth and no travel is silently discarded.
        let settled = abs(rem.x) < 0.005 && abs(rem.y) < 0.005
        if !contact || (now - lastMotionAt > 0.09 && settled) { stop() }
        rem = ControllerVector2(x: min(max(target.x - delivered.x, -1.2), 1.2),
                                y: min(max(target.y - delivered.y, -1.2), 1.2))
        let step = Float(min(max(dt, 0.001), 0.05))
        let offset = min(max(floor, 0), 0.4)
        var result = ControllerVector2.zero
        for axis in 0..<2 {
            let value = axis == 0 ? rem.x : rem.y
            let velocity = value * Self.responsiveness
            let magnitude = min(abs(velocity), 1)
            let out: Float = abs(value) < 0.0005 ? 0 : (velocity < 0 ? -1 : 1) * (offset + (1 - offset) * magnitude)
            let applied = min(max(velocity, -1), 1) * step
            if axis == 0 {
                result.x = out
                delivered.x = min(max(delivered.x + applied, -1.3), 1.3)
            } else {
                result.y = out
                delivered.y = min(max(delivered.y + applied, -1.3), 1.3)
            }
        }
        output = result
        return result
    }
}

/// Pressure-driven local effects. These are not game/weapon telemetry.
/// Schedule against monotonic time; never replay missed pulses after a stall.
struct ControllerTriggerEnvelope {
    struct Output {
        var intensity: Float = 0
        var duration: Double = 0.03
        var forceBoost: Float = 0
    }
    private var preset: AdaptiveTriggerPreset = .off
    private var previous: Float = 0
    private var peak: Float = 0
    private var nextPulse: Double = 0
    private var recoilEnd: Double = 0
    private var lastTime: Double?
    mutating func sample(preset mode: AdaptiveTriggerPreset, pressure: Float, now: Double) -> Output {
        guard now.isFinite, pressure.isFinite else { self = Self(); return Output() }
        if mode != preset || lastTime.map({ now - $0 > 0.25 || now < $0 }) == true {
            self = Self(); preset = mode; previous = min(max(pressure, 0), 1)
        }
        lastTime = now
        let p = min(max(pressure, 0), 1)
        defer { previous = p }
        peak = max(peak, p)
        var result = Output()
        let threshold: Float
        let frequency: Double
        switch mode {
        case .handgun: threshold = 0.33; frequency = 0
        case .revolver: threshold = 0.22; frequency = 0
        case .rifle: threshold = 0.80; frequency = 7
        case .automaticWeapon: threshold = 0.75; frequency = 12
        case .archery: threshold = 0.20; frequency = 3
        case .crossbow: threshold = 0.20; frequency = 4
        case .shield: threshold = 0.10; frequency = 4
        case .chainsaw: threshold = 0.20; frequency = 9
        case .motorStart: threshold = 0.30; frequency = 6
        case .brakePedal: threshold = 0.45; frequency = 8
        case .flashlight: threshold = 0.10; frequency = 0
        default: threshold = 1.1; frequency = 0
        }
        if p <= 0.04 {
            if previous > 0.04, peak >= threshold {
                switch mode {
                case .handgun, .revolver: result.intensity = 0.60; result.duration = 0.06
                case .archery: result.intensity = 0.80; result.duration = 0.05
                case .crossbow: result.intensity = 0.60; result.duration = 0.04
                default: break
                }
            }
            peak = 0; nextPulse = 0; recoilEnd = 0
            return result
        }
        let crossing = previous < threshold && p >= threshold
        if crossing {
            nextPulse = now
            if mode == .handgun || mode == .revolver { result.intensity = mode == .revolver ? 0.7 : 0.55; result.duration = 0.025 }
            if mode == .flashlight { result.intensity = 0.4; result.duration = 0.025 }
        }
        if p >= threshold, frequency > 0, now >= nextPulse {
            nextPulse = max(nextPulse + 1 / frequency, now + 0.001)
            switch mode {
            case .rifle: result.intensity = 0.75; result.duration = 0.10; recoilEnd = now + 0.10
            case .automaticWeapon: result.intensity = 0.80; result.duration = 0.025; recoilEnd = now + 0.025
            case .brakePedal: result.intensity = 0.25*(p-threshold)/(1-threshold); result.duration = 0.08
            case .archery: result.intensity = 0.5*p*p; result.duration = 0.30
            case .crossbow: result.intensity = 0.3*p; result.duration = 0.20
            case .shield: result.intensity = crossing ? 1 : 0.5; result.duration = crossing ? 0.08 : 0.20
            case .chainsaw: result.intensity = 0.75; result.duration = 0.08; recoilEnd = now + 0.05
            case .motorStart: result.intensity = 0.55; result.duration = 0.12; recoilEnd = now + 0.06
            default: break
            }
        }
        if p < threshold { recoilEnd = 0; nextPulse = 0 }
        if now < recoilEnd {
            result.forceBoost = mode == .automaticWeapon ? 0.22 : (mode == .motorStart ? 0.15 : 0.20)
        }
        return result
    }
}
