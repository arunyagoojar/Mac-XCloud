import Foundation
import simd

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
        let dt: Double = 1.0 / 60.0

        // MARK: - Adaptive triggers, macros, shortcuts (unchanged contract)

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


        // MARK: - Simulated controller (GameController axes; flat face-up = identity)

        func rx(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(1,0,0), SIMD3(0,cos(a),-sin(a)), SIMD3(0,sin(a),cos(a))]) }
        func ry(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(cos(a),0,sin(a)), SIMD3(0,1,0), SIMD3(-sin(a),0,cos(a))]) }
        func rz(_ a: Double) -> simd_double3x3 { simd_double3x3(rows: [SIMD3(cos(a),-sin(a),0), SIMD3(sin(a),cos(a),0), SIMD3(0,0,1)]) }
        let deg = Double.pi / 180
        /// Steering = roll about the world's forward axis; pitch tilts the
        /// controller toward the player; yaw turns it on the spot.
        func orientation(bank: Double, pitch: Double, yaw: Double) -> simd_double3x3 { rz(yaw) * ry(-bank) * rx(pitch) }
        struct Reading { var t: Double; var gyro: MotionVector; var acc: MotionVector; var gravity: MotionVector }
        var noise: UInt64 = 0x9E3779B97F4A7C15
        func gaussian() -> Double {
            func uniform() -> Double { noise = noise &* 6364136223846793005 &+ 1442695040888963407; return Double(noise >> 11) / Double(1 << 53) }
            return (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform())
        }
        func simulate(_ duration: Double, rate: Double = 250, bias: MotionVector = MotionVector(0.4, -0.3, 0.5) * (Double.pi / 180),
                      gyroNoise: Double = 0.15 * (Double.pi / 180), accNoise: Double = 0.004, rumble: Bool = false,
                      translation: ((Double) -> MotionVector)? = nil,
                      pose: (Double) -> (bank: Double, pitch: Double, yaw: Double)) -> [Reading] {
            var out: [Reading] = []; var t = 0.0; let h = 1 / rate
            while t < duration {
                let p = pose(t), q = pose(t + 1e-4)
                let r = orientation(bank: p.bank, pitch: p.pitch, yaw: p.yaw)
                let w = r.transpose * ((orientation(bank: q.bank, pitch: q.pitch, yaw: q.yaw) - r) * 1e4)
                let truth = r.transpose * MotionVector(0, 0, -1)
                var acc = truth + MotionVector(gaussian(), gaussian(), gaussian()) * accNoise
                if let translation { acc += r.transpose * (-translation(t)) }
                var gyro = MotionVector(w[1][2], w[2][0], w[0][1]) + bias + MotionVector(gaussian(), gaussian(), gaussian()) * gyroNoise
                if rumble {
                    let a = sin(2 * .pi * 155 * t), b = sin(2 * .pi * 62 * t)
                    acc += MotionVector(0.22 * a, 0.18 * b, 0.25 * a * b + 0.1 * b)
                    gyro += MotionVector(2.5 * b, 1.8 * a, 2.2 * a) * (Double.pi / 180)
                }
                out.append(Reading(t: t, gyro: gyro, acc: acc, gravity: truth)); t += h
            }
            return out
        }
        /// Feeds readings through fusion + steering at a 120 Hz tick.
        func steer(_ readings: [Reading], bias: MotionVector = .zero, vibrating: Bool = false,
                   configuration: SteeringWheelEngine.Configuration = .init()) -> [(t: Double, angle: Double, truth: Double, output: Double)] {
            var fusion = MotionFusion(bias: bias), clock = MotionSampleClock(), wheel = SteeringWheelEngine(configuration: configuration)
            var result: [(Double, Double, Double, Double)] = []; var i = 0; var tick = 0.0; var truth = 0.0
            while tick < readings.last!.t {
                while i < readings.count && readings[i].t <= tick {
                    fusion.ingest(rotationRate: readings[i].gyro, acceleration: readings[i].acc, dt: clock.step(arrival: readings[i].t), vibrating: vibrating)
                    truth = SteeringGeometry.bank(gravity: readings[i].gravity); i += 1
                }
                let output = wheel.update(gravity: fusion.gravity, dt: 1.0 / 120)
                result.append((tick, wheel.angle + wheel.centerBank, truth, output)); tick += 1.0 / 120
            }
            return result
        }
        func rms(_ values: [Double]) -> Double { (values.map { $0 * $0 }.reduce(0, +) / Double(max(values.count, 1))).squareRoot() }

        // MARK: - Sensor fusion and sample timing

        var clock = MotionSampleClock()
        var stamps: [Double] = []
        for frame in 0..<400 { stamps.append(floor(Double(frame) * 0.004 / 0.0167) * 0.0167) }   // 4 reports per 60 Hz burst
        let clockSteps = stamps.map { clock.step(arrival: $0) }
        check(abs(clockSteps.reduce(0, +) - stamps.last!) < 0.03, "Bursty report delivery integrates the real elapsed time")
        check(abs(clock.nominalInterval - 0.004) < 0.0008, "The report interval is learned from bursty delivery")

        var restingFusion = MotionFusion()
        for reading in simulate(10, pose: { _ in (0, 35 * deg, 0) }) {
            restingFusion.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false)
        }
        check(simd_length(restingFusion.bias - MotionVector(0.4, -0.3, 0.5) * deg) < 0.05 * deg, "A controller resting on a table has its gyro offset measured")
        check(restingFusion.biasSource == .rested, "A table rest counts as a measurement")

        // Held in the hands: tremor-level noise, then a slow deliberate turn
        // that keeps gravity put (pure yaw). It must not be taken for drift.
        let trueBias = MotionVector(0.4, -0.3, 0.5) * deg
        var heldMeasured = MotionFusion(bias: trueBias, source: .rested)
        for reading in simulate(6, gyroNoise: 0.7 * deg, pose: { t in (0, 35 * deg, t < 2 ? 0 : 0.8 * deg * (t - 2)) }) {
            heldMeasured.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false)
        }
        check(simd_length(heldMeasured.bias - trueBias) < 0.01 * deg, "A measured offset is never overwritten while the controller is held")
        var heldLearning = MotionFusion()
        for reading in simulate(8, gyroNoise: 0.7 * deg, pose: { t in (0, 35 * deg, t < 4 ? 0 : 0.8 * deg * (t - 4)) }) {
            heldLearning.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false)
        }
        check(heldLearning.biasSource < .rested, "Holding the controller is not mistaken for a table rest")
        check(abs(heldLearning.bias.z * cos(35 * deg) + heldLearning.bias.y * sin(35 * deg)) < 0.25 * deg,
              "A slow deliberate turn is not learned as drift")
        // A lap or a stand that sways slowly (breathing) is not a table.
        var lap = MotionFusion()
        for reading in simulate(12, gyroNoise: 0.05 * deg, pose: { t in (0, (35 + 0.4 * sin(2 * .pi * 0.25 * t)) * deg, 0) }) {
            lap.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false)
        }
        check(simd_length(lap.bias - trueBias) < 0.12 * deg || lap.biasSource < .rested, "Slow sway on a lap does not corrupt the measurement")
        var calibrating = MotionFusion()
        calibrating.beginCalibration(duration: 1)
        for reading in simulate(1.5, pose: { _ in (0, 0, 0) }) { calibrating.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false) }
        check(calibrating.calibration == .succeeded && simd_length(calibrating.bias - MotionVector(0.4, -0.3, 0.5) * deg) < 0.05 * deg, "Explicit calibration measures the bias")
        var moved = MotionFusion()
        moved.beginCalibration(duration: 1)
        for reading in simulate(1.5, pose: { t in (0, 20 * deg * t, 0) }) { moved.ingest(rotationRate: reading.gyro, acceleration: reading.acc, dt: 0.004, vibrating: false) }
        check(moved.calibration == .failedMoved, "Calibration refuses a moving controller")
        var nonfinite = MotionFusion()
        nonfinite.ingest(rotationRate: MotionVector(.nan, 0, 0), acceleration: MotionVector(0, 0, -1), dt: 0.004, vibrating: false)
        check(nonfinite.gravity == nil && nonfinite.samples == 0, "Non-finite sensor data is ignored")

        // MARK: - Steering

        func driving(_ t: Double) -> (bank: Double, pitch: Double, yaw: Double) {
            ((18 * sin(2 * .pi * 0.23 * t) + 9 * sin(2 * .pi * 0.71 * t + 1) + 3 * sin(2 * .pi * 1.9 * t)) * deg,
             (35 + 8 * sin(2 * .pi * 0.17 * t + 0.4)) * deg, 6 * sin(2 * .pi * 0.11 * t) * deg)
        }
        let learned = MotionVector(0.4, -0.3, 0.5) * deg
        let normal = steer(simulate(12, pose: driving)).filter { $0.t > 1.5 }
        check(rms(normal.map { $0.angle - $0.truth }) < 0.8 * deg, "Steering tracks the wheel angle within a degree while driving")
        let rumbleRun = steer(simulate(12, rumble: true, pose: driving), bias: learned, vibrating: true).filter { $0.t > 1.5 }
        check(rms(rumbleRun.map { $0.angle - $0.truth }) < 1.2 * deg, "Game rumble does not disturb the wheel")
        let arms = steer(simulate(12, translation: { t in t.truncatingRemainder(dividingBy: 1) < 0.2 ? MotionVector(0.35, 0, 0.1) : .zero }, pose: driving)).filter { $0.t > 1.5 }
        check(rms(arms.map { $0.angle - $0.truth }) < 1.2 * deg, "Arm movement does not steer the car")
        let crossTalk = steer(simulate(8, pose: { t in (15 * deg, (42 + 32 * sin(2 * .pi * 0.5 * t)) * deg, 0) })).filter { $0.t > 1.5 }.map(\.angle)
        check((crossTalk.max()! - crossTalk.min()!) < 0.5 * deg, "Tilting the controller toward or away never steers (pitch cross-talk)")
        let yawTalk = steer(simulate(8, pose: { t in (15 * deg, 35 * deg, 40 * deg * sin(2 * .pi * 0.4 * t)) })).filter { $0.t > 1.5 }.map(\.angle)
        check((yawTalk.max()! - yawTalk.min()!) < 0.5 * deg, "Turning the controller on the spot never steers (yaw cross-talk)")
        for hold in [5.0, 85.0] {
            let run = steer(simulate(8, pose: { t in var p = driving(t); p.pitch = hold * deg; return p })).filter { $0.t > 1.5 }
            check(rms(run.map { $0.angle - $0.truth }) < 0.8 * deg, "Steering works held flat and upright (\(Int(hold))°)")
        }
        let still = steer(simulate(8, rumble: true, pose: { _ in (0, 35 * deg, 0) }), bias: learned, vibrating: true).filter { $0.t > 2 }.map(\.output)
        check(still.map(abs).max()! < 0.06, "A level controller stays centered under rumble")
        let sweep = steer(simulate(6, pose: { t in ((-10 + 20 * min(max((t - 1.5) / 4, 0), 1)) * deg, 35 * deg, 0) })).filter { $0.t > 1.6 }.map(\.output)
        check(zip(sweep, sweep.dropFirst()).allSatisfy { $1 >= $0 - 0.003 }, "Steering crosses center smoothly with no snapping or reversal")
        let step = steer(simulate(4, pose: { t in let x = min(max((t - 2) / 0.12, 0), 1); return (25 * deg * x * x * (3 - 2 * x), 35 * deg, 0) }))
        let handAt = step.first { abs($0.truth) > 0.9 * 25 * deg }!.t, wheelAt = step.first { abs($0.angle) > 0.9 * 25 * deg }!.t
        check(wheelAt - handAt < 0.02 && step.map { abs($0.angle) }.max()! < 25.6 * deg, "A quick turn arrives within 20 ms without overshoot")

        var recentered = SteeringWheelEngine()
        let tilted = orientation(bank: 6 * deg, pitch: 30 * deg, yaw: 0).transpose * MotionVector(0, 0, -1)
        recentered.update(gravity: tilted, dt: 1.0 / 120)
        recentered.recenter()
        check(abs(recentered.update(gravity: tilted, dt: 1.0 / 120)) < 0.001, "Recenter makes the current hold straight ahead")
        check(recentered.update(gravity: nil, dt: 1.0 / 120) == 0 && !recentered.available, "Lost sensors release the wheel")

        let lock = SteeringResponse.Parameters(fullLock: 40 * deg)
        check(SteeringResponse.output(angle: 0, parameters: lock) == 0, "Center is exactly zero")
        check(abs(SteeringResponse.output(angle: 10 * deg, parameters: lock) - 0.25) < 0.001, "Linear response: a quarter of the range is a quarter of the stick")
        check(SteeringResponse.output(angle: 60 * deg, parameters: lock) == 1 && SteeringResponse.output(angle: -60 * deg, parameters: lock) == -1, "Full lock saturates both ways")
        var quick = lock; quick.exponent = 0.6
        let nearCenter = SteeringResponse.output(angle: 0.05 * deg, parameters: quick)
        check(nearCenter > 0 && nearCenter < 0.01, "A quick curve still has a finite slope at center (noise is not amplified)")
        var compensated = lock; compensated.antiDeadzone = 0.15
        let boostCurve = stride(from: 0.0, through: 10.0, by: 0.01).map { SteeringResponse.output(angle: $0 * deg, parameters: compensated) }
        check(zip(boostCurve, boostCurve.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 < 0.002 },
              "Center boost is continuous: no jump or snap anywhere near center")
        check(SteeringResponse.output(angle: 4 * deg, parameters: compensated) > SteeringResponse.output(angle: 4 * deg, parameters: lock) + 0.1,
              "Center boost makes small turns count more")

        // MARK: - Steering settings migration

        var legacySettings = ControllerEnhancements()
        legacySettings.steeringRangeDegrees = 55
        legacySettings.steeringDeadzoneDegrees = 0.5; legacySettings.steeringExponent = 1.4; legacySettings.steeringInverted = true
        let decodedLegacy = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONEncoder().encode(legacySettings))
        check(abs(decodedLegacy.effectiveSteeringAngleDegrees - 55) < 0.001, "Legacy steering range migrates to the wheel range")
        check(abs(decodedLegacy.effectiveSteeringPhysicalDeadzoneDegrees - 0.5) < 0.001, "Legacy center dead zone migrates")
        check(decodedLegacy == legacySettings, "Migrated settings round-trip unchanged")
        var legacyPayload = try JSONSerialization.jsonObject(with: try encoder.encode(ControllerEnhancements())) as! [String: Any]
        legacyPayload["gyroEnabled"] = true
        legacyPayload["gyroStick"] = "left"
        legacyPayload["steeringFloor"] = 0.3
        legacyPayload["steeringCurve"] = ["linear": [String: Any]()]
        let withOldFloor = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        check(withOldFloor.gyroMode == .steering, "A profile with retired steering fields still decodes")
        check(!String(decoding: try encoder.encode(withOldFloor), as: UTF8.self).contains("steeringFloor"), "Retired fields are never written back")
        let fresh = ControllerEnhancements()
        check(abs(fresh.effectiveSteeringAngleDegrees - 40) < 0.001, "New profiles default to a 40-degree wheel")
        check(fresh.effectiveGyroActivation == .always, "Gyro aiming is active all the time unless limited to aiming")
        var olderProfile = try JSONSerialization.jsonObject(with: encoder.encode(ControllerEnhancements())) as! [String: Any]
        olderProfile["gyroAimOnly"] = true
        let upgraded = try JSONDecoder().decode(ControllerEnhancements.self, from: JSONSerialization.data(withJSONObject: olderProfile))
        check(upgraded.effectiveGyroActivation == .whileAiming, "Profiles from earlier builds keep aiming only while L2 is held")
        check(abs(fresh.effectiveAimDeadzoneCompensation - 0.12) < 0.001, "Aiming compensates a typical right-stick dead zone by default")
        var saved = ControllerEnhancements()
        saved.steeringAngleDegrees = 33; saved.steeringAntiDeadzone = 0.1; saved.steeringSmoothing = 0.4
        saved.gyroActivation = .whileAiming; saved.gyroAcceleration = 0.5; saved.touchpadAcceleration = 0.7
        check(try JSONDecoder().decode(ControllerEnhancements.self, from: JSONEncoder().encode(saved)) == saved, "New motion and touch settings survive save and reload")

        // MARK: - Gyro aiming

        func aim(_ readings: [Reading], configuration: GyroAimEngine.Configuration = .init()) -> [(t: Double, x: Double, y: Double)] {
            var fusion = MotionFusion(), clock = MotionSampleClock(), engine = GyroAimEngine()
            engine.configure(configuration)
            var result: [(Double, Double, Double)] = []; var i = 0; var tick = 0.0
            while tick < readings.last!.t {
                while i < readings.count && readings[i].t <= tick {
                    fusion.ingest(rotationRate: readings[i].gyro, acceleration: readings[i].acc, dt: clock.step(arrival: readings[i].t), vibrating: false); i += 1
                }
                let drained = fusion.drainRotation()
                let out = engine.sample(rate: drained.rate, gravity: fusion.gravity, dt: 1.0 / 120).coarse
                result.append((tick, Double(out.x), Double(out.y))); tick += 1.0 / 120
            }
            return result
        }
        let tremor = aim(simulate(10, pose: { t in (0.04 * deg * sin(2 * .pi * 9 * t), 35 * deg + 0.03 * deg * sin(2 * .pi * 8 * t), 0.05 * deg * sin(2 * .pi * 10 * t)) }))
        check(tremor.filter { $0.t > 6 }.allSatisfy { $0.x == 0 && $0.y == 0 }, "Hand tremor at rest never moves the camera")
        let slowTurn = aim(simulate(12, pose: { t in (0, 35 * deg, t < 8 ? 0 : (t < 10 ? -3 * deg * (t - 8) : -6 * deg)) }))
        check(slowTurn.filter { $0.t > 8.2 && $0.t < 9.9 }.allSatisfy { $0.x > 0.1 }, "A slow 3°/s turn moves the camera on every tick")
        check(slowTurn.filter { $0.t > 10.12 }.allSatisfy { $0.x == 0 && $0.y == 0 }, "The camera stops when the hand stops — no phantom input")
        var turnOutputs: [Double] = []
        for hold in [5.0, 40.0, 80.0] {
            let run = aim(simulate(6, pose: { t in (0, hold * deg, t < 3 ? 0 : -30 * deg * (t - 3)) })).filter { $0.t > 3.5 && $0.t < 5.5 }
            turnOutputs.append(run.map(\.x).reduce(0, +) / Double(run.count))
            check(run.allSatisfy { abs($0.y) < 0.05 }, "A horizontal turn stays horizontal at a \(Int(hold))° hold")
        }
        check(turnOutputs.min()! > 0.4 && turnOutputs.max()! - turnOutputs.min()! < 0.05, "Turning gives the same aim whether held flat, tilted or upright")
        let lookUp = aim(simulate(5, pose: { t in (0, (35 + (t < 2.5 ? 0 : 20 * (t - 2.5))) * deg, 0) })).filter { $0.t > 3 && $0.t < 4.8 }
        check(lookUp.allSatisfy { $0.y > 0.2 && abs($0.x) < 0.05 }, "Pitching up aims up")
        var inverted = GyroAimEngine.Configuration(); inverted.invertY = true
        let lookDown = aim(simulate(5, pose: { t in (0, (35 + (t < 2.5 ? 0 : 20 * (t - 2.5))) * deg, 0) }), configuration: inverted).filter { $0.t > 3 && $0.t < 4.8 }
        check(lookDown.allSatisfy { $0.y < -0.2 }, "Vertical inversion flips vertical aim")
        var faster = GyroAimEngine.Configuration(); faster.sensitivity = 2
        let quickTurn = aim(simulate(6, pose: { t in (0, 35 * deg, t < 3 ? 0 : -20 * deg * (t - 3)) }), configuration: faster).filter { $0.t > 3.5 && $0.t < 5.5 }
        let baseTurn = aim(simulate(6, pose: { t in (0, 35 * deg, t < 3 ? 0 : -20 * deg * (t - 3)) })).filter { $0.t > 3.5 && $0.t < 5.5 }
        check(quickTurn.map(\.x).reduce(0, +) > baseTurn.map(\.x).reduce(0, +) * 1.4, "Sensitivity scales aim speed")
        check(StickShaper.magnitude(demand: 0, exponent: 1, antiDeadzone: 0.2) == 0, "Zero demand is exactly zero even with compensation")

                // Gyro as a mouse: the per-tick turn adds up to the real rotation, so
        // a mouse following it moves exactly as far as the hand turned.
        var mouseAim = GyroAimEngine()
        mouseAim.configure(GyroAimEngine.Configuration(smoothing: 0))
        var turned = 0.0
        for _ in 0..<120 {   // one second at 120 Hz, turning right at 30°/s while held flat
            _ = mouseAim.sample(rate: MotionVector(0, 0, -30 * deg), gravity: MotionVector(0, 0, -1), dt: 1.0 / 120)
            turned += mouseAim.turn.x
        }
        check(abs(turned * 180 / .pi - 30) < 1.5, "Gyro mouse output adds up to the controller's real turn (\(Int((turned * 180 / .pi).rounded()))°)")
        var restingTurn = 0.0
        for tick in 0..<120 {   // then a second of a resting hand (tremor-level 0.4°/s)
            _ = mouseAim.sample(rate: MotionVector(0, 0, -0.4 * deg), gravity: MotionVector(0, 0, -1), dt: 1.0 / 120)
            if tick >= 24 { restingTurn += abs(mouseAim.turn.x) + abs(mouseAim.turn.y) }
        }
        check(restingTurn == 0, "A resting hand moves the mouse not at all")

