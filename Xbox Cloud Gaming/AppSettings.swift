//
//  AppSettings.swift
//  Xbox Cloud Gaming
//
//  The app's settings catalog: every Better xCloud setting the app exposes,
//  with labels and notes, plus the model that reads/writes them through the
//  BxCBridge and drives the native Settings window from a controller.
//

import Combine
import GameController
import SwiftUI

// MARK: - Definitions

enum SettingScope {
    case global   // applies when the next stream starts
    case stream   // applies live to the current stream
}

enum SettingKind {
    case toggle(defaultValue: Bool)
    /// value list with labels, cycled with ◄ ►
    case option(values: [String], labels: [String], defaultValue: String)
    /// numeric steps cycled with ◄ ►; unset shows "Default"
    case steps(values: [Double], labels: [String])
    case serverRegion
    case ledColor
}

struct SettingDef: Identifiable {
    let id: String          // Better xCloud pref key (or app-local id)
    let label: String
    let note: String?
    let scope: SettingScope
    let kind: SettingKind
}

struct SettingsCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let rows: [SettingDef]

    static let all: [SettingsCategory] = [
        SettingsCategory(id: "stream", title: "Stream", icon: "dot.radiowaves.left.and.right", rows: [
            SettingDef(id: "server.region", label: "Server region",
                       note: "Server used for new streams. Only affects the next stream you start.",
                       scope: .global, kind: .serverRegion),
            SettingDef(id: "stream.video.resolution", label: "Target resolution",
                       note: "Caps the stream resolution. 1080p (HQ) picks a better encoder profile.",
                       scope: .global, kind: .option(
                            values: ["auto", "720p", "1080p", "1080p-hq"],
                            labels: ["Default (auto)", "720p", "1080p", "1080p (HQ)"],
                            defaultValue: "auto")),
            SettingDef(id: "stream.video.maxBitrate", label: "Max video bitrate",
                       note: "⚠️ Limits the video bitrate. Low caps can look blocky in fast scenes.",
                       scope: .global, kind: .steps(
                            values: [0, 5_120_000, 10_240_000, 15_360_000],
                            labels: ["Unlimited", "5 Mb/s", "10 Mb/s", "15 Mb/s"])),
            SettingDef(id: "stream.video.preventResolutionDrops", label: "Prevent resolution drops",
                       note: "⚠️ Locks the stream to the target resolution — can cause stuttering when bandwidth drops.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stream.video.codecProfile", label: "Visual quality",
                       note: "Higher quality uses a better H264 profile (when the browser supports it).",
                       scope: .global, kind: .option(
                            values: ["default", "low", "normal", "high"],
                            labels: ["Default", "Low", "Normal", "High"],
                            defaultValue: "default")),
            SettingDef(id: "server.ipv6.prefer", label: "Prefer IPv6 server",
                       note: "Can reduce latency when your network supports IPv6.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stream.video.combineAudio", label: "Combine audio & video",
                       note: "May fix the laggy audio problem. Experimental.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "server.bypassRestriction", label: "Bypass region restriction",
                       note: "⚠️ Streams via proxy servers in other regions. Use at your own risk.",
                       scope: .global, kind: .option(
                            values: ["off", "br", "jp", "kr", "pl", "us"],
                            labels: ["Off", "Brazil", "Japan", "Korea", "Poland", "United States"],
                            defaultValue: "off")),
        ]),
        SettingsCategory(id: "stats", title: "Overlay & Stats", icon: "waveform.path.ecg.rectangle", rows: [
            SettingDef(id: "stats.showWhenPlaying", label: "Show stats when playing",
                       note: "The ping / fps / bitrate bar inside a stream.",
                       scope: .stream, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stats.items", label: "Stats items",
                       note: "Which stats appear on the bar.",
                       scope: .stream, kind: .option(
                            values: ["full", "essential", "performance", "minimal"],
                            labels: ["Full (ping, fps, bitrate, decode, loss)",
                                     "Essential (ping, fps)",
                                     "Performance (fps, bitrate, decode)",
                                     "Minimal (ping only)"],
                            defaultValue: "full")),
            SettingDef(id: "stats.position", label: "Stats position",
                       note: nil,
                       scope: .stream, kind: .option(
                            values: ["top-left", "top-center", "top-right"],
                            labels: ["Top left", "Top center", "Top right"],
                            defaultValue: "top-right")),
            SettingDef(id: "stats.textSize", label: "Stats text size",
                       note: nil,
                       scope: .stream, kind: .option(
                            values: ["small", "normal", "large"],
                            labels: ["Small", "Normal", "Large"],
                            defaultValue: "normal")),
            SettingDef(id: "stats.opacity.all", label: "Stats opacity",
                       note: "Overall transparency of the stats bar.",
                       scope: .stream, kind: .steps(
                            values: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
                            labels: [])),
            SettingDef(id: "stats.quickGlance.enabled", label: "Quick Glance mode",
                       note: "Stats appear only while you hold the Xbox/PS button.",
                       scope: .stream, kind: .toggle(defaultValue: false)),
        ]),
        SettingsCategory(id: "video", title: "Video", icon: "slider.horizontal.3", rows: [
            SettingDef(id: "video.brightness", label: "Brightness",
                       note: "Live video filter, applied to the stream.",
                       scope: .stream, kind: .steps(values: stride(from: 0.0, through: 100.0, by: 5).map { $0 }, labels: [])),
            SettingDef(id: "video.contrast", label: "Contrast",
                       note: "Live video filter, applied to the stream.",
                       scope: .stream, kind: .steps(values: stride(from: 0.0, through: 100.0, by: 5).map { $0 }, labels: [])),
            SettingDef(id: "video.saturation", label: "Saturation",
                       note: "Live video filter, applied to the stream.",
                       scope: .stream, kind: .steps(values: stride(from: 0.0, through: 100.0, by: 5).map { $0 }, labels: [])),
            SettingDef(id: "video.maxFps", label: "Limit FPS",
                       note: "Caps the stream's frame rate. 60 = unlimited.",
                       scope: .stream, kind: .steps(
                            values: [10, 20, 30, 40, 50, 60],
                            labels: ["10 fps", "20 fps", "30 fps", "40 fps", "50 fps", "Unlimited"])),
        ]),
        SettingsCategory(id: "controller", title: "Controller", icon: "gamecontroller", rows: [
            SettingDef(id: "app.led", label: "LED color",
                       note: "The DualSense light bar. Applies when a controller is connected.",
                       scope: .stream, kind: .ledColor),
            SettingDef(id: "controller.pollingRate", label: "Polling rate",
                       note: "Higher = lower input latency, slightly more CPU. Default is 250 Hz.",
                       scope: .stream, kind: .steps(
                            values: [4, 8, 15, 30, 60],
                            labels: ["250 Hz (default)", "125 Hz", "66 Hz", "33 Hz", "16 Hz"])),
            SettingDef(id: "deviceVibration.mode", label: "Device vibration",
                       note: "Vibrates phones/tablets during effects (not the controller).",
                       scope: .stream, kind: .option(
                            values: ["off", "on", "auto"],
                            labels: ["Off", "On", "On when not using gamepad"],
                            defaultValue: "off")),
            SettingDef(id: "deviceVibration.intensity", label: "Vibration intensity",
                       note: nil,
                       scope: .stream, kind: .steps(
                            values: stride(from: 10.0, through: 100.0, by: 10).map { $0 },
                            labels: [])),
        ]),
        SettingsCategory(id: "site", title: "Site", icon: "safari", rows: [
            SettingDef(id: "ui.splashVideo.skip", label: "Skip Xbox splash video",
                       note: "Skips the intro video when a stream starts.",
                       scope: .global, kind: .toggle(defaultValue: true)),
            SettingDef(id: "ui.feedbackDialog.disabled", label: "Disable feedback dialogs",
                       note: "Hides the rate-your-stream dialog after sessions.",
                       scope: .global, kind: .toggle(defaultValue: true)),
            SettingDef(id: "ui.reduceAnimations", label: "Reduce animations",
                       note: "Less site UI animation for a snappier feel.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "ui.hideScrollbar", label: "Hide scrollbar",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "ui.theme", label: "Theme",
                       note: "OLED turns the site background true black.",
                       scope: .global, kind: .option(
                            values: ["default", "dark-oled"],
                            labels: ["Default", "OLED black"],
                            defaultValue: "default")),
            SettingDef(id: "ui.controllerFriendly", label: "Controller-friendly UI",
                       note: "Bigger targets and gamepad-navigable site menus.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "ui.controllerStatus.show", label: "Controller connection toasts",
                       note: "Shows a toast when a controller connects or disconnects.",
                       scope: .global, kind: .toggle(defaultValue: true)),
            SettingDef(id: "block.tracking", label: "Block xCloud analytics",
                       note: "Stops the site's telemetry pings.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "ui.streamMenu.simplify", label: "Simplify in-stream menu",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "loadingScreen.waitTime.show", label: "Show queue wait time",
                       note: "Estimated wait time on loading screens.",
                       scope: .global, kind: .toggle(defaultValue: true)),
        ]),
    ]
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    enum Pane { case sidebar, rows }

    @Published var selectedCategoryId = SettingsCategory.all[0].id
    @Published var pane: Pane = .sidebar
    @Published var sidebarFocus = 0
    @Published var rowFocus = 0
    @Published var ledColorIndex: Int {
        didSet {
            UserDefaults.standard.set(ledColorIndex, forKey: "ledColorIndex")
            browser?.controllerInput.setLED(LEDColor.all[ledColorIndex])
        }
    }
    @Published private(set) var bridgeAvailable = false
    @Published private(set) var regions: [(value: String, label: String)] = [("default", "Default (closest server)")]

    private var globalValues: [String: Any] = [:]
    private var streamValues: [String: Any] = [:]
    private var regionIndex = 0

    private(set) weak var browser: BrowserModel?

    init(browser: BrowserModel) {
        self.browser = browser
        ledColorIndex = UserDefaults.standard.object(forKey: "ledColorIndex") as? Int ?? 1
    }

    var selectedCategory: SettingsCategory {
        SettingsCategory.all.first { $0.id == selectedCategoryId } ?? SettingsCategory.all[0]
    }

    func selectCategory(_ id: String) {
        selectedCategoryId = id
        sidebarFocus = SettingsCategory.all.firstIndex { $0.id == id } ?? 0
        pane = .rows
        rowFocus = 0
    }

    // MARK: - Load

    private static let readAllJS = """
    (function () {
      try {
        var regions = (typeof BxCBridge !== 'undefined') ? BxCBridge.regions() : {};
        return JSON.stringify({
          bridge: typeof BxCBridge !== 'undefined',
          regions: regions,
          global: JSON.parse(localStorage.getItem('BetterXcloud') || '{}'),
          stream: JSON.parse(localStorage.getItem('BetterXcloud.Stream') || '{}')
        });
      } catch (e) { return JSON.stringify({ bridge: false }); }
    })();
    """

    func load() {
        browser?.evaluateJS(Self.readAllJS) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self,
                      let json = result as? String,
                      let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                self.bridgeAvailable = root["bridge"] as? Bool ?? false
                self.globalValues = root["global"] as? [String: Any] ?? [:]
                self.streamValues = root["stream"] as? [String: Any] ?? [:]

                if let regionDict = root["regions"] as? [String: Any] {
                    var options: [(value: String, label: String)] = [("default", "Default (closest server)")]
                    for key in regionDict.keys.sorted() {
                        let info = regionDict[key] as? [String: Any]
                        let name = (info?["displayName"] as? String) ?? (info?["shortName"] as? String) ?? key
                        options.append((key, name))
                    }
                    self.regions = options
                }

                let current = self.rawValue("server.region") as? String ?? "default"
                self.regionIndex = self.regions.firstIndex { $0.value == current } ?? 0
                self.objectWillChange.send()
            }
        }
    }

    private func rawValue(_ key: String) -> Any? {
        switch key {
        case "app.led": return nil
        default: break
        }
        if globalValues.keys.contains(key) { return globalValues[key] }
        if streamValues.keys.contains(key) { return streamValues[key] }
        return nil
    }

    // MARK: - Display helpers

    func isOn(_ def: SettingDef) -> Bool {
        if let value = rawValue(def.id) as? Bool { return value }
        if case .toggle(let defaultValue) = def.kind { return defaultValue }
        return false
    }

    /// Index into the def's option/steps list; nil when the value is unset (shows "Default").
    func optionIndex(_ def: SettingDef) -> Int? {
        let raw = rawValue(def.id)
        switch def.kind {
        case .option(let values, _, _):
            if let value = raw as? String, let index = values.firstIndex(of: value) { return index }
            return nil
        case .steps(let values, _):
            if let value = raw as? Double, let index = values.firstIndex(of: value) { return index }
            if let value = raw as? Int, let asDouble = Double(exactly: value),
               let index = values.firstIndex(of: asDouble) { return index }
            return nil
        case .serverRegion:
            return regionIndex
        case .ledColor:
            return ledColorIndex
        default:
            return nil
        }
    }

    func optionLabel(_ def: SettingDef, index: Int) -> String {
        switch def.kind {
        case .option(_, let labels, _):
            return labels.indices.contains(index) ? labels[index] : "?"
        case .steps(_, let labels):
            if labels.indices.contains(index) { return labels[index] }
            if case .steps(let values, _) = def.kind, values.indices.contains(index) {
                return String(format: "%.0f", values[index])
            }
            return "?"
        case .serverRegion:
            return regions.indices.contains(index) ? regions[index].label : "?"
        case .ledColor:
            return LEDColor.all.indices.contains(index) ? LEDColor.all[index].label : "?"
        default:
            return "?"
        }
    }

    func defaultValueLabel(_ def: SettingDef) -> String {
        switch def.kind {
        case .toggle(let defaultValue): return defaultValue ? "On" : "Off"
        case .option(_, let labels, let defaultValue):
            if let def = def.optionDefaultIndex() { return labels[def] }
            _ = defaultValue
            return "Default"
        default: return "Default"
        }
    }

    // MARK: - Changes

    func toggle(_ def: SettingDef) {
        let newValue = !isOn(def)
        write(def, newValue)
    }

    func adjust(_ def: SettingDef, delta: Int) {
        switch def.kind {
        case .toggle:
            toggle(def)
        case .option(let values, _, _):
            let count = values.count
            let index = wrap((optionIndex(def) ?? -1) + delta, count)
            write(def, values[index])
        case .steps(let values, _):
            let count = values.count
            let index = wrap((optionIndex(def) ?? (delta > 0 ? -1 : 0)) + delta, count)
            write(def, values[index])
        case .serverRegion:
            regionIndex = wrap(regionIndex + delta, regions.count)
            write(def, regions[regionIndex].value)
        case .ledColor:
            ledColorIndex = wrap(ledColorIndex + delta, LEDColor.all.count)
        default:
            break
        }
        objectWillChange.send()
    }

    private func write(_ def: SettingDef, _ value: Any) {
        guard let browser else { return }
        let scopeCall = def.scope == .global ? "setGlobal" : "setStream"
        browser.evaluateJS("try { BxCBridge.\(scopeCall)('\(def.id)', \(jsonEncoded(value))); 'ok' } catch (e) { 'err' }")

        switch def.scope {
        case .global: globalValues[def.id] = value
        case .stream: streamValues[def.id] = value
        }
    }

    private func wrap(_ value: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }

    private func jsonEncoded(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(format: "%.0f", double) }
        if let string = value as? String { return "'\(string.replacingOccurrences(of: "'", with: "\\'"))'" }
        if let array = value as? [String] { return "[" + array.map { "'\($0)'" }.joined(separator: ",") + "]" }
        return "null"
    }
}

