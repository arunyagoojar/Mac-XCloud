//
//  SettingsWindow.swift
//  Mac XCloud
//
//  The Settings window: a System Settings–style sidebar and the app's
//  general pages. Controller, motion, touchpad, keyboard & mouse, shortcut
//  and profile pages live in ControllerSettingsPages.swift.
//

import AppKit
import Sparkle
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel
    @State private var search = ""
    @State private var scrolled = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 228)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(scrolled || model.needsReload ? 1 : 0)
                if model.needsReload { reloadBanner }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onPreferenceChange(SettingsScrollOffsetKey.self) { offset in
                        let next = offset > 1
                        if next != scrolled { scrolled = next }
                    }
            }
            .background(SettingsPalette.page)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear {
            browser.isSettingsWindowOpen = true
            model.load()
        }
        .onChange(of: model.route) { _ in scrolled = false }
        .onDisappear { browser.isSettingsWindowOpen = false }
    }

    // MARK: - Sidebar

    private var selectedPane: SettingsPane {
        switch model.route {
        case .pane(let pane): return pane
        case .profileEditor: return .shortcuts
        }
    }

    private var visiblePaneGroups: [[SettingsPane]] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsPane.groups }
        return SettingsPane.groups
            .map { $0.filter { $0.searchText.contains(needle) } }
            .filter { !$0.isEmpty }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(text: $search)
                .frame(height: 28)
                .padding(.horizontal, 10)
                .padding(.top, 46)
                .padding(.bottom, 8)
            if visiblePaneGroups.isEmpty {
                Text("No Results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                Spacer()
            } else {
                List(selection: Binding<SettingsPane?>(
                    get: { selectedPane },
                    set: { pane in if let pane { model.navigate(to: .pane(pane)) } }
                )) {
                    ForEach(Array(visiblePaneGroups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { pane in
                                HStack(spacing: 8) {
                                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                                    Text(pane.title).lineLimit(1)
                                }
                                .padding(.vertical, 1)
                                .tag(pane)
                                .accessibilityLabel(pane.title)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(SidebarMaterial().ignoresSafeArea())
        .overlay(alignment: .top) { WindowDragStrip().frame(height: 38) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: model.navigateBack) { Image(systemName: "chevron.left") }
                .help("Back")
                .accessibilityLabel("Back")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBackInSettings)
            Button(action: model.navigateForward) { Image(systemName: "chevron.right") }
                .help("Forward")
                .accessibilityLabel("Forward")
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForwardInSettings)
            Text(pageTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let message = model.saveMessage, message != "Saved", message != "Saving…" {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 380, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .medium))
        .padding(.leading, 16).padding(.trailing, 18)
        .frame(height: 38)
        .background(WindowDragStrip())
    }

    private var reloadBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.accentColor)
            Text(browser.isStreaming
                 ? "Some changes take effect with your next game."
                 : "Some changes take effect after the Xbox page reloads.")
                .font(.system(size: 12))
            Spacer()
            if !browser.isStreaming {
                Button("Reload Now") {
                    browser.reload()
                    model.needsReload = false
                }
                .controlSize(.small)
            }
            Button {
                model.needsReload = false
            } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var pageTitle: String {
        switch model.route {
        case .pane(let pane): return pane.title
        case .profileEditor(let kind): return kind == .controllerCustomization ? "Button Remapping" : "Xbox Button Shortcuts"
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .pane(let pane):
            switch pane {
            case .general: GeneralSettingsPage(model: model)
            case .streaming: StreamingSettingsPage(model: model)
            case .overlay: OverlaySettingsPage(model: model)
            case .controller: ControllerSettingsPage(service: browser.controllerFeatures, model: model)
            case .motion: MotionSettingsPage(service: browser.controllerFeatures)
            case .touchpad: TouchpadSettingsPage(service: browser.controllerFeatures)
            case .keyboardMouse: KeyboardMouseSettingsPage(model: model, store: browser.keyboardMouse)
            case .shortcuts: ShortcutsSettingsPage(service: browser.controllerFeatures, model: model)
            case .profiles: ProfilesSettingsPage(store: browser.inputPresets)
            case .site: SiteSettingsPage(model: model)
            case .advanced: AdvancedSettingsPage(model: model)
            case .about: AboutSettingsPage()
            }
        case .profileEditor(let kind):
            ProfileEditorView(model: ProfileEditorModel(kind: kind, browser: browser))
                .background(SettingsPalette.page)
        }
    }
}

extension SettingsPane {
    /// What the sidebar search matches: title, keywords and every setting
    /// shown on the page.
    var searchText: String {
        ([title, keywords] + settingIDs.compactMap { SettingsPaneCatalog.label(for: $0) })
            .joined(separator: " ").lowercased()
    }

    var settingIDs: [String] {
        switch self {
        case .general: return ["server.region", "stream.locale", "ui.splashVideo.skip"]
        case .streaming: return ["stream.video.resolution", "stream.video.codecProfile", "stream.video.maxBitrate",
                                 "app.clarityPipeline", "video.processing.sharpness", "video.maxFps", "video.ratio",
                                 "audio.volume", "audio.mic.onPlaying", "xhome.video.resolution",
                                 "stream.video.preventResolutionDrops", "video.brightness", "video.contrast", "video.saturation"]
        case .overlay: return ["stats.showWhenPlaying", "stats.quickGlance.enabled", "stats.items", "stats.position",
                               "stats.textSize", "stats.opacity.all", "stats.opacity.background", "stats.colors", "gameBar.position"]
        case .site: return ["ui.theme", "ui.controllerFriendly", "ui.reduceAnimations", "ui.layout", "ui.hideSections",
                            "ui.imageQuality", "loadingScreen.waitTime.show", "ui.feedbackDialog.disabled"]
        case .advanced: return ["block.tracking", "block.features", "controller.pollingRate", "localCoOp.enabled"]
        default: return []
        }
    }
}

enum SettingsPaneCatalog {
    static func label(for id: String) -> String? {
        (SettingsCategory.all.flatMap(\.rows) + SettingsCategory.controllerRows).first { $0.id == id }?.label
    }
}

extension SettingsRoute {
    /// Parses a `--xcg-settings-route` launch argument (scripted UI checks).
    static func launchRoute(named name: String) -> SettingsRoute {
        let needle = name.lowercased()
        if let pane = SettingsPane.allCases.first(where: { $0.rawValue.lowercased() == needle || $0.title.lowercased() == needle }) {
            return .pane(pane)
        }
        return .home
    }
}

// MARK: - Native pieces

/// The translucent sidebar material of a macOS settings window.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// AppKit's search field (native look, clear button, Escape clears).
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.focusRingType = .default
        field.setAccessibilityLabel("Search settings")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Better xCloud setting rows

/// Renders one Better xCloud setting with the right native control.
struct BxSettingRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    var label: String? = nil
    var note: String? = nil
    /// Show the catalog's own explanation when no note is given.
    var catalogNote = false

    var body: some View {
        if let def = model.def(id) {
            row(def)
        }
    }

    @ViewBuilder private func row(_ def: SettingDef) -> some View {
        let title = label ?? def.label
        let detail = note ?? (catalogNote ? def.note.map(Self.plain) : nil)
        switch def.kind {
        case .toggle:
            SettingsToggleRow(label: title, note: detail, isOn: Binding(
                get: { model.isOn(def) }, set: { model.setToggle(def, desired: $0) }))
        case .option(let values, _, _):
            SettingsRow(title, note: detail) { picker(def, count: values.count) }
        case .numberOption(let values, _, _):
            SettingsRow(title, note: detail) { picker(def, count: values.count) }
        case .serverRegion:
            SettingsRow(title, note: detail) { picker(def, count: model.regionCount) }
        case .range(let lower, let upper, let step, _, let format):
            SettingsSliderRow(label: title, note: detail, value: Binding(
                get: { model.rangeValue(def) ?? lower }, set: { model.setRange(def, value: $0) }),
                range: lower...upper, valueText: format, step: step)
        case .multi(let options):
            SettingsRow(title, note: detail) {
                Menu {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button { model.toggleMulti(def, value: option.value) } label: {
                            if model.multiSelection(def).contains(option.value) {
                                Label(option.label, systemImage: "checkmark")
                            } else { Text(option.label) }
                        }
                    }
                } label: { Text(summary(def, options: options)) }
                .fixedSize()
                .accessibilityLabel(title)
            }
        default:
            EmptyView()
        }
    }

    private func picker(_ def: SettingDef, count: Int) -> some View {
        Picker(def.label, selection: Binding<Int>(
            get: { model.optionIndex(def) ?? model.defaultOptionIndex(def) },
            set: { model.setOption(def, index: $0) }
        )) {
            ForEach(0..<count, id: \.self) { index in
                Text(model.optionLabel(def, index: index)).tag(index)
            }
        }
        .settingsPicker()
    }

    private func summary(_ def: SettingDef, options: [(value: String, label: String)]) -> String {
        let selection = model.multiSelection(def)
        if selection.isEmpty { return "None" }
        let labels = options.filter { selection.contains($0.value) }.map(\.label)
        return labels.count <= 2 ? labels.joined(separator: ", ") : "\(labels.count) selected"
    }

    /// Notes in the catalog carry warning emoji for the old UI; the new rows
    /// say the same thing in plain words.
    nonisolated static func plain(_ note: String) -> String {
        note.replacingOccurrences(of: "⚠️ ", with: "")
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel
    @State private var automaticUpdates = UpdaterService.controller.updater.automaticallyChecksForUpdates

    var body: some View {
        SettingsPage("General") {
            if !model.bridgeAvailable {
                SettingsWarning(text: "Cloud settings load once xbox.com/play has finished loading in the main window.",
                                symbol: "info.circle.fill", tint: .blue)
            }
            SettingsGroup("Server", footer: "Automatic measures every Xbox server from this network and uses the fastest. Changes apply to your next game.") {
                BxSettingRow(model: model, id: "server.region", label: "Region", note: nil)
                Divider()
                SettingsRow("Fastest server", note: pingNote) {
                    if model.isPingingRegions {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Button("Stop", action: model.stopRegionPing).controlSize(.small)
                        }
                    } else {
                        Button(model.bestRegionResult == nil ? "Test Now" : "Test Again") { model.testRegions() }
                            .controlSize(.small)
                    }
                }
                Divider()
                BxSettingRow(model: model, id: "stream.locale", label: "Game language", note: nil)
            }
            SettingsGroup("Launch") {
                BxSettingRow(model: model, id: "ui.splashVideo.skip", label: "Skip the Xbox intro video", note: nil)
                Divider()
                SettingsToggleRow(label: "Play games in full screen",
                                  note: "Full screen lets macOS turn on Game Mode: the game gets priority and controllers are read more often over Bluetooth. Leaves full screen when the game ends.",
                                  isOn: $browser.fullscreenForGames)
            }
            SettingsGroup("Updates") {
                SettingsToggleRow(label: "Check for updates automatically", isOn: Binding(
                    get: { automaticUpdates },
                    set: { automaticUpdates = $0; UpdaterService.controller.updater.automaticallyChecksForUpdates = $0 }))
                Divider()
                SettingsRow("Mac Xcloud \(AboutSettingsPage.version)") {
                    Button("Check Now") { UpdaterService.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!UpdaterService.controller.updater.canCheckForUpdates)
                }
            }
        }
    }

    private var pingNote: String {
        if model.isPingingRegions { return model.pingStatusText ?? "Testing servers…" }
        if let best = model.bestRegionResult { return "\(best.displayName) · \(best.averageMs) ms" }
        return "Measure the latency to every available server."
    }
}

