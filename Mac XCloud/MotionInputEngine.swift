//
//  MotionInputEngine.swift
//  Mac XCloud
//
//  The motion-processing layer behind every controller enhancement. Nothing
//  here knows about GameController, WebKit or persistence: every engine is a
//  value type the contract tests drive with simulated sensor data.
//
//    MotionSampleClock     robust time steps for bursty sensor reports
//    MotionFusion          gyro + accelerometer fusion: gravity direction,
//                          continuous gyro-bias calibration, per-tick rates
//    SteeringWheelEngine   pitch-invariant bank angle → left stick
//    GyroAimEngine         player-space angular velocity → right stick
//    TouchpadCameraEngine  finger velocity with pointer acceleration → stick
//    StickShaper           shared response-curve / dead-zone-compensation stage
//
//  Design rules shared by every engine:
//  • Sensors are processed at their own report rate; outputs are read at the
//    stream tick. Nothing is sampled instantaneously at the tick, so a 250 Hz
//    gyro is never aliased down to a 60 Hz snapshot.
//  • Output is a pure function of the current physical state. There is no
//    snapping toward a center, no accumulated target and no output floor:
//    when the hand stops, the output is exactly zero (aim/touch) or exactly
//    the held angle (steering).
//  • Game dead-zone compensation is explicit, radial, and gated by real
//    motion, so a still controller can never produce a phantom stick value.
//

import Foundation
import simd

typealias MotionVector = SIMD3<Double>

// MARK: - Adaptive filtering

/// Speed-adaptive low-pass filter following Casiez, Roussel & Vogel's 1€
/// algorithm. The cutoff frequency rises with the estimated signal speed, so
/// a slow signal is smoothed while fast strokes pass with almost no lag.
/// Strictly time-based: identical behavior at 60, 120 or 250 Hz.
struct OneEuroFilter {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    init(minimumCutoff: Double, beta: Double, derivativeCutoff: Double = 2.0) {
        self.minimumCutoff = max(minimumCutoff, 0.01)
        self.beta = max(beta, 0)
        self.derivativeCutoff = max(derivativeCutoff, 0.01)
    }

    private var value: Double = 0
    private var raw: Double = 0
    private var derivative: Double = 0
    private var primed = false

    var current: Double { primed ? value : 0 }
    var isPrimed: Bool { primed }

    mutating func reset() {
        value = 0; raw = 0; derivative = 0; primed = false
    }

    private static func alpha(cutoff: Double, step: Double) -> Double {
        let tau = 1 / (2 * Double.pi * max(cutoff, 0.0001))
        return 1 / (1 + tau / step)
    }

    mutating func filter(_ sample: Double, dt: Double) -> Double {
        guard sample.isFinite else { reset(); return 0 }
        let step = min(max(dt, 0.0005), 0.1)
        guard primed else {
            primed = true
            raw = sample; value = sample; derivative = 0
            return value
        }
        let estimatedRate = (sample - raw) / step
        derivative += Self.alpha(cutoff: derivativeCutoff, step: step) * (estimatedRate - derivative)
        raw = sample
        let cutoff = minimumCutoff + beta * abs(derivative)
        value += Self.alpha(cutoff: cutoff, step: step) * (sample - value)
        return value
    }
}

// MARK: - Sample timing

/// Assigns an integration step to each motion report. GameController hands
/// reports to the main thread, where a busy frame can deliver several at
/// once; integrating those with their arrival gaps would lose rotation. The
/// clock tracks the device's report interval and spreads bursts across it,
/// paying the borrowed time back from the next normal gap.
struct MotionSampleClock {
    private(set) var nominalInterval: Double = 1.0 / 250.0
    private var lastArrival: Double?
    private var debt: Double = 0
    private var windowStart: Double?
    private var windowCount = 0
    private var seeded = false

    mutating func reset() {
        lastArrival = nil
        debt = 0
        windowStart = nil
        windowCount = 0
    }

    mutating func step(arrival: Double) -> Double {
        guard arrival.isFinite else { return 0 }
        guard let last = lastArrival else {
            lastArrival = arrival
            windowStart = arrival
            windowCount = 0
            return nominalInterval
        }
        let gap = arrival - last
        lastArrival = max(arrival, last)
        // Long stalls (sensor sleep, reconnect, app nap) are not integrated:
        // the accelerometer re-anchors orientation within a second instead.
        guard gap <= 0.25 else {
            debt = 0
            windowStart = arrival
            windowCount = 0
            return nominalInterval
        }
        // The report interval is the average spacing over half-second
        // windows: exact under bursty delivery, where individual gaps lie.
        windowCount += 1
        if let start = windowStart, arrival - start >= 0.5 {
            let measured = (arrival - start) / Double(windowCount)
            if measured > 0.0008 && measured < 0.05 {
                // The first window sets the rate outright; later ones refine it.
                nominalInterval += (measured - nominalInterval) * (seeded ? 0.5 : 1)
                seeded = true
            }
            windowStart = arrival
            windowCount = 0
        }
        if gap < nominalInterval * 0.35 {
            debt = min(debt + nominalInterval - max(gap, 0), 0.1)
            return nominalInterval
        }
        let repay = min(debt, gap - nominalInterval * 0.35)
        debt -= repay
        // Bluetooth occasionally holds a report back for 50–80 ms.
        return min(gap - repay, 0.1)
    }
}

