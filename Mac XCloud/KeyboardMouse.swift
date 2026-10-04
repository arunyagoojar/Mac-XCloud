//
//  KeyboardMouse.swift
//  Mac XCloud
//
//  Keyboard & mouse play has two paths, both inside the Xbox page:
//
//  • Native: games that support keyboard & mouse on Xbox receive real key and
//    mouse input from Xbox's own stream client. WebKit lacks two Chromium
//    APIs that client requires (Keyboard Lock, and pointer lock in a
//    WKWebView needs the host's permission); the app supplies both — see
//    `BetterXCloud.compatibilityScript`, `fullscreenBridgeScript` and the
//    pointer-lock delegate in `WebView`.
//  • Emulated: for every other game, Better xCloud presents a virtual
//    controller driven by the keyboard and mouse.
//
//  While the mouse is captured, Escape is routed by the app: a quick press
//  goes to the game (pause menus), holding it releases the mouse — the same
//  contract Chrome offers with Keyboard Lock.
//

import Foundation

enum KeyboardMouseSettings {
    private static let sensitivityKey = "mkb.mouseSensitivity.v1"

    /// Multiplier on the emulated controller's mouse look (1 = layout default).
    static var mouseSensitivity: Double {
        get {
            let value = UserDefaults.standard.object(forKey: sensitivityKey) as? Double ?? 1
            return value.isFinite ? min(max(value, 0.2), 4) : 1
        }
        set { UserDefaults.standard.set(min(max(newValue, 0.2), 4), forKey: sensitivityKey) }
    }

    /// How long Escape must be held to release a captured mouse.
    static let escapeHoldToRelease: TimeInterval = 0.6

    /// Built-in Better xCloud keyboard layouts for the virtual controller.
    struct Layout: Identifiable, Hashable {
        let id: Int
        let name: String
        let summary: [(control: String, keys: String)]

        static func == (lhs: Layout, rhs: Layout) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static let layouts: [Layout] = [
        Layout(id: -1, name: "Standard", summary: [
            ("Move", "W A S D"), ("Look", "Mouse"),
            ("Right trigger / Left trigger", "Left click / Right click"),
            ("A", "Space or E"), ("B", "C or Delete"), ("X", "R"), ("Y", "V"),
            ("Left bumper / Right bumper", "Q / F"),
            ("Left stick click / Right stick click", "X / Z"),
            ("D-pad", "Arrow keys or 1 2 3 4"),
            ("Menu / View", "Return / Tab"), ("Xbox button", "`")
        ]),
        Layout(id: -2, name: "Shooter", summary: [
            ("Move", "W A S D"), ("Look", "Mouse"),
            ("Right trigger / Left trigger", "Left click / Right click"),
            ("A", "Space or E"), ("B", "Control or Delete"), ("X", "R"), ("Y", "V"),
            ("Left bumper / Right bumper", "C or G / Q"),
            ("Left stick click / Right stick click", "Shift / F"),
            ("D-pad", "Arrow keys"),
            ("Menu / View", "Return / Tab"), ("Xbox button", "`")
        ]),
    ]
}
