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
//  • Controller layout: in every other game the keyboard and mouse play as an
//    Xbox controller. The page-side engine (`BetterXCloud.keyboardLayerScript`)
//    presses the controller the way a physical one would, through the same
//    Gamepad API path Xbox already reads, using one of the layouts below.
//
//  While the mouse is captured, Escape is routed by the app: a quick press
//  goes to the game, holding it releases the mouse — the same contract
//  Chrome offers with Keyboard Lock.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

// MARK: - Controls

/// Everything on an Xbox controller a key or mouse button can press.
enum KeyboardControl: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
    case a, b, x, y
    case leftBumper, rightBumper, leftTrigger, rightTrigger
    case leftStickPress, rightStickPress
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case view, menu, xbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftStickUp: return "Move forward"
        case .leftStickDown: return "Move back"
        case .leftStickLeft: return "Move left"
        case .leftStickRight: return "Move right"
        case .rightStickUp: return "Look up"
        case .rightStickDown: return "Look down"
        case .rightStickLeft: return "Look left"
        case .rightStickRight: return "Look right"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftBumper: return "Left bumper"
        case .rightBumper: return "Right bumper"
        case .leftTrigger: return "Left trigger"
        case .rightTrigger: return "Right trigger"
        case .leftStickPress: return "Left stick press"
        case .rightStickPress: return "Right stick press"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .view: return "View"
        case .menu: return "Menu"
        case .xbox: return "Xbox button"
        }
    }

    /// The control's number in the page's controller state: standard Gamepad
    /// button indices, and 100+/200+ for the left/right stick directions.
    var pageIndex: Int {
        switch self {
        case .a: return 0
        case .b: return 1
        case .x: return 2
        case .y: return 3
        case .leftBumper: return 4
        case .rightBumper: return 5
        case .leftTrigger: return 6
        case .rightTrigger: return 7
        case .view: return 8
        case .menu: return 9
        case .leftStickPress: return 10
        case .rightStickPress: return 11
        case .dpadUp: return 12
        case .dpadDown: return 13
        case .dpadLeft: return 14
        case .dpadRight: return 15
        case .xbox: return 16
        case .leftStickUp: return 100
        case .leftStickDown: return 101
        case .leftStickLeft: return 102
        case .leftStickRight: return 103
        case .rightStickUp: return 200
        case .rightStickDown: return 201
        case .rightStickLeft: return 202
        case .rightStickRight: return 203
        }
    }

    enum Section: String, CaseIterable {
        case movement = "Movement"
        case camera = "Camera"
        case buttons = "Buttons"
        case shouldersAndTriggers = "Bumpers & Triggers"
        case dpad = "D-pad"
        case system = "System"
    }

    var section: Section {
        switch self {
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight, .leftStickPress: return .movement
        case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight, .rightStickPress: return .camera
        case .a, .b, .x, .y: return .buttons
        case .leftBumper, .rightBumper, .leftTrigger, .rightTrigger: return .shouldersAndTriggers
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return .dpad
        case .view, .menu, .xbox: return .system
        }
    }
}

/// Where mouse movement goes.
enum MouseLookStick: String, Codable, CaseIterable, Sendable {
    case right, left, off

    var title: String {
        switch self {
        case .right: return "Right stick (camera)"
        case .left: return "Left stick"
        case .off: return "Nothing"
        }
    }

    /// The number the page engine expects (Better xCloud's convention).
    var pageValue: Int {
        switch self {
        case .off: return 0
        case .left: return 1
        case .right: return 2
        }
    }
}

// MARK: - Layouts

/// A complete keyboard & mouse layout: which keys and mouse buttons press
/// which controller input, and where mouse movement goes. Inputs are named
/// like `KeyboardEvent.code` ("KeyW", "Space", "ShiftLeft") so they follow
/// key positions, not letters, and "Mouse0"…"Mouse4" / "ScrollUp"… for the
/// mouse. Each control takes up to two inputs; an input presses one control.
struct KeyboardLayout: Codable, Identifiable, Equatable, Sendable {
    static let inputsPerControl = 2

    var id: UUID
    var name: String
    var bindings: [String: [String]]
    var mouseLook: MouseLookStick = .right
    var invertMouseY = false