// MARK: - Sensor fusion

/// Gyro + accelerometer fusion for a handheld controller.
///
/// Gravity is tracked as a unit vector in the controller's own frame. Every
/// report rotates it by the measured angular velocity (so orientation follows
/// the hand with zero lag), then nudges it toward the accelerometer with a
/// time constant near one second. The accelerometer is trusted only when its
/// magnitude is close to 1 g — hand translation, centripetal acceleration and
/// rumble all change the magnitude — and far less while the game is
/// vibrating the controller. Drift is therefore bounded, shakes are
/// rejected, and nothing ever snaps.
///
/// The gyroscope's bias is learned continuously whenever the controller is
/// genuinely still, and can also be measured explicitly.
struct MotionFusion {
    struct Configuration {
        /// Accelerometer correction time constant while handling normally.
        var gravityTimeConstant: Double = 0.9
        /// While the controller is vibrating the accelerometer is mostly
        /// shake; the gyroscope carries orientation almost alone.
        var vibrationTimeConstant: Double = 2.0
        /// Deviation of |acceleration| from 1 g beyond which the
        /// accelerometer is ignored completely.
        var accelerationTolerance: Double = 0.1
        /// Raw angular speed (rad/s) below which the controller may be still.
        var stillRateThreshold: Double = 0.05
        /// Continuous stillness required before bias learning starts.
        var stillTimeRequired: Double = 0.6
        var biasTimeConstant: Double = 3.0
        var maximumBias: Double = 0.17
    }

    enum CalibrationState: Equatable {
        case idle
        case measuring(progress: Double)
        case succeeded
        case failedMoved
    }

    var configuration = Configuration()
    private(set) var gravity: MotionVector?
    private(set) var bias = MotionVector.zero
    /// Latest bias-corrected angular velocity (rad/s, controller frame).
    private(set) var rate = MotionVector.zero
    private(set) var stillTime: Double = 0
    private(set) var accelerometerTrust: Double = 0
    private(set) var calibration: CalibrationState = .idle
    private(set) var samples = 0

    private var stillReference: MotionVector?
    private var averagedRate = MotionVector.zero
    private var filteredAcceleration: MotionVector?
    private var disagreementTime: Double = 0
    private var accumulatedRotation = MotionVector.zero
    private var accumulatedTime: Double = 0
    private var accumulatedSamples = 0
    private var calibrationSum = MotionVector.zero
    private var calibrationTime: Double = 0
    private var calibrationDuration: Double = 1.5
    private var calibrationReference: MotionVector?

    init(bias: MotionVector = .zero) {
        self.bias = Self.clampBias(bias, limit: Configuration().maximumBias)
    }

    /// Forget orientation (after a reconnect or a long gap). Bias survives:
    /// it belongs to the physical sensor, not the session.
    mutating func resetOrientation() {
        gravity = nil
        rate = .zero
        stillTime = 0
        stillReference = nil
        filteredAcceleration = nil
        disagreementTime = 0
        accumulatedRotation = .zero
        accumulatedTime = 0
        accumulatedSamples = 0
    }

    mutating func setBias(_ value: MotionVector) {
        bias = Self.clampBias(value, limit: configuration.maximumBias)
    }

    /// Starts an explicit gyro calibration: the controller must rest still
    /// (on a table, or held very steadily) for `duration` seconds.
    mutating func beginCalibration(duration: Double = 1.5) {
        calibrationSum = .zero
        calibrationTime = 0
        calibrationDuration = min(max(duration, 0.5), 5)
        calibrationReference = nil
        calibration = .measuring(progress: 0)
    }

    mutating func cancelCalibration() {
        if case .measuring = calibration { calibration = .idle }
    }

    mutating func acknowledgeCalibrationResult() {
        if calibration == .succeeded || calibration == .failedMoved { calibration = .idle }
    }

