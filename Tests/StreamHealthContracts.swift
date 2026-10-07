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
                    lossPerSecond: Int = 0, dropsPerSecond: Int = 0, jitter: Double = 2, decode: Double = 4,
                    freezesAt: Set<Int> = [], height: (Int) -> Int = { _ in 1080 }) -> [StreamHealthSample] {
            (0...seconds).map { t in
                StreamHealthSample(time: Double(t), pingMs: ping(t), fps: fps, bitrateMbps: bitrate(t),
                                   packetsLost: lossPerSecond * t, packetsReceived: 1500 * t,
                                   framesDropped: dropsPerSecond * t, framesReceived: Int(fps) * t,
                                   jitterMs: jitter, decodeMs: decode,
                                   freezes: freezesAt.filter { $0 <= t }.count, frameHeight: height(t))
            }
        }
        let wired = NetworkConditions(link: .wired)
        let goodWiFi = NetworkConditions(link: .wifi, rssi: -55, noise: -92, band: .ghz5, transmitRateMbps: 866)

        let clean = StreamHealthAnalyzer.report(samples: stream(), network: goodWiFi)
        check(clean?.level == .good && clean?.issues.isEmpty == true, "A clean stream on good Wi-Fi reports Good with no advice")
        check(clean?.summary == "28 ms · 0.0% loss · 60 fps · 18 Mbps", "The summary reads latency, loss, frame rate and bitrate")
        check(StreamHealthAnalyzer.report(samples: Array(stream().prefix(2)), network: wired) == nil, "Two seconds are not enough to judge")

        let lossy = StreamHealthAnalyzer.report(samples: stream(lossPerSecond: 50, dropsPerSecond: 2), network: goodWiFi)
        check(lossy?.issues.first?.kind == .packetLoss && lossy?.level == .poor, "3% packet loss that drops frames is a poor connection, named as packet loss")
        check(lossy?.issues.first?.advice.contains("Ethernet") == true, "On Wi-Fi, packet loss advice points at the router or Ethernet")
        let repaired = StreamHealthAnalyzer.report(samples: stream(lossPerSecond: 50), network: goodWiFi)
        check(repaired?.issues.isEmpty == true && repaired?.level == .good, "Loss the stream repairs without dropping a frame raises no alarm")
        let frozen = StreamHealthAnalyzer.report(samples: stream(lossPerSecond: 30, freezesAt: [12]), network: wired)
        check(frozen?.issues.first?.kind == .packetLoss, "Loss that froze the picture is reported")
        let buffered = StreamHealthAnalyzer.report(samples: stream(jitter: 0), network: goodWiFi)
        check(buffered?.issues.isEmpty == true, "Without a network jitter figure, nothing is guessed")

        let far = StreamHealthAnalyzer.report(samples: stream(ping: { _ in 112 }), network: wired)
        check(far?.issues.map(\.kind) == [.latency] && far?.level == .poor, "112 ms latency is named, with the fastest-server advice")

        let spiky = StreamHealthAnalyzer.report(samples: stream(ping: { $0 % 4 == 0 ? 120 : 30 }), network: wired)
        check(spiky?.issues.contains { $0.kind == .latencySpikes } == true, "Bursts of latency are reported as spikes")

        let weak = StreamHealthAnalyzer.report(samples: stream(jitter: 22), network: NetworkConditions(link: .wifi, rssi: -71, noise: -90, band: .ghz5))
        check(weak?.issues.contains { $0.kind == .weakSignal } == true && weak?.issues.contains { $0.kind == .jitter } == true,
              "An unsteady stream on a weak signal blames the signal")
        let quietWeak = StreamHealthAnalyzer.report(samples: stream(), network: NetworkConditions(link: .wifi, rssi: -70, noise: -90, band: .ghz5))
        check(quietWeak?.issues.isEmpty == true, "A middling signal that streams cleanly raises no alarm")
        let quietBand = StreamHealthAnalyzer.report(samples: stream(), network: NetworkConditions(link: .wifi, rssi: -50, noise: -90, band: .ghz2))
        check(quietBand?.issues.isEmpty == true, "2.4 GHz Wi-Fi that streams cleanly raises no alarm")
        let band = StreamHealthAnalyzer.report(samples: stream(jitter: 24), network: NetworkConditions(link: .wifi, rssi: -50, noise: -90, band: .ghz2))
        check(band?.issues.contains { $0.kind == .slowBand } == true, "2.4 GHz Wi-Fi is pointed out when the stream is unsteady")

        let slowMac = StreamHealthAnalyzer.report(samples: stream(dropsPerSecond: 4, decode: 15), network: wired)
        check(slowMac?.issues.first?.kind == .decoding && slowMac?.issues.contains { $0.kind == .frameDrops } == false,
              "Slow decoding is blamed on the Mac, not reported again as dropped frames")
        let drops = StreamHealthAnalyzer.report(samples: stream(dropsPerSecond: 3), network: wired)
        check(drops?.issues.map(\.kind) == [.frameDrops], "Dropped frames on a healthy network are named on their own")

        let calmScene = StreamHealthAnalyzer.report(samples: stream(bitrate: { $0 > 14 ? 5 : 20 }), network: wired)
        check(calmScene?.issues.isEmpty == true, "A calm scene or a menu (low bitrate, nothing lost) raises no alarm")
        let squeezed = StreamHealthAnalyzer.report(samples: stream(height: { $0 > 12 ? 720 : 1080 }), network: wired)
        check(squeezed?.issues.contains { $0.kind == .bandwidth && $0.title.contains("720p") } == true,
              "A drop in resolution is reported as lower picture quality")
        let thirty = StreamHealthAnalyzer.report(samples: stream(fps: 30), network: wired)
        check(thirty?.issues.isEmpty == true, "A game running at 30 fps is not a connection problem")

        // Only what the player can see interrupts the game.
        let fairJitter = StreamHealthAnalyzer.report(samples: stream(jitter: 24), network: wired)
        check(fairJitter?.issues.first?.kind == .jitter && fairJitter?.issues.first?.hurtsPlay == false,
              "Moderate jitter is shown in Settings but does not interrupt the game")
        check(lossy?.issues.first?.hurtsPlay == true && far?.issues.first?.hurtsPlay == true,
              "Visible packet loss and very high latency are worth a notice")

        // The page memory watch: a leak is caught long before WebKit's 8 GB
        // limit; normal play and one-off jumps never trigger it.
        func watch(_ readings: [(Double, Double)]) -> Double? {
            var memory = PageMemoryWatch()
            return readings.first { memory.add($0.1, at: $0.0) }?.0
        }
        let healthy = (0...150).map { t in (Double(t) * 2, 650 + 180 * sin(Double(t))) }
        check(watch(healthy) == nil, "A stream wobbling between 470 and 830 MB is left alone")
        let loading = (0...30).map { t in (Double(t) * 2, t < 5 ? 400.0 : 1700.0) }
        check(watch(loading) == nil, "A single jump past the floor (a scene loading) is not a leak")
        let leak = (0...60).map { t in (Double(t) * 2, 600 + 160 * Double(t) * 2) }
        let caught = watch(leak)
        check(caught != nil && caught! <= 16 && 600 + 160 * caught! < 3200,
              "A leak of 160 MB/s is caught within about 15 seconds, below 3.2 GB")
        let slowGrowth = (0...150).map { t in (Double(t) * 2, 1600 + 5 * Double(t) * 2) }
        check(watch(slowGrowth) == nil, "Slow growth (caches filling) is not mistaken for a leak")
        check(PageMemoryWatch.lighterRenderer(than: "webgpu") == "webgl2" && PageMemoryWatch.lighterRenderer(than: "webgl2") == "default"
              && PageMemoryWatch.lighterRenderer(than: "default") == nil, "Renderers step down WebGPU → WebGL → plain video, then stop")
        check(PageMemoryWatch.pipeline(renderer: "webgl2", processing: "cas") == "webgl-cas"
              && PageMemoryWatch.pipeline(renderer: "webgl2", processing: "usm") == "webgl-usm"
              && PageMemoryWatch.pipeline(renderer: "default", processing: "cas") == "native",
              "Stepping down keeps the chosen sharpening kind")

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
