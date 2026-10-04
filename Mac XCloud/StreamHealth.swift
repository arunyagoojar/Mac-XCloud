//
//  StreamHealth.swift
//  Mac XCloud
//
//  Turns the stream's numbers into plain advice: not "jitter 34 ms" but
//  "Unsteady connection · Pause other downloads". The rules live in
//  StreamHealthAnalysis.swift; this file collects the stream statistics and
//  the Wi-Fi conditions macOS reports (signal, noise, band; no location
//  permission needed) and shows the result.
//

import Combine
import CoreWLAN
import Foundation
import Network
import SwiftUI

// MARK: - Live monitor

/// Collects the stream's statistics and the Wi-Fi conditions, and keeps a
/// current report. A problem that lasts is announced once in the game.
@MainActor
final class StreamHealthMonitor: ObservableObject {
    private static let noticesKey = "streamHealth.notices.v1"
    static let persistedKeys = [noticesKey]

    @Published private(set) var report: StreamHealthReport?
    @Published private(set) var network: NetworkConditions?
    /// Announce problems that last while playing.
    @Published var noticesEnabled = UserDefaults.standard.object(forKey: noticesKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(noticesEnabled, forKey: Self.noticesKey) }
    }
    /// Called with a problem worth telling the player about.
    var onNotice: ((StreamHealthIssue) -> Void)?

    private var samples: [StreamHealthSample] = []
    private var persisting: [StreamHealthIssue.Kind: Int] = [:]
    private var announced: Set<StreamHealthIssue.Kind> = []
    private var lastNoticeAt = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var link = NetworkConditions.Link.other

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let link: NetworkConditions.Link = path.usesInterfaceType(.wiredEthernet) ? .wired
                : path.usesInterfaceType(.wifi) ? .wifi : .other
            Task { @MainActor [weak self] in
                self?.link = link
                self?.refreshNetwork()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "xcg.stream-health.path", qos: .utility))
    }

    deinit { pathMonitor.cancel() }

    /// The Wi-Fi conditions right now (signal, noise, band, link rate).
    /// CoreWLAN answers in a few milliseconds, too long for the main thread,
    /// which also reads the controller: it is asked on a background queue.
    func refreshNetwork() {
        #if DEBUG
        guard !previewing else { return }
        #endif
        let link = self.link
        guard link == .wifi else {
            let conditions = NetworkConditions(link: link)
            if network != conditions { network = conditions }
            return
        }
        Self.wifiQueue.async { [weak self] in
            var conditions = NetworkConditions(link: .wifi)
            if let wifi = CWWiFiClient.shared().interface() {
                let rssi = wifi.rssiValue(), noise = wifi.noiseMeasurement()
                conditions.rssi = rssi != 0 ? rssi : nil
                conditions.noise = noise != 0 ? noise : nil
                // CWChannelBand raw values: 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz.
                switch wifi.wlanChannel()?.channelBand.rawValue {
                case 1?: conditions.band = .ghz2
                case 2?: conditions.band = .ghz5
                case 3?: conditions.band = .ghz6
                default: conditions.band = nil
                }
                let rate = wifi.transmitRate()
                conditions.transmitRateMbps = rate > 0 ? rate : nil
            }
            let measured = conditions
            let monitor = self
            Task { @MainActor in
                guard let monitor, monitor.link == .wifi, monitor.network != measured else { return }
                monitor.network = measured
            }
        }
    }

    private static let wifiQueue = DispatchQueue(label: "xcg.stream-health.wifi", qos: .utility)

    func ingest(_ telemetry: StreamTelemetry) {
        let now = ProcessInfo.processInfo.systemUptime
        samples.append(StreamHealthSample(time: now, pingMs: telemetry.pingMs, fps: telemetry.fps,
                                          bitrateMbps: telemetry.bitrateMbps, packetsLost: telemetry.packetLossCount,
                                          packetsReceived: telemetry.packetsReceived, framesDropped: telemetry.framesDropped,
                                          framesReceived: telemetry.framesReceived, jitterMs: telemetry.jitterMs,
                                          decodeMs: telemetry.decodeTimeMs))
        samples.removeAll { $0.time < now - StreamHealthAnalyzer.window - 5 }
        if samples.count % 3 == 0 { refreshNetwork() }
        let next = StreamHealthAnalyzer.report(samples: samples, network: network)
        if next != report { report = next }
        considerNotice(next)
    }

    #if DEBUG
    private var previewing = false

    /// Settings snapshots: show a report computed from given samples.
    func preview(network: NetworkConditions, samples: [StreamHealthSample]) {
        previewing = true
        self.network = network
        report = StreamHealthAnalyzer.report(samples: samples, network: network)
    }
    #endif

    /// The stream ended: start fresh next time.
    func reset() {
        samples.removeAll()
        persisting.removeAll()
        announced.removeAll()
        if report != nil { report = nil }
    }

    private func considerNotice(_ report: StreamHealthReport?) {
        let current = Set(report?.issues.map(\.kind) ?? [])
        persisting = persisting.filter { current.contains($0.key) }
        for issue in report?.issues ?? [] { persisting[issue.kind, default: 0] += 1 }
        guard noticesEnabled, let issue = report?.issues.first(where: { persisting[$0.kind, default: 0] >= 8 && !announced.contains($0.kind) }),
              Date().timeIntervalSince(lastNoticeAt) > 90 else { return }
        announced.insert(issue.kind)
        lastNoticeAt = Date()
        onNotice?(issue)
    }
}

// MARK: - Views

extension StreamHealthLevel {
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

/// The Connection section of Settings › Performance: the stream's health in
/// plain words, what is wrong and what to do.
struct StreamHealthSection: View {
    @ObservedObject var monitor: StreamHealthMonitor
    let isStreaming: Bool

    var body: some View {
        SettingsGroup("Connection", footer: footer) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 13, weight: .semibold))
                    if let summary = monitor.report?.summary, !summary.isEmpty, isStreaming {
                        Text(summary).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let network = monitor.network {
                    Label(network.description, systemImage: network.link == .wired ? "cable.connector" : "wifi")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .settingsRow()
            .accessibilityElement(children: .combine)
            if isStreaming, let issues = monitor.report?.issues {
                // The three that matter most; the rest usually follow from them.
                ForEach(Array(issues.prefix(3))) { issue in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: SettingsSymbol.available(issue.symbol))
                            .foregroundStyle(issue.level.color)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                            Text(issue.advice).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .settingsRow()
                    .accessibilityElement(children: .combine)
                }
            }
            Divider()
            SettingsToggleRow(label: "Tell me when the connection gets worse",
                              note: "A short notice in the game when a problem lasts.",
                              isOn: $monitor.noticesEnabled)
        }
        .onAppear { monitor.refreshNetwork() }
    }

    private var statusColor: Color {
        guard isStreaming else { return .secondary.opacity(0.5) }
        return monitor.report?.level.color ?? .secondary.opacity(0.5)
    }

    private var statusTitle: String {
        guard isStreaming else { return "Not playing" }
        guard let report = monitor.report else { return "Measuring…" }
        return report.level == .good ? "Good connection" : report.level == .fair ? "Fair connection" : "Poor connection"
    }

    private var footer: String {
        isStreaming ? "Based on the last 20 seconds of the stream."
                    : "Start a game to see how the connection holds up."
    }
}