extension SettingDef {
    func optionDefaultIndex() -> Int? {
        if case .option(let values, _, let defaultValue) = kind {
            return values.firstIndex(of: defaultValue)
        }
        return nil
    }
}

// MARK: - Controller navigation

extension SettingsModel {
    func moveFocus(_ direction: Int) {
        switch pane {
        case .sidebar:
            let count = SettingsCategory.all.count
            sidebarFocus = wrap(sidebarFocus + direction, count)
        case .rows:
            let count = selectedCategory.rows.count
            guard count > 0 else { return }
            rowFocus = wrap(rowFocus + direction, count)
        }
        objectWillChange.send()
    }

    func adjustFocused(_ delta: Int) {
        switch pane {
        case .sidebar:
            // Left/right on the sidebar moves between categories too.
            moveFocus(delta)
        case .rows:
            if rows.indices.contains(rowFocus) {
                adjust(rows[rowFocus], delta: delta)
            }
        }
    }

    func activateFocused() {
        switch pane {
        case .sidebar:
            let category = SettingsCategory.all[sidebarFocus]
            selectCategory(category.id)
        case .rows:
            guard rows.indices.contains(rowFocus) else { return }
            let def = rows[rowFocus]
            if case .toggle = def.kind { toggle(def); objectWillChange.send() }
        }
    }

    func closeWindow() {
        browser?.closeSettingsWindow()
    }

    var rows: [SettingDef] {
        selectedCategory.rows
    }
}