    init(id: UUID, name: String, bindings: [String: [String]], mouseLook: MouseLookStick = .right, invertMouseY: Bool = false) {
        self.id = id
        self.name = name
        self.bindings = bindings
        self.mouseLook = mouseLook
        self.invertMouseY = invertMouseY
    }

    private enum CodingKeys: String, CodingKey { case id, name, bindings, mouseLook, invertMouseY }

    /// Tolerant: a layout saved by another version keeps its keys even if a
    /// field is missing or unknown.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "My Layout"
        bindings = (try? c.decode([String: [String]].self, forKey: .bindings)) ?? [:]
        mouseLook = (try? c.decode(MouseLookStick.self, forKey: .mouseLook)) ?? .right
        invertMouseY = (try? c.decode(Bool.self, forKey: .invertMouseY)) ?? false
    }

    func inputs(for control: KeyboardControl) -> [String] {
        bindings[control.rawValue] ?? []
    }

    /// The control an input currently presses, if any.
    func control(for input: String) -> KeyboardControl? {
        KeyboardControl.allCases.first { inputs(for: $0).contains(input) }
    }

    /// Binds `input` to `control` in `slot` (0 or 1). An input presses one
    /// control only, so it moves here from wherever it was; that control is
    /// returned.
    @discardableResult
    mutating func bind(_ input: String, to control: KeyboardControl, slot: Int) -> KeyboardControl? {
        let previous = self.control(for: input)
        if let previous { bindings[previous.rawValue]?.removeAll { $0 == input } }
        var list = bindings[control.rawValue] ?? []
        let index = min(max(slot, 0), Self.inputsPerControl - 1)
        if index < list.count { list[index] = input } else { list.append(input) }
        bindings[control.rawValue] = Array(list.prefix(Self.inputsPerControl))
        prune()
        return previous == control ? nil : previous
    }

    mutating func unbind(_ control: KeyboardControl, slot: Int) {
        guard var list = bindings[control.rawValue], list.indices.contains(slot) else { return }
        list.remove(at: slot)
        bindings[control.rawValue] = list
        prune()
    }

    private mutating func prune() {
        bindings = bindings.filter { !$0.value.isEmpty }
    }

    /// What the page engine needs, as plain JSON values.
    var pageMapping: [String: Int] {
        var mapping: [String: Int] = [:]
        for control in KeyboardControl.allCases {
            for input in inputs(for: control) where mapping[input] == nil { mapping[input] = control.pageIndex }
        }
        return mapping
    }
}

enum BuiltInKeyboardLayouts {
    static let standardID = UUID(uuidString: "6E1C0000-0000-4000-8000-00000000A001")!
    static let shooterID = UUID(uuidString: "6E1C0000-0000-4000-8000-00000000A002")!

    private static func layout(_ id: UUID, _ name: String, _ pairs: [(KeyboardControl, [String])]) -> KeyboardLayout {
        KeyboardLayout(id: id, name: name, bindings: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue, $0.1) }))
    }

    /// Better xCloud's "Standard" layout.
    static let standard = layout(standardID, "Standard", [
        (.leftStickUp, ["KeyW"]), (.leftStickDown, ["KeyS"]), (.leftStickLeft, ["KeyA"]), (.leftStickRight, ["KeyD"]),
        (.rightStickUp, ["KeyU"]), (.rightStickDown, ["KeyJ"]), (.rightStickLeft, ["KeyH"]), (.rightStickRight, ["KeyK"]),
        (.a, ["Space", "KeyE"]), (.b, ["KeyC", "Backspace"]), (.x, ["KeyR"]), (.y, ["KeyV"]),
        (.leftBumper, ["KeyQ"]), (.rightBumper, ["KeyF"]),
        (.leftTrigger, ["Mouse2"]), (.rightTrigger, ["Mouse0"]),
        (.leftStickPress, ["KeyX"]), (.rightStickPress, ["KeyZ"]),
        (.dpadUp, ["ArrowUp", "Digit1"]), (.dpadDown, ["ArrowDown", "Digit2"]),
        (.dpadLeft, ["ArrowLeft", "Digit3"]), (.dpadRight, ["ArrowRight", "Digit4"]),
        (.view, ["Tab"]), (.menu, ["Enter"]), (.xbox, ["Backquote"]),
    ])

    /// Better xCloud's "Shooter" layout.
    static let shooter = layout(shooterID, "Shooter", [
        (.leftStickUp, ["KeyW"]), (.leftStickDown, ["KeyS"]), (.leftStickLeft, ["KeyA"]), (.leftStickRight, ["KeyD"]),
        (.rightStickUp, ["KeyI"]), (.rightStickDown, ["KeyK"]), (.rightStickLeft, ["KeyJ"]), (.rightStickRight, ["KeyL"]),
        (.a, ["Space", "KeyE"]), (.b, ["ControlLeft", "Backspace"]), (.x, ["KeyR"]), (.y, ["KeyV"]),
        (.leftBumper, ["KeyC", "KeyG"]), (.rightBumper, ["KeyQ"]),
        (.leftTrigger, ["Mouse2"]), (.rightTrigger, ["Mouse0"]),
        (.leftStickPress, ["ShiftLeft"]), (.rightStickPress, ["KeyF"]),
        (.dpadUp, ["ArrowUp"]), (.dpadDown, ["ArrowDown"]), (.dpadLeft, ["ArrowLeft"]), (.dpadRight, ["ArrowRight"]),
        (.view, ["Tab"]), (.menu, ["Enter"]), (.xbox, ["Backquote"]),
    ])

    static let all = [standard, shooter]

    static func isBuiltIn(_ id: UUID) -> Bool { all.contains { $0.id == id } }
}