    /// Feeds one sensor report. `rotationRate` is rad/s, `acceleration` is the
    /// total acceleration in g (gravity included), both in the controller
    /// frame GameController reports.
    mutating func ingest(rotationRate raw: MotionVector, acceleration: MotionVector, dt: Double, vibrating: Bool) {
        guard dt > 0, dt.isFinite, Self.isFinite(raw), Self.isFinite(acceleration) else { return }
        samples &+= 1
        let magnitude = simd_length(acceleration)
        let measuredDown = magnitude > 0.2 ? acceleration / magnitude : nil

        updateCalibration(raw: raw, down: measuredDown, magnitude: magnitude, dt: dt, vibrating: vibrating)
        if let filtered = filteredAcceleration, simd_length(filtered) > 0.2 {
            learnBias(raw: raw, down: simd_normalize(filtered), magnitude: magnitude, dt: dt, vibrating: vibrating)
        }

        rate = raw - bias
        accumulatedRotation += rate * dt
        accumulatedTime += dt
        accumulatedSamples += 1

        // Prediction: a world-fixed vector seen from a rotating body turns the
        // opposite way, dv/dt = -ω × v. Exact rotation, not a linearization.
        let speed = simd_length(rate)
        let axis = speed > 1e-9 ? rate / speed : MotionVector.zero
        // The accelerometer is low-passed in the controller frame, rotated
        // with the gyro so the average never lags a turn. Rumble (60–200 Hz)
        // and sensor noise average out; real gravity does not.
        if var filtered = filteredAcceleration {
            if speed > 1e-9 { filtered = Self.rotate(filtered, axis: axis, angle: -speed * dt) }
            let tau = vibrating ? 0.08 : 0.03
            filtered += (acceleration - filtered) * (1 - exp(-dt / tau))
            filteredAcceleration = filtered
        } else {
            filteredAcceleration = acceleration
        }

        guard var down = gravity else {
            // Start only from a clean reading: an arm in motion would seed a
            // tilted horizon that then takes seconds to unwind.
            if let measuredDown, abs(magnitude - 1) < 0.05 { gravity = measuredDown }
            accelerometerTrust = 0
            return
        }
        if speed > 1e-9 {
            down = Self.rotate(down, axis: axis, angle: -speed * dt)
        }
        // Correction toward the accelerometer, weighted by how much it can be
        // believed right now.
        var trust = 0.0
        if let filtered = filteredAcceleration {
            let filteredMagnitude = simd_length(filtered)
            let deviation = abs(filteredMagnitude - 1)
            let tolerance = configuration.accelerationTolerance
            if deviation < tolerance, filteredMagnitude > 0.2 {
                let measured = filtered / filteredMagnitude
                trust = pow(1 - deviation / tolerance, 2)
                // Fast rotation adds centripetal acceleration of its own.
                trust *= min(max(1 - (speed - 1.5) / 3, 0), 1)
                // Arm movement tilts the measured direction briefly without
                // much change in magnitude. A sudden disagreement with the
                // gyro-tracked direction is distrusted; one that persists is
                // real drift and is corrected normally.
                let disagreement = acos(min(max(simd_dot(measured, down), -1), 1))
                if disagreement > 4 * .pi / 180 {
                    disagreementTime = min(disagreementTime + dt, 2)
                } else {
                    disagreementTime = max(disagreementTime - 3 * dt, 0)
                }
                let persistent = disagreementTime >= 0.6
                if !persistent {
                    let ratio = disagreement / (3 * .pi / 180)
                    trust *= 1 / (1 + ratio * ratio)
                }
                if trust > 0 {
                    var tau = vibrating ? configuration.vibrationTimeConstant : configuration.gravityTimeConstant
                    // A disagreement that outlasts any arm movement is real
                    // error (a long sensor gap, a hard knock): fix it briskly.
                    if persistent { tau = min(tau, 0.3) }
                    let alpha = (1 - exp(-dt / max(tau, 0.05))) * trust
                    down = simd_normalize(down + (measured - down) * alpha)
                }
            }
        }
        accelerometerTrust = trust
        gravity = down
    }

    /// Gravity projected `elapsed` seconds past the last report using the
    /// latest angular velocity. Sensors report at ~65 Hz over Bluetooth;
    /// reading orientation between reports this way removes the 15 ms
    /// staircase and the half-interval of latency it adds.
    func predictedGravity(after elapsed: Double) -> MotionVector? {
        guard let gravity else { return nil }
        let step = min(max(elapsed, 0), 0.04)
        let speed = simd_length(rate)
        guard step > 0, speed > 1e-9 else { return gravity }
        return Self.rotate(gravity, axis: rate / speed, angle: -speed * step)
    }

    /// Average bias-corrected angular velocity since the previous call, the
    /// time it covers and how many reports contributed. A call with no new
    /// reports returns zero duration.
    mutating func drainRotation() -> (rate: MotionVector, duration: Double, samples: Int) {
        defer {
            accumulatedRotation = .zero
            accumulatedTime = 0
            accumulatedSamples = 0
        }
        guard accumulatedTime > 0 else { return (.zero, 0, 0) }
        return (accumulatedRotation / accumulatedTime, accumulatedTime, accumulatedSamples)
    }

