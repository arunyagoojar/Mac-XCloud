#if DEBUG
import AppKit
import SwiftUI

/// Development aid: renders every Settings page offscreen, in light and dark
/// appearance, to PNG files, then quits. Launch with
/// `--xcg-snapshot-settings <directory>`.
@MainActor
enum SettingsSnapshotter {
    static func run(browser: BrowserModel, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            // Give the page bridge a moment so cloud settings can load.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            browser.settingsModel.load()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let routes = SettingsPane.allCases.map { SettingsRoute.pane($0) } + ProfileKind.allCases.map { SettingsRoute.profileEditor($0) }
                for route in routes {
                    browser.settingsModel.navigate(to: route)
                    let root = SettingsRootView(model: browser.settingsModel).environmentObject(browser)
                    let view = NSHostingView(rootView: root)
                    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 760),
                                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                    window.titlebarAppearsTransparent = true
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = view
                    window.orderBack(nil)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let base: String
                        switch route {
                        case .pane(let pane): base = pane.rawValue
                        case .profileEditor(let kind): base = "editor-" + kind.rawValue
                        }
                        let name = "\(base)-\(appearance == .aqua ? "light" : "dark").png"
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                    }
                    window.orderOut(nil)
                }
            }
            // Mode-specific pages, rendered with a throwaway settings store so
            // the user's real profile is never touched.
            let suite = "MacXcloud.Snapshot." + UUID().uuidString
            let scratch = ControllerFeatureService(defaults: UserDefaults(suiteName: suite)!, persistenceKey: "snapshot", automaticallyAttach: false)
            let variants: [(String, (inout ControllerEnhancements) -> Void, Bool)] = [
                ("motion-aiming", { $0.setGyroMode(.aiming) }, false),
                ("motion-steering", { $0.setGyroMode(.steering) }, false),
                ("touchpad-camera", { $0.touchpadAimEnabled = true }, true),
            ]
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, edit, touchpad) in variants {
                    scratch.updateSettings { var e = ControllerEnhancements(); edit(&e); $0.enhancements = e }
                    let page = Group {
                        if touchpad { TouchpadSettingsPage(service: scratch) } else { MotionSettingsPage(service: scratch) }
                    }.environmentObject(browser)
                    let view = NSHostingView(rootView: page.frame(width: 680, height: 760))
                    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 680, height: 760),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = view
                    window.orderBack(nil)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                    }
                    window.orderOut(nil)
                }
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            NSApp.terminate(nil)
        }
    }
}
#endif
