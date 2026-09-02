//
//  SettingsOverlay.swift
//  Xbox Cloud Gaming
//
//  The app's settings overlay: a transparent, controller-navigable panel that
//  reads and writes Better xCloud's live settings through the BxCBridge JS
//  interface, plus device-level controller settings (DualSense LED).
//

import Combine
import GameController
import SwiftUI

// MARK: - Model

struct RegionInfo: Decodable, Equatable {
    var shortName: String?
    var displayName: String?
    var isDefault: Bool?
}

struct OverlayRow: Identifiable {
    enum Kind {
        case toggle
        case cycle
        case action(() -> Void)
    }

    let id: String
    let section: String
    let label: String
    let kind: Kind
    let note: String?
    let isOn: Bool
    let value: String

    var isToggleOrCycle: Bool {
        if case .action = kind { return false }
        return true
    }

    var isCycle: Bool {
        if case .cycle = kind { return true }
        return false
    }

    var isToggle: Bool {
        if case .toggle = kind { return true }
        return false
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var bridgeAvailable = false
    @Published var rows: [OverlayRow] = []
    @Published var focusIndex = 0
    @Published var ledColorIndex: Int {
        didSet { UserDefaults.standard.set(ledColorIndex, forKey: "ledColorIndex") }
    }

    private var regionOptions: [(value: String, label: String)] = [("default", "Default (closest server)")]
    private var regionIndex = 0
    private var resolutionIndex = 0
    private var bitrateIndex = 0
    private var preventDrops = false
    private var splashSkip = true
    private var feedbackDisabled = true
    private var statsShow = false
    private var statsPositionIndex = 0
    private var statsPresetIndex = 0
    private var vibrationModeIndex = 0
    private var vibrationIntensityIndex = 4   // 50%

    static let resolutions = ["auto", "720p", "1080p", "1080p-hq"]
    static let resolutionLabels = ["Default (auto)", "720p", "1080p", "1080p (High quality)"]
    /// Raw storage values; 0 = unlimited.
    static let bitrates: [(value: Double, label: String)] = [
        (0, "Unlimited"), (5_120_000, "5 Mb/s"), (10_240_000, "10 Mb/s"), (15_360_000, "15 Mb/s"),
    ]
    static let statsPositions = ["top-left", "top-center", "top-right"]
    static let statsPresets: [(label: String, items: [String])] = [
        ("Full (ping, fps, bitrate, decode, loss)", ["ping", "fps", "btr", "dt", "pl", "fl"]),
        ("Essential (ping, fps)", ["ping", "fps"]),
        ("Performance (fps, bitrate, decode)", ["fps", "btr", "dt"]),
        ("Minimal (ping only)", ["ping"]),
    ]
    static let vibrationModes = ["off", "on", "auto"]
    static let vibrationModeLabels = ["Off", "On", "On when idle"]

    private weak var browser: BrowserModel?
    private let ledColors = LEDColor.all

    init(browser: BrowserModel) {
        self.browser = browser
        ledColorIndex = UserDefaults.standard.object(forKey: "ledColorIndex") as? Int ?? 1
    }

    // MARK: - Load / persist

    func load() {
        browser?.evaluateJS(BetterXCloud.readStateJS) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self,
                      let json = result as? String,
                      let data = json.data(using: .utf8),
                      let snapshot = try? JSONDecoder().decode(OverlaySnapshot.self, from: data) else {
                    self?.bridgeAvailable = false
                    self?.rebuildRows()
                    return
                }
                self.apply(snapshot)
                self.rebuildRows()
            }
        }
    }

    private struct OverlaySnapshot: Decodable {
        let bridge: Bool
        let regions: [String: RegionInfo]?
        let region: String?
        let resolution: String?
        let rawBitrate: Double?
        let preventDrops: Bool?
        let splashSkip: Bool?
        let feedbackDisabled: Bool?
        let statsShow: Bool?
        let statsPosition: String?
        let statsItems: [String]?
        let vibrationMode: String?
        let vibrationIntensity: Double?
    }

    private func apply(_ s: OverlaySnapshot) {
        bridgeAvailable = s.bridge
        guard s.bridge else { return }

        let keys = s.regions?.keys.sorted() ?? []
        regionOptions = [("default", "Default (closest server)")] + keys.map { key in
            let info = s.regions?[key]
            let name = info?.displayName ?? info?.shortName ?? key
            return (key, name)
        }
        if let region = s.region, let index = regionOptions.firstIndex(where: { $0.value == region }) {
            regionIndex = index
        }

        if let res = s.resolution, let index = Self.resolutions.firstIndex(of: res) {
            resolutionIndex = index
        }
        let bitrate = s.rawBitrate ?? 0
        bitrateIndex = (Self.bitrates.firstIndex { $0.value == bitrate }) ?? 0
        preventDrops = s.preventDrops ?? false
        splashSkip = s.splashSkip ?? true
        feedbackDisabled = s.feedbackDisabled ?? true
        statsShow = s.statsShow ?? false
        if let pos = s.statsPosition, let index = Self.statsPositions.firstIndex(of: pos) {
            statsPositionIndex = index
        }
        if let items = s.statsItems, let index = Self.statsPresets.firstIndex(where: { Set($0.items) == Set(items) }) {
            statsPresetIndex = index
        }
        if let mode = s.vibrationMode, let index = Self.vibrationModes.firstIndex(of: mode) {
            vibrationModeIndex = index
        }
        if let intensity = s.vibrationIntensity, intensity >= 10 {
            vibrationIntensityIndex = Int((intensity - 10) / 10)
        }
    }

    // MARK: - Row construction

    private func rebuildRows() {
        var rows: [OverlayRow] = []
        func add(_ id: String, _ section: String, _ label: String, isOn: Bool = false, value: String = "", note: String? = nil, kind: OverlayRow.Kind) {
            rows.append(OverlayRow(id: id, section: section, label: label, kind: kind, note: note, isOn: isOn, value: value))
        }

        let stream = "STREAM & OVERLAY"
        add("stats.show", stream, "Show stats overlay", isOn: statsShow, kind: .toggle)
        add("stats.position", stream, "Stats position", value: Self.statsPositions[statsPositionIndex].replacingOccurrences(of: "-", with: " ").capitalized, kind: .cycle)
        add("stats.items", stream, "Stats items", value: Self.statsPresets[statsPresetIndex].label, kind: .cycle)
        add("vibration.mode", stream, "Controller vibration", value: Self.vibrationModeLabels[vibrationModeIndex], kind: .cycle)
        add("vibration.intensity", stream, "Vibration intensity", value: "\(10 + vibrationIntensityIndex * 10)%", kind: .cycle)

        let video = "VIDEO"
        add("video.resolution", video, "Target resolution", value: Self.resolutionLabels[resolutionIndex], note: "Applies to the next stream", kind: .cycle)
        add("video.bitrate", video, "Max bitrate", value: Self.bitrates[bitrateIndex].label, note: "Applies to the next stream", kind: .cycle)
        add("video.preventDrops", video, "Prevent resolution drops", isOn: preventDrops, note: "Applies to the next stream", kind: .toggle)

        let site = "SITE"
        add("site.region", site, "Server region", value: regionOptions[regionIndex].label, note: "Applies to the next stream", kind: .cycle)
        add("site.splash", site, "Skip Xbox splash video", isOn: splashSkip, kind: .toggle)
        add("site.feedback", site, "Disable feedback dialogs", isOn: feedbackDisabled, kind: .toggle)

        let controller = "CONTROLLER"
        if let name = browser?.controllerInput.controllerName {
            add("controller.led", controller, "LED color — \(name)", value: ledColors[ledColorIndex].label, note: browser?.controllerInput.supportsLED == true ? nil : "LED not exposed by this controller", kind: .cycle)
        } else {
            add("controller.led", controller, "LED color", value: "No controller connected", kind: .cycle)
        }
        add("page.reload", controller, "Reload page (apply all changes)", kind: .action { [weak self] in
            self?.browser?.reload()
        })

        if !bridgeAvailable {
            rows.insert(OverlayRow(id: "bridge.warning", section: "", label: "Open xbox.com/play at least once, then reopen settings to load your cloud settings.", kind: .action({}), note: nil, isOn: false, value: ""), at: 0)
        }
        self.rows = rows
        focusIndex = min(focusIndex, max(rows.count - 1, 0))
    }

    // MARK: - Controller navigation

    func navigate(_ direction: Int) {
        guard !rows.isEmpty else { return }
        focusIndex = (focusIndex + direction + rows.count) % rows.count
        objectWillChange.send()
    }

    func adjust(_ direction: Int) {
        changeValue(at: focusIndex, delta: direction)
    }

    func activate() {
        changeValue(at: focusIndex, delta: 1)
    }

    private func changeValue(at index: Int, delta: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]

        switch row.id {
        case "stats.show":
            statsShow.toggle()
            setStream("stats.showWhenPlaying", statsShow)
        case "stats.position":
            statsPositionIndex = wrap(statsPositionIndex + delta, Self.statsPositions.count)
            setStream("stats.position", Self.statsPositions[statsPositionIndex])
        case "stats.items":
            statsPresetIndex = wrap(statsPresetIndex + delta, Self.statsPresets.count)
            setStream("stats.items", Self.statsPresets[statsPresetIndex].items)
        case "vibration.mode":
            vibrationModeIndex = wrap(vibrationModeIndex + delta, Self.vibrationModes.count)
            setStream("deviceVibration.mode", Self.vibrationModes[vibrationModeIndex])
        case "vibration.intensity":
            vibrationIntensityIndex = wrap(vibrationIntensityIndex + delta, 10)
            setStream("deviceVibration.intensity", 10 + vibrationIntensityIndex * 10)
        case "video.resolution":
            resolutionIndex = wrap(resolutionIndex + delta, Self.resolutions.count)
            setGlobal("stream.video.resolution", Self.resolutions[resolutionIndex])
        case "video.bitrate":
            bitrateIndex = wrap(bitrateIndex + delta, Self.bitrates.count)
            setGlobal("stream.video.maxBitrate", Self.bitrates[bitrateIndex].value)
        case "video.preventDrops":
            preventDrops.toggle()
            setGlobal("stream.video.preventResolutionDrops", preventDrops)
        case "site.region":
            regionIndex = wrap(regionIndex + delta, regionOptions.count)
            setGlobal("server.region", regionOptions[regionIndex].value)
        case "site.splash":
            splashSkip.toggle()
            setGlobal("ui.splashVideo.skip", splashSkip)
        case "site.feedback":
            feedbackDisabled.toggle()
            setGlobal("ui.feedbackDialog.disabled", feedbackDisabled)
        case "controller.led":
            ledColorIndex = wrap(ledColorIndex + delta, ledColors.count)
            browser?.controllerInput.setLED(ledColors[ledColorIndex])
        case "page.reload":
            if case .action(let run) = row.kind { run() }
            browser?.showSettingsOverlay = false
        default:
            break
        }
        rebuildRows()
    }

    private func wrap(_ value: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (value + count) % count
    }

    private func setGlobal(_ key: String, _ value: Any) {
        browser?.evaluateJS("try { BxCBridge.setGlobal('\(key)', \(jsonEncoded(value))); 'ok' } catch (e) { 'err' }")
    }

    private func setStream(_ key: String, _ value: Any) {
        browser?.evaluateJS("try { BxCBridge.setStream('\(key)', \(jsonEncoded(value))); 'ok' } catch (e) { 'err' }")
    }

    private func jsonEncoded(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? Double { return String(format: "%.0f", number) }
        if let int = value as? Int { return String(int) }
        if let string = value as? String { return "'\(string.replacingOccurrences(of: "'", with: "\\'"))'" }
        if let array = value as? [String] {
            return "[" + array.map { "'\($0)'" }.joined(separator: ",") + "]"
        }
        return "null"
    }
}