    private mutating func learnBias(raw: MotionVector, down: MotionVector?, magnitude: Double, dt: Double, vibrating: Bool) {
        // Stillness is judged on motion averaged over ~0.25 s: hand tremor in
        // a resting grip swings the instantaneous rate past any sensible
        // threshold but averages to (bias-sized) nothing, so the drift keeps
        // being learned while the controller is held, not only on a table.
        averagedRate += (raw - bias - averagedRate) * (1 - exp(-dt / 0.25))
        guard !vibrating, let down, abs(magnitude - 1) < 0.05,
              simd_length(averagedRate) < configuration.stillRateThreshold * 0.6,
              simd_length(raw - bias) < configuration.stillRateThreshold * 3 else {
            stillTime = 0
            stillReference = nil
            return
        }
        // The (low-passed) gravity direction must stay put too: a slow deliberate turn has
        // a low rate but steadily changes it (except pure yaw, which is why
        // learning is slow and starts only after a full stillness window).
        if let reference = stillReference, simd_dot(reference, down) > cos(1.2 * .pi / 180) {
            stillTime += dt
        } else {
            stillReference = down
            stillTime = 0
        }
        guard stillTime >= configuration.stillTimeRequired else { return }
        let alpha = 1 - exp(-dt / configuration.biasTimeConstant)
        bias = Self.clampBias(bias + (raw - bias) * alpha, limit: configuration.maximumBias)
    }

    private mutating func updateCalibration(raw: MotionVector, down: MotionVector?, magnitude: Double, dt: Double, vibrating: Bool) {
        guard case .measuring = calibration else { return }
        guard let down, abs(magnitude - 1) < 0.08, !vibrating else {
            calibration = .failedMoved
            return
        }
        if let reference = calibrationReference {
            if simd_dot(reference, down) < cos(2.0 * .pi / 180) {
                calibration = .failedMoved
                return
            }
        } else {
            calibrationReference = down
        }
        if calibrationTime > 0.2 {
            let mean = calibrationSum / calibrationTime
            if simd_length(raw - mean) > 0.12 {
                calibration = .failedMoved
                return
            }
        }
        calibrationSum += raw * dt
        calibrationTime += dt
        if calibrationTime >= calibrationDuration {
            bias = Self.clampBias(calibrationSum / calibrationTime, limit: configuration.maximumBias)
            calibration = .succeeded
        } else {
            calibration = .measuring(progress: calibrationTime / calibrationDuration)
        }
    }

    static func rotate(_ vector: MotionVector, axis: MotionVector, angle: Double) -> MotionVector {
        let c = cos(angle), s = sin(angle)
        return vector * c + simd_cross(axis, vector) * s + axis * simd_dot(axis, vector) * (1 - c)
    }

    private static func clampBias(_ value: MotionVector, limit: Double) -> MotionVector {
        guard isFinite(value) else { return .zero }
        return simd_clamp(value, MotionVector(repeating: -limit), MotionVector(repeating: limit))
    }

    static func isFinite(_ value: MotionVector) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

// MARK: - Shared stick shaping

/// Turns a normalized demand (0…1, "how much of the stick's travel the
/// physical input asks for") into a stick magnitude.
///
/// • `exponent` bends the response (1 linear, below 1 quicker off center,
///   above 1 gentler). The curve is linear over the first 4 % of travel so its
///   slope at center is finite: sensor noise around zero is never amplified
///   the way a raw power curve would amplify it.
/// • `antiDeadzone` starts output just past the game's own stick dead zone,
///   so the smallest real movement already moves the game. In game space the
///   response stays continuous.
enum StickShaper {
    static let linearKnee = 0.04

    static func curve(_ demand: Double, exponent: Double) -> Double {
        let x = min(max(demand.isFinite ? demand : 0, 0), 1)
        let e = min(max(exponent.isFinite ? exponent : 1, 0.3), 3)
        guard e != 1 else { return x }
        if x >= linearKnee { return pow(x, e) }
        return pow(linearKnee, e) * (x / linearKnee)
    }

