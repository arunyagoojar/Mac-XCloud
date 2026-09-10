//
//  AppSettings.swift
//  Mac XCloud
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
    case profileLauncher(ProfileKind)
    case pingTest
}

/// Settings owns its own same-window history instead of relying on a split-view
/// selection. Controller tools are first-class destinations in the same history.
enum SettingsRoute: Equatable {
    case home
    case category(String)
    case controllerSection(ControllerToolSection)
    // The virtual-controller / keyboard-shortcut editors open inside the
    // settings panel's own navigation instead of a separate window.
    case profileEditor(ProfileKind)
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
            SettingDef(id: "app.pingTest", label: "Region latency test",
                       note: "Warms up and measures every available server three times, then automatically uses the lowest stable latency. Run again after changing networks.",
                       scope: .global, kind: .pingTest),
            SettingDef(id: "server.region", label: "Server region",
                       note: "Automatic measures every available server and selects the fastest stable result. A manually chosen region stays fixed. Changes affect your next stream.",
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
                       note: "Chooses the H.264 codec profile for new streams. High gives the best compression quality. Select it, then use Reload to Apply.",
                       scope: .global, kind: .option(
                            values: ["low", "normal", "high"],
                            labels: ["Low", "Normal", "High"],
                            defaultValue: "high")),
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
        SettingsCategory(id: "clarity", title: "Clarity", icon: "sparkles.rectangle.stack", rows: [
            SettingDef(id: "app.clarityInfo", label: "Recommended for this M1 Mac",
                       note: "For native 1080p/1440p streams, WebGL 2 or WebGPU + AMD CAS is recommended for optimal sharpness.",
                       scope: .stream, kind: .info(text: "WebGPU + CAS for high-resolution")),
            SettingDef(id: "app.clarityPipeline", label: "Clarity pipeline",
                       note: "Select an upscaling or sharpening pipeline. WebGL/WebGPU changes apply live.",
                       scope: .stream, kind: .option(
                            values: ["native", "webgpu-cas", "webgpu-usm", "webgl-cas", "webgl-usm"],
                            labels: [
                                "Native video (off)",
                                "WebGPU + AMD CAS (Apple Metal)",
                                "WebGPU + Unsharp Mask (Apple Metal)",
                                "WebGL 2 + AMD CAS",
                                "WebGL 2 + Unsharp Mask"
                            ],
                            defaultValue: "native")),
            SettingDef(id: "video.processing.mode", label: "Processing mode",
                       note: "Quality gives the best image on Apple Silicon; Performance reduces GPU use.",
                       scope: .stream, kind: .option(
                            values: ["performance", "quality"],
                            labels: ["Performance", "Quality"],
                            defaultValue: "quality")),
        ]),
        SettingsCategory(id: "video", title: "Video", icon: "film", rows: [
            SettingDef(id: "video.maxFps", label: "Limit FPS",
                       note: "Caps the stream's frame rate.",
                       scope: .stream, kind: .range(min: 10, max: 60, step: 10, defaultValue: 60, format: { $0 >= 60 ? "Unlimited" : "\(Int($0)) fps" })),
            SettingDef(id: "video.player.powerPreference", label: "Renderer configuration",
                       note: "Prioritize battery life or performance for the video renderer.",
                       scope: .stream, kind: .option(
                            values: ["default", "low-power", "high-performance"],
                            labels: ["Default", "Battery saving", "High performance"],
                            defaultValue: "default")),
            SettingDef(id: "video.processing.sharpness", label: "Sharpness",
                       note: "Strength of the clarity boost filter. 0 = off.",
                       scope: .stream, kind: .range(min: 0, max: 10, step: 1, defaultValue: 0, format: { $0 == 0 ? "Off" : "\(Int($0))" })),
            SettingDef(id: "video.ratio", label: "Aspect ratio",
                       note: "Changes the video's shape — useful for ultrawide displays.",
                       scope: .stream, kind: .option(
                            values: ["16:9", "16:10", "18:9", "20:9", "21:9", "3:2", "4:3", "5:4", "fill"],
                            labels: ["16:9 (default)", "16:10", "18:9", "20:9", "21:9", "3:2", "4:3", "5:4", "Fill (stretch)"],
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
        SettingsCategory(id: "remote", title: "Remote Play", icon: "tv.and.mediabox", rows: [
            SettingDef(id: "xhome.video.resolution", label: "Remote Play resolution",
                       note: "Resolution when streaming from your own Xbox console.",
                       scope: .global, kind: .option(
                            values: ["720p", "1080p", "1080p-hq"],
                            labels: ["720p", "1080p", "1080p (HQ)"],
                            defaultValue: "1080p")),
            SettingDef(id: "xhome.ipv6.prefer", label: "Prefer IPv6 for Remote Play",
                       note: nil,
                       scope: .global, kind: .toggle(defaultValue: false)),
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
                            ("touch", "Play with touch"),
                            ("most-popular", "Most popular"),
                            ("byog", "Stream your own game"),
                            ("recently-added", "Recently added"),
                            ("leaving-soon", "Leaving soon"),
                            ("genres", "Genres"),
                            ("all-games", "All games"),
                       ])),
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

    /// Controller preferences formerly lived in an extra Controller Tools
    /// category. They now appear in Controller Overview, leaving nine primary
    /// Settings categories and seven first-class Controller destinations.
    static let controllerRows: [SettingDef] = [
        SettingDef(id: "app.led", label: "LED color",
                   note: "The DualSense light bar. Pick a dot, or use the picker for any color.",
                   scope: .stream, kind: .ledColor),
        SettingDef(id: "controller.pollingRate", label: "Polling rate",
                   note: "How often input is sent to the cloud. Higher = lower latency, more CPU.",
                   scope: .stream, kind: .range(min: 4, max: 60, step: 4, defaultValue: 4, format: { "\((1000.0 / $0).rounded()) Hz" })),
        SettingDef(id: "localCoOp.enabled", label: "Enable local co-op support",
                   note: "Two controllers as two players in the same stream. Only works with some games.",
                   scope: .stream, kind: .toggle(defaultValue: false)),
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
        .init(key: "server.region", scope: .global, value: "default"),
        .init(key: "server.ipv6.prefer", scope: .global, value: true),
        .init(key: "stream.video.resolution", scope: .global, value: "1080p-hq"),
        .init(key: "stream.video.codecProfile", scope: .global, value: "high"),
        // Unlimited bitrate allows full resolution/quality without artificial cap.
        .init(key: "stream.video.maxBitrate", scope: .global, value: 0.0),
        .init(key: "stream.video.preventResolutionDrops", scope: .global, value: false),
        .init(key: "ui.splashVideo.skip", scope: .global, value: true),
        .init(key: "ui.feedbackDialog.disabled", scope: .global, value: true),
        .init(key: "ui.controllerFriendly", scope: .global, value: true),
        .init(key: "block.tracking", scope: .global, value: true),
        .init(key: "stats.showWhenPlaying", scope: .stream, value: false),
        .init(key: "stats.items", scope: .stream, value: ["ping", "fps", "btr", "dt", "pl", "fl"]),
        .init(key: "stats.position", scope: .stream, value: "top-right"),
        .init(key: "stats.opacity.all", scope: .stream, value: 90.0),
        .init(key: "stats.opacity.background", scope: .stream, value: 65.0),
        .init(key: "stats.colors", scope: .stream, value: true),
        .init(key: "video.player.type", scope: .stream, value: "webgl2"),
        .init(key: "video.player.powerPreference", scope: .stream, value: "high-performance"),
        .init(key: "video.processing", scope: .stream, value: "cas"),
        .init(key: "video.processing.mode", scope: .stream, value: "quality"),
        .init(key: "video.processing.sharpness", scope: .stream, value: 2.0),
        .init(key: "video.maxFps", scope: .stream, value: 60.0),
        .init(key: "video.brightness", scope: .stream, value: 100.0),
        .init(key: "video.contrast", scope: .stream, value: 100.0),
        .init(key: "video.saturation", scope: .stream, value: 100.0),
        .init(key: "audio.volume", scope: .stream, value: 100.0),
        .init(key: "controller.pollingRate", scope: .stream, value: 4.0),
    ]

    /// Factory reset across every settings store: saved profiles and per-game
    /// links, native mirrors, page-side Better xCloud preferences and app
    /// preferences. The Xbox page reloads afterwards so the site re-reads its
    /// cleared localStorage. Sign-in and website data are untouched.
    func resetAllSettings() {
        guard let browser else {
            saveMessage = "The Xbox page is not ready."
            return
        }
        saveMessage = "Resetting all settings…"
        let clearJS = """
        (function () {
          try {
            var doomed = [];
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k === "BetterXcloud" || k === "BetterXcloud.Stream" ||
                  k.indexOf("BetterXcloud.Stream.") === 0 || k.indexOf("XCG.") === 0) doomed.push(k);
            }
            for (var j = 0; j < doomed.length; j++) { try { localStorage.removeItem(doomed[j]); } catch (e) {} }
          } catch (e) {}
        })();
        """
        browser.evaluateJS(clearJS) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let defaults = UserDefaults.standard
                for key in ["nativeBetterXcloudGlobal", "nativeBetterXcloudStream",
                            "nativeRendererRecoveryVersion", "cachedServerRegions",
                            "ledColorIndex", "ledCustomR", "ledCustomG", "ledCustomB",
                            "app.clarityPipeline", "inputPresets.defaultWebMigrated.v2",
                            "nativeController.settings.v1", "nativeController.settingsVersion",
                            "controller.globalRumbleGain", "controller.streamCalibration"] {
                    defaults.removeObject(forKey: key)
                }
                self.ledColorIndex = 1
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await browser.inputPresets.resetAllToFactory()
                    browser.controllerFeatures.resetSettings()
                    browser.controllerFeatures.globalRumbleGain = 1
                    browser.controllerFeatures.applyCalibrationToStream = false
                    self.globalValues = [:]
                    self.streamValues = [:]
                    self.bestRegionResult = nil
                    self.resolvedRegionName = nil
                    self.regions = [("default", "Auto (closest server)")]
                    self.regionIndex = 0
                    self.needsReload = false
                    self.saveMessage = "All settings were reset — reloading the Xbox page…"
                    self.objectWillChange.send()
                    browser.reload()
                }
            }
        }
    }