// MARK: - View

struct SettingsOverlayView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.08))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        let rows = model.rows
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index < rows.count && (index == 0 || rows[index - 1].section != row.section) && !row.section.isEmpty {
                                sectionHeader(row.section)
                            }
                            rowView(row, index: index)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .frame(width: 400)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .leading) { Divider().overlay(.white.opacity(0.1)) }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.bridgeAvailable
                     ? "B for back · A select · ◄ ► change"
                     : "Open xbox.com/play first, then reopen")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button {
                browser.showSettingsOverlay = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.35))
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowView(_ row: OverlayRow, index: Int) -> some View {
        let isFocused = model.focusIndex == index

        Button {
            model.focusIndex = index
            model.activate()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .font(.system(size: 14, weight: isFocused ? .semibold : .regular))
                        .foregroundStyle(.white)
                    if let note = row.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer()
                if row.isToggleOrCycle {
                    HStack(spacing: 8) {
                        if row.isCycle {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(isFocused ? 0.8 : 0.3))
                        }
                        Text(rowValueText(row))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(rowValueColor(row))
                        if row.isCycle {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(isFocused ? 0.8 : 0.3))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Color(red: 0.30, green: 0.85, blue: 0.35).opacity(0.9) : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { model.focusIndex = index }
        }
    }

    private func rowValueText(_ row: OverlayRow) -> String {
        switch row.id {
        case "stats.show", "video.preventDrops", "site.splash", "site.feedback":
            return row.isOn ? "On" : "Off"
        default:
            return row.value
        }
    }

    private func rowValueColor(_ row: OverlayRow) -> Color {
        if row.isToggle {
            return row.isOn ? Color(red: 0.35, green: 0.9, blue: 0.4) : .white.opacity(0.5)
        }
        return .white
    }
}