// MARK: - Input names

/// Names for keys and mouse inputs, and the macOS key codes behind them.
enum KeyboardInputName {
    /// macOS virtual key code → `KeyboardEvent.code`, as WebKit reports it.
    /// Command, Fn, Caps Lock and Escape are left out: they belong to the
    /// Mac (shortcuts) or to releasing the mouse.
    static let codes: [UInt16: String] = {
        var table: [UInt16: String] = [
            0x00: "KeyA", 0x01: "KeyS", 0x02: "KeyD", 0x03: "KeyF", 0x04: "KeyH", 0x05: "KeyG", 0x06: "KeyZ",
            0x07: "KeyX", 0x08: "KeyC", 0x09: "KeyV", 0x0A: "IntlBackslash", 0x0B: "KeyB", 0x0C: "KeyQ",
            0x0D: "KeyW", 0x0E: "KeyE", 0x0F: "KeyR", 0x10: "KeyY", 0x11: "KeyT", 0x12: "Digit1", 0x13: "Digit2",
            0x14: "Digit3", 0x15: "Digit4", 0x16: "Digit6", 0x17: "Digit5", 0x18: "Equal", 0x19: "Digit9",
            0x1A: "Digit7", 0x1B: "Minus", 0x1C: "Digit8", 0x1D: "Digit0", 0x1E: "BracketRight", 0x1F: "KeyO",
            0x20: "KeyU", 0x21: "BracketLeft", 0x22: "KeyI", 0x23: "KeyP", 0x24: "Enter", 0x25: "KeyL",
            0x26: "KeyJ", 0x27: "Quote", 0x28: "KeyK", 0x29: "Semicolon", 0x2A: "Backslash", 0x2B: "Comma",
            0x2C: "Slash", 0x2D: "KeyN", 0x2E: "KeyM", 0x2F: "Period", 0x30: "Tab", 0x31: "Space",
            0x32: "Backquote", 0x33: "Backspace",
            0x38: "ShiftLeft", 0x3A: "AltLeft", 0x3B: "ControlLeft", 0x3C: "ShiftRight", 0x3D: "AltRight",
            0x3E: "ControlRight",
            0x41: "NumpadDecimal", 0x43: "NumpadMultiply", 0x45: "NumpadAdd", 0x47: "NumLock",
            0x4B: "NumpadDivide", 0x4C: "NumpadEnter", 0x4E: "NumpadSubtract", 0x51: "NumpadEqual",
            0x52: "Numpad0", 0x53: "Numpad1", 0x54: "Numpad2", 0x55: "Numpad3", 0x56: "Numpad4",
            0x57: "Numpad5", 0x58: "Numpad6", 0x59: "Numpad7", 0x5B: "Numpad8", 0x5C: "Numpad9",
            0x5D: "IntlYen", 0x5E: "IntlRo", 0x5F: "NumpadComma",
            0x73: "Home", 0x74: "PageUp", 0x75: "Delete", 0x77: "End", 0x79: "PageDown",
            0x7B: "ArrowLeft", 0x7C: "ArrowRight", 0x7D: "ArrowDown", 0x7E: "ArrowUp",
        ]
        let functionKeys: [(UInt16, Int)] = [(0x7A, 1), (0x78, 2), (0x63, 3), (0x76, 4), (0x60, 5), (0x61, 6),
                                             (0x62, 7), (0x64, 8), (0x65, 9), (0x6D, 10), (0x67, 11), (0x6F, 12)]
        for (code, number) in functionKeys { table[code] = "F\(number)" }
        return table
    }()