    /// `onset` (0…1) fades the anti-dead-zone in over the first instant of
    /// motion, so the jump past the game's dead zone happens only for motion
    /// that is clearly real.
    static func magnitude(demand: Double, exponent: Double, antiDeadzone: Double, onset: Double = 1) -> Double {
        let shaped = curve(demand, exponent: exponent)
        guard shaped > 0 else { return 0 }
        let floor = min(max(antiDeadzone.isFinite ? antiDeadzone : 0, 0), 0.5) * min(max(onset, 0), 1)
        return min(floor + (1 - floor) * shaped, 1)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Racing steering

/// Steering angle from the fused gravity direction.
///
/// The wheel angle is the *bank* of the controller: how far its left-right
/// axis is tilted relative to the horizon. Bank is independent of pitch (how
/// far the controller leans toward or away from you) and of yaw (turning it
/// on the spot), so lifting, lowering or twisting the controller while
/// driving never steers the car. It is absolute, so the center can never
/// drift; the gyro inside the fusion makes it respond instantly.
enum SteeringGeometry {
    static func bank(gravity: MotionVector) -> Double {
        atan2(gravity.x, (gravity.y * gravity.y + gravity.z * gravity.z).squareRoot())
    }
}

/// The physical response of the virtual wheel: wheel angle → stick position.
/// Pure and static so tests and the settings preview share one definition.
enum SteeringResponse {
    struct Parameters: Equatable {
        /// Rotation (radians) that reaches full lock.
        var fullLock: Double = 40 * .pi / 180
        var exponent: Double = 1
        /// Left-stick dead-zone compensation for the game (0…0.4).
        var antiDeadzone: Double = 0
        /// Optional dead band around center, radians.
        var deadzone: Double = 0
        var maximum: Double = 1
        var inverted = false
    }

    /// Angle over which dead-zone compensation fades in. A hard step at
    /// center (the textbook anti-dead-zone) is only invisible when the game
    /// really has that dead zone; when it doesn't, the car snaps across
    /// center. Fading the compensation in exponentially keeps the response
    /// continuous and kink-free either way: center turns quicker, never jumps.
    static func compensationOnset(span: Double) -> Double {
        min(max(span * 0.06, 1 * .pi / 180), 3 * .pi / 180)
    }

    static func output(angle: Double, parameters p: Parameters) -> Double {
        guard angle.isFinite else { return 0 }
        let span = max(abs(p.fullLock), 5 * .pi / 180)
        let deadzone = min(max(p.deadzone, 0), span * 0.2)
        let travel = max(abs(angle) - deadzone, 0)
        guard travel > 0 else { return 0 }
        let demand = min(travel / max(span - deadzone, 0.0001), 1)
        let onset = 1 - exp(-travel / compensationOnset(span: span))
        let magnitude = StickShaper.magnitude(demand: demand, exponent: p.exponent,
                                              antiDeadzone: p.antiDeadzone, onset: onset)
        let sign: Double = (angle < 0 ? -1 : 1) * (p.inverted ? -1 : 1)
        return sign * magnitude * min(max(p.maximum, 0.1), 1)
    }
}

/// Wheel angle → filtered → stick. The center is an explicit calibration
/// (the bank captured by Recenter), never something the engine moves.
struct SteeringWheelEngine {
    struct Configuration: Equatable {
        var response = SteeringResponse.Parameters()
        /// 0 (none) … 1 (heavy). The fused angle is already clean; this only
        /// trims residual jitter and is speed-adaptive, so turns keep their
        /// speed.
        var smoothing: Double = 0.2
    }

    private(set) var configuration = Configuration()
    /// Bank captured by the last recenter (radians).
    var centerBank: Double = 0
    private(set) var bank: Double = 0
    private(set) var angle: Double = 0
    private(set) var output: Double = 0
    private(set) var available = false
    private var filter = OneEuroFilter(minimumCutoff: 12, beta: 8)

    mutating func configure(_ configuration: Configuration) {
        if configuration.smoothing != self.configuration.smoothing {
            filter = Self.makeFilter(smoothing: configuration.smoothing)
        }
        self.configuration = configuration
    }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        filter = Self.makeFilter(smoothing: configuration.smoothing)
    }

    private static func makeFilter(smoothing: Double) -> OneEuroFilter {
        let amount = min(max(smoothing.isFinite ? smoothing : 0.2, 0), 1)
        // 0 → 25 Hz (transparent), 0.2 → ~15 Hz, 1 → 2.5 Hz.
        let cutoff = 25 * pow(0.1, amount)
        return OneEuroFilter(minimumCutoff: cutoff, beta: 10, derivativeCutoff: 4)
    }

    /// Makes the current physical bank the straight-ahead position.
    mutating func recenter() {
        centerBank = bank
        filter.reset()
        angle = 0
        output = 0
    }

    mutating func reset() {
        filter.reset()
        bank = 0; angle = 0; output = 0; available = false
    }

    /// Reads the fused gravity once per output tick.
    @discardableResult
    mutating func update(gravity: MotionVector?, dt: Double) -> Double {
        guard let gravity, MotionFusion.isFinite(gravity), simd_length(gravity) > 0.5 else {
            // No orientation yet (or sensors lost): release the wheel.
            if available || output != 0 { filter.reset() }
            available = false
            angle = 0
            output = 0
            return 0
        }
        available = true
        bank = SteeringGeometry.bank(gravity: gravity)
        let relative = bank - centerBank
        angle = configuration.smoothing <= 0.001 ? relative : filter.filter(relative, dt: dt)
        output = SteeringResponse.output(angle: angle, parameters: configuration.response)
        return output
    }

    mutating func release() {
        if available || output != 0 { filter.reset() }
        angle = 0
        output = 0
    }
}

// MARK: - Gyro aiming

/// Gyro-to-right-stick aiming.
///
/// 1. Angular velocity is averaged over every sensor report since the last
///    tick (no aliasing) and projected into player space: horizontal aim
///    follows rotation about the world's vertical axis, with part of the
///    controller's roll allowed in, so it works the same flat, tilted or
///    upright; vertical aim is the controller's own pitch.
/// 2. Soft tiered smoothing averages only slow movement (hand tremor);
///    deliberate movement passes through untouched.
/// 3. A rest gate with hysteresis decides whether the hand is moving at all.
///    Below it the output is exactly zero.
/// 4. Angular speed × sensitivity (optionally accelerated) is the share of the
///    stick's travel, shaped radially and lifted past the game's dead zone.
///
/// `coarse` is the full output for an idle physical stick; `fine` omits the
/// dead-zone compensation so the browser adapter can add it to a physical
/// stick that is already past the dead zone.
struct GyroAimEngine {
    struct Configuration: Equatable {
        /// Share of full stick per rad/s. 1.0 reaches full stick at ~57°/s.
        var sensitivity: Double = 1.0
        /// 0 … 1. Lowers sensitivity for slow movement and raises it for fast
        /// movement around the base value (precise small corrections, quick
        /// turns).
        var acceleration: Double = 0
        var exponent: Double = 1
        var antiDeadzone: Double = 0.12
        /// Angular speed (rad/s) below which the hand counts as still.
        var stillThreshold: Double = 1.4 * .pi / 180
        /// 0 … 1. Averages slow movement over a longer window and up to a
        /// higher speed; deliberate fast movement is never smoothed.
        var smoothing: Double = 0.5
        var invertX = false
        var invertY = false
        /// Share of controller roll that contributes to horizontal aim.
        var rollContribution: Double = 0.41
    }

