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
    /// dropdown with a fixed list of values
    case option(values: [String], labels: [String], defaultValue: String)
    /// dropdown with numeric values
    case numberOption(values: [Double], labels: [String], defaultValue: Double)
    /// numeric range rendered as a slider; unset values show the default
    case range(min: Double, max: Double, step: Double, defaultValue: Double, format: (Double) -> String)
    /// dropdown with multiple checkable entries (array value)
    case multi(options: [(value: String, label: String)])
    case serverRegion
    case ledColor
    case info(text: String)
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

    static let localeValues: [String] = ["default", "ar-SA", "bg-BG", "cs-CZ", "da-DK", "de-DE", "el-GR", "en-GB", "en-US", "es-ES", "es-MX", "fi-FI", "fr-FR", "he-IL", "hu-HU", "it-IT", "ja-JP", "ko-KR", "nb-NO", "nl-NL", "pl-PL", "pt-BR", "pt-PT", "ro-RO", "ru-RU", "sk-SK", "sv-SE", "th-TH", "tr-TR", "zh-CN", "zh-TW"]
    static let localeLabels: [String] = ["Default (account)", "العربية", "Български", "Čeština", "Dansk", "Deutsch", "Ελληνικά", "English (UK)", "English (US)", "Español (ES)", "Español (LatAm)", "Suomi", "Français", "עברית", "Magyar", "Italiano", "日本語", "한국어", "Norsk bokmål", "Nederlands", "Polski", "Português (BR)", "Português (PT)", "Română", "Русский", "Slovenčina", "Svenska", "ไทย", "Türkçe", "中文(简体)", "中文(繁體)"]

    static let all: [SettingsCategory] = [
        SettingsCategory(id: "server", title: "Server", icon: "server.rack", rows: [
            SettingDef(id: "server.region", label: "Server region",
                       note: "Server used for new streams. Only affects the next stream you start.",
                       scope: .global, kind: .serverRegion),
            SettingDef(id: "server.bypassRestriction", label: "Bypass region restriction",
                       note: "⚠️ Streams via proxy servers in other regions. Use at your own risk.",
                       scope: .global, kind: .option(
                            values: ["off", "br", "jp", "kr", "pl", "us"],
                            labels: ["Off", "Brazil", "Japan", "Korea", "Poland", "United States"],
                            defaultValue: "off")),
            SettingDef(id: "server.ipv6.prefer", label: "Prefer IPv6 server",
                       note: "Can reduce latency when your network supports IPv6.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stream.locale", label: "Preferred game language",
                       note: "Language used inside streamed games. Applies to new streams.",
                       scope: .global, kind: .option(
                            values: SettingsCategory.localeValues,
                            labels: SettingsCategory.localeLabels,
                            defaultValue: "default")),
        ]),
        SettingsCategory(id: "stream", title: "Stream", icon: "dot.radiowaves.left.and.right", rows: [
            SettingDef(id: "stream.video.resolution", label: "Target resolution",
                       note: "Caps the stream resolution. 1080p (HQ) picks a better encoder profile.",
                       scope: .global, kind: .option(
                            values: ["auto", "720p", "1080p", "1080p-hq"],
                            labels: ["Default (auto)", "720p", "1080p", "1080p (HQ)"],
                            defaultValue: "auto")),
            SettingDef(id: "stream.video.codecProfile", label: "Visual quality",
                       note: "Higher quality uses a better H264 profile (when the browser supports it).",
                       scope: .global, kind: .option(
                            values: ["default", "low", "normal", "high"],
                            labels: ["Default", "Low", "Normal", "High"],
                            defaultValue: "default")),
            SettingDef(id: "stream.video.maxBitrate", label: "Max video bitrate",
                       note: "⚠️ Limits the video bitrate. Low caps can look blocky in fast scenes.",
                       scope: .global, kind: .numberOption(
                            values: [0, 5_120_000, 10_240_000, 15_360_000],
                            labels: ["Unlimited", "5 Mb/s", "10 Mb/s", "15 Mb/s"],
                            defaultValue: 0)),
            SettingDef(id: "stream.video.preventResolutionDrops", label: "Prevent resolution drops",
                       note: "⚠️ Locks the stream to the target resolution — can cause stuttering when bandwidth drops.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "audio.volume.booster.enabled", label: "Enable volume control feature",
                       note: "Unlocks the in-stream volume slider (up to 600%).",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "screenshot.applyFilters", label: "Apply video filters to screenshots",
                       note: "Screenshots taken in-stream use your brightness/contrast/saturation filters.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "audio.mic.onPlaying", label: "Enable microphone on game launch",
                       note: "Turns on party-chat mic automatically when a game starts.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "game.fortnite.forceConsole", label: "Fortnite: force console version",
                       note: "Streams the console version of Fortnite (also unlocks Save the World).",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stream.video.combineAudio", label: "Combine audio & video",
                       note: "May fix the laggy audio problem. Experimental.",
                       scope: .global, kind: .toggle(defaultValue: false)),
        ]),
        SettingsCategory(id: "stats", title: "Overlay & Stats", icon: "waveform.path.ecg", rows: [
            SettingDef(id: "stats.showWhenPlaying", label: "Show stats when playing",
                       note: "The ping / fps / bitrate bar inside a stream.",
                       scope: .stream, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stats.items", label: "Stats items",
                       note: "Which stats appear on the bar.",
                       scope: .stream, kind: .option(
                            values: ["full", "essential", "performance", "minimal"],
                            labels: ["All stats", "Essential (ping, fps)", "Performance (fps, bitrate, decode)", "Minimal (ping only)"],
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
                            values: ["0.9rem", "1.0rem", "1.1rem"],
                            labels: ["Small", "Normal", "Large"],
                            defaultValue: "0.9rem")),
            SettingDef(id: "stats.opacity.all", label: "Stats opacity",
                       note: "Overall transparency of the stats bar.",
                       scope: .stream, kind: .range(min: 50, max: 100, step: 10, defaultValue: 80, format: { "\(Int($0))%" })),
            SettingDef(id: "stats.opacity.background", label: "Stats background opacity",
                       note: "How solid the stats bar's background is.",
                       scope: .stream, kind: .range(min: 0, max: 100, step: 10, defaultValue: 100, format: { "\(Int($0))%" })),
            SettingDef(id: "stats.colors", label: "Conditional formatting colors",
                       note: "Colors bad values (high ping, lost frames) red and good values green.",
                       scope: .stream, kind: .toggle(defaultValue: false)),
            SettingDef(id: "stats.quickGlance.enabled", label: "Quick Glance mode",
                       note: "Stats appear only while you hold the Xbox/PS button.",
                       scope: .stream, kind: .toggle(defaultValue: true)),
            SettingDef(id: "gameBar.position", label: "Game Bar position",
                       note: "The small in-stream info bar (time played, battery).",
                       scope: .global, kind: .option(
                            values: ["off", "bottom-left", "bottom-right"],
                            labels: ["Off", "Bottom left", "Bottom right"],
                            defaultValue: "off")),
        ]),
        SettingsCategory(id: "video", title: "Video", icon: "film", rows: [
            SettingDef(id: "video.player.type", label: "Renderer",
                       note: "WebGL2 can be smoother on some Macs; default uses the plain video element.",
                       scope: .stream, kind: .option(
                            values: ["default", "webgl2", "webgpu"],
                            labels: ["Default", "WebGL 2", "WebGPU (experimental)"],
                            defaultValue: "default")),
            SettingDef(id: "video.maxFps", label: "Limit FPS",
                       note: "Caps the stream's frame rate.",
                       scope: .stream, kind: .range(min: 10, max: 60, step: 10, defaultValue: 60, format: { $0 >= 60 ? "Unlimited" : "\(Int($0)) fps" })),
            SettingDef(id: "video.player.powerPreference", label: "Renderer configuration",
                       note: "Prioritize battery life or performance for the video renderer.",
                       scope: .stream, kind: .option(
                            values: ["default", "low-power", "high-performance"],
                            labels: ["Default", "Battery saving", "High performance"],
                            defaultValue: "default")),
            SettingDef(id: "video.processing", label: "Clarity boost",
                       note: "Post-processing to sharpen the stream image.",
                       scope: .stream, kind: .option(
                            values: ["usm", "cas"],
                            labels: ["Unsharp masking", "AMD FidelityFX CAS"],
                            defaultValue: "usm")),
            SettingDef(id: "video.processing.mode", label: "Clarity boost mode",
                       note: "Quality looks better; performance costs less CPU.",
                       scope: .stream, kind: .option(
                            values: ["performance", "quality"],
                            labels: ["Performance", "Quality"],
                            defaultValue: "performance")),
            SettingDef(id: "video.processing.sharpness", label: "Sharpness",
                       note: "Strength of the clarity boost filter. 0 = off.",
                       scope: .stream, kind: .range(min: 0, max: 10, step: 1, defaultValue: 0, format: { $0 == 0 ? "Off" : "\(Int($0))" })),
            SettingDef(id: "video.ratio", label: "Aspect ratio",
                       note: "Changes the video's shape — useful for ultrawide displays.",
                       scope: .stream, kind: .option(
                            values: ["16:9", "16:10", "18:9", "20:9", "21:9", "3:2", "4:3", "5:4", "fill"],
                            labels: ["16:9 (default)", "16:10", "18:9", "20:9", "21:9", "3:2", "4:3", "5:4", "Stretch"],
                            defaultValue: "16:9")),
            SettingDef(id: "video.position", label: "Position",
                       note: "Where the video sits inside the window.",
                       scope: .stream, kind: .option(
                            values: ["top", "top-half", "center", "bottom-half", "bottom"],
                            labels: ["Top", "Top half", "Center (default)", "Bottom half", "Bottom"],
                            defaultValue: "center")),
            SettingDef(id: "video.saturation", label: "Saturation",
                       note: "Live video filter. 100 = unchanged.",
                       scope: .stream, kind: .range(min: 50, max: 150, step: 5, defaultValue: 100, format: { "\(Int($0))%" })),
            SettingDef(id: "video.contrast", label: "Contrast",
                       note: "Live video filter. 100 = unchanged.",
                       scope: .stream, kind: .range(min: 50, max: 150, step: 5, defaultValue: 100, format: { "\(Int($0))%" })),
            SettingDef(id: "video.brightness", label: "Brightness",
                       note: "Live video filter. 100 = unchanged.",
                       scope: .stream, kind: .range(min: 50, max: 150, step: 5, defaultValue: 100, format: { "\(Int($0))%" })),
            SettingDef(id: "audio.volume", label: "Audio volume",
                       note: "Stream volume — up to 600% boost (needs 'Enable volume control').",
                       scope: .stream, kind: .range(min: 0, max: 600, step: 10, defaultValue: 100, format: { "\(Int($0))%" })),
        ]),
        SettingsCategory(id: "controller", title: "Controller", icon: "gamecontroller", rows: [
            SettingDef(id: "app.led", label: "LED color",
                       note: "The DualSense light bar. Pick a dot, or use the picker for any color.",
                       scope: .stream, kind: .ledColor),
            SettingDef(id: "controller.pollingRate", label: "Polling rate",
                       note: "How often input is sent to the cloud. Higher = lower latency, more CPU.",
                       scope: .stream, kind: .range(min: 4, max: 60, step: 4, defaultValue: 4, format: { "\((1000.0 / $0).rounded()) Hz" })),
            SettingDef(id: "deviceVibration.mode", label: "Device vibration",
                       note: "Vibrates phones/tablets during effects (the controller's own rumble is unchanged).",
                       scope: .stream, kind: .option(
                            values: ["off", "on", "auto"],
                            labels: ["Off", "On", "On when not using gamepad"],
                            defaultValue: "off")),
            SettingDef(id: "deviceVibration.intensity", label: "Vibration intensity",
                       note: nil,
                       scope: .stream, kind: .range(min: 10, max: 100, step: 10, defaultValue: 50, format: { "\(Int($0))%" })),
            SettingDef(id: "localCoOp.enabled", label: "Enable local co-op support",
                       note: "Two controllers as two players in the same stream. Only works with some games.",
                       scope: .stream, kind: .toggle(defaultValue: false)),
            SettingDef(id: "touchController.mode", label: "Touch controller",
                       note: "On-screen touch controls. Requires a touch-capable device.",
                       scope: .global, kind: .option(
                            values: ["default", "off", "all"],
                            labels: ["Default", "Off", "All games"],
                            defaultValue: "default")),
        ]),
        SettingsCategory(id: "mkb", title: "Mouse & Keyboard", icon: "keyboard", rows: [
            SettingDef(id: "mkb.enabled", label: "Emulate controller with Mouse & Keyboard",
                       note: "Play games that don't support MKB by faking a controller. Could be viewed as cheating online.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "nativeMkb.mode", label: "Native Mouse & Keyboard",
                       note: "Uses the real MKB support some games offer, with no emulation.",
                       scope: .global, kind: .option(
                            values: ["default", "off", "on"],
                            labels: ["Default", "Off", "On"],
                            defaultValue: "default")),
            SettingDef(id: "nativeMkb.forcedGames", label: "Force native MKB for these games",
                       note: "Managed from Better xCloud's own list for now — full picker coming in the next update.",
                       scope: .global, kind: .info(text: "Coming in the next update")),
            SettingDef(id: "mkb.cursor.hideIdle", label: "Hide mouse cursor on idle",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "nativeMkb.scroll.sensitivityX", label: "Horizontal scroll sensitivity",
                       note: nil,
                       scope: .stream, kind: .range(min: 0, max: 10000, step: 1000, defaultValue: 0, format: { $0 == 0 ? "Default" : String(format: "%.1fx", $0 / 100) })),
            SettingDef(id: "nativeMkb.scroll.sensitivityY", label: "Vertical scroll sensitivity",
                       note: nil,
                       scope: .stream, kind: .range(min: 0, max: 10000, step: 1000, defaultValue: 0, format: { $0 == 0 ? "Default" : String(format: "%.1fx", $0 / 100) })),
            SettingDef(id: "mkb.profiles", label: "Custom key-mapping profiles",
                       note: "Create and edit your own MKB button layouts.",
                       scope: .global, kind: .info(text: "Coming in the next update")),
        ]),
        SettingsCategory(id: "site", title: "Site & UI", icon: "safari", rows: [
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
            SettingDef(id: "ui.streamMenu.simplify", label: "Simplify in-stream menu",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "loadingScreen.waitTime.show", label: "Show queue wait time",
                       note: "Estimated wait time on loading screens.",
                       scope: .global, kind: .toggle(defaultValue: true)),
            SettingDef(id: "loadingScreen.gameArt.show", label: "Show game art on loading screen",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: true)),
            SettingDef(id: "loadingScreen.rocket", label: "Rocket animation",
                       note: "The little rocket during stream startup.",
                       scope: .global, kind: .option(
                            values: ["show", "hide-queue", "hide"],
                            labels: ["Always show", "Hide when queuing", "Always hide"],
                            defaultValue: "show")),
            SettingDef(id: "ui.gameCard.waitTime.show", label: "Show wait time on game cards",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: true)),
        ]),
        SettingsCategory(id: "advanced", title: "Advanced", icon: "gearshape.2", rows: [
            SettingDef(id: "block.tracking", label: "Block xCloud analytics",
                       note: "Stops the site's telemetry pings.",
                       scope: .global, kind: .toggle(defaultValue: false)),
            SettingDef(id: "block.features", label: "Disable features",
                       note: "Turn off social/chat features you don't use.",
                       scope: .global, kind: .multi(options: [
                            ("chat", "Chat"),
                            ("friends", "Friends & followers"),
                            ("notifications-invites", "Notifications: invites"),
                            ("notifications-achievements", "Notifications: achievements"),
                            ("remote-play", "Remote Play"),
                       ])),
            SettingDef(id: "ui.hideSections", label: "Hide home page sections",
                       note: "Remove rows from the xCloud home page.",
                       scope: .global, kind: .multi(options: [
                            ("news", "News"),
                            ("friends", "Play with friends"),
                            ("native-mkb", "Play with mouse & keyboard"),
                            ("touch", "Play with touch"),
                            ("most-popular", "Most popular"),
                            ("byog", "Stream your own game"),
                            ("recently-added", "Recently added"),
                            ("leaving-soon", "Leaving soon"),
                            ("genres", "Genres"),
                            ("all-games", "All games"),
                       ])),
            SettingDef(id: "userAgent.profile", label: "User-Agent profile",
                       note: "⚠️ Pretends to be another device. May cause unexpected behavior.",
                       scope: .global, kind: .option(
                            values: ["default", "windows-edge", "macos-safari", "vr-oculus", "smarttv-generic", "smarttv-tizen", "custom"],
                            labels: ["Default", "Edge + Windows", "Safari + macOS", "Android TV", "Smart TV (generic)", "Samsung Smart TV", "Custom"],
                            defaultValue: "default")),
            SettingDef(id: "ui.imageQuality", label: "Website image quality",
                       note: "Compression of box art on the home page. Lower = faster.",
                       scope: .global, kind: .range(min: 10, max: 90, step: 10, defaultValue: 90, format: { $0 >= 90 ? "Default" : "\(Int($0))%" })),
            SettingDef(id: "ui.layout", label: "Layout",
                       note: "TV layout makes everything bigger.",
                       scope: .global, kind: .option(
                            values: ["default", "normal", "tv"],
                            labels: ["Default", "Normal", "Smart TV"],
                            defaultValue: "default")),
        ]),
    ]
}