    func applySuggested() {
        saveMessage = "Applying optimized M1 settings…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            for change in Self.suggestedForMac {
                await self.writeAndWait(id: change.key, scope: change.scope, value: change.value)
            }
            self.saveMessage = "Suggested settings saved"
        }
    }

    /// Verified write: Better xCloud validates/transforms the value, writes it,
    /// and returns a same-scope readback. UI and native mirrors update only after
    /// that response, and per-key generations discard stale completions.
    func write(id: String, scope: SettingScope, value: Any) {
        write(id: id, scope: scope, value: value, completion: nil)
    }

    private func writeAndWait(id: String, scope: SettingScope, value: Any) async {
        await withCheckedContinuation { continuation in
            write(id: id, scope: scope, value: value) { _ in continuation.resume() }
        }
    }

    private func write(id: String, scope: SettingScope, value: Any, completion: ((Bool) -> Void)?) {
        let intendedPresetID = browser?.inputPresets.activePresetID
        let generationKey = "\(scope == .global ? "global" : "stream"):\(id)"
        let generation = (writeGenerations[generationKey] ?? 0) + 1
        writeGenerations[generationKey] = generation

        guard let browser else {
            saveMessage = "The Xbox page is not ready."
            completion?(false)
            return
        }

        // Optimistic update so the control responds instantly; every failure
        // path below reverts to the previous value. The verified readback in
        // the success path replaces this with what Better xCloud accepted.
        let previous = rawValue(id)
        if id != "app.clarityPipeline" {
            switch scope {
            case .global: globalValues[id] = value
            case .stream: streamValues[id] = value
            }
            saveMessage = "Saving…"
            objectWillChange.send()
        }

        func revertOptimisticUpdate() {
            switch scope {
            case .global: globalValues[id] = previous
            case .stream: streamValues[id] = previous
            }
            if id == "server.region", let previousRegion = previous as? String,
               let index = regions.firstIndex(where: { $0.value == previousRegion }) {
                regionIndex = index
            }
            objectWillChange.send()
        }

        let script: String
        if id == "app.clarityPipeline" {
            let pipeline = (value as? String) ?? "native"
            UserDefaults.standard.set(pipeline, forKey: "app.clarityPipeline")
            let renderer: String
            let processing: String
            switch pipeline {
            case "webgl-usm": renderer = "webgl2"; processing = "usm"
            case "webgl-cas": renderer = "webgl2"; processing = "cas"
            case "webgpu-usm": renderer = "webgpu"; processing = "usm"
            case "webgpu-cas": renderer = "webgpu"; processing = "cas"
            default: renderer = "default"; processing = "usm"
            }
            script = """
            (function () {
              try {
                var hasBridge = typeof BxCBridge !== 'undefined';
                if (hasBridge) {
                  try { BxCBridge.setStream('video.player.type', \(jsonEncoded(renderer))); } catch (_) {}
                  try { BxCBridge.setStream('video.processing', \(jsonEncoded(processing))); } catch (_) {}
                }
                localStorage.setItem('XCG.Upscaler', 'off');
                window.postMessage({type:'xcg-upscaler', mode:'off'}, '*');
                if (\(jsonEncoded(pipeline)) !== 'native' && hasBridge) {
                  try {
                    var sh = BxCBridge.getStream('video.processing.sharpness');
                    if (sh === 0 || sh === '0' || typeof sh === 'undefined') {
                      BxCBridge.setStream('video.processing.sharpness', 3);
                    }
                  } catch (_) {}
                }
                var up = localStorage.getItem('XCG.Upscaler');
                var r = hasBridge ? (function(){ try { return BxCBridge.getStream('video.player.type'); } catch(_){ return \(jsonEncoded(renderer)); } })() : \(jsonEncoded(renderer));
                var p = hasBridge ? (function(){ try { return BxCBridge.getStream('video.processing'); } catch(_){ return \(jsonEncoded(processing)); } })() : \(jsonEncoded(processing));
                return JSON.stringify({ok:true, accepted:\(jsonEncoded(pipeline)), raw:up, renderer:r, processing:p, bridgeAvailable:hasBridge});
              } catch (e) { return JSON.stringify({ok:false,error:String(e)}); }
            })();
            """
        } else {
            let scopeName = scope == .global ? "global" : "stream"
            script = """
            (function () {
              try {
                var val = \(jsonEncoded(value));
                if (typeof BxCBridge === 'undefined') {
                  var lsKey = '\(scopeName)' === 'global' ? 'BetterXcloud' : 'BetterXcloud.Stream';
                  var current = JSON.parse(localStorage.getItem(lsKey) || '{}');
                  current[\(jsonEncoded(id))] = val;
                  localStorage.setItem(lsKey, JSON.stringify(current));
                  return JSON.stringify({ok:true, accepted:val, readback:val, raw:val, bridgeAvailable:false});
                }
                var accepted = BxCBridge.setPublic('\(scopeName)', \(jsonEncoded(id)), val);
                var readback = BxCBridge.getPublic('\(scopeName)', \(jsonEncoded(id)));
                var raw = BxCBridge.rawSameScope('\(scopeName)', \(jsonEncoded(id)));
                return JSON.stringify({ok:true,accepted:accepted,readback:readback,raw:raw, bridgeAvailable:true});
              } catch (e) { return JSON.stringify({ok:false,error:String(e)}); }
            })();
            """
        }
        browser.evaluateJS(script) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { completion?(false); return }
                guard self.writeGenerations[generationKey] == generation else { completion?(false); return }
                if let error {
                    revertOptimisticUpdate()
                    self.saveMessage = "Could not save: \(error.localizedDescription)"
                    completion?(false)
                    return
                }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      response["ok"] as? Bool == true else {
                    revertOptimisticUpdate()
                    self.saveMessage = (try? JSONSerialization.jsonObject(with: (result as? String ?? "").data(using: .utf8) ?? Data()) as? [String: Any])?["error"] as? String ?? "Could not save this setting."
                    completion?(false)
                    return
                }
                if id == "app.clarityPipeline" {
                    let pipeline = (value as? String) ?? "fsr1"
                    self.globalValues[id] = pipeline
                    self.streamValues["video.player.type"] = response["renderer"] ?? "default"
                    self.streamValues["video.processing"] = response["processing"] ?? "usm"
                    NativeSettingsMirror.save(pipeline, for: id, scope: .global)
                    NativeSettingsMirror.save(self.streamValues["video.player.type"]!, for: "video.player.type", scope: .stream)
                    NativeSettingsMirror.save(self.streamValues["video.processing"]!, for: "video.processing", scope: .stream)
                    self.needsReload = pipeline != "fsr1"
                } else {
                    let stored = response["raw"] ?? response["readback"] ?? value
                    switch scope {
                    case .global:
                        self.globalValues[id] = stored
                        NativeSettingsMirror.save(stored, for: id, scope: .global)
                    case .stream:
                        self.streamValues[id] = stored
                        NativeSettingsMirror.save(stored, for: id, scope: .stream)
                    }
                    if scope == .global || ["stream.video.codecProfile", "video.player.type", "video.processing"].contains(id) {
                        self.needsReload = true
                    }
                    if ["controller.settings", "video.brightness", "video.contrast", "video.saturation", "video.processing.sharpness", "audio.volume"].contains(id) {
                        self.browser?.inputPresets.noteBetterXCloudInputChanged(for: intendedPresetID)
                    }
                }
                if id == "server.region", let selected = response["readback"] as? String,
                   let index = self.regions.firstIndex(where: { $0.value == selected }) {
                    self.regionIndex = index
                }
                if id == "stats.showWhenPlaying", let visible = response["readback"] as? Bool {
                    // Update the overlay immediately instead of waiting for the
                    // page's own setting.changed listener to run.
                    self.browser?.evaluateJS("window.postMessage({ type: 'xcg-stats-visibility', visible: \(visible) }, '*')")
                }
                // Surface normalization: if Better xCloud stored a different
                // value than requested (e.g. unsupported quality), say so.
                // The setting id is included so a mismatch can be reported
                // against the exact row instead of a generic error.
                if let readback = response["readback"], !(readback is [Any] || readback is [String: Any]) {
                    let isEquivalent: Bool
                    if let b1 = readback as? Bool, let b2 = value as? Bool {
                        isEquivalent = (b1 == b2)
                    } else if let b1 = (readback as? NSNumber)?.boolValue, let b2 = value as? Bool {
                        isEquivalent = (b1 == b2)
                    } else if let b1 = readback as? Bool, let b2 = (value as? NSNumber)?.boolValue {
                        isEquivalent = (b1 == b2)
                    } else if let n1 = readback as? NSNumber, let n2 = value as? NSNumber {
                        isEquivalent = (n1.doubleValue == n2.doubleValue)
                    } else {
                        isEquivalent = String(describing: readback) == String(describing: value)
                    }
                    if !isEquivalent {
                        self.saveMessage = "Saved as '\(readback)' — requested '\(value)' is not supported here for '\(id)'"
                    } else {
                        self.saveMessage = "Saved"
                    }
                } else {
                    self.saveMessage = "Saved"
                }
                self.objectWillChange.send()
                completion?(true)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    enum Pane { case sidebar, rows }

    @Published var selectedCategoryId = SettingsCategory.all[0].id
    @Published var route: SettingsRoute = .home
    @Published private(set) var backStack: [SettingsRoute] = []
    @Published private(set) var forwardStack: [SettingsRoute] = []
    @Published var pane: Pane = .sidebar
    @Published var sidebarFocus = 0
    @Published var rowFocus = 0
    @Published var homeFocus = 0
    @Published var ledColorIndex: Int {
        didSet {
            UserDefaults.standard.set(ledColorIndex, forKey: "ledColorIndex")
            browser?.controllerInput.setLED(LEDColor.all[ledColorIndex])
        }
    }
    @Published private(set) var bridgeAvailable = false
    @Published private(set) var regions: [(value: String, label: String)] = [("default", "Auto (closest server)")]
    @Published private(set) var resolvedRegionName: String?
    @Published var saveMessage: String?
    @Published var needsReload = false
    @Published var isPingingRegions = false
    @Published var pingStatusText: String?
    @Published var bestRegionResult: RegionPingResult?

    struct RegionPingResult: Equatable {
        let name: String
        let displayName: String
        let baseURI: String
        /// Median response time from three post-warm-up samples. Median avoids
        /// choosing a server because of one unusually fast or slow request.
        let averageMs: Int
        let jitterMs: Int
        let samples: Int
    }

    private var regionPingTask: Task<Void, Never>?

    /// Tests the actual Xbox streaming endpoint exposed for every offered
    /// region. Better xCloud itself does not perform this test: it merely uses
    /// the region Xbox marks as `isDefault`, which may be an account fallback
    /// and not the lowest-latency region from this network.
    func testRegions(automaticallySelectBest: Bool = true) {
        guard !isPingingRegions else { return }
        isPingingRegions = true
        pingStatusText = "Finding all servers…"
        saveMessage = "Testing every available Xbox server…"
        bestRegionResult = nil
        browser?.evaluateJS("window.__xcgRegionPingCancelled = false")
        regionPingTask?.cancel()
        regionPingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let listResult = try await browser?.callAsyncJS("""
                    try {
                      if (typeof BxCBridge === 'undefined') return JSON.stringify({error:'Xbox page is not ready'});
                      return JSON.stringify(BxCBridge.regionList());
                    } catch (e) { return JSON.stringify({error:String(e)}); }
                    """)
                guard let listText = listResult as? String,
                      let listData = listText.data(using: .utf8),
                      let regionItems = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]],
                      !regionItems.isEmpty else {
                    self.isPingingRegions = false
                    self.pingStatusText = nil
                    self.saveMessage = "Could not retrieve region list"
                    self.regionPingTask = nil
                    return
                }

                let probeTargets: [[String: String]] = regionItems.compactMap { region in
                    guard let name = region["name"] as? String,
                          let baseURI = region["baseUri"] as? String, !baseURI.isEmpty else { return nil }
                    return [
                        "name": name,
                        "displayName": (region["displayName"] as? String) ?? (region["shortName"] as? String) ?? name,
                        "baseURI": baseURI,
                    ]
                }
                guard !probeTargets.isEmpty,
                      let targetData = try? JSONSerialization.data(withJSONObject: probeTargets),
                      let targetJSON = String(data: targetData, encoding: .utf8) else {
                    self.isPingingRegions = false
                    self.pingStatusText = nil
                    self.saveMessage = "Could not prepare the region test"
                    self.regionPingTask = nil
                    return
                }

                self.pingStatusText = "Testing \(probeTargets.count) servers…"
                self.saveMessage = "Measuring \(probeTargets.count) Xbox servers (three samples each)…"
                self.objectWillChange.send()

                // Run a small number of regions in parallel. This is much
                // faster than serial requests without flooding the connection
                // or making the measurements compete with each other.
                let probeScript = """
                return await (async function () {
                  var targets = \(targetJSON);
                  var cancelled = function () { return window.__xcgRegionPingCancelled === true; };
                  var measure = async function (target) {
                    var samples = [];
                    // The first request establishes DNS/TLS/connection state;
                    // it is intentionally excluded from the three scored runs.
                    for (var sample = 0; sample < 4 && !cancelled(); sample++) {
                      var controller = new AbortController();
                      var timeout = setTimeout(function () { controller.abort(); }, 3500);
                      var started = performance.now();
                      try {
                        var endpoint = new URL('/v2/servers/home?mr=50&_xcgLatency=' + Date.now() + '-' + sample, target.baseURI).toString();
                        await fetch(endpoint, {
                          method: 'GET', cache: 'no-store', signal: controller.signal
                        });
                        samples.push(Math.round(performance.now() - started));
                      } catch (_) {
                        // Timeouts and network failures are excluded. A region
                        // with no successful requests can never be selected.
                      } finally { clearTimeout(timeout); }
                    }
                    return {name:target.name, displayName:target.displayName, baseURI:target.baseURI,
                            times:samples.length > 1 ? samples.slice(1) : samples};
                  };
                  var cursor = 0, results = [];
                  var worker = async function () {
                    while (!cancelled()) {
                      var index = cursor++;
                      if (index >= targets.length) return;
                      results.push(await measure(targets[index]));
                    }
                  };
                  await Promise.all(Array.from({length: Math.min(6, targets.length)}, worker));
                  return JSON.stringify({cancelled:cancelled(), results:results});
                })();
                """
                let probeResult = try await browser?.callAsyncJS(probeScript)
                guard let probeText = probeResult as? String,
                      let probeData = probeText.data(using: .utf8),
                      let probeRoot = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any] else {
                    self.isPingingRegions = false
                    self.pingStatusText = nil
                    self.regionPingTask = nil
                    self.saveMessage = "Region test returned no data — reload the Xbox page, then test again"
                    return
                }
                if probeRoot["cancelled"] as? Bool == true {
                    self.isPingingRegions = false
                    self.pingStatusText = nil
                    self.saveMessage = "Region test stopped"
                    self.regionPingTask = nil
                    return
                }

                let rawResults = probeRoot["results"] as? [[String: Any]] ?? []
                let pingResults: [RegionPingResult] = rawResults.compactMap { result in
                    guard let name = result["name"] as? String,
                          let displayName = result["displayName"] as? String,
                          let baseURI = result["baseURI"] as? String,
                          let samples = result["times"] as? [NSNumber], !samples.isEmpty else { return nil }
                    let values = samples.map(\.intValue).sorted()
                    let median = values[values.count / 2]
                    let mean = Double(values.reduce(0, +)) / Double(values.count)
                    let jitter = Int((values.map { abs(Double($0) - mean) }.reduce(0, +) / Double(values.count)).rounded())
                    return RegionPingResult(name: name, displayName: displayName, baseURI: baseURI,
                                            averageMs: median, jitterMs: jitter, samples: values.count)
                }

                self.isPingingRegions = false
                self.pingStatusText = nil
                self.regionPingTask = nil

                // Lowest median response time wins. Jitter only breaks a tie,
                // so this remains faithful to the user's fastest-ping choice.
                let sorted = pingResults.sorted {
                    $0.averageMs == $1.averageMs ? $0.jitterMs < $1.jitterMs : $0.averageMs < $1.averageMs
                }
                if let best = sorted.first {
                    self.bestRegionResult = best
                    if automaticallySelectBest {
                        self.useBestRegion(best, automatic: true)
                    } else {
                        self.saveMessage = "The best server for you is \(best.displayName) (\(best.averageMs) ms, ±\(best.jitterMs) ms)"
                    }
                } else {
                    self.saveMessage = "No regions responded to latency test"
                }
                self.objectWillChange.send()
            } catch {
                self.isPingingRegions = false
                self.pingStatusText = nil
                self.regionPingTask = nil
                if !Task.isCancelled { self.saveMessage = "Region test failed: \(error.localizedDescription)" }
            }
        }
    }

    func stopRegionPing() {
        browser?.evaluateJS("window.__xcgRegionPingCancelled = true")
        regionPingTask?.cancel()
        regionPingTask = nil
        isPingingRegions = false
        pingStatusText = nil
        saveMessage = "Region test stopped"
    }

    func useBestRegion() {
        guard let bestRegionResult else {
            saveMessage = "Run the region test first"
            return
        }
        useBestRegion(bestRegionResult, automatic: false)
    }

    private func useBestRegion(_ result: RegionPingResult, automatic: Bool) {
        write(id: "server.region", scope: .global, value: result.name) { [weak self] saved in
            guard saved, let self else { return }
            self.saveMessage = automatic
                ? "Automatically selected \(result.displayName) (\(result.averageMs) ms, ±\(result.jitterMs) ms)"
                : "Selected \(result.displayName) (\(result.averageMs) ms, ±\(result.jitterMs) ms)"
            self.objectWillChange.send()
        }
        if let idx = regions.firstIndex(where: { $0.value == result.name }) {
            regionIndex = idx
        }
    }

    static func clarityDescription(for pipeline: String) -> String {
        switch pipeline {
        case "webgpu-cas":
            return "WebGPU AMD CAS: Modern compute shader contrast-adaptive sharpening with minimal WebKit CPU overhead."
        case "webgpu-usm":
            return "WebGPU Unsharp Mask: Modern compute shader unsharp masking running on Apple Silicon WebGPU."
        case "webgl-cas":
            return "WebGL 2 AMD CAS: High-performance contrast-adaptive sharpening that enhances textures without halos."
        case "webgl-usm":
            return "WebGL 2 Unsharp Mask: Classic high-frequency convolution filter that accentuates edges with low GPU overhead."
        case "native":
            return "Native video pass-through: WebKit hardware decoding with zero post-processing overhead or added latency."
        default:
            return "Select a clarity and upscaling pipeline for your stream."
        }
    }

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
    private var loadGeneration = 0
    private var writeGenerations: [String: Int] = [:]

    private(set) weak var browser: BrowserModel?

    init(browser: BrowserModel) {
        self.browser = browser
        let savedLED = UserDefaults.standard.object(forKey: "ledColorIndex") as? Int ?? 1
        ledColorIndex = min(max(savedLED, 0), max(0, LEDColor.all.count - 1))
    }

    var selectedCategory: SettingsCategory {
        SettingsCategory.all.first { $0.id == selectedCategoryId } ?? SettingsCategory.all[0]
    }

    var canGoBackInSettings: Bool { !backStack.isEmpty }
    var canGoForwardInSettings: Bool { !forwardStack.isEmpty }

    func navigate(to destination: SettingsRoute) {
        guard destination != route else { return }
        backStack.append(route)
        forwardStack.removeAll()
        applyRoute(destination)
    }

    func navigateBack() {
        guard let destination = backStack.popLast() else {
            if route != .home { navigate(to: .home) }
            return
        }
        forwardStack.append(route)
        applyRoute(destination)
    }

    func navigateForward() {
        guard let destination = forwardStack.popLast() else { return }
        backStack.append(route)
        applyRoute(destination)
    }

    func navigateHome() {
        navigate(to: .home)
    }

    func openControllerTools(_ section: ControllerToolSection = .overview) {
        navigate(to: .controllerSection(section))
    }

    private func applyRoute(_ destination: SettingsRoute) {
        route = destination
        rowFocus = 0
        switch destination {
        case .home:
            pane = .sidebar
            homeFocus = min(homeFocus, max(0, homeDestinationCount - 1))
        case .category(let id):
            selectedCategoryId = SettingsCategory.all.first(where: { $0.id == id })?.id ?? SettingsCategory.all[0].id
            sidebarFocus = SettingsCategory.all.firstIndex { $0.id == selectedCategoryId } ?? 0
            pane = .rows
        case .controllerSection(let section):
            homeFocus = SettingsCategory.all.count + (ControllerToolSection.allCases.firstIndex(of: section) ?? 0)
            pane = .sidebar
        case .profileEditor:
            // The inline editor keeps the settings pane focused on itself.
            pane = .rows
        }
        browser?.settingsRouteDidChange()
        objectWillChange.send()
    }

    func selectCategory(_ id: String) {
        navigate(to: .category(id))
    }

    private var homeDestinationCount: Int {
        SettingsCategory.all.count + ControllerToolSection.allCases.count
    }

    // MARK: - Load

    private static let readAllJS = """
    (function () {
      try {
        if (typeof BxCBridge === 'undefined') return JSON.stringify({bridge:false,error:'Better xCloud bridge is unavailable'});
        var snapshot = BxCBridge.settingsSnapshot();
        var selected = BxCBridge.selectedRegion();
        return JSON.stringify({
          bridge: true,
          regions: BxCBridge.regions(),
          selectedRegion: selected,
          upscaler: localStorage.getItem('XCG.Upscaler') || 'off',
          global: snapshot.global || {},
          stream: snapshot.stream || {}
        });
      } catch (e) { return JSON.stringify({bridge:false,error:String(e)}); }
    })();
    """

    func load() {
        loadGeneration += 1
        let generation = loadGeneration
        guard let browser else {
            bridgeAvailable = false
            saveMessage = "The Xbox page is not ready."
            return
        }
        browser.evaluateJS(Self.readAllJS) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self, self.loadGeneration == generation else { return }
                guard error == nil,
                      let json = result as? String,
                      let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.bridgeAvailable = false
                    self.saveMessage = "The Xbox page is not ready."
                    return
                }
                self.bridgeAvailable = root["bridge"] as? Bool ?? false
                guard self.bridgeAvailable else {
                    self.saveMessage = root["error"] as? String ?? "Better xCloud bridge is unavailable."
                    return
                }
                self.globalValues = root["global"] as? [String: Any] ?? [:]
                self.streamValues = root["stream"] as? [String: Any] ?? [:]
                let renderer = self.streamValues["video.player.type"] as? String ?? "default"
                let processing = self.streamValues["video.processing"] as? String ?? "usm"
                self.globalValues["app.clarityPipeline"] = renderer == "webgpu" ? (processing == "cas" ? "webgpu-cas" : "webgpu-usm") :
                     renderer == "webgl2" ? (processing == "cas" ? "webgl-cas" : "webgl-usm") : "native"
                if let selected = root["selectedRegion"] as? [String: Any] {
                    self.resolvedRegionName = (selected["displayName"] as? String) ?? (selected["shortName"] as? String)
                }
                if let regionDict = root["regions"] as? [String: Any] {
                    // Xbox's `isDefault` field is a service-assigned default,
                    // not a latency measurement. Do not label it “closest”.
                    let autoLabel = self.resolvedRegionName.map { "Automatic (Xbox suggested: \($0))" } ?? "Automatic (tests fastest server)"
                    var options: [(value: String, label: String)] = [("default", autoLabel)]
                    for key in regionDict.keys.sorted() {
                        let info = regionDict[key] as? [String: Any]
                        options.append((key, (info?["displayName"] as? String) ?? (info?["shortName"] as? String) ?? key))
                    }
                    self.regions = options
                }
                let current = self.rawValue("server.region") as? String ?? "default"
                self.regionIndex = self.regions.firstIndex { $0.value == current } ?? 0
                self.saveMessage = nil
                self.objectWillChange.send()
                // Fresh installs and reset settings begin in Automatic mode.
                // Replace Xbox's location heuristic with a real test as soon
                // as its offered endpoints are available.
                if current == "default", !self.isPingingRegions, self.bestRegionResult == nil {
                    self.testRegions(automaticallySelectBest: true)
                }
            }
        }
    }

    private func rawValue(_ key: String) -> Any? {
        if key == "app.led" { return nil }
        if globalValues.keys.contains(key) { return globalValues[key] }
        if streamValues.keys.contains(key) { return streamValues[key] }
        return nil
    }

    var clarityPipeline: String {
        (rawValue("app.clarityPipeline") as? String) ?? "fsr1"
    }

    func isOn(_ def: SettingDef) -> Bool {
        if let value = rawValue(def.id) as? Bool { return value }
        if case .toggle(let defaultValue) = def.kind { return defaultValue }
        return false
    }

    /// Current selection for dropdowns; nil means the setting is untouched
    /// (controls then show the definition's default).
    func optionIndex(_ def: SettingDef) -> Int? {
        let raw = rawValue(def.id)
        if def.id == "stats.items", let items = raw as? [String] {
            let presets: [[String]] = [
                ["ping", "fps", "btr", "dt", "pl", "fl"],
                ["ping", "fps"],
                ["fps", "btr", "dt"],
                ["ping"],
            ]
            return presets.firstIndex { Set($0) == Set(items) }
        }
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
        guard case .range(let lower, let upper, _, let defaultValue, _) = def.kind else { return nil }
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
        setToggle(def, desired: !isOn(def))
    }

    func setToggle(_ def: SettingDef, desired: Bool) {
        guard case .toggle = def.kind else { return }
        write(def, desired)
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
            let proposed = wrap(regionIndex + delta, regions.count)
            write(def, regions[proposed].value)
        case .ledColor:
            ledColorIndex = min(max(wrap(ledColorIndex + delta, LEDColor.all.count), 0), max(0, LEDColor.all.count - 1))
        default:
            break
        }
        objectWillChange.send()
    }

    func setOption(_ def: SettingDef, index: Int) {
        switch def.kind {
        case .option(let values, _, _):
            guard values.indices.contains(index) else { return }
            if def.id == "stats.items" {
                let presets: [[String]] = [
                    ["ping", "fps", "btr", "dt", "pl", "fl"],
                    ["ping", "fps"],
                    ["fps", "btr", "dt"],
                    ["ping"],
                ]
                write(def, presets[index])
            } else {
                write(def, values[index])
            }
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
        switch route {
        case .home:
            homeFocus = wrap(homeFocus + direction, homeDestinationCount)
        case .category:
            let count = rows.count
            guard count > 0 else { return }
            rowFocus = wrap(rowFocus + direction, count)
        case .controllerSection, .profileEditor:
            // Controller/editor controls retain native focus. Do not route d-pad
            // input into a hidden settings row.
            return
        }
        objectWillChange.send()
    }

    func adjustFocused(_ delta: Int) {
        switch route {
        case .home:
            moveFocus(delta)
        case .category:
            guard rows.indices.contains(rowFocus) else { return }
            adjust(rows[rowFocus], delta: delta)
        case .controllerSection, .profileEditor:
            // Let native focused controls handle keyboard/controller activation;
            // never mutate rows from a category that is not visible.
            return
        }
    }

    func activateFocused() {
        switch route {
        case .home:
            guard homeDestinationCount > 0 else { return }
            if homeFocus < SettingsCategory.all.count {
                navigate(to: .category(SettingsCategory.all[homeFocus].id))
            } else {
                let sectionIndex = homeFocus - SettingsCategory.all.count
                guard ControllerToolSection.allCases.indices.contains(sectionIndex) else { return }
                navigate(to: .controllerSection(ControllerToolSection.allCases[sectionIndex]))
            }
        case .category:
            guard rows.indices.contains(rowFocus) else { return }
            let def = rows[rowFocus]
            if case .toggle = def.kind {
                toggle(def)
            } else {
                adjust(def, delta: 1)
            }
        case .controllerSection, .profileEditor:
            return
        }
    }

    func handleCancel() {
        if route == .home {
            browser?.closeSettingsWindow()
        } else {
            navigateBack()
        }
    }

    func switchDestination(_ delta: Int) {
        switch route {
        case .home:
            moveFocus(delta)
        case .category(let id):
            guard let current = SettingsCategory.all.firstIndex(where: { $0.id == id }) else { return }
            let destinations = SettingsCategory.all.count + ControllerToolSection.allCases.count
            let next = wrap(current + delta, destinations)
            if next < SettingsCategory.all.count {
                navigate(to: .category(SettingsCategory.all[next].id))
            } else {
                navigate(to: .controllerSection(ControllerToolSection.allCases[next - SettingsCategory.all.count]))
            }
        case .controllerSection(let section):
            let categoryCount = SettingsCategory.all.count
            guard let sectionIndex = ControllerToolSection.allCases.firstIndex(of: section) else { return }
            let destinations = categoryCount + ControllerToolSection.allCases.count
            let next = wrap(categoryCount + sectionIndex + delta, destinations)
            if next < categoryCount {
                navigate(to: .category(SettingsCategory.all[next].id))
            } else {
                navigate(to: .controllerSection(ControllerToolSection.allCases[next - categoryCount]))
            }
        case .profileEditor:
            // Keyboard input belongs to the inline editor; nothing to switch.
            return
        }
    }

    var rows: [SettingDef] {
        guard case .category(let id) = route,
              let category = SettingsCategory.all.first(where: { $0.id == id }) else { return [] }
        return category.rows
    }
}