// MARK: - Streaming

struct StreamingSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var showPictureAdjustments = false
    @State private var showAdvanced = false

    var body: some View {
        SettingsPage("Streaming") {
            SettingsGroup("Quality", footer: "Quality settings apply to your next game.") {
                BxSettingRow(model: model, id: "stream.video.resolution", label: "Resolution",
                             note: "1080p (HQ) asks Xbox for its best encoder settings.")
                Divider()
                BxSettingRow(model: model, id: "stream.video.codecProfile", label: "Video quality", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stream.video.maxBitrate", label: "Bandwidth limit",
                             note: "Limit only on slow or metered connections.")
            }
            SettingsGroup("Picture") {
                SettingsRow("Sharpening", note: "Restores detail softened by video compression.") {
                    Picker("Sharpening", selection: Binding<String>(
                        get: { model.clarityPipeline == "fsr1" ? "native" : model.clarityPipeline },
                        set: { value in if let def = model.def("app.clarityPipeline") { model.write(id: def.id, scope: def.scope, value: value) } }
                    )) {
                        Text("Off").tag("native")
                        Text("Standard").tag("webgl-cas")
                        Text("Standard (Metal)").tag("webgpu-cas")
                        Divider()
                        Text("Classic Unsharp Mask").tag("webgl-usm")
                        Text("Classic Unsharp Mask (Metal)").tag("webgpu-usm")
                    }
                    .settingsPicker()
                }
                if model.clarityPipeline != "native" {
                    Divider()
                    BxSettingRow(model: model, id: "video.processing.sharpness", label: "Strength", note: nil)
                }
                Divider()
                BxSettingRow(model: model, id: "video.maxFps", label: "Frame rate limit", note: nil)
                Divider()
                BxSettingRow(model: model, id: "video.ratio", label: "Aspect ratio", note: nil)
                Divider()
                SettingsDisclosure("Color Adjustments", isExpanded: $showPictureAdjustments) {
                    BxSettingRow(model: model, id: "video.brightness", label: "Brightness", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "video.contrast", label: "Contrast", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "video.saturation", label: "Saturation", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "video.position", label: "Position", note: nil)
                }
            }
            SettingsGroup("Sound") {
                BxSettingRow(model: model, id: "audio.volume", label: "Game volume", note: nil)
                Divider()
                BxSettingRow(model: model, id: "audio.volume.booster.enabled", label: "Allow volume above 100%", note: nil)
                Divider()
                BxSettingRow(model: model, id: "audio.mic.onPlaying", label: "Turn on the microphone when a game starts", note: nil)
            }
            SettingsGroup("Remote Play", footer: "Streaming from your own Xbox console.") {
                BxSettingRow(model: model, id: "xhome.video.resolution", label: "Resolution", note: nil)
            }
            SettingsGroup {
                SettingsDisclosure("Advanced", isExpanded: $showAdvanced) {
                    BxSettingRow(model: model, id: "stream.video.preventResolutionDrops", label: "Hold resolution when bandwidth drops",
                                 note: "Can stutter instead of softening the picture.")
                    Divider()
                    BxSettingRow(model: model, id: "video.processing.mode", label: "Sharpening mode", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "video.player.powerPreference", label: "Renderer power", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "stream.video.combineAudio", label: "Combine audio and video",
                                 note: "Experimental. Can fix audio that lags behind the picture.")
                    Divider()
                    BxSettingRow(model: model, id: "screenshot.applyFilters", label: "Apply color adjustments to screenshots", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "game.fortnite.forceConsole", label: "Fortnite: stream the console version", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "server.ipv6.prefer", label: "Prefer IPv6 servers", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "xhome.ipv6.prefer", label: "Prefer IPv6 for Remote Play", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "server.bypassRestriction", label: "Stream through another region",
                                 note: "Uses third-party proxy servers. Use at your own risk.")
                }
            }
        }
    }
}

