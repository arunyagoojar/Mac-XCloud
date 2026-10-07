//
//  StreamHealthAnalysis.swift
//  Mac XCloud
//
//  The stream health rules: the last 20 seconds of stream statistics plus
//  the Wi-Fi conditions in, plain-language problems and advice out. Pure, so
//  the contract tests drive it with recorded-style numbers.
//

import Foundation

// MARK: - Inputs

struct StreamHealthSample: Equatable {
    var time: TimeInterval
    var pingMs: Double
    var fps: Double
    var bitrateMbps: Double
    /// Cumulative counters since the stream started.
    var packetsLost: Int
    var packetsReceived: Int
    var framesDropped: Int
    var framesReceived: Int
    /// The network's jitter (RTP interarrival, ms); 0 when not reported.
    /// Not Better xCloud's "jitter", which is the playout buffer's delay and
    /// sits at 20–60 ms on a perfect connection.
    var jitterMs: Double
    var decodeMs: Double
    /// Cumulative count of picture freezes since the stream started.
    var freezes: Int = 0
    /// Height of the decoded picture (1080 for 1080p); 0 when not reported.
    var frameHeight: Int = 0
}

struct NetworkConditions: Equatable {
    enum Link: Equatable { case wired, wifi, other }
    enum Band: Equatable { case ghz2, ghz5, ghz6 }

    var link: Link
    var rssi: Int? = nil
    var noise: Int? = nil
    var band: Band? = nil
    var transmitRateMbps: Double? = nil

    var description: String {
        switch link {
        case .wired: return "Ethernet"
        case .other: return "Network"
        case .wifi:
            var parts = ["Wi‑Fi"]
            switch band {
            case .ghz2?: parts.append("2.4 GHz")
            case .ghz5?: parts.append("5 GHz")
            case .ghz6?: parts.append("6 GHz")
            case nil: break
            }
            if let rssi { parts.append("\(rssi) dBm") }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Report

enum StreamHealthLevel: Int, Comparable {
    case good, fair, poor

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        }
    }
}

struct StreamHealthIssue: Equatable, Identifiable {
    enum Kind: String {
        case weakSignal, slowBand, interference, packetLoss, latency, latencySpikes, jitter
        case decoding, frameDrops, lowFrameRate, bandwidth
    }

    var kind: Kind
    var level: StreamHealthLevel
    var title: String
    /// One or two sentences: what to do about it.
    var advice: String
    /// A few words for the in-game notice.
    var shortAdvice: String
    var symbol: String

    var id: String { kind.rawValue }

    /// Worth interrupting the game for: the player can already see or feel
    /// it. Everything else is shown in Settings › Performance only.
    var hurtsPlay: Bool {
        switch kind {
        case .packetLoss, .frameDrops, .bandwidth: return true
        default: return level == .poor
        }
    }
}

struct StreamHealthReport: Equatable {
    var level: StreamHealthLevel
    var issues: [StreamHealthIssue]
    var latencyMs: Double?
    var lossPercent: Double?
    var fps: Double?
    var bitrateMbps: Double?

