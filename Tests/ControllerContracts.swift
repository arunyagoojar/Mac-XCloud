import Foundation

@main
struct ControllerContracts {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
            print("PASS: \(label)")
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(label) }
            catch { checks += 1; print("PASS: \(label)") }
        }

        for mode in [AdaptiveTriggerPreset.acceleration, .braking, .deceleration] {
            let zones = mode.pedalStrengths!
            check(zones.count == 10, "\(mode) uses ten feedback zones")
            check(zones.allSatisfy { $0 > 0 && $0 <= 1 }, "\(mode) retains resistance at full travel")
            check(zip(zones, zones.dropFirst()).allSatisfy { $0 <= $1 }, "\(mode) has no terminal force drop")
        }
        check(zip(AdaptiveTriggerPreset.braking.pedalStrengths!, AdaptiveTriggerPreset.acceleration.pedalStrengths!).allSatisfy { $0 < $1 }, "Comfort brake is lighter than accelerator")

        var parameters = AdaptiveTriggerCustomParameters.default
        parameters.mode = .vibration
        parameters.amplitude = 0.72
        parameters.frequency = 0.19
        let custom = CustomAdaptiveTriggerPreset(name: "Test Pulse", parameters: parameters)
        var triggers = AdaptiveTriggerSettings.default
        triggers.select(.custom(custom.id), for: .left, library: [custom])
        check(triggers.leftUsesCustom && triggers.leftCustom == parameters, "Saved vibration applies exact parameters")
        check(triggers.selection(for: .left, library: [custom]) == .custom(custom.id), "Saved effect resolves in selector")
        check(triggers.selection(for: .left, library: []) == .currentCustomSnapshot, "Deleted library item preserves applied snapshot")
        triggers.select(.builtIn(.bowAndArrow), for: .right, library: [custom])
        check(triggers.leftUsesCustom && !triggers.rightUsesCustom, "Left and right selection are independent")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = try encoder.encode(AdaptiveTriggerSettings.default)
        check(!String(decoding: legacy, as: UTF8.self).contains("CustomPresetID"), "Nil library references do not alter legacy encoding")
        check(try JSONDecoder().decode(AdaptiveTriggerSettings.self, from: legacy) == .default, "Legacy trigger settings decode")
        check(try JSONDecoder().decode(AdaptiveTriggerSettings.self, from: encoder.encode(triggers)) == triggers, "Custom selection round-trips")
        parameters.amplitude = .nan
        parameters.frequency = .infinity
        parameters.startPosition = -1
        check(parameters.clamped.amplitude.isFinite && parameters.clamped.frequency.isFinite && parameters.clamped.startPosition >= 0, "Nonfinite trigger parameters are safely clamped")

        let steps = [ControllerMacroStep(delayMilliseconds: 0, action: .button(control: .buttonA, isPressed: true)), ControllerMacroStep(delayMilliseconds: 80, action: .button(control: .buttonA, isPressed: false))]
        let macro = try ControllerMacro(name: "A Tap", steps: steps)
        check(try JSONDecoder().decode(ControllerMacro.self, from: encoder.encode(macro)) == macro, "Editable macro round-trips")
        let shortcut = ControllerShortcut(name: "Tap chord", controls: [.leftShoulder, .rightShoulder], activation: .press, action: .macro(id: macro.id))
        try shortcut.validate()
        check(shortcut.action == .macro(id: macro.id), "Chord references saved macro UUID")
        rejects("Empty shortcut is rejected") { try ControllerShortcut(name: "Empty", controls: [], activation: .press, action: .none).validate() }
        rejects("Nested macro is rejected") { _ = try ControllerMacro(name: "Nested", steps: [.init(delayMilliseconds: 0, action: .nativeAction(.macro(id: macro.id)))]) }
        rejects("Overlong macro is rejected") { _ = try ControllerMacro(name: "Long", steps: [.init(delayMilliseconds: 2_001, action: .nativeAction(.none))]) }
        rejects("Too many steps are rejected") { _ = try ControllerMacro(name: "Many", steps: Array(repeating: steps[0], count: 17)) }
        rejects("Nonfinite macro haptics are rejected") { _ = try ControllerMacro(name: "Invalid", steps: [.init(delayMilliseconds: 0, action: .haptic(intensity: .nan, sharpness: 0.5, durationMilliseconds: 100))]) }
        print("\(checks) controller/model contract checks passed. No hardware or user data touched.")
    }
}