// MARK: - Touchpad camera

        func touch(_ positions: (Double) -> (Double, Double)?, duration: Double, rate: Double = 250, configuration: TouchpadCameraEngine.Configuration = .init()) -> [(t: Double, x: Double, y: Double)] {
            var engine = TouchpadCameraEngine(); engine.configure(configuration)
            var result: [(Double, Double, Double)] = []; var t = 0.0, tick = 0.0; var jitter = 0
            while t < duration {
                while tick <= t { let out = engine.tick(now: tick, dt: 1.0 / 120).coarse; result.append((tick, Double(out.x), Double(out.y))); tick += 1.0 / 120 }
                if let p = positions(t) { jitter += 1; engine.report(position: (p.0.rounded() + Double(jitter % 3 == 0 ? 1 : 0), p.1.rounded()), at: t) } else { engine.lift() }
                t += 1 / rate
            }
            return result
        }
        check(touch({ _ in (100, 50) }, duration: 2).allSatisfy { $0.x == 0 && $0.y == 0 }, "A resting finger with sensor jitter never moves the camera")
        let swipeSpeeds = [80.0, 300.0, 1000.0].map { speed -> Double in
            let run = touch({ t in (-800 + speed * t, 0) }, duration: 1.2).filter { $0.t > 0.2 && $0.t < 1.1 }
            return run.map(\.x).reduce(0, +) / Double(run.count)
        }
        check(swipeSpeeds[0] > 0 && swipeSpeeds[0] < swipeSpeeds[1] && swipeSpeeds[1] < swipeSpeeds[2], "Faster swipes turn faster; slow strokes still move")
        let slowStroke = touch({ t in (-800 + 80 * t, 0) }, duration: 1.2).filter { $0.t > 0.25 && $0.t < 1.1 }.map(\.x)
        let slowMean = slowStroke.reduce(0, +) / Double(slowStroke.count)
        check(slowStroke.allSatisfy { abs($0 - slowMean) < slowMean * 0.25 }, "Slow strokes move smoothly, without pixel stutter")
        let stopping = touch({ t in t < 1 ? (-400 + 500 * t, 0) : (100, 0) }, duration: 2)
        check(stopping.filter { $0.t > 1.12 }.allSatisfy { $0.x == 0 }, "The camera stops within about 100 ms of the finger stopping")
        let lifting = touch({ t in t < 1 ? (-400 + 500 * t, 0) : nil }, duration: 2)
        check(lifting.filter { $0.t > 1.01 }.allSatisfy { $0.x == 0 }, "Lifting the finger stops the camera at once")
        let sparse = touch({ t in (-400 + 500 * t, 0) }, duration: 1.2, rate: 60).filter { $0.t > 0.2 && $0.t < 1.1 }
        check(sparse.allSatisfy { $0.x > 0.1 }, "Sparse touch reports never drop the camera to zero mid-swipe")
        var upward = TouchpadCameraEngine.Configuration(); upward.invertY = true
        let vertical = touch({ t in (0, -300 + 400 * t) }, duration: 1, configuration: upward).filter { $0.t > 0.2 && $0.t < 0.9 }
        check(vertical.allSatisfy { $0.y < 0 }, "Vertical inversion flips touch aim")

        // MARK: - Input ownership mapping

        check(ControllerGyroMode.off.owner == .physical && ControllerGyroMode.steering.owner == .steering
              && ControllerGyroMode.aiming.owner == .gyroAim,
              "Each motion mode maps to exactly one input owner")
        var modeProbe = ControllerEnhancements()
        check(modeProbe.gyroMode == .off, "Disabled gyro maps to the Off mode")
        modeProbe.setGyroMode(.steering)
        check(modeProbe.gyroEnabled && modeProbe.gyroStick == .left && modeProbe.gyroMode == .steering, "Steering mode selects the left stick")
        modeProbe.setGyroMode(.aiming)
        check(modeProbe.gyroStick == .right && modeProbe.gyroMode == .aiming, "Aiming mode returns to the right stick")
        var retiredFlick = ControllerEnhancements(); retiredFlick.gyroEnabled = true; retiredFlick.gyroFlickMode = true
        check(retiredFlick.gyroMode == .off, "Profiles that used the retired flick shifting start with motion off")
        var limitedSteering = ControllerEnhancements()
        check(limitedSteering.effectiveSteeringMaximum == 1, "Existing profiles retain full steering output")
        limitedSteering.steeringMaximum = .nan
        check(limitedSteering.effectiveSteeringMaximum == 1, "Invalid maximum steering safely falls back to full output")

        // MARK: - Adaptive triggers

        check(AdaptiveTriggerPreset.recommendedCatalog.count == 14 && AdaptiveTriggerPreset.recommendedCatalog.first == .off,
              "Catalog offers the fourteen DualSenseX-style modes starting at Off")
        check(AdaptiveTriggerPreset.migrated("semiAutomaticGun") == .automatic && AdaptiveTriggerPreset.migrated("clutchBite") == .brake
              && AdaptiveTriggerPreset.migrated("bowDraw") == .bow && AdaptiveTriggerPreset.migrated("ratchetDetents") == .twoStage,
              "Legacy saved preset names migrate into the current catalog")
        check(AdaptiveTriggerPreset.migrated("verySoftTrigger") == .softSpring && AdaptiveTriggerPreset.migrated("hardTrigger") == .stiffSpring
              && AdaptiveTriggerPreset.migrated("deceleration") == .brake && AdaptiveTriggerPreset.migrated("resistanceTrigger") == .stiffSpring,
              "Effect names from early builds map to their closest effect instead of Off")
        var click = ControllerTriggerEnvelope()
        _ = click.sample(preset: .pistol, pressure: 0, now: 0)
        check(click.sample(preset: .pistol, pressure: 0.6, now: dt).intensity > 0, "A break-style trigger clicks as it passes its wall")
        check(click.sample(preset: .pistol, pressure: 1, now: 2 * dt).intensity == 0, "Holding past the wall never repeats the click")
        _ = click.sample(preset: .pistol, pressure: 0, now: 3 * dt)
        check(click.sample(preset: .pistol, pressure: 0.6, now: 4 * dt).intensity > 0, "Releasing re-arms the click")
        for mode in [AdaptiveTriggerPreset.automatic, .machineGun, .accelerator, .brake, .heartbeat] {
            var quiet = ControllerTriggerEnvelope()
            var total: Float = 0
            for frame in 0..<120 { total += quiet.sample(preset: mode, pressure: Float(frame % 60) / 59, now: Double(frame) * dt).intensity }
            check(total == 0, "\(mode.rawValue) never plays grip haptics on its own")
        }

        // MARK: - DualSense touch decoding (unchanged contract)

        var usb = [UInt8](repeating: 0, count: 64); usb[0] = 1; usb[33] = 0x80; usb[37] = 0x80
        check(DualSenseTouchPacket.decode(usb)?.first?.isActive == false, "USB contact flag detects actual release")
        usb[33] = 0; usb[34] = 0xc0; usb[35] = 0xc3; usb[36] = 0x21
        let touch0 = DualSenseTouchPacket.decode(usb)?.first
        check(touch0?.isActive == true && abs(touch0!.position.x) < 0.002 && abs(touch0!.position.y) < 0.002, "USB packed touch coordinates decode centre")
        var bt = [UInt8](repeating: 0, count: 78); bt[0] = 0x31
        for i in 0..<8 { bt[34+i] = usb[33+i] }
        check(DualSenseTouchPacket.decode(bt)?.first == touch0, "Bluetooth touch layout matches USB")
        check(DualSenseTouchPacket.decode([1,0,0]) == nil, "Truncated reports cannot create touches")

        print("\(checks) controller/model contract checks passed. No hardware or user data touched.")
    }
}
