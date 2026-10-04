import AppKit
import SwiftUI

@MainActor
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private weak var browser: BrowserModel?
    private var terminateObserver: NSObjectProtocol?

    init(browser: BrowserModel) {
        self.browser = browser
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Mac Xcloud")
        item.button?.toolTip = "Mac Xcloud"
        // Built when it opens, so nothing runs on the main thread (which also
        // reads the controller) while it is closed.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        }
    }

    /// Removes the status item during quit so the icon never outlives the
    /// terminating process.
    func tearDown() {
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let browser else { return }
        menu.removeAllItems()
        // What's playing, and how the stream is doing, at a glance.
        let playing = browser.isStreaming
        menu.addItem(label(playing && !browser.currentGameTitle.isEmpty ? browser.currentGameTitle : (playing ? "Playing" : "Not playing"), bold: true))
        if playing {
            let t = browser.telemetry
            var parts: [String] = []
            if t.pingMs >= 0 { parts.append(String(format: "%.0f ms", t.pingMs)) }
            if t.fps > 0 { parts.append(String(format: "%.0f fps", t.fps)) }
            if t.bitrateMbps > 0 { parts.append(String(format: "%.1f Mbps", t.bitrateMbps)) }
            if !t.resolution.isEmpty { parts.append(t.resolution) }
            if !browser.currentRegion.isEmpty { parts.append(browser.currentRegion) }
            if !parts.isEmpty { menu.addItem(label(parts.joined(separator: " · "))) }
            if let health = browser.streamHealth.report {
                let issue = health.issues.first.map { " · \($0.title)" } ?? ""
                menu.addItem(label("Connection: \(health.level.title)\(issue)"))
            }
        }

        menu.addItem(.separator())
        let controller = browser.controllerInput
        if let name = controller.controllerName {
            var text = name
            if let percent = controller.batteryPercent {
                text += " · \(percent)%" + (controller.batteryStateText == "Charging" ? " (charging)" : "")
            }
            menu.addItem(label(text))
        } else {
            menu.addItem(label("No controller connected"))
        }
        let profiles = NSMenuItem(title: "Game Profile", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        for preset in browser.inputPresets.presets {
            let presetItem = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            presetItem.target = self
            presetItem.representedObject = preset.id.uuidString
            presetItem.state = browser.inputPresets.activePresetID == preset.id ? .on : .off
            profileMenu.addItem(presetItem)
        }
        profiles.submenu = profileMenu
        menu.addItem(profiles)

        if !browser.gameLibrary.recent.isEmpty {
            let recent = NSMenuItem(title: "Recent Games", action: nil, keyEquivalent: "")
            let games = browser.dockMenu.menu()
            // The Dock menu leads with its own header; the submenu title says it.
            if let header = games.items.first, !header.isEnabled { games.removeItem(header) }
            recent.submenu = games
            menu.addItem(recent)
        }

        menu.addItem(.separator())
        menu.addItem(action("Open Mac Xcloud", #selector(openMainWindow)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        let isFullscreen = browser.isFullscreen
        menu.addItem(action(isFullscreen ? "Exit Full Screen" : "Enter Full Screen", #selector(toggleFullscreen)))
        menu.addItem(action("Reload Xbox Page", #selector(reload)))
        menu.addItem(.separator())
        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(action("Quit Mac Xcloud", #selector(quitApp), key: "q"))
    }

    private func label(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if bold {
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        }
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
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

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