// MARK: - Suggested settings (curated for Mac)

extension SettingsModel {
    struct SuggestedChange {
        let key: String
        let scope: SettingScope
        let value: Any
    }

    static let suggestedForMac: [SuggestedChange] = [
        .init(key: "stream.video.resolution", scope: .global, value: "1080p"),
        .init(key: "stream.video.codecProfile", scope: .global, value: "high"),
        .init(key: "stream.video.maxBitrate", scope: .global, value: 0.0),
        .init(key: "stream.video.preventResolutionDrops", scope: .global, value: false),
        .init(key: "ui.splashVideo.skip", scope: .global, value: true),
        .init(key: "ui.feedbackDialog.disabled", scope: .global, value: true),
        .init(key: "ui.reduceAnimations", scope: .global, value: true),
        .init(key: "stats.showWhenPlaying", scope: .stream, value: true),
        .init(key: "stats.items", scope: .stream, value: ["ping", "fps", "btr", "dt", "pl", "fl"]),
        .init(key: "stats.position", scope: .stream, value: "top-right"),
        .init(key: "video.maxFps", scope: .stream, value: 60.0),
        .init(key: "video.brightness", scope: .stream, value: 100.0),
        .init(key: "video.contrast", scope: .stream, value: 100.0),
        .init(key: "video.saturation", scope: .stream, value: 100.0),
        .init(key: "video.processing.sharpness", scope: .stream, value: 0.0),
        .init(key: "audio.volume", scope: .stream, value: 100.0),
        .init(key: "controller.pollingRate", scope: .stream, value: 8.0),
        .init(key: "deviceVibration.mode", scope: .stream, value: "off"),
    ]