    var summary: String {
        var parts: [String] = []
        if let latencyMs { parts.append("\(Int(latencyMs.rounded())) ms") }
        if let lossPercent { parts.append(String(format: "%.1f%% loss", lossPercent)) }
        if let fps { parts.append("\(Int(fps.rounded())) fps") }
        if let bitrateMbps, bitrateMbps > 0 { parts.append(String(format: "%.0f Mbps", bitrateMbps)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Analysis

enum StreamHealthAnalyzer {
    static let window: TimeInterval = 20

    /// nil until there are a few seconds of data.
    static func report(samples: [StreamHealthSample], network: NetworkConditions?, targetFPS: Double = 60) -> StreamHealthReport? {
        guard let last = samples.last else { return nil }
        let recent = samples.filter { $0.time >= last.time - window }
        guard recent.count >= 4, let first = recent.first, last.time - first.time >= 3 else { return nil }

        let pings = recent.map(\.pingMs).filter { $0 >= 0 }.sorted()
        let latency = pings.isEmpty ? nil : median(pings)
        let spike = pings.isEmpty ? 0 : percentile(pings, 0.9) - (latency ?? 0)
        let jitter = median(recent.map(\.jitterMs).filter { $0 > 0 }.sorted())
        let decode = median(recent.map(\.decodeMs).filter { $0 > 0 }.sorted())
        let fps = median(recent.map(\.fps).filter { $0 > 0 }.sorted())
        let bitrate = median(recent.map(\.bitrateMbps).filter { $0 > 0 }.sorted())

        // Loss over the window, from the cumulative counters.
        let lost = max(last.packetsLost - first.packetsLost, 0)
        let received = max(last.packetsReceived - first.packetsReceived, 0)
        var loss: Double?
        if lost + received > 0 {
            loss = Double(lost) * 100 / Double(lost + received)
        } else if lost > 0, bitrate > 0 {
            // No received count: estimate packets from the bitrate (~1200-byte packets).
            let estimated = bitrate * 1_000_000 / 8 / 1200 * (last.time - first.time)
            loss = Double(lost) * 100 / max(Double(lost) + estimated, 1)
        } else {
            loss = 0
        }
        let dropped = max(last.framesDropped - first.framesDropped, 0)
        let shown = max(last.framesReceived - first.framesReceived, 0)
        let dropRate = dropped + shown > 0 ? Double(dropped) * 100 / Double(dropped + shown) : 0
        // Lost packets matter only when they reach the screen. WebRTC resends
        // or repairs most of them, and those still count as lost.
        let froze = last.freezes > first.freezes
        let visible = dropRate >= 1 || froze
        // Xbox lowers the resolution when the connection can't keep up; a
        // lower bitrate alone is usually just a calm scene or a menu.
        let heights = recent.map(\.frameHeight).filter { $0 > 0 }
        let latestHeight = recent.suffix(4).map(\.frameHeight).filter { $0 > 0 }.max() ?? 0
        let resolutionDropped = latestHeight > 0 && Double(latestHeight) < Double(heights.max() ?? 0) * 0.8

        var issues: [StreamHealthIssue] = []
        let wifi = network?.link == .wifi
        let networkTrouble = ((loss ?? 0) >= 1 && visible) || jitter >= 20 || spike >= 50

        if let loss, loss >= 1, visible {
            issues.append(StreamHealthIssue(
                kind: .packetLoss, level: loss >= 3 ? .poor : .fair,
                title: String(format: "Packet loss (%.1f%%)", loss),
                advice: wifi ? "Wi‑Fi is dropping data, which shows up as stutter and blocky video. Move closer to the router or use Ethernet."
                             : "The connection is dropping data, which shows up as stutter and blocky video. Pause downloads or other streams on the network.",
                shortAdvice: wifi ? "Move closer to the router" : "Pause other downloads",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"))
        }
        if let latency, latency >= 60 {
            issues.append(StreamHealthIssue(
                kind: .latency, level: latency >= 100 ? .poor : .fair,
                title: "High latency (\(Int(latency.rounded())) ms)",
                advice: "Controls feel delayed because the server is far away or the network is slow. Try Settings › General › Fastest server.",
                shortAdvice: "Try a closer server", symbol: "timer"))
        }
        if spike >= 50 {
            issues.append(StreamHealthIssue(
                kind: .latencySpikes, level: spike >= 100 ? .poor : .fair,
                title: "Latency spikes",
                advice: "Something else on the network is using it in bursts: downloads, cloud backups or another stream.",
                shortAdvice: "Pause downloads and backups", symbol: "waveform.path.ecg"))
        }
        if jitter >= 20 {
            issues.append(StreamHealthIssue(
                kind: .jitter, level: jitter >= 40 ? .poor : .fair,
                title: "Unsteady connection",
                advice: wifi ? "Data arrives unevenly, so the stream has to wait for it. A wired connection or a closer router helps most."
                             : "Data arrives unevenly, so the stream has to wait for it. Other traffic on the network is the usual cause.",
                shortAdvice: wifi ? "Use Ethernet if you can" : "Pause other traffic", symbol: "chart.line.uptrend.xyaxis"))
        }
        let frameTime = 1000 / max(targetFPS, 30)
        let decoding = decode >= frameTime * 0.6
        if decoding {
            issues.append(StreamHealthIssue(
                kind: .decoding, level: decode >= frameTime * 0.8 ? .poor : .fair,
                title: "This Mac is decoding slowly (\(Int(decode.rounded())) ms)",
                advice: "Close other demanding apps, or turn off Sharpening or lower the resolution in Settings › Streaming.",
                shortAdvice: "Close other apps", symbol: "cpu"))
        }
        if dropRate >= 1.5 && !decoding {
            issues.append(StreamHealthIssue(
                kind: .frameDrops, level: dropRate >= 5 ? .poor : .fair,
                title: String(format: "Dropped frames (%.0f%%)", dropRate),
                advice: networkTrouble ? "Frames arrive damaged or late because of the network problems above."
                                       : "The stream is skipping frames. If it continues, lower the resolution in Settings › Streaming.",
                shortAdvice: "Check the connection", symbol: "film.stack"))
        }
        // A frame rate below 60 on its own is not reported: many games run at
        // 30 fps, and that is not something the connection can fix.
        let latestBitrate = median(recent.suffix(5).map(\.bitrateMbps).filter { $0 > 0 }.sorted())
        let peakBitrate = recent.map(\.bitrateMbps).max() ?? 0
        let bitrateCollapsed = peakBitrate > 0 && latestBitrate > 0 && latestBitrate < peakBitrate * 0.4 && latestBitrate < 8
        if resolutionDropped || (bitrateCollapsed && visible) {
            issues.append(StreamHealthIssue(
                kind: .bandwidth, level: .fair,
                title: resolutionDropped ? "Picture quality dropped (\(latestHeight)p)" : "Bandwidth dropped",
                advice: "The network slowed down, so Xbox lowered the picture quality to keep up. Downloads or other streams on the network are the usual cause.",
                shortAdvice: "Pause other downloads", symbol: "arrow.down.circle"))
        }
        if let network, network.link == .wifi {
            if let rssi = network.rssi, rssi <= -75 || (rssi <= -67 && networkTrouble) {
                issues.append(StreamHealthIssue(
                    kind: .weakSignal, level: rssi <= -75 && networkTrouble ? .poor : .fair,
                    title: "Weak Wi‑Fi signal (\(rssi) dBm)",
                    advice: "Move closer to the router or remove what's between them, or use Ethernet.",
                    shortAdvice: "Move closer to the router", symbol: "wifi.exclamationmark"))
            }
            if network.band == .ghz2, networkTrouble {
                issues.append(StreamHealthIssue(
                    kind: .slowBand, level: .fair,
                    title: "2.4 GHz Wi‑Fi",
                    advice: "5 GHz Wi‑Fi is faster and steadier for streaming. Join your router's 5 GHz network if it has one.",
                    shortAdvice: "Use 5 GHz Wi‑Fi", symbol: "wifi"))
            }
            if let rssi = network.rssi, let noise = network.noise, rssi - noise < 15, networkTrouble {
                issues.append(StreamHealthIssue(
                    kind: .interference, level: .fair,
                    title: "Wi‑Fi interference",
                    advice: "Other networks or devices nearby are drowning out the signal. A different Wi‑Fi channel or Ethernet helps.",
                    shortAdvice: "Try another Wi‑Fi channel", symbol: "antenna.radiowaves.left.and.right"))
            }
        }
        // Worst first; at the same level, causes (signal, band, interference,
        // a slow Mac) before the symptoms they explain.
        let causes: Set<StreamHealthIssue.Kind> = [.weakSignal, .slowBand, .interference, .decoding]
        issues.sort { a, b in
            if a.level != b.level { return a.level > b.level }
            return causes.contains(a.kind) && !causes.contains(b.kind)
        }
        return StreamHealthReport(level: issues.map(\.level).max() ?? .good, issues: issues,
                                  latencyMs: latency, lossPercent: loss, fps: fps > 0 ? fps : nil,
                                  bitrateMbps: bitrate > 0 ? bitrate : nil)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)]
    }
}
