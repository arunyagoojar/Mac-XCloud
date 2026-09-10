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

        for mode in [AdaptiveTriggerPreset.accelerator, .brake] {
            var pedal = ControllerTriggerEnvelope()
            _ = pedal.sample(preset: mode, pressure: 0, now: 0)
            let held = pedal.sample(preset: mode, pressure: 1, now: 0.016)
            check(held.intensity == 0 && held.forceBoost == 0, "\(mode.rawValue) pedal holds pressure without haptic spikes")
        }

        var parameters = AdaptiveTriggerCustomParameters.default
        parameters.mode = .vibration
        parameters.amplitude = 0.72
        parameters.frequency = 0.19
        check(parameters.clamped.amplitude == 0.72 && parameters.clamped.frequency == 0.19, "Vibration parameters apply in range")

        var triggers = AdaptiveTriggerSettings.default
        triggers.select(.bow, for: .left)
        triggers.select(.heartbeat, for: .right)
        check(triggers.leftPreset == .bow && triggers.rightPreset == .heartbeat, "Left and right selection are independent")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = try encoder.encode(AdaptiveTriggerSettings.default)
        check(!String(decoding: legacy, as: UTF8.self).contains("CustomPresetID"), "Default encoding stays free of removed library keys")
        check(try JSONDecoder().decode(AdaptiveTriggerSettings.self, from: legacy) == .default, "Legacy trigger settings decode")
        check(try JSONDecoder().decode(AdaptiveTriggerSettings.self, from: encoder.encode(triggers)) == triggers, "Selection round-trips")
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
        let legacyController = try encoder.encode(ControllerSettings.default)
        check(!String(decoding: legacyController, as: UTF8.self).contains("enhancements"), "New optional settings preserve legacy checksums")
        check(try JSONDecoder().decode(ControllerSettings.self, from: legacyController) == .default, "Legacy controller settings still decode")
        var enhanced = ControllerSettings.default
        enhanced.enhancements = ControllerEnhancements()
        enhanced.enhancements?.gyroEnabled = true
        var applied = ControllerSettings.default
        applied.calibration.leftTrigger.deadzone = 0.3
        applied.apply(enhanced.perPreset)
        check(applied.enhancements?.gyroEnabled == true && applied.calibration.leftTrigger.deadzone == 0.3, "Profiles transfer gyro but retain local trigger calibration")
        check(applied.calibration.leftTrigger.apply(to: 0.2) == 0 && applied.calibration.leftTrigger.apply(to: 1) == 1, "Trigger offset suppresses rest and preserves full output")
        var curve = ControllerEnhancements()
        curve.rumbleExponent = 2; curve.rumbleGain = 2
        check(abs(curve.rumble(0.5, global: 0.5) - 0.25) < 0.001, "Rumble applies exponent, profile gain and global gain")
        check(curve.rumble(0, global: 2) == 0 && curve.rumble(1, global: 2) == 1, "Rumble silence and saturation are bounded")
        var stages = AdaptiveTriggerCustomParameters.default
        stages.mode = .twoStageFeedback
        check(stages.level(at: 0) == 0 && stages.level(at: 1) == stages.endStrength, "Two-stage effect keeps final resistance")
        stages.mode = .detent; stages.endStrength = 0
        check(stages.level(at: 1) == 0, "Detent releases after breakpoint")
        check(ControllerMotionProjection.yaw(x: 0, y: 0, z: 1, gx: 0, gy: 0, gz: -1) == 1, "Flat-held controller uses Z rotation for yaw")
        check(ControllerMotionProjection.yaw(x: 0, y: 1, z: 0, gx: 0, gy: -1, gz: 0) == 1, "Upright controller uses Y rotation for yaw")
        check(ControllerMotionProjection.yaw(x: .nan, y: 0, z: 0, gx: 0, gy: -1, gz: 0) == 0, "Invalid motion stays neutral")
        check(AdaptiveTriggerPreset.recommendedCatalog.count == 14 && AdaptiveTriggerPreset.recommendedCatalog.first == .off,
              "Catalog offers the fourteen DualSenseX-style modes starting at Off")
        check(AdaptiveTriggerPreset.migrated("semiAutomaticGun") == .automatic && AdaptiveTriggerPreset.migrated("clutchBite") == .brake
              && AdaptiveTriggerPreset.migrated("bowDraw") == .bow && AdaptiveTriggerPreset.migrated("ratchetDetents") == .twoStage,
              "Legacy saved preset names migrate into the current catalog")
        for mode in [AdaptiveTriggerPreset.pistol, .sniper, .automatic, .machineGun, .bow, .twoStage] {
            var envelope = ControllerTriggerEnvelope()
            _ = envelope.sample(preset: mode, pressure: 0, now: 0)
            check(envelope.sample(preset: mode, pressure: 1, now: 1.0/60).intensity > 0,
                  "\(mode.rawValue) fires feedback once pressure crosses its wall")
        }
        check(ControllerAimMath.axis(0.02, deadzone: 0.08) == 0, "Touch noise has a firm neutral zone")
        check(ControllerAimMath.smooth(0, previous: 0.9, dt: 1.0/60) == 0, "Gyro releases in one update without a residual tail")
        check(ControllerAimMath.smooth(1, previous: 0, dt: 1.0/60) > 0.85, "Motion filter responds within one 60 Hz update")
        check(ControllerAimMath.tiltDelta(0.04, centre: 0) == 0, "Tilt inside three degrees is neutral")
        check(abs(ControllerAimMath.tiltDelta(.pi/9, centre: 0) - 1) < 0.0001, "Held twenty-degree tilt holds full stick")
        check(ControllerAimMath.tiltDelta(0, centre: 0) == 0, "Returning to tilt centre releases stick")
        check(ControllerAimMath.axis(.nan, deadzone: 0.08) == 0, "Invalid sensor sample remains neutral")
        var flick = ControllerFlickState()
        _ = flick.sample(rate: 0, angle: 0, now: 0)
        check(flick.sample(rate: 2, angle: 0.2, now: 0.1) == 1, "Up flick emits up pulse")
        check(flick.sample(rate: -2, angle: 0.1, now: 0.2) == 0, "Return stroke cannot downshift")
        check(flick.sample(rate: 0, angle: 0.3, now: 0.5) == 0, "Pause away from neutral does not rearm")
        check(flick.sample(rate: -2, angle: 0.1, now: 0.7) == 0, "Delayed return is also suppressed")
        _ = flick.sample(rate: 0, angle: 0, now: 1)
        _ = flick.sample(rate: 0, angle: 0, now: 1.2)
        check(flick.sample(rate: -2, angle: -0.2, now: 1.3) == -1, "Deliberate down flick works after settling at neutral")
        check(flick.sample(rate: 2, angle: -0.1, now: 1.5) == 0, "Return from a down flick cannot upshift")
        _ = flick.sample(rate: 0, angle: -0.05, now: 1.6)
        _ = flick.sample(rate: 0, angle: 0, now: 1.66)
        check(flick.sample(rate: -2, angle: 0.02, now: 1.7) == -1, "Rapid repeated downshift fires without a full return to neutral")
        var returnFlick = ControllerFlickState()
        _ = returnFlick.sample(rate: 0, angle: 0, now: 0)
        check(returnFlick.sample(rate: 2, angle: 0.1, now: 0.1) == 1, "Up flick fires before any tilt")
        _ = returnFlick.sample(rate: 0, angle: 0.15, now: 0.3)
        _ = returnFlick.sample(rate: 0, angle: 0.15, now: 0.36)
        check(returnFlick.sample(rate: -2, angle: 0.15, now: 0.45) == 0, "Return stroke toward neutral is suppressed even after rearming")
        check(returnFlick.sample(rate: -2, angle: 0.01, now: 0.55) == -1, "Deliberate opposite flick crossing neutral fires")
        var adaptive = ControllerAdaptiveFilter()
        var noise: Float = 0
        for i in 0..<120 { let v = adaptive.sample(0.2 + (i % 2 == 0 ? 0.01 : -0.01), dt: 1.0/60); if i > 60 { noise = max(noise, abs(v - 0.2)) } }
        check(noise < 0.006, "Adaptive filter reduces steady-input jitter")
        adaptive.reset()
        check(adaptive.sample(1, dt: 1.0/60) > 0.7, "Fast movement passes over 70 percent within one sample")
        check(adaptive.sample(0, dt: 1.0/60) == 0, "Adaptive filter preserves immediate release")
        let at = ControllerVector2(x: 0.5, y: 0.4)
        check(ControllerAimMath.trackpad(current: at, previous: at, dt: 1.0/60, sensitivity: 0.35) == .zero, "Stationary finger never keeps turning camera")
        let slide = ControllerAimMath.trackpad(current: at, previous: .zero, dt: 1.0/60, sensitivity: 0.35)
        check(slide.x > 0 && slide.y > 0, "Trackpad motion follows finger direction")
        var usb = [UInt8](repeating: 0, count: 64); usb[0] = 1; usb[33] = 0x80; usb[37] = 0x80
        check(DualSenseTouchPacket.decode(usb)?.first?.isActive == false, "USB contact flag detects actual release")
        usb[33] = 0; usb[34] = 0xc0; usb[35] = 0xc3; usb[36] = 0x21
        let touch = DualSenseTouchPacket.decode(usb)?.first
        check(touch?.isActive == true && abs(touch!.position.x) < 0.002 && abs(touch!.position.y) < 0.002, "USB packed touch coordinates decode centre")
        var bt = [UInt8](repeating: 0, count: 78); bt[0] = 0x31
        for i in 0..<8 { bt[34+i] = usb[33+i] }
        check(DualSenseTouchPacket.decode(bt)?.first == touch, "Bluetooth touch layout matches USB")
        check(DualSenseTouchPacket.decode([1,0,0]) == nil, "Truncated reports cannot create touches")
        var precision = ControllerPrecisionGyro()
        var stableNeutral = true
        for i in 0..<120 {
            let v = precision.sample(ControllerVector2(x: i % 2 == 0 ? 0.001 : -0.001, y: 0.0007), dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12)
            stableNeutral = stableNeutral && v == .zero
        }
        check(stableNeutral, "Stationary gyro noise never becomes stick movement")
        var slow = ControllerVector2.zero
        for _ in 0..<30 { slow = precision.sample(ControllerVector2(x: 0.008, y: 0), dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12) }
        check(slow.x > 0.12 && slow.y == 0, "Slow gyro below old dead zone now crosses game dead zone")
        check(precision.fine.x > 0 && precision.fine.x < 0.01, "Physical-stick blending uses fine gyro correction without a resistance floor")
        check(precision.sample(.zero, dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12) == .zero, "Gyro stops without a filter tail at sensor rest")
        let slowGain = ControllerAimMath.trackpad(current: ControllerVector2(x: 0.5, y: 0), previous: .zero, dt: 0.015, sensitivity: 0.05).x
        let fastGain = ControllerAimMath.trackpad(current: ControllerVector2(x: 0.5, y: 0), previous: .zero, dt: 0.015, sensitivity: 1).x
        check(fastGain > slowGain + 0.2 && fastGain < 1, "Touch sensitivity remains distinct for fast swipes instead of clipping both to maximum")
        precision.reset()
        for _ in 0..<30 { slow = precision.sample(ControllerVector2(x: 0.008, y: 0.001), dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12) }
        check(slow.x > 0.12 && slow.y == 0, "Slow horizontal aiming does not amplify vertical sensor noise")
        var turnaround = ControllerPrecisionGyro()
        for _ in 0..<40 { _ = turnaround.sample(ControllerVector2(x: 0.6, y: 0), dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12) }
        var reversed: Float = 1
        for i in 0..<8 {
            let rate: Float = i < 3 ? 0 : -0.6
            reversed = turnaround.sample(ControllerVector2(x: rate, y: 0), dt: 1.0/60, noise: 0.003, sensitivity: 0.45, floor: 0.12).x
        }
        check(reversed < 0 && abs(reversed + 0.12) > 0.15, "Reversed gyro keeps its full response across the turnaround pause")
        let defaults = ControllerEnhancements()
        check((defaults.gyroStick ?? .right) == .right && (defaults.touchpadStick ?? .right) == .right, "Both aim targets default to right stick")
        check(defaults.effectiveGyroNoiseThreshold == 0.003, "Legacy default motion dead zone migrates to precision threshold")
        var chosen = defaults; chosen.gyroStick = .left; chosen.touchpadStick = .right
        let decodedChosen = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONEncoder().encode(chosen))
        check(decodedChosen.gyroStick == .left && decodedChosen.touchpadStick == .right, "Independent stick targets survive profile round trip")
        check(defaults.gyroMode == .off, "Disabled gyro maps to the Off mode")
        var modeProbe = defaults
        modeProbe.setGyroMode(.steering)
        check(modeProbe.gyroEnabled && modeProbe.gyroStick == .left && modeProbe.gyroMode == .steering, "Steering mode selects the left stick")
        modeProbe.setGyroMode(.flickShift)
        check(modeProbe.gyroFlickMode == true && modeProbe.gyroStick == .right && modeProbe.gyroMode == .flickShift, "Flick mode returns to the right stick")
        let held = ControllerAimMath.steering(angle: 0.15, centre: 0, range: .pi / 6, floor: 0.12)
        check(held > 0.12, "Held steering angle produces a persistent stick position")
        let cruising = ControllerAimMath.steering(angle: 0.06, centre: 0, range: .pi / 6, floor: 0.30)
        check(cruising > 0.30, "Slow cruising tilt clears a large game inner dead zone")
        var wheelFilter = ControllerAdaptiveFilter()
        var wheel: Float = 0
        for _ in 0..<600 { wheel = wheelFilter.sample(held, dt: 1.0/60) }
        check(abs(wheel - held) < 0.001, "Steering does not recenter during ten seconds held at an angle")
        var serviceWheel = ControllerAdaptiveFilter()
        var heldWheel: Float = 0
        for _ in 0..<120 { heldWheel = serviceWheel.sample(held, dt: 1.0/60, minimum: 12, beta: 4, neutralImmediately: false) }
        check(abs(heldWheel - held) < 0.001, "Steering filter holds the angle without a reset-on-neutral restart")
        check(ControllerAimMath.steering(angle: 0, centre: 0, range: .pi / 6, floor: 0.12) == 0, "Steering returns to zero only at saved neutral")
        check(ControllerAimMath.steering(angle: -0.15, centre: 0, range: .pi / 6, floor: 0.12) < -0.12, "Steering holds in both directions")
        check(ControllerAimMath.touchGain(2, sensitivity: 3, floor: 0) > ControllerAimMath.touchGain(2, sensitivity: 0.05, floor: 0) + 0.7, "Touch sensitivity changes cached filtered movement immediately")
        let halfSpeed = ControllerAimMath.touchGain(1, sensitivity: 0.35, floor: 0)
        check(abs(halfSpeed - ControllerAimMath.touchGain(2, sensitivity: 0.35, floor: 0) / 2) < 0.001, "Touch output is linear in finger speed instead of saturating early")
        var servo = ControllerTouchServo()
        var moment = 0.0
        for _ in 0..<10 {
            servo.move(dx: 0.02, dy: 0, sensitivity: 0.35, at: moment)
            moment += 1.0 / 66
            _ = servo.sample(dt: 1.0/60, floor: 0.12, now: moment, contact: true)
        }
        check(abs(servo.target.x - 0.07) < 0.0001, "Touch travel accumulates into the servo target")
        servo.move(dx: 0.15, dy: 0, sensitivity: 0.35, at: moment)
        moment += 1.0 / 60
        var burst = servo.sample(dt: 1.0/60, floor: 0.12, now: moment, contact: true)
        check(burst.x > 0.9, "A flick commands near-full camera speed immediately")
        moment += 1.0 / 60
        for _ in 0..<60 {
            moment += 1.0 / 60
            burst = servo.sample(dt: 1.0/60, floor: 0.12, now: moment, contact: true)
        }
        check(abs(burst.x) < 0.001 && abs(servo.target.x - servo.delivered.x) < 0.006, "The servo delivers the flick with a short glide, then rests with no creep")
        servo.move(dx: 0.004, dy: 0, sensitivity: 0.35, at: moment)
        moment += 1.0 / 60
        let glide = servo.sample(dt: 1.0/60, floor: 0.12, now: moment, contact: true)
        check(glide.x > 0.12 && glide.x < 0.5, "A very slow drag still glides above the game dead zone")
        servo.stop()
        let lifted = servo.sample(dt: 1.0/60, floor: 0.12, now: moment + 0.1, contact: false)
        check(lifted == .zero, "Lifting the finger stops the camera immediately")
        var walk = ControllerTouchServo()
        var shiver = 0.0
        for i in 0..<60 {
            walk.move(dx: i % 3 == 2 ? -0.002 : 0.002, dy: 0, sensitivity: 0.35, at: shiver)
            shiver += 0.016
            _ = walk.sample(dt: 1.0/60, floor: 0.12, now: shiver, contact: true)
        }
        for _ in 0..<30 {
            shiver += 0.016
            _ = walk.sample(dt: 1.0/60, floor: 0.12, now: shiver, contact: true)
        }
        check(abs(walk.delivered.x) < 0.05, "Coordinate shiver on a resting finger cannot walk the camera away")
        func wheelReading(_ angle: Double, gravity: Bool = false, pitch: Double = 0) -> ControllerWheelMotion {
            let vector = ControllerMotionVector(x: sin(angle)*cos(pitch), y: -cos(angle)*cos(pitch), z: -sin(pitch))
            return ControllerWheelMotion.select(hasGravity: gravity, gravity: gravity ? vector : .zero,
                                                acceleration: vector)!
        }
        let fallback = wheelReading(0.2)
        check(fallback.source == .acceleration, "Wheel uses acceleration when separate gravity is unavailable")
        check(wheelReading(0.2, gravity: true).source == .gravity, "Valid separated gravity is preferred")
        check(ControllerWheelMotion.select(hasGravity: true, gravity: .zero, acceleration: fallback.vector)?.source == .acceleration,
              "Zero gravity cannot silently disable steering when acceleration is valid")
        check(ControllerWheelMotion.select(hasGravity: false, gravity: .zero, acceleration: .zero) == nil,
              "Missing sensor data is unavailable rather than a valid zero angle")
        var sensorWheel = ControllerWheelState()
        _ = sensorWheel.sample(wheelReading(0), rate: .zero, now: 0)
        var time = 0.0
        for _ in 0..<600 {
            time += 1.0/60
            _ = sensorWheel.sample(wheelReading(0.2), rate: .zero, now: time)
        }
        check(abs(sensorWheel.angle - 0.2) < 0.0001, "Acceleration-only wheel holds an angle for ten seconds with zero rotation rate")
        for _ in 0..<120 {
            time += 1.0/60
            _ = sensorWheel.sample(wheelReading(0.201), rate: .zero, now: time)
        }
        check(sensorWheel.angle > 0.2009, "Held wheel registers a 0.057 degree adjustment")
        sensorWheel.center()
        check(sensorWheel.angle == 0, "Center saves the current measured wheel angle")
        for _ in 0..<120 {
            time += 1.0/60
            _ = sensorWheel.sample(wheelReading(0.101), rate: .zero, now: time)
        }
        check(abs(sensorWheel.angle + 0.1) < 0.0001, "Wheel turns relative to a nonzero saved centre")
        check(sensorWheel.sample(nil, rate: .zero, now: time + 1) == nil && !sensorWheel.available,
              "Unavailable wheel sensor suppresses synthetic steering")
        var fastWheel = ControllerWheelState()
        _ = fastWheel.sample(wheelReading(0), rate: .zero, now: 0)
        for frame in 1...30 {
            _ = fastWheel.sample(wheelReading(Double(frame)/60),
                rate: ControllerMotionVector(x: 0, y: 0, z: -1), now: Double(frame)/60)
        }
        check(abs(fastWheel.angle - 0.5) < 0.001, "Gyro prediction tracks fast wheel turns without accelerometer filter lag")
        var tiltedWheel = ControllerWheelState()
        _ = tiltedWheel.sample(wheelReading(0, pitch: 0.6), rate: .zero, now: 0)
        for frame in 1...180 {
            _ = tiltedWheel.sample(wheelReading(-0.3, pitch: 0.6), rate: .zero, now: Double(frame)/60)
        }
        check(abs(tiltedWheel.angle + 0.3) < 0.001, "Wheel angle works with a face-toward-player pitched grip")
        // Gravity leaves the wheel plane entirely (wheel axis near vertical):
        // steering must continue on the wheel-axis gyro rate and re-anchor
        // seamlessly once the plane becomes observable again.
        var lockedWheel = ControllerWheelState()
        _ = lockedWheel.sample(wheelReading(0, gravity: true, pitch: 0.6), rate: .zero, now: 0)
        var lockedTime = 0.0
        for frame in 1...60 {
            lockedTime = Double(frame) / 60
            _ = lockedWheel.sample(wheelReading(0.5 * lockedTime, gravity: true, pitch: 0.6),
                rate: ControllerMotionVector(x: 0, y: 0, z: -0.5), now: lockedTime)
        }
        check(lockedWheel.available && abs(lockedWheel.angle - 0.5) < 0.001,
              "Observable steering reaches a known angle before the axis locks")
        var expectedLocked = 0.5 * lockedTime
        var lostLockedFrames = 0
        for _ in 1...120 {
            lockedTime += 1.0/60
            expectedLocked += 1.0/60
            // pitch 1.45 rad leaves ~0.014 in-plane magnitude, under the 0.04 limit
            if lockedWheel.sample(wheelReading(expectedLocked, gravity: true, pitch: 1.45),
                rate: ControllerMotionVector(x: 0, y: 0, z: -1), now: lockedTime) == nil {
                lostLockedFrames += 1
            }
        }
        check(lostLockedFrames == 0 && lockedWheel.available,
              "Steering continues while the wheel axis points at the ceiling")
        check(abs(lockedWheel.angle - Float(atan2(sin(expectedLocked), cos(expectedLocked)))) < 0.05,
              "Axis-locked steering tracks the wheel rate without drifting away")
        for _ in 1...60 {
            lockedTime += 1.0/60
            expectedLocked += 1.0/60
            _ = lockedWheel.sample(wheelReading(expectedLocked, gravity: true, pitch: 0.6),
                rate: ControllerMotionVector(x: 0, y: 0, z: -1), now: lockedTime)
        }
        check(abs(lockedWheel.angle - Float(atan2(sin(expectedLocked), cos(expectedLocked)))) < 0.02,
              "Wheel re-anchors to gravity on return from the axis-locked zone")
        var quietWheel = ControllerWheelState()
        _ = quietWheel.sample(wheelReading(0), rate: .zero, now: 0)
        var maximumNoise: Float = 0
        var quietResponse = ControllerSteeringResponse()
        quietResponse.reset(at: 0)
        for frame in 1...240 {
            let value = quietWheel.sample(wheelReading(frame % 2 == 0 ? 0.003 : -0.003), rate: .zero, now: Double(frame)/60)!
            let output = quietResponse.sample(target: Double(value), now: Double(frame)/60, smoothing: 0.5)
            if frame > 60 { maximumNoise = max(maximumNoise, abs(output)) }
        }
        check(maximumNoise < 0.0004, "Final steering smoother removes over 86% of alternating stationary angle jitter")
        let minute = ControllerAimMath.steering(angle: 0.001, centre: 0, range: 0.7, floor: 0)
        check(minute > 0, "Sub-degree wheel changes are no longer discarded by a hard neutral zone")
        check(abs(ControllerAimMath.steering(angle: 0.002, centre: 0, range: 0.7, floor: 0) - minute*2) < 0.000001,
              "Steering response is proportional rather than a power curve")
        check(ControllerAimMath.steering(angle: -0.001, centre: 0, range: 0.7, floor: 0) == -minute,
              "Small left and right turns have symmetric output")
        var reversalWheel = ControllerWheelState()
        _ = reversalWheel.sample(wheelReading(0), rate: .zero, now: 0)
        var expectedAngle = 0.0
        var peakError: Float = 0
        var lostFrames = 0
        for frame in 1...120 {
            let speed = frame <= 30 ? -2.0 : (frame <= 90 ? 2.0 : -2.0)
            expectedAngle += speed / 60
            // A brief acceleration rejection exactly when direction reverses.
            let reading: ControllerWheelMotion? = (31...33).contains(frame) || (91...93).contains(frame) ? nil : wheelReading(expectedAngle)
            if let actual = reversalWheel.sample(reading, rate: ControllerMotionVector(x: 0, y: 0, z: -speed), now: Double(frame)/60) {
                peakError = max(peakError, abs(actual - Float(expectedAngle)))
            } else { lostFrames += 1 }
        }
        check(lostFrames == 0 && peakError < 0.001, "Fast bidirectional reversals bridge three rejected samples without centering or lag")
        check(reversalWheel.bridgedSamples == 6, "Short sensor rejection uses bounded gyro prediction")
        for frame in 121...36120 {
            _ = reversalWheel.sample(wheelReading(expectedAngle), rate: .zero, now: Double(frame)/60)
        }
        check(abs(reversalWheel.angle - Float(expectedAngle)) < 0.0001, "Absolute steering remains held for ten simulated minutes")
        let beforeOldSample = reversalWheel.angle
        _ = reversalWheel.sample(wheelReading(1), rate: .zero, now: 600)
        check(reversalWheel.angle == beforeOldSample, "Out-of-order sample cannot rewind the wheel")
        check(reversalWheel.sample(nil, rate: .zero, now: 603) == nil, "Sustained sensor loss releases steering instead of sticking forever")
        var noRateWheel = ControllerWheelState()
        _ = noRateWheel.sample(wheelReading(0), rate: .zero, now: 0, hasRate: false)
        check(noRateWheel.sample(nil, rate: .zero, now: 0.016, hasRate: false) == nil, "Missing rotation sensor cannot pretend to predict a turn")
        check(abs(ControllerAimMath.steering(angle: .pi/3, centre: 0, range: .pi*2/3, floor: 0) - 0.5) < 0.0001,
              "120-degree full lock gives half steering at 60 degrees")
        check(ControllerAimMath.steering(angle: 0.01, centre: 0, range: 1, floor: 0.3, deadzone: 0.02) == 0,
              "Optional center dead zone suppresses rest jitter")
        check(abs(ControllerAimMath.steering(angle: 0.5, centre: 0, range: 1, floor: 0, exponent: 2, inverted: true) + 0.25) < 0.0001,
              "Steering curve and inversion are independent of wheel angle tracking")
        var wheelSettings = ControllerEnhancements()
        wheelSettings.steeringRangeDegrees = 110; wheelSettings.steeringSmoothing = 0.8
        wheelSettings.steeringDeadzoneDegrees = 0.5; wheelSettings.steeringExponent = 1.4; wheelSettings.steeringInverted = true
        let savedWheel = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONEncoder().encode(wheelSettings))
        check(savedWheel == wheelSettings, "New steering controls survive profile save and reload")
        for smooth in [0.0, 0.5, 1.0] {
            for direction in [-1.0, 1.0] {
                var preciseWheel = ControllerWheelState()
                _ = preciseWheel.sample(wheelReading(0), rate: .zero, now: 0)
                var maxSlowError: Float = 0
                var slowResponse = ControllerSteeringResponse()
                slowResponse.reset(at: 0)
                // Deliberately inverted gyro projection: it must not fight angle input.
                for frame in 1...600 {
                    let position = direction * Double(frame) / 60 * (Double.pi / 180)
                    _ = preciseWheel.sample(wheelReading(position, gravity: true),
                        rate: ControllerMotionVector(x: 0, y: 0, z: direction * Double.pi / 180), now: Double(frame)/60)
                    let mapped = ControllerAimMath.steering(angle: preciseWheel.angle, centre: 0, range: 25 * .pi/180, floor: 0)
                    let finalOutput = slowResponse.sample(target: Double(mapped), now: Double(frame)/60, smoothing: smooth)
                    maxSlowError = max(maxSlowError, abs(finalOutput * 25 * .pi/180 - Float(position)))
                }
                check(maxSlowError < 0.0015, "One-degree/second center movement stays within 0.086 degrees, smoothing \(smooth), direction \(direction)")
                preciseWheel.reset()
                _ = preciseWheel.sample(wheelReading(0), rate: .zero, now: 0)
                for frame in 1...60 {
                    let position = direction * Double(frame)/60 * 25 * .pi/180
                    _ = preciseWheel.sample(wheelReading(position, gravity: true),
                        rate: ControllerMotionVector(x: 0, y: 0, z: direction * 25 * .pi/180), now: Double(frame)/60)
                }
                let lock = ControllerAimMath.steering(angle: preciseWheel.angle, centre: 0, range: 25 * .pi/180, floor: 0)
                check(abs(lock) > 0.99, "25 physical degrees maps to over 99% target with opposing gyro, smoothing \(smooth), direction \(direction)")
            }
        }
        for smooth in [0.0, 0.5, 1.0] {
            let time = ControllerSteeringResponse.responseTime(smoothing: smooth)
            var step = ControllerSteeringResponse(); step.reset(at: 0)
            let completed = step.sample(target: 1, now: time, smoothing: smooth)
            check(abs(completed - 1) < 0.00001, "Smoothing time matches complete response at setting \(smooth)")
            var heldResponse = ControllerSteeringResponse(); heldResponse.reset(at: 0)
            var previous: Float = 0
            var intermediate = 0
            var monotonic = true
            for frame in 1...180 {
                let result = heldResponse.sample(target: 0.6, now: Double(frame)/60, smoothing: smooth)
                monotonic = monotonic && result >= previous - 0.000001 && result <= 0.600001
                if result > 0.001 && result < 0.599 { intermediate += 1 }
                previous = result
            }
            check(monotonic, "Step progresses without bounce, setting \(smooth)")
            check(intermediate >= 1 && abs(previous - 0.6) < 0.000001, "15-degree step passes through intermediate values and holds exact target")
        }
        var fastResponse = ControllerSteeringResponse(); fastResponse.reset(at: 0)
        var gentleResponse = ControllerSteeringResponse(); gentleResponse.reset(at: 0)
        let fastStart = fastResponse.sample(target: 1, now: 1.0/60, smoothing: 0)
        let gentleStart = gentleResponse.sample(target: 1, now: 1.0/60, smoothing: 1)
        check(gentleStart <= fastStart * 0.21, "Smoothing slider produces a substantial, predictable transition difference")
        var substep = ControllerSteeringResponse(); substep.reset(at: 0)
        var wholeStep = ControllerSteeringResponse(); wholeStep.reset(at: 0)
        let whole = wholeStep.sample(target: 0.7, now: 0.1, smoothing: 0.5)
        var split: Float = 0
        for frame in 1...12 { split = substep.sample(target: 0.7, now: Double(frame)/120, smoothing: 0.5) }
        check(abs(whole - split) < 0.000001, "Time-weighted smoother agrees for one step and twelve substeps")
        var compensationResponse = ControllerSteeringResponse(); compensationResponse.reset(at: 0)
        let tinyTurn = ControllerAimMath.steering(angle: 0.01, centre: 0, range: 0.44, floor: 0.3)
        let smoothedTinyTurn = compensationResponse.sample(target: Double(tinyTurn), now: 1.0/60, smoothing: 0.5)
        check(smoothedTinyTurn > 0 && smoothedTinyTurn < tinyTurn * 0.2, "Final output smoothing also softens the game's dead-zone compensation step")
        var microResponse = ControllerSteeringResponse(); microResponse.reset(at: 0)
        var microOutput: Float = 0
        for frame in 1...120 { microOutput = microResponse.sample(target: 0.0001, now: Double(frame)/60, smoothing: 1) }
        check(abs(microOutput - 0.0001) < 0.00000001, "Smoothing never discards a tiny held steering target")
        var reversalResponse = ControllerSteeringResponse(); reversalResponse.reset(at: 0)
        var reversedSteering: Float = 0
        var reversalBounded = true
        for frame in 1...60 {
            reversedSteering = reversalResponse.sample(target: frame < 15 ? 1 : -1, now: Double(frame)/60, smoothing: 0.5)
            reversalBounded = reversalBounded && reversedSteering.isFinite && abs(reversedSteering) <= 1
        }
        check(reversalBounded, "Rapid reversal remains bounded")
        check(reversedSteering < -0.999, "Reversal settles fully on the new side")
        reversalResponse.reset(at: 1)
        check(reversalResponse.sample(target: 0, now: 1.016, smoothing: 1) == 0, "Center/reset clears all old steering momentum")
        check(reversalResponse.sample(target: 1, now: 2, smoothing: 1) == 0, "Long scheduling gap releases stale output")
        for amplitude in [0.1, 0.3, 0.4, 0.5, 0.8, 1.0, -0.1, -0.3, -0.4, -0.5, -0.8, -1.0] {
            var ramp = ControllerSteeringResponse(); ramp.reset(at: 0)
            var straightRamp = true
            for part in 1...9 {
                let actual = ramp.sample(target: amplitude, now: Double(part) / 60, smoothing: 1)
                straightRamp = straightRamp && abs(Double(actual) - amplitude * Double(part)/9) < 0.000001
            }
            check(straightRamp, "Equal-time increments are equal across the whole step, target \(amplitude)")
        }
        var wholeRangeLinear = true
        for percent in -100...100 {
            let fraction = Float(percent) / 100
            let mapped = ControllerAimMath.steering(angle: fraction * 50 * .pi/180, centre: 0, range: 50 * .pi/180, floor: 0)
            wholeRangeLinear = wholeRangeLinear && abs(mapped - fraction) < 0.000001
        }
        check(wholeRangeLinear, "Every 1% angle increment maps to 1% target, including 30–50% travel")
        var firstSignal = ControllerSteeringResponse(); firstSignal.reset(at: 0)
        var secondSignal = ControllerSteeringResponse(); secondSignal.reset(at: 0)
        var combinedSignal = ControllerSteeringResponse(); combinedSignal.reset(at: 0)
        var superposition = true
        for frame in 1...600 {
            let first = sin(Double(frame) * 0.071) * 0.3
            let second = cos(Double(frame) * 0.033) * 0.4
            let now = Double(frame)/60
            let a = firstSignal.sample(target: first, now: now, smoothing: 1)
            let b = secondSignal.sample(target: second, now: now, smoothing: 1)
            let ab = combinedSignal.sample(target: first + second, now: now, smoothing: 1)
            superposition = superposition && abs(ab - a - b) < 0.000001
        }
        check(superposition, "Smoothing obeys linear superposition for changing targets and reversals")
        var limitedSteering = ControllerEnhancements()
        check(limitedSteering.effectiveSteeringMaximum == 1, "Existing profiles retain full steering output")
        limitedSteering.steeringMaximum = 0.6
        let restoredSteering = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONEncoder().encode(limitedSteering))
        check(restoredSteering.effectiveSteeringMaximum == 0.6, "Maximum steering survives profile serialization")
        limitedSteering.steeringMaximum = .nan
        check(limitedSteering.effectiveSteeringMaximum == 1, "Invalid maximum steering safely falls back to full output")
        check(AdaptiveTriggerPreset.recommendedCatalog.count == 14, "DualSenseX-style default menu offers fourteen built-in modes")
        check(AdaptiveTriggerPreset.recommendedCatalog.first == .off && AdaptiveTriggerPreset.recommendedCatalog.last == .choppy, "Catalog order mirrors the DualSenseX menu")
        var click = ControllerTriggerEnvelope()
        _ = click.sample(preset: .twoStage, pressure: 0, now: 0)
        check(click.sample(preset: .twoStage, pressure: 0.9, now: 1.0/60).intensity == 0.7, "Two-stage break fires once at the wall")
        check(click.sample(preset: .twoStage, pressure: 0.9, now: 2.0/60).intensity == 0, "Two-stage wall holds without repeating impulses")
        check(click.sample(preset: .twoStage, pressure: 0, now: 3.0/60).intensity == 0.60, "Two-stage release produces the digital click kick")
        var semi = ControllerTriggerEnvelope()
        _ = semi.sample(preset: .pistol, pressure: 0, now: 0)
        _ = semi.sample(preset: .pistol, pressure: 0.6, now: 1.0/60)
        check(semi.sample(preset: .pistol, pressure: 0, now: 2.0/60).intensity == 0.60, "Semi-automatic release kicks after the break")
        var machine = ControllerTriggerEnvelope()
        _ = machine.sample(preset: .machineGun, pressure: 0, now: 0)
        let bursts = machine.sample(preset: .machineGun, pressure: 0.8, now: 1.0/60)
        check(bursts.intensity > 0 && bursts.forceBoost > 0, "Machine mode rhythm combines haptics and bounded recoil")
        var shot = ControllerTriggerEnvelope()
        _ = shot.sample(preset: .pistol, pressure: 0, now: 0)
        check(shot.sample(preset: .pistol, pressure: 0.5, now: 0.016).intensity > 0, "Pistol break produces one impulse")
        check(shot.sample(preset: .pistol, pressure: 0.5, now: 0.032).intensity == 0, "Holding a pistol does not repeat break impulses")
        check(shot.sample(preset: .pistol, pressure: 0, now: 0.048).intensity == 0.6, "Pistol release produces a separate kick")
        check(shot.sample(preset: .pistol, pressure: 0, now: 0.064).intensity == 0, "Release kick cannot repeat at rest")
        var automatic = ControllerTriggerEnvelope()
        _ = automatic.sample(preset: .automatic, pressure: 0, now: 0)
        let firing = automatic.sample(preset: .automatic, pressure: 1, now: 0.016)
        check(firing.intensity > 0 && firing.forceBoost > 0, "Automatic fire combines haptics and bounded resistance recoil")
        check(automatic.sample(preset: .automatic, pressure: 1, now: 0.05).forceBoost == 0, "Recoil spike expires while trigger stays held")
        check(automatic.sample(preset: .automatic, pressure: 0, now: 0.07).forceBoost == 0, "Release clears recoil immediately")
        var disturbed = ControllerWheelState()
        _ = disturbed.sample(wheelReading(0), rate: .zero, now: 0)
        let disturbedAngle = disturbed.sample(wheelReading(0.25), rate: .zero, now: 1.0/60)!
        check(abs(disturbedAngle) < 0.03, "A one-frame accelerometer disturbance cannot abruptly steer by fourteen degrees")
        var slowRaw = ControllerWheelState()
        _ = slowRaw.sample(wheelReading(0), rate: .zero, now: 0)
        var rawError: Float = 0
        for frame in 1...600 {
            let angle = Double(frame)/60 * Double.pi/180
            let actual = slowRaw.sample(wheelReading(angle), rate: ControllerMotionVector(x: 0, y: 0, z: -Double.pi/180), now: Double(frame)/60)!
            rawError = max(rawError, abs(actual - Float(angle)))
        }
        check(rawError < 0.001, "Gyro-assisted raw acceleration follows one-degree-per-second turns without deadband")
        print("\(checks) controller/model contract checks passed. No hardware or user data touched.")
    }
}