    private(set) var configuration = Configuration()
    private(set) var raw = ControllerVector2.zero
    private(set) var smoothed = ControllerVector2.zero
    private(set) var output = ControllerVector2.zero
    private(set) var fine = ControllerVector2.zero
    private(set) var isMoving = false
    private var history: [(x: Double, y: Double, dt: Double)] = []

    mutating func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    mutating func reset() {
        history.removeAll(keepingCapacity: true)
        raw = .zero; smoothed = .zero; output = .zero; fine = .zero; isMoving = false
    }

    /// Player-space projection (JoyShockMapper's "player space"): yaw about
    /// the world vertical using only the axes that can carry it, with roll
    /// partially admitted; pitch stays local. Returns rad/s, horizontal
    /// positive turning right, vertical positive pitching up.
    static func playerSpace(rate: MotionVector, gravity: MotionVector?, rollContribution: Double) -> (horizontal: Double, vertical: Double) {
        guard let gravity, simd_length(gravity) > 0.5 else {
            // Without orientation, assume the controller is roughly flat.
            return (-rate.z, rate.x)
        }
        let up = -simd_normalize(gravity)
        let worldYaw = rate.y * up.y + rate.z * up.z
        let planar = (rate.y * rate.y + rate.z * rate.z).squareRoot()
        let relax = 1 + min(max(rollContribution, 0), 1)
        let yaw = (worldYaw < 0 ? -1.0 : 1.0) * min(abs(worldYaw) * relax, planar)
        return (-yaw, rate.x)
    }

