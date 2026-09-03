//
//  ControllerModels.swift
//  Xbox Cloud Gaming
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
    var hasMotion: Bool
    var hasAttitude: Bool
    var hasRotationRate: Bool
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
        hasMotion: false,
        hasAttitude: false,
        hasRotationRate: false,
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

struct ControllerVector3: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = ControllerVector3(x: 0, y: 0, z: 0)
}

struct ControllerQuaternion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = ControllerQuaternion(x: 0, y: 0, z: 0, w: 1)
}

struct ControllerMotionSnapshot: Codable, Equatable, Sendable {
    var acceleration: ControllerVector3
    var gravity: ControllerVector3
    var userAcceleration: ControllerVector3
    var rotationRate: ControllerVector3
    var attitude: ControllerQuaternion

    static let zero = ControllerMotionSnapshot(
        acceleration: .zero,
        gravity: .zero,
        userAcceleration: .zero,
        rotationRate: .zero,
        attitude: .identity
    )
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
    var motion: ControllerMotionSnapshot?
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
        motion: nil,
        battery: nil
    )
}

// MARK: - Calibration and response curves

enum ResponseCurve: Codable, Equatable, Sendable {
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

struct ResponseCurvePoint: Codable, Equatable, Sendable {
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

enum AdaptiveTriggerPreset: String, Codable, CaseIterable, Sendable {
    case off
    case softResistance
    case firmResistance
    case weapon
    case automaticRecoil
    case burstPulse
    case bow
    case accelerator
    case brakeComfort
    case brakeFirm
    case absPulse
    case platformerEndStop
    case cinematic
    case vibration
    case custom
}

enum AdaptiveTriggerEffectMode: String, Codable, CaseIterable, Sendable {
    case off
    case feedback
    case weapon
    case vibration
    case slopeFeedback
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
        value.startPosition = min(max(value.startPosition, 0), 0.99)
        value.endPosition = min(max(value.endPosition, value.startPosition + 0.01), 1)
        value.startStrength = min(max(value.startStrength, 0), 1)
        value.endStrength = min(max(value.endStrength, 0), 1)
        value.amplitude = min(max(value.amplitude, 0), 1)
        value.frequency = min(max(value.frequency, 0), 1)
        return value
    }
}

struct AdaptiveTriggerSettings: Codable, Equatable, Sendable {
    var leftPreset: AdaptiveTriggerPreset
    var rightPreset: AdaptiveTriggerPreset
    var leftCustom: AdaptiveTriggerCustomParameters
    var rightCustom: AdaptiveTriggerCustomParameters

    static let `default` = AdaptiveTriggerSettings(
        leftPreset: .off,
        rightPreset: .off,
        leftCustom: .default,
        rightCustom: .default
    )
}

// MARK: - Haptics and motion

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

enum GyroMode: String, Codable, CaseIterable, Sendable {
    case off
    case raw
    case rightStick
    case pointer
}

struct GyroSettings: Codable, Equatable, Sendable {
    var mode: GyroMode
    var sensitivityX: Float
    var sensitivityY: Float
    var deadzone: Float
    var invertX: Bool
    var invertY: Bool

    static let `default` = GyroSettings(
        mode: .off,
        sensitivityX: 1,
        sensitivityY: 1,
        deadzone: 0.02,
        invertX: false,
        invertY: false
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

    var errorDescription: String? {
        switch self {
        case .tooManySteps(let maximum): return "A macro can contain at most \(maximum) steps."
        case .negativeDelay: return "Macro step delays cannot be negative."
        case .durationExceeded(let maximum): return "A macro cannot exceed \(maximum) milliseconds."
        case .invalidHapticDuration: return "Haptic macro durations must be between 0 and 2000 milliseconds."
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
        for step in steps {
            if case .haptic(_, _, let duration) = step.action,
               !(0...Self.maximumDurationMilliseconds).contains(duration) {
                throw ControllerMacroValidationError.invalidHapticDuration
            }
        }
        guard totalDurationMilliseconds <= Self.maximumDurationMilliseconds else {
            throw ControllerMacroValidationError.durationExceeded(maximumMilliseconds: Self.maximumDurationMilliseconds)
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

struct ControllerSettings: Codable, Equatable, Sendable {
    var calibration: ControllerCalibration
    var adaptiveTriggers: AdaptiveTriggerSettings
    var haptics: HapticSettings
    var gyro: GyroSettings
    var touchpad: TouchpadSettings
    var categoryPreset: ControllerCategoryPresetSettings
    var shortcuts: ControllerShortcutSchema
    var macros: [ControllerMacro]
    var led: ControllerLEDSettings

    static let `default` = ControllerSettings(
        calibration: .default,
        adaptiveTriggers: .default,
        haptics: .default,
        gyro: .default,
        touchpad: .default,
        categoryPreset: .default,
        shortcuts: .default,
        macros: [],
        led: .default
    )
}
