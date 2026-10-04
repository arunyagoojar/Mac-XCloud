// Contract for the stream health rules: plain advice only for real problems,
// and never a false alarm on a clean stream.
import Foundation

@main
struct StreamHealthContracts {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
            print("PASS: \(label)")
        }
        /// 20 seconds of one-second samples.
        func stream(seconds: Int = 20, ping: (Int) -> Double = { _ in 28 }, fps: Double = 60, bitrate: (Int) -> Double = { _ in 18 },
                    lossPerSecond: Int = 0, dropsPerSecond: Int = 0, jitter: Double = 2, decode: Double = 4) -> [StreamHealthSample] {
            (0...seconds).map { t in
                StreamHealthSample(time: Double(t), pingMs: ping(t), fps: fps, bitrateMbps: bitrate(t),
                                   packetsLost: lossPerSecond * t, packetsReceived: 1500 * t,
                                   framesDropped: dropsPerSecond * t, framesReceived: Int(fps) * t,
                                   jitterMs: jitter, decodeMs: decode)
            }
        }
        let wired = NetworkConditions(link: .wired)
        let goodWiFi = NetworkConditions(link: .wifi, rssi: -55, noise: -92, band: .ghz5, transmitRateMbps: 866)

        let clean = StreamHealthAnalyzer.report(samples: stream(), network: goodWiFi)
        check(clean?.level == .good && clean?.issues.isEmpty == true, "A clean stream on good Wi-Fi reports Good with no advice")
        check(clean?.summary == "28 ms · 0.0% loss · 60 fps · 18 Mbps", "The summary reads latency, loss, frame rate and bitrate")
        check(StreamHealthAnalyzer.report(samples: Array(stream().prefix(2)), network: wired) == nil, "Two seconds are not enough to judge")

        let lossy = StreamHealthAnalyzer.report(samples: stream(lossPerSecond: 45), network: goodWiFi)
        check(lossy?.issues.first?.kind == .packetLoss && lossy?.level == .poor, "3% packet loss is a poor connection, named as packet loss")
        check(lossy?.issues.first?.advice.contains("Ethernet") == true, "On Wi-Fi, packet loss advice points at the router or Ethernet")

        let far = StreamHealthAnalyzer.report(samples: stream(ping: { _ in 112 }), network: wired)
        check(far?.issues.map(\.kind) == [.latency] && far?.level == .poor, "112 ms latency is named, with the fastest-server advice")

        let spiky = StreamHealthAnalyzer.report(samples: stream(ping: { $0 % 4 == 0 ? 120 : 30 }), network: wired)
        check(spiky?.issues.contains { $0.kind == .latencySpikes } == true, "Bursts of latency are reported as spikes")

        let weak = StreamHealthAnalyzer.report(samples: stream(jitter: 22), network: NetworkConditions(link: .wifi, rssi: -71, noise: -90, band: .ghz5))
        check(weak?.issues.contains { $0.kind == .weakSignal } == true && weak?.issues.contains { $0.kind == .jitter } == true,
              "An unsteady stream on a weak signal blames the signal")
        let quietWeak = StreamHealthAnalyzer.report(samples: stream(), network: NetworkConditions(link: .wifi, rssi: -70, noise: -90, band: .ghz5))
        check(quietWeak?.issues.isEmpty == true, "A middling signal that streams cleanly raises no alarm")
        let band = StreamHealthAnalyzer.report(samples: stream(), network: NetworkConditions(link: .wifi, rssi: -50, noise: -90, band: .ghz2))
        check(band?.issues.map(\.kind) == [.slowBand], "2.4 GHz Wi-Fi is pointed out")

        let slowMac = StreamHealthAnalyzer.report(samples: stream(dropsPerSecond: 4, decode: 15), network: wired)
        check(slowMac?.issues.first?.kind == .decoding && slowMac?.issues.contains { $0.kind == .frameDrops } == false,
              "Slow decoding is blamed on the Mac, not reported again as dropped frames")
        let drops = StreamHealthAnalyzer.report(samples: stream(dropsPerSecond: 3), network: wired)
        check(drops?.issues.map(\.kind) == [.frameDrops], "Dropped frames on a healthy network are named on their own")

        let squeezed = StreamHealthAnalyzer.report(samples: stream(bitrate: { $0 > 14 ? 5 : 20 }), network: wired)
        check(squeezed?.issues.contains { $0.kind == .bandwidth } == true, "A collapse in bitrate is reported as a bandwidth drop")

        // Game setup suggestions follow the catalog genre.
        check(GameSetupKind.suggested(category: "Racing & flying", title: "Forza Horizon 6") == .racing, "Racing games are offered the wheel")
        check(GameSetupKind.suggested(category: "Racing & flying", title: "Microsoft Flight Simulator 2024") == nil, "Flight games are not offered a car wheel")
        check(GameSetupKind.suggested(category: "Shooter", title: "Call of Duty") == .shooter, "Shooters are offered gyro aiming")
        check(GameSetupKind.suggested(category: "Sports", title: "EA SPORTS FC") == nil, "Other genres get no suggestion")
        var racing = ControllerSettings.default
        GameSetupKind.racing.apply(to: &racing)
        check(racing.enhancements?.gyroMode == .steering && racing.adaptiveTriggers.rightPreset == .accelerator
              && racing.adaptiveTriggers.leftPreset == .brake, "The racing setup turns on steering and pedal triggers")
        var shooter = ControllerSettings.default
        GameSetupKind.shooter.apply(to: &shooter)
        check(shooter.enhancements?.gyroMode == .aiming && shooter.adaptiveTriggers.rightPreset == .pistol, "The shooter setup turns on gyro aiming and a trigger break")

        print("\(checks) stream health and setup contract checks passed.")
    }
}