    mutating func sample(rate: MotionVector, gravity: MotionVector?, dt: Double) -> (coarse: ControllerVector2, fine: ControllerVector2) {
        guard MotionFusion.isFinite(rate), dt.isFinite, dt > 0 else {
            reset()
            return (.zero, .zero)
        }
        let c = configuration
        var (h, v) = Self.playerSpace(rate: rate, gravity: gravity, rollContribution: c.rollContribution)
        if c.invertX { h = -h }
        if c.invertY { v = -v }
        raw = ControllerVector2(x: Float(h), y: Float(v))

        // Soft tiered smoothing: slow movement is averaged over ~100 ms, which
        // cancels physiological hand tremor (8–12 Hz) while a deliberate slow
        // track survives; fast movement bypasses the average entirely.
        let smoothing = min(max(c.smoothing, 0), 1)
        let window = 0.06 + 0.08 * smoothing
        history.append((h, v, dt))
        var span = history.reduce(0) { $0 + $1.dt }
        while history.count > 1, span - history[0].dt >= window {
            span -= history[0].dt
            history.removeFirst()
        }
        let meanX = history.reduce(0) { $0 + $1.x * $1.dt } / max(span, 1e-6)
        let meanY = history.reduce(0) { $0 + $1.y * $1.dt } / max(span, 1e-6)
        let speed = (h * h + v * v).squareRoot()
        let threshold = (2 + 10 * smoothing) * .pi / 180
        let direct = StickShaper.smoothstep(threshold, threshold * 2, speed)
        let sx = h * direct + meanX * (1 - direct)
        let sy = v * direct + meanY * (1 - direct)
        smoothed = ControllerVector2(x: Float(sx), y: Float(sy))

        // Rest gate with hysteresis.
        let magnitude = (sx * sx + sy * sy).squareRoot()
        let still = max(c.stillThreshold, 1e-4)
        if isMoving {
            if magnitude < still * 0.8 { isMoving = false }
        } else if magnitude > still {
            isMoving = true
        }
        guard isMoving, magnitude > 1e-9 else {
            output = .zero; fine = .zero
            return (output, fine)
        }
        let settle = 1 - exp(-dt / max(0.012 * smoothing, 0.0005))

        // Sensitivity with optional acceleration (slow ≈ 6°/s, fast ≈ 90°/s).
        let acceleration = min(max(c.acceleration, 0), 1)
        let blend = StickShaper.smoothstep(0.1, 1.6, magnitude)
        let scale = (1 - 0.5 * acceleration) + (1.5 * acceleration) * blend
        let demand = magnitude * max(c.sensitivity, 0.01) * scale
        let onset = (magnitude - still * 0.8) / (still * 0.8)
        let coarseMagnitude = StickShaper.magnitude(demand: demand, exponent: c.exponent,
                                                    antiDeadzone: c.antiDeadzone, onset: onset)
        let fineMagnitude = StickShaper.curve(demand, exponent: c.exponent)
        let dx = sx / magnitude, dy = sy / magnitude
        // A last, very short settle (≤ 12 ms) removes tick-to-tick steps;
        // stopping is never delayed by it (the gate above zeroes at once).
        func settled(_ previous: Float, _ target: Double) -> Float {
            Float(Double(previous) + (target - Double(previous)) * settle)
        }
        output = ControllerVector2(x: settled(output.x, dx * coarseMagnitude), y: settled(output.y, dy * coarseMagnitude))
        fine = ControllerVector2(x: settled(fine.x, dx * fineMagnitude), y: settled(fine.y, dy * fineMagnitude))
        return (output, fine)
    }
}

// MARK: - Touchpad camera

/// Trackpad-style camera control.
///
/// Finger reports pass through a small spatial hysteresis (sensor jitter of
/// a resting finger never registers as movement), then velocity is measured
/// over real report time across an adaptive window: long for slow strokes,
/// where pixel quantization would otherwise make speed flicker, short for
/// fast swipes, so they respond at once. The stick follows finger *speed*:
/// a still or lifted finger gives exactly zero, nothing accumulates and
/// nothing coasts. Pointer acceleration keeps slow strokes precise while fast
/// swipes turn faster, the way a Mac trackpad behaves.
struct TouchpadCameraEngine {
    struct Configuration: Equatable {
        /// Share of full stick per (half pad width per second) of finger speed.
        var sensitivity: Double = 0.45
        /// 0 … 1. How much faster quick swipes turn than slow strokes.
        var acceleration: Double = 0.5
        var exponent: Double = 1
        var antiDeadzone: Double = 0.12
        /// 0 … 1 velocity smoothing for slow strokes.
        var smoothing: Double = 0.35
        var maximumOutput: Double = 1
        var invertY = false
    }

    /// Touch surface size in reporting units (DualSense: 1920 × 1080).
    static let halfWidth = 959.5
    static let halfHeight = 539.5
    /// Finger speeds below this (pixels/s) are a resting finger.
    static let restSpeed = 12.0
    /// Positional hysteresis radius (pixels).
    static let jitterRadius = 2.0

    private(set) var configuration = Configuration()
    private(set) var contact = false
    private(set) var velocity = (x: 0.0, y: 0.0)
    private(set) var output = ControllerVector2.zero
    private(set) var fine = ControllerVector2.zero
    private var anchor = (x: 0.0, y: 0.0)
    private var history: [(t: Double, x: Double, y: Double)] = []
    private var reportInterval = 1.0 / 250.0
    private var moving = false

    var fingerDown: Bool { contact }
    var fingerPosition: (x: Double, y: Double)? { contact ? anchor : nil }