    static func code(forKeyCode keyCode: UInt16) -> String? { codes[keyCode] }

    /// A short, readable name: "W", "Space", "Left Shift", "Left Click".
    static func displayName(_ input: String) -> String {
        if let fixed = fixedNames[input] { return fixed }
        if input.hasPrefix("Key"), input.count == 4 { return typedCharacter(for: input) ?? String(input.suffix(1)) }
        if input.hasPrefix("Digit") { return String(input.dropFirst(5)) }
        if input.hasPrefix("Numpad") { return "Keypad " + (fixedNames["Numpad·" + input.dropFirst(6)] ?? String(input.dropFirst(6))) }
        if input.hasPrefix("F"), Int(input.dropFirst()) != nil { return input }
        return typedCharacter(for: input) ?? input
    }

    private static let fixedNames: [String: String] = [
        "Space": "Space", "Enter": "Return", "Tab": "Tab", "Backspace": "Delete", "Delete": "Forward Delete",
        "Backquote": "`", "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]",
        "Backslash": "\\", "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/",
        "IntlBackslash": "§", "ShiftLeft": "Left Shift", "ShiftRight": "Right Shift",
        "ControlLeft": "Left Control", "ControlRight": "Right Control",
        "AltLeft": "Left Option", "AltRight": "Right Option",
        "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
        "Home": "Home", "End": "End", "PageUp": "Page Up", "PageDown": "Page Down",
        "NumLock": "Clear", "IntlYen": "¥", "IntlRo": "_",
        "Numpad·Decimal": ".", "Numpad·Multiply": "*", "Numpad·Add": "+", "Numpad·Divide": "/",
        "Numpad·Enter": "Enter", "Numpad·Subtract": "-", "Numpad·Equal": "=", "Numpad·Comma": ",",
        "Mouse0": "Left Click", "Mouse1": "Middle Click", "Mouse2": "Right Click",
        "Mouse3": "Mouse Back", "Mouse4": "Mouse Forward",
        "ScrollUp": "Scroll Up", "ScrollDown": "Scroll Down", "ScrollLeft": "Scroll Left", "ScrollRight": "Scroll Right",
    ]

    /// The character a key types on the current keyboard layout, so an AZERTY
    /// keyboard shows "A" for the key in the "Q" position.
    private static func typedCharacter(for input: String) -> String? {
        guard let keyCode = codes.first(where: { $0.value == input })?.key,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}

// MARK: - Settings

/// Keyboard & mouse preferences and the user's own layouts.
@MainActor
final class KeyboardMouseStore: ObservableObject {
    private static let emulationKey = "kbm.controllerLayout.enabled.v1"
    private static let layoutsKey = "kbm.layouts.v1"
    private static let selectedKey = "kbm.layout.selected.v1"
    private static let sensitivityKey = "mkb.mouseSensitivity.v1"
    static let persistedKeys = [emulationKey, layoutsKey, selectedKey, sensitivityKey]

    /// How long Escape must be held to release a captured mouse.
    static let escapeHoldToRelease: TimeInterval = 0.6

    /// Play games without keyboard & mouse support with a controller layout.
    @Published var controllerLayoutEnabled: Bool { didSet { save() } }
    @Published private(set) var customLayouts: [KeyboardLayout]
    @Published var selectedLayoutID: UUID { didSet { save() } }
    /// Multiplier on mouse look (1 = layout default).
    @Published var mouseSensitivity: Double { didSet { save() } }

    /// Called after every change so the running page can follow.
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private var loading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controllerLayoutEnabled = true
        customLayouts = []
        mouseSensitivity = 1
        selectedLayoutID = BuiltInKeyboardLayouts.standardID
        read()
        loading = false
    }

