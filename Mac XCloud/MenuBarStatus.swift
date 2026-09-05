import AppKit
import SwiftUI

@MainActor
final class MenuBarStatusController {
    private let item: NSStatusItem
    private weak var browser: BrowserModel?
    private var timer: Timer?

    init(browser: BrowserModel) {
        self.browser = browser
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Mac Xcloud")
        item.button?.toolTip = "Mac Xcloud"
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenu() }
        }
    }

    func refreshMenu() {
        guard let browser else { return }
        let menu = NSMenu()
        let title = browser.isStreaming && !browser.currentGameTitle.isEmpty ? browser.currentGameTitle : "Not currently streaming"
        let current = NSMenuItem(title: "Current Streaming: \(title)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        if browser.isStreaming {
            addInfo("Region", browser.currentRegion.isEmpty ? "—" : browser.currentRegion, to: menu)
            addInfo("Resolution", browser.telemetry.resolution.isEmpty ? "—" : browser.telemetry.resolution, to: menu)
            addInfo("Ping", browser.telemetry.pingMs >= 0 ? String(format: "%.0f ms", browser.telemetry.pingMs) : "—", to: menu)
            addInfo("FPS", String(format: "%.0f", browser.telemetry.fps), to: menu)
            addInfo("Bitrate", String(format: "%.1f Mbps", browser.telemetry.bitrateMbps), to: menu)
            addInfo("Packet Loss", String(format: "%.2f%% (%d)", browser.telemetry.packetLossPercent, browser.telemetry.packetLossCount), to: menu)
            addInfo("Frames Dropped", "\(browser.telemetry.framesDropped)", to: menu)
            addInfo("Decode Time", String(format: "%.2f ms", browser.telemetry.decodeTimeMs), to: menu)
            addInfo("Jitter", String(format: "%.2f ms", browser.telemetry.jitterMs), to: menu)
        }
        menu.addItem(.separator())

        let controller = browser.controllerInput
        let controllerText = controller.controllerName.map { "Controller: \($0)" } ?? "Controller: Not connected"
        let c = NSMenuItem(title: controllerText, action: nil, keyEquivalent: "")
        c.isEnabled = false
        menu.addItem(c)
        if let percent = controller.batteryPercent {
            let b = NSMenuItem(title: "Battery: \(percent)%\(controller.batteryStateText == "Charging" ? " · Charging" : "")", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
        }
        menu.addItem(.separator())
        let presets = NSMenuItem(title: "Input Preset", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu()
        for preset in browser.inputPresets.presets {
            let presetItem = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            presetItem.target = self
            presetItem.representedObject = preset.id.uuidString
            presetItem.state = browser.inputPresets.activePresetID == preset.id ? .on : .off
            presetMenu.addItem(presetItem)
        }
        presets.submenu = presetMenu
        menu.addItem(presets)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "u")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let main = NSMenuItem(title: "Open Main Window", action: #selector(openMainWindow), keyEquivalent: "")
        main.target = self
        menu.addItem(main)
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let fullscreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullscreen.target = self
        menu.addItem(fullscreen)
        let reload = NSMenuItem(title: "Reload Xbox Cloud", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mac Xcloud", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    private func addInfo(_ label: String, _ value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        Task { await browser?.inputPresets.applyPreset(id: id) }
    }
    @objc private func checkForUpdates() {
        UpdaterService.checkForUpdates()
    }
    @objc private func openMainWindow() { browser?.openMainWindow() }
    @objc private func openSettings() { browser?.openSettingsWindow() }
    @objc private func toggleFullscreen() { browser?.toggleFullscreen() }
    @objc private func reload() { browser?.reload() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

struct StatusItemBootstrap: NSViewRepresentable {
    @EnvironmentObject var browser: BrowserModel
    func makeNSView(context: Context) -> NSView {
        if browser.statusController == nil { browser.statusController = MenuBarStatusController(browser: browser) }
        return NSView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