    func applySuggested() {
        for change in Self.suggestedForMac {
            write(id: change.key, scope: change.scope, value: change.value)
        }
        objectWillChange.send()
    }

    /// Direct write used by both user changes and the suggested preset.
    func write(id: String, scope: SettingScope, value: Any) {
        guard let browser else { return }
        let scopeCall = scope == .global ? "setGlobal" : "setStream"
        browser.evaluateJS("try { BxCBridge.\(scopeCall)('\(id)', \(jsonEncoded(value))); 'ok' } catch (e) { 'err' }")
        switch scope {
        case .global: globalValues[id] = value
        case .stream: streamValues[id] = value
        }
    }
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

    /// App-local: a custom LED color chosen with the color picker.
    var customLEDColor: Color {
        get {
            let r = UserDefaults.standard.object(forKey: "ledCustomR") as? Double ?? 0.30
            let g = UserDefaults.standard.object(forKey: "ledCustomG") as? Double ?? 0.85
            let b = UserDefaults.standard.object(forKey: "ledCustomB") as? Double ?? 0.35
            return Color(red: r, green: g, blue: b)
        }
        set {
            let srgb = NSColor(newValue).usingColorSpace(.sRGB)
            let r = Double(srgb?.redComponent ?? 0)
            let g = Double(srgb?.greenComponent ?? 0)
            let b = Double(srgb?.blueComponent ?? 0)
            UserDefaults.standard.set(r, forKey: "ledCustomR")
            UserDefaults.standard.set(g, forKey: "ledCustomG")
            UserDefaults.standard.set(b, forKey: "ledCustomB")
            browser?.controllerInput.setLED(r: r, g: g, b: b)
        }
    }

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
        objectWillChange.send()
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
        if key == "app.led" { return nil }
        if globalValues.keys.contains(key) { return globalValues[key] }
        if streamValues.keys.contains(key) { return streamValues[key] }
        return nil
    }

    // MARK: - Value access for controls

    func isOn(_ def: SettingDef) -> Bool {
        if let value = rawValue(def.id) as? Bool { return value }
        if case .toggle(let defaultValue) = def.kind { return defaultValue }
        return false
    }

    /// Current selection for dropdowns; nil means the setting is untouched
    /// (controls then show the definition's default).
    func optionIndex(_ def: SettingDef) -> Int? {
        let raw = rawValue(def.id)
        switch def.kind {
        case .option(let values, _, _):
            if let value = raw as? String, let index = values.firstIndex(of: value) { return index }
            return nil
        case .numberOption(let values, _, _):
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
        case .numberOption(_, let labels, _):
            return labels.indices.contains(index) ? labels[index] : "?"
        case .serverRegion:
            return regions.indices.contains(index) ? regions[index].label : "?"
        default:
            return "?"
        }
    }

    func defaultValueLabel(_ def: SettingDef) -> String {
        switch def.kind {
        case .option(let values, let labels, let defaultValue):
            if let index = values.firstIndex(of: defaultValue) { return labels.indices.contains(index) ? labels[index] : "Default" }
        case .numberOption(let values, let labels, let defaultValue):
            if let index = values.firstIndex(of: defaultValue) { return labels.indices.contains(index) ? labels[index] : "Default" }
        default:
            break
        }
        return "Default"
    }

    /// Current numeric value for slider rows (falls back to the default).
    func rangeValue(_ def: SettingDef) -> Double? {
        guard case .range(let lower, let upper, let step, let defaultValue, _) = def.kind else { return nil }
        let raw = rawValue(def.id)
        if let value = raw as? Double { return min(max(value, lower), upper) }
        if let value = raw as? Int, let asDouble = Double(exactly: value) { return min(max(asDouble, lower), upper) }
        return defaultValue
    }

    func rangeText(_ def: SettingDef) -> String? {
        guard let value = rangeValue(def), case .range(_, _, _, _, let format) = def.kind else { return nil }
        return format(value)
    }

    func multiSelection(_ def: SettingDef) -> Set<String> {
        if let value = rawValue(def.id) as? [String] { return Set(value) }
        return []
    }

    func toggleMulti(_ def: SettingDef, value: String) {
        var selection = multiSelection(def)
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
        write(def, Array(selection).sorted())
    }

    // MARK: - Changes

    func toggle(_ def: SettingDef) {
        write(def, !isOn(def))
        objectWillChange.send()
    }

    func adjust(_ def: SettingDef, delta: Int) {
        switch def.kind {
        case .toggle:
            toggle(def)
        case .option(let values, _, _):
            let index = wrap((optionIndex(def) ?? -1) + delta, values.count)
            write(def, values[index])
        case .numberOption(let values, _, _):
            let index = wrap((optionIndex(def) ?? -1) + delta, values.count)
            write(def, values[index])
        case .range(let lower, let upper, let step, let defaultValue, _):
            let current = rangeValue(def) ?? defaultValue
            let new = min(max(current + Double(delta) * step, lower), upper)
            write(def, new)
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

    func setOption(_ def: SettingDef, index: Int) {
        switch def.kind {
        case .option(let values, _, _):
            guard values.indices.contains(index) else { return }
            write(def, values[index])
        case .numberOption(let values, _, _):
            guard values.indices.contains(index) else { return }
            write(def, values[index])
        case .serverRegion:
            guard regions.indices.contains(index) else { return }
            regionIndex = index
            write(def, regions[index].value)
        default:
            break
        }
        objectWillChange.send()
    }

    func setRange(_ def: SettingDef, value: Double) {
        if case .range(let lower, let upper, _, _, _) = def.kind {
            write(def, min(max(value, lower), upper))
            objectWillChange.send()
        }
    }

    private func write(_ def: SettingDef, _ value: Any) {
        write(id: def.id, scope: def.scope, value: value)
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
    func optionValues() -> [String]? {
        if case .option(let values, _, _) = kind { return values }
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
            if case .toggle = def.kind {
                toggle(def)
            } else {
                adjust(def, delta: 1)
            }
        }
    }

    func closeWindow() {
        browser?.closeSettingsWindow()
    }

    var rows: [SettingDef] {
        selectedCategory.rows
    }
}