    /// Re-reads everything (after a settings backup is imported).
    func reloadFromDefaults() {
        loading = true
        read()
        loading = false
        onChange?()
    }

    private func read() {
        controllerLayoutEnabled = defaults.object(forKey: Self.emulationKey) as? Bool ?? true
        // One unreadable layout must not cost the others.
        if let data = defaults.data(forKey: Self.layoutsKey),
           let items = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            customLayouts = items.compactMap { item -> KeyboardLayout? in
                guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return try? JSONDecoder().decode(KeyboardLayout.self, from: itemData)
            }.filter { !BuiltInKeyboardLayouts.isBuiltIn($0.id) }
        } else {
            customLayouts = []
        }
        let sensitivity = defaults.object(forKey: Self.sensitivityKey) as? Double ?? 1
        mouseSensitivity = sensitivity.isFinite ? min(max(sensitivity, 0.2), 4) : 1
        let stored = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        selectedLayoutID = stored ?? Self.migratedLayoutID()
        if !allLayouts.contains(where: { $0.id == selectedLayoutID }) { selectedLayoutID = BuiltInKeyboardLayouts.standardID }
    }

    /// 1.3.9 picked Better xCloud's layouts by number (-1 Standard, -2 Shooter).
    private static func migratedLayoutID() -> UUID {
        let mirrored = NativeSettingsMirror.values(for: .stream)["mkb.p1.preset.mappingId"]
        let number = (mirrored as? Int) ?? (mirrored as? Double).map(Int.init)
        return number == -2 ? BuiltInKeyboardLayouts.shooterID : BuiltInKeyboardLayouts.standardID
    }

    var allLayouts: [KeyboardLayout] { BuiltInKeyboardLayouts.all + customLayouts }

    var selectedLayout: KeyboardLayout {
        allLayouts.first { $0.id == selectedLayoutID } ?? BuiltInKeyboardLayouts.standard
    }

    func isBuiltIn(_ layout: KeyboardLayout) -> Bool { BuiltInKeyboardLayouts.isBuiltIn(layout.id) }

    /// A new layout copied from `source`, selected and ready to edit.
    @discardableResult
    func createLayout(from source: KeyboardLayout, named name: String? = nil) -> KeyboardLayout {
        var layout = source
        layout.id = UUID()
        layout.name = uniqueName(name ?? (isBuiltIn(source) ? "My \(source.name) Layout" : "\(source.name) Copy"))
        customLayouts.append(layout)
        selectedLayoutID = layout.id
        save()
        return layout
    }

    func update(_ layout: KeyboardLayout) {
        guard let index = customLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        customLayouts[index] = layout
        save()
    }

    /// Renames a layout; empty names are ignored.
    func rename(_ id: UUID, to proposed: String) {
        guard let index = customLayouts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != customLayouts[index].name else { return }
        customLayouts[index].name = uniqueName(String(trimmed.prefix(60)), excluding: id)
        save()
    }

    func delete(_ id: UUID) {
        customLayouts.removeAll { $0.id == id }
        if selectedLayoutID == id { selectedLayoutID = BuiltInKeyboardLayouts.standardID }
        save()
    }

    private func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let used = Set(allLayouts.filter { $0.id != id }.map { $0.name.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var number = 2
        while used.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Everything the page engine needs, as a JSON-ready dictionary.
    var pageConfiguration: [String: Any] {
        let layout = selectedLayout
        return ["enabled": controllerLayoutEnabled,
                "mapping": layout.pageMapping,
                "mouseLook": layout.mouseLook.pageValue,
                "invertY": layout.invertMouseY,
                "sensitivity": mouseSensitivity]
    }

    var pageConfigurationJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: pageConfiguration, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func save() {
        guard !loading else { return }
        defaults.set(controllerLayoutEnabled, forKey: Self.emulationKey)
        if let data = try? JSONEncoder().encode(customLayouts) { defaults.set(data, forKey: Self.layoutsKey) }
        defaults.set(selectedLayoutID.uuidString, forKey: Self.selectedKey)
        defaults.set(mouseSensitivity, forKey: Self.sensitivityKey)
        onChange?()
    }
}