// MARK: - Overlay

struct OverlaySettingsPage: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage("Performance", subtitle: "How the stream is doing, and the overlay with its numbers.") {
            StreamHealthSection(monitor: browser.streamHealth, isStreaming: browser.isStreaming)
            SettingsGroup("Overlay") {
                BxSettingRow(model: model, id: "stats.showWhenPlaying", label: "Show while playing", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.quickGlance.enabled", label: "Show while holding the Xbox button",
                             note: "Peek at the numbers without leaving the overlay on.")
            }
            SettingsGroup("Appearance") {
                BxSettingRow(model: model, id: "stats.items", label: "Show", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.position", label: "Position", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.textSize", label: "Text size", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.opacity.all", label: "Opacity", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.opacity.background", label: "Background", note: nil)
                Divider()
                BxSettingRow(model: model, id: "stats.colors", label: "Highlight problems in color", note: nil)
            }
            SettingsGroup("Game Bar") {
                BxSettingRow(model: model, id: "gameBar.position", label: "Position",
                             note: "Play time and battery at the bottom of the stream.")
            }
        }
    }
}

// MARK: - Xbox website

struct SiteSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var showMore = false

    var body: some View {
        SettingsPage("Xbox Website", subtitle: "How xbox.com/play looks and behaves inside Mac Xcloud.") {
            SettingsGroup("Appearance") {
                BxSettingRow(model: model, id: "ui.theme", label: "Background", note: nil)
                Divider()
                BxSettingRow(model: model, id: "ui.layout", label: "Layout", note: nil)
                Divider()
                BxSettingRow(model: model, id: "ui.reduceAnimations", label: "Reduce animations", note: nil)
                Divider()
                BxSettingRow(model: model, id: "ui.controllerFriendly", label: "Controller-friendly menus", note: nil)
            }
            SettingsGroup("Home Page") {
                BxSettingRow(model: model, id: "ui.hideSections", label: "Hide sections", note: nil)
                Divider()
                BxSettingRow(model: model, id: "ui.gameCard.waitTime.show", label: "Show wait times on games", note: nil)
                Divider()
                BxSettingRow(model: model, id: "ui.imageQuality", label: "Artwork quality", note: nil)
            }
            SettingsGroup("Loading Screens") {
                BxSettingRow(model: model, id: "loadingScreen.waitTime.show", label: "Show estimated wait time", note: nil)
                Divider()
                BxSettingRow(model: model, id: "loadingScreen.gameArt.show", label: "Show game artwork", note: nil)
                Divider()
                BxSettingRow(model: model, id: "loadingScreen.rocket", label: "Rocket animation", note: nil)
            }
            SettingsGroup {
                SettingsDisclosure("More", isExpanded: $showMore) {
                    BxSettingRow(model: model, id: "ui.feedbackDialog.disabled", label: "Don't ask for stream feedback", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "ui.controllerStatus.show", label: "Announce controller connections", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "ui.streamMenu.simplify", label: "Simplify the in-game menu", note: nil)
                    Divider()
                    BxSettingRow(model: model, id: "ui.hideScrollbar", label: "Hide scroll bars", note: nil)
                }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsPage: View {
    @EnvironmentObject private var browser: BrowserModel
    @ObservedObject var model: SettingsModel
    @State private var confirmingReset = false
    @State private var showControllerTools = false

    var body: some View {
        SettingsPage("Advanced") {
            SettingsGroup("Privacy") {
                BxSettingRow(model: model, id: "block.tracking", label: "Block Xbox analytics", note: nil)
                Divider()
                BxSettingRow(model: model, id: "block.features", label: "Turn off features", note: nil)
            }
            SettingsGroup("Controller Input") {
                BxSettingRow(model: model, id: "controller.pollingRate", label: "Input polling",
                             note: "How often controller input is sent. The fastest setting has the lowest latency.")
                Divider()
                BxSettingRow(model: model, id: "localCoOp.enabled", label: "Local co-op",
                             note: "Two controllers play as two players, in games that support it.")
            }
            SettingsGroup("Troubleshooting") {
                SettingsToggleRow(label: "Show diagnostics in the game window", isOn: $browser.showReport)
                Divider()
                SettingsDisclosure("Controller Connection Tests", isExpanded: $showControllerTools) {
                    ControllerConnectionTests()
                }
            }
            SettingsGroup("Backup", footer: "A backup contains every preference and profile. Your Xbox sign-in is never included.") {
                SettingsRow("Settings backup") {
                    HStack(spacing: 8) {
                        Button("Import…") { SettingsBackupManager.presentImport(browser: browser) }
                        Button("Export…") { SettingsBackupManager.presentExport(browser: browser) }
                    }
                    .controlSize(.small)
                }
            }
            SettingsGroup(footer: "Deletes saved game profiles and restores every setting to its default, then reloads Xbox Cloud Gaming. You stay signed in.") {
                SettingsRow("Reset all settings") {
                    Button("Reset…", role: .destructive) { confirmingReset = true }
                        .controlSize(.small)
                }
            }
        }
        .alert("Reset All Settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved profile and per-game setup is deleted and all settings return to their defaults. Your Xbox sign-in is kept.")
        }
    }
}

/// Bridge checks for the rare case where the game doesn't see the controller
/// or the motion output.
struct ControllerConnectionTests: View {
    @EnvironmentObject private var browser: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run these with a game streaming. The aim and steering tests move the camera or car briefly three seconds after you click, so switch to the game window.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Test Aim") { browser.testAimRoute() }
                Button("Test Steering") { browser.testSteerRoute() }
                Button("Check Connection") { Task { await browser.inspectControllerWebSupport() } }
                Button("Keyboard & Mouse") { browser.runMkbDiagnostics() }
            }
            .controlSize(.small)
            ScrollView {
                Text(browser.controllerWebDiagnostics)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(SettingsPalette.well, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Export Report…", action: browser.exportControllerDiagnostics).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - About

struct AboutSettingsPage: View {
    @State private var supportFailure: String?

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Mac Xcloud").font(.system(size: 20, weight: .semibold))
                Text("Version \(Self.version)").foregroundStyle(.secondary)
                Text("Xbox Cloud Gaming and Remote Play, made for the Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            SettingsGroup {
                SettingsRow("Built with") { Text("Better xCloud 6.7.12 · MIT License").foregroundStyle(.secondary) }
                Divider()
                SettingsRow("Support development") {
                    Button("Buy Me a Coffee…") { openSupportPage() }.controlSize(.small)
                }
            }
            SettingsGroup("Keyboard Shortcuts") {
                shortcut("Settings", "⌘,")
                Divider()
                shortcut("Full screen", "⌃⌘F")
                Divider()
                shortcut("Reload the Xbox page", "⌘R")
                Divider()
                shortcut("Back / Forward", "⌘[  ⌘]")
                Divider()
                shortcut("Xbox home", "⇧⌘L")
                Divider()
                shortcut("Release the mouse while playing", "Hold Esc")
                Divider()
                shortcut("Open Settings from the controller", "Hold L3 + R3")
            }
            Text("Mac Xcloud is not affiliated with or endorsed by Microsoft or Sony.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .alert("Couldn't Open the Link", isPresented: Binding(get: { supportFailure != nil }, set: { if !$0 { supportFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(supportFailure ?? "") }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        SettingsRow(title) { Text(keys).foregroundStyle(.secondary).font(.system(size: 12, design: .rounded)) }
    }

    private func openSupportPage() {
        guard let url = URL(string: "https://ko-fi.com/arunyagoojar"), NSWorkspace.shared.open(url) else {
            supportFailure = "Ko-fi could not be opened in your browser."
            return
        }
    }
}