    mutating func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Positions are in pad pixels (x right, y up). A new contact rebases.
    mutating func report(position: (x: Double, y: Double), at time: Double) {
        guard position.x.isFinite, position.y.isFinite, time.isFinite else { return }
        guard contact, let last = history.last else {
            contact = true
            anchor = position
            history = [(time, position.x, position.y)]
            velocity = (0, 0)
            moving = false
            return
        }
        let gap = time - last.t
        if gap > 0.0015 && gap < 0.05 { reportInterval += (gap - reportInterval) * 0.05 }
        let dx = position.x - anchor.x, dy = position.y - anchor.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > Self.jitterRadius {
            let follow = 1 - Self.jitterRadius / distance
            anchor = (anchor.x + dx * follow, anchor.y + dy * follow)
        }
        history.append((max(time, last.t), anchor.x, anchor.y))
        let horizon = history[history.count - 1].t - 0.2
        if let keep = history.firstIndex(where: { $0.t >= horizon }), keep > 1 {
            history.removeFirst(keep - 1)
        }
    }

    mutating func lift() {
        contact = false
        history.removeAll(keepingCapacity: true)
        velocity = (0, 0)
        output = .zero
        fine = .zero
        moving = false
    }

    mutating func reset() { lift() }

    /// Position at time `t` from the report history (linear interpolation).
    private func position(at t: Double) -> (x: Double, y: Double)? {
        guard let first = history.first else { return nil }
        if t <= first.t { return (first.x, first.y) }
        for index in stride(from: history.count - 1, through: 0, by: -1) where history[index].t <= t {
            let a = history[index]
            guard index + 1 < history.count else { return (a.x, a.y) }
            let b = history[index + 1]
            let f = (t - a.t) / max(b.t - a.t, 1e-6)
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }
        return (first.x, first.y)
    }

    private func velocity(endingAt end: Double, window: Double) -> (x: Double, y: Double) {
        guard let first = history.first, let p1 = position(at: end) else { return (0, 0) }
        let start = max(end - window, first.t)
        let span = end - start
        guard span > 0.006, let p0 = position(at: start) else { return (0, 0) }
        return ((p1.x - p0.x) / span, (p1.y - p0.y) / span)
    }

    /// Called once per output tick.
    mutating func tick(now: Double, dt: Double) -> (coarse: ControllerVector2, fine: ControllerVector2) {
        guard contact, dt > 0, dt.isFinite, let latest = history.last else {
            output = .zero; fine = .zero
            return (output, fine)
        }
        let c = configuration
        // Reports that stop arriving mean the finger stopped (touch APIs that
        // report only on change); the position then holds until `now`.
        let end = now - latest.t > max(reportInterval * 2.5, 0.03) ? now : latest.t
        let slowWindow = 0.03 + 0.06 * min(max(c.smoothing, 0), 1)
        let coarse = velocity(endingAt: end, window: slowWindow)
        let coarseSpeed = (coarse.x * coarse.x + coarse.y * coarse.y).squareRoot()
        let window = slowWindow + (0.016 - slowWindow) * StickShaper.smoothstep(150, 900, coarseSpeed)
        velocity = window < slowWindow - 0.001 ? velocity(endingAt: end, window: window) : coarse
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        if moving {
            if speed < Self.restSpeed * 0.5 { moving = false }
        } else if speed > Self.restSpeed {
            moving = true
        }
        guard moving, speed > 0 else {
            output = .zero; fine = .zero
            return (output, fine)
        }
        let units = speed / Self.halfWidth
        let acceleration = min(max(c.acceleration, 0), 1)
        let gain = 1 + 2.5 * acceleration * StickShaper.smoothstep(0.4, 4.0, units)
        let demand = units * max(c.sensitivity, 0.01) * gain
        let onset = (speed - Self.restSpeed * 0.5) / Self.restSpeed
        let limit = min(max(c.maximumOutput, 0.1), 1)
        let coarseMagnitude = StickShaper.magnitude(demand: demand, exponent: c.exponent,
                                                    antiDeadzone: c.antiDeadzone, onset: onset) * limit
        let fineMagnitude = StickShaper.curve(demand, exponent: c.exponent) * limit
        let dx = velocity.x / speed
        let dy = velocity.y / speed * (c.invertY ? -1 : 1)
        output = ControllerVector2(x: Float(dx * coarseMagnitude), y: Float(dy * coarseMagnitude))
        fine = ControllerVector2(x: Float(dx * fineMagnitude), y: Float(dy * fineMagnitude))
        return (output, fine)
    }
}

// MARK: - Input ownership

/// Which system currently owns the enhanced input path. Exactly one owner is
/// active at a time; the owner is published for diagnostics and drives the
/// arbitration in the stream output builder.
enum MotionInputOwner: String {
    case none = "None"
    case physical = "Physical controller"
    case steering = "Gyro steering"
    case gyroAim = "Gyro aiming"
    case touchpad = "Touchpad aiming"
    case mkbNative = "Keyboard & mouse (native)"
    case mkbEmulated = "Keyboard & mouse (emulated)"
}
