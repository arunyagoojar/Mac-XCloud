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
        item.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Xbox Cloud Gaming")
        item.button?.toolTip = "Xbox Cloud Gaming"
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
        if !browser.currentRegion.isEmpty {
            let region = NSMenuItem(title: "Region: \(browser.currentRegion)", action: nil, keyEquivalent: "")
            region.isEnabled = false
            menu.addItem(region)
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
        let quit = NSMenuItem(title: "Quit Xbox Cloud Gaming", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

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
