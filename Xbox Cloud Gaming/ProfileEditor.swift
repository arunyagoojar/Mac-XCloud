//
//  ProfileEditor.swift
//  Xbox Cloud Gaming
//
//  Native editors for Better xCloud's IndexedDB profile stores.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Profile types

enum ProfileKind: String, CaseIterable, Identifiable, Hashable {
    case mkb = "mkb"
    case keyboard = "keyboard"
    case controllerShortcuts = "controller-shortcuts"
    case controllerCustomization = "controller-customization"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mkb: "Virtual Controller Profiles"
        case .keyboard: "Keyboard Shortcut Profiles"
        case .controllerShortcuts: "Controller Shortcut Profiles"
        case .controllerCustomization: "Controller Remapping Profiles"
        }
    }

    var subtitle: String {
        switch self {
        case .mkb: "Map keyboard and mouse input to a virtual Xbox controller."
        case .keyboard: "Assign keyboard shortcuts to Better xCloud actions."
        case .controllerShortcuts: "Assign Home/PS + button shortcuts."
        case .controllerCustomization: "Remap buttons, deadzones, trigger ranges and rumble."
        }
    }
}

struct BxProfile: Identifiable {
    var id: Int
    var name: String
    var data: [String: Any]
    var isBuiltIn: Bool { id <= 0 }
}

// MARK: - Model

@MainActor
final class ProfileEditorModel: ObservableObject {
    let kind: ProfileKind
    private weak var browser: BrowserModel?

    @Published var profiles: [BxProfile] = []
    @Published var selectedID: Int?
    @Published var activeID: Int?
    @Published var draftName = ""
    @Published var draftData: [String: Any] = [:]
    @Published var message: String?
    @Published var isBusy = false

    init(kind: ProfileKind, browser: BrowserModel) {
        self.kind = kind
        self.browser = browser
    }

    var selectedProfile: BxProfile? { profiles.first { $0.id == selectedID } }
    var canEdit: Bool { (selectedID ?? 0) > 0 }

    func load() {
        Task { await reload() }
    }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await browser?.callAsyncJS(
                "return JSON.stringify({profiles: await BxCBridge.listProfiles(kind), selections: BxCBridge.profileSelections()});",
                arguments: ["kind": kind.rawValue]
            )
            guard let text = result as? String,
                  let data = text.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["profiles"] as? [String: Any],
                  let records = payload["data"] as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            profiles = records.compactMap { key, value in
                guard let object = value as? [String: Any] else { return nil }
                let id = (object["id"] as? NSNumber)?.intValue ?? Int(key) ?? 0
                return BxProfile(id: id,
                                 name: object["name"] as? String ?? "Profile \(id)",
                                 data: object["data"] as? [String: Any] ?? [:])
            }.sorted { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
                return lhs.id < rhs.id
            }
            let selections = root["selections"] as? [String: Any] ?? [:]
            switch kind {
            case .mkb: activeID = (selections["mkb"] as? NSNumber)?.intValue
            case .keyboard: activeID = (selections["keyboard"] as? NSNumber)?.intValue
            case .controllerShortcuts: activeID = (selections["controllerShortcuts"] as? NSNumber)?.intValue
            case .controllerCustomization: activeID = (selections["controllerCustomization"] as? NSNumber)?.intValue
            }
            if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
                selectedID = activeID.flatMap { active in profiles.contains(where: { $0.id == active }) ? active : nil }
                    ?? profiles.first?.id
            }
            loadDraft()
            message = nil
        } catch {
            message = "Could not load profiles: \(error.localizedDescription)"
        }
    }

    func select(_ id: Int?) {
        selectedID = id
        loadDraft()
    }

    func createProfile() {
        let blank: [String: Any]
        switch kind {
        case .mkb:
            blank = ["mapping": [:], "mouse": ["mapTo": 2, "sensitivityX": 100, "sensitivityY": 100, "deadzoneCounterweight": 20]]
        case .keyboard, .controllerShortcuts:
            blank = ["mapping": [:]]
        case .controllerCustomization:
            blank = ["mapping": [:], "settings": ["leftTriggerRange": [0, 100], "rightTriggerRange": [0, 100], "leftStickDeadzone": [0, 100], "rightStickDeadzone": [0, 100], "vibrationIntensity": 100]]
        }
        create(name: "New Profile", data: blank)
    }

    func copySelected() {
        guard let profile = selectedProfile else { return }
        create(name: profile.name + " Copy", data: profile.data)
    }

    private func create(name: String, data: [String: Any]) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let result = try await browser?.callAsyncJS(
                    "return await BxCBridge.createProfile(kind, name, data);",
                    arguments: ["kind": kind.rawValue, "name": name, "data": data]
                )
                if let number = result as? NSNumber { selectedID = number.intValue }
                await reload()
                message = "Profile created"
            } catch {
                message = "Could not create profile: \(error.localizedDescription)"
            }
        }
    }

    func save() {
        guard let id = selectedID, id > 0 else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Profile name cannot be empty"; return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let preset: [String: Any] = ["id": id, "name": trimmed, "data": draftData]
                _ = try await browser?.callAsyncJS(
                    "await BxCBridge.saveProfile(kind, preset); await BxCBridge.refreshProfiles(kind); return true;",
                    arguments: ["kind": kind.rawValue, "preset": preset]
                )
                message = "Saved"
                await reload()
            } catch {
                message = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    func deleteSelected() {
        guard let id = selectedID, id > 0 else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                _ = try await browser?.callAsyncJS(
                    "await BxCBridge.deleteProfile(kind, id); await BxCBridge.refreshProfiles(kind); return true;",
                    arguments: ["kind": kind.rawValue, "id": id]
                )
                selectedID = nil
                await reload()
                message = "Profile deleted"
            } catch {
                message = "Could not delete: \(error.localizedDescription)"
            }
        }
    }

    func makeActive() {
        guard let id = selectedID else { return }
        Task {
            do {
                _ = try await browser?.callAsyncJS(
                    "return await BxCBridge.selectProfile(kind, id);",
                    arguments: ["kind": kind.rawValue, "id": id]
                )
                activeID = id
                message = "Active profile changed"
            } catch {
                message = "Could not activate: \(error.localizedDescription)"
            }
        }
    }

    private func loadDraft() {
        guard let profile = selectedProfile else {
            draftName = ""
            draftData = [:]
            return
        }
        draftName = profile.name
        draftData = profile.data
    }

    // MARK: - Mapping helpers

    func mappingArray(_ key: String) -> [String] {
        let mapping = draftData["mapping"] as? [String: Any] ?? [:]
        return (mapping[key] as? [Any] ?? []).compactMap { $0 as? String }
    }

    func setMappingArray(_ key: String, codes: [String]) {
        var mapping = draftData["mapping"] as? [String: Any] ?? [:]
        let clean = codes.filter { !$0.isEmpty }
        if clean.isEmpty { mapping.removeValue(forKey: key) } else { mapping[key] = Array(clean.prefix(2)) }
        draftData["mapping"] = mapping
        objectWillChange.send()
    }

    func shortcut(_ action: String) -> [String: Any]? {
        let mapping = draftData["mapping"] as? [String: Any] ?? [:]
        return mapping[action] as? [String: Any]
    }

    func setShortcut(_ action: String, code: String?, modifiers: Int = 0) {
        var mapping = draftData["mapping"] as? [String: Any] ?? [:]
        if let code, !code.isEmpty {
            var record: [String: Any] = ["code": code]
            if modifiers != 0 { record["modifiers"] = modifiers }
            // One keyboard combination must perform only one action.
            for key in mapping.keys {
                guard let old = mapping[key] as? [String: Any] else { continue }
                if old["code"] as? String == code, (old["modifiers"] as? NSNumber)?.intValue ?? 0 == modifiers {
                    mapping.removeValue(forKey: key)
                }
            }
            mapping[action] = record
        } else {
            mapping.removeValue(forKey: action)
        }
        draftData["mapping"] = mapping
        objectWillChange.send()
    }

    func controllerAction(_ button: String) -> String {
        let mapping = draftData["mapping"] as? [String: Any] ?? [:]
        return mapping[button] as? String ?? ""
    }

    func setControllerAction(_ button: String, action: String) {
        var mapping = draftData["mapping"] as? [String: Any] ?? [:]
        if action.isEmpty { mapping.removeValue(forKey: button) } else { mapping[button] = action }
        draftData["mapping"] = mapping
        objectWillChange.send()
    }

    func customizationTarget(_ source: String) -> Int? {
        let mapping = draftData["mapping"] as? [String: Any] ?? [:]
        return (mapping[source] as? NSNumber)?.intValue
    }

    func setCustomizationTarget(_ source: String, target: Int?) {
        var mapping = draftData["mapping"] as? [String: Any] ?? [:]
        if let target { mapping[source] = target } else { mapping.removeValue(forKey: source) }
        draftData["mapping"] = mapping
        objectWillChange.send()
    }

    func mouseNumber(_ key: String, default fallback: Double) -> Double {
        let mouse = draftData["mouse"] as? [String: Any] ?? [:]
        return (mouse[key] as? NSNumber)?.doubleValue ?? fallback
    }

    func setMouseNumber(_ key: String, value: Double) {
        var mouse = draftData["mouse"] as? [String: Any] ?? [:]
        mouse[key] = value
        draftData["mouse"] = mouse
        objectWillChange.send()
    }

    func customizationNumber(_ key: String, default fallback: Double) -> Double {
        let settings = draftData["settings"] as? [String: Any] ?? [:]
        return (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    func setCustomizationNumber(_ key: String, value: Double) {
        var settings = draftData["settings"] as? [String: Any] ?? [:]
        settings[key] = value
        draftData["settings"] = settings
        objectWillChange.send()
    }
}

// MARK: - Key capture

struct KeyCaptureField: NSViewRepresentable {
    var value: String
    var onCapture: (String, Int) -> Void

    func makeNSView(context: Context) -> KeyCaptureTextField {
        let field = KeyCaptureTextField()
        field.placeholderString = "Click, then press a key"
        field.stringValue = value
        field.onCapture = onCapture
        return field
    }

    func updateNSView(_ field: KeyCaptureTextField, context: Context) {
        field.stringValue = value
        field.onCapture = onCapture
    }
}

final class KeyCaptureTextField: NSTextField {
    var onCapture: ((String, Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape clears/cancels.
            window?.makeFirstResponder(nil)
            return
        }
        let code = Self.code(for: event)
        var modifiers = 0
        if event.modifierFlags.contains(.control) { modifiers |= 1 }
        if event.modifierFlags.contains(.shift) { modifiers |= 2 }
        if event.modifierFlags.contains(.option) { modifiers |= 4 }
        stringValue = Self.display(code: code, modifiers: modifiers)
        onCapture?(code, modifiers)
        window?.makeFirstResponder(nil)
    }

    static func display(code: String, modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & 1 != 0 { parts.append("⌃") }
        if modifiers & 2 != 0 { parts.append("⇧") }
        if modifiers & 4 != 0 { parts.append("⌥") }
        parts.append(code.replacingOccurrences(of: "Key", with: "").replacingOccurrences(of: "Digit", with: ""))
        return parts.joined()
    }

    static func code(for event: NSEvent) -> String {
        // Match KeyboardEvent.code strings consumed by Better xCloud.
        let map: [UInt16: String] = [
            0:"KeyA",1:"KeyS",2:"KeyD",3:"KeyF",4:"KeyH",5:"KeyG",6:"KeyZ",7:"KeyX",8:"KeyC",9:"KeyV",
            11:"KeyB",12:"KeyQ",13:"KeyW",14:"KeyE",15:"KeyR",16:"KeyY",17:"KeyT",18:"Digit1",19:"Digit2",
            20:"Digit3",21:"Digit4",22:"Digit6",23:"Digit5",24:"Equal",25:"Digit9",26:"Digit7",27:"Minus",
            28:"Digit8",29:"Digit0",30:"BracketRight",31:"KeyO",32:"KeyU",33:"BracketLeft",34:"KeyI",35:"KeyP",
            36:"Enter",37:"KeyL",38:"KeyJ",39:"Quote",40:"KeyK",41:"Semicolon",42:"Backslash",43:"Comma",
            44:"Slash",45:"KeyN",46:"KeyM",47:"Period",48:"Tab",49:"Space",50:"Backquote",51:"Backspace",
            53:"Escape",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",
            115:"Home",116:"PageUp",117:"Delete",119:"End",121:"PageDown",123:"ArrowLeft",124:"ArrowRight",
            125:"ArrowDown",126:"ArrowUp"
        ]
        return map[event.keyCode] ?? event.charactersIgnoringModifiers ?? "Unknown"
    }
}

// MARK: - Views

struct ProfileEditorView: View {
    @ObservedObject var model: ProfileEditorModel

    private let gamepadInputs: [(String, String)] = [
        ("0","A"),("1","B"),("2","X"),("3","Y"),("4","LB"),("5","RB"),("6","LT"),("7","RT"),
        ("8","View"),("9","Menu"),("10","L3"),("11","R3"),("12","D-pad Up"),("13","D-pad Down"),
        ("14","D-pad Left"),("15","D-pad Right"),("16","Home/PS"),("100","Left Stick Up"),
        ("101","Left Stick Down"),("102","Left Stick Left"),("103","Left Stick Right"),
        ("200","Right Stick Up"),("201","Right Stick Down"),("202","Right Stick Left"),("203","Right Stick Right")
    ]

    private let shortcutActions: [(String, String)] = [
        ("bx.settings.show", "Show Settings"),("mkb.toggle", "Toggle Mouse & Keyboard"),
        ("stream.screenshot.capture", "Take Screenshot"),("stream.video.toggle", "Toggle Video"),
        ("stream.sound.toggle", "Toggle Sound"),("stream.menu.show", "Show Stream Menu"),
        ("stream.stats.toggle", "Show/Hide Stats"),("stream.microphone.toggle", "Toggle Microphone"),
        ("stream.volume.inc", "Increase Stream Volume"),("stream.volume.dec", "Decrease Stream Volume"),
        ("controller.xbox.press", "Press Xbox Button"),("ta.open", "Open TrueAchievements")
    ]

    private let controllerShortcutButtons: [(String, String)] = [
        ("3","Y"),("0","A"),("2","X"),("1","B"),("12","D-pad Up"),("13","D-pad Down"),
        ("14","D-pad Left"),("15","D-pad Right"),("8","View"),("9","Menu"),("4","LB"),("5","RB"),
        ("6","LT"),("7","RT"),("10","L3"),("11","R3")
    ]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Spacer()
                            if model.activeID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            if profile.isBuiltIn { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(Optional(profile.id))
                    }
                }
                HStack {
                    Button(action: model.createProfile) { Image(systemName: "plus") }
                    Button(action: model.copySelected) { Image(systemName: "doc.on.doc") }.disabled(model.selectedID == nil)
                    Button(role: .destructive, action: model.deleteSelected) { Image(systemName: "trash") }.disabled(!model.canEdit)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            editor
        }
        .navigationTitle(model.kind.title)
        .frame(minWidth: 820, minHeight: 580)
        .background(.ultraThinMaterial)
        .onAppear { model.load() }
    }

    @ViewBuilder
    private var editor: some View {
        if model.selectedID == nil {
            ContentUnavailableView("No Profile Selected", systemImage: "keyboard")
        } else {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        TextField("Profile name", text: $model.draftName)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!model.canEdit)
                        Text(model.kind.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Make Active", action: model.makeActive)
                        .disabled(model.activeID == model.selectedID)
                    Button("Save", action: model.save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEdit || model.isBusy)
                }
                .padding()

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.canEdit {
                            Label("Built-in profiles are read-only. Use Copy to customize this profile.", systemImage: "lock.fill")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        switch model.kind {
                        case .mkb: mkbEditor
                        case .keyboard: keyboardEditor
                        case .controllerShortcuts: controllerShortcutEditor
                        case .controllerCustomization: customizationEditor
                        }
                    }
                    .padding()
                }

                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }

    private var mkbEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Mouse") {
                numericRow("Horizontal sensitivity", key: "sensitivityX", range: 1...300, fallback: 100)
                numericRow("Vertical sensitivity", key: "sensitivityY", range: 1...300, fallback: 100)
                numericRow("Deadzone counterweight", key: "deadzoneCounterweight", range: 1...50, fallback: 20)
            }
            GroupBox("Virtual controller mappings") {
                ForEach(gamepadInputs, id: \.0) { key, label in
                    HStack {
                        Text(label).frame(width: 130, alignment: .leading)
                        TextField("KeyboardEvent.code (up to two, comma separated)", text: Binding(
                            get: { model.mappingArray(key).joined(separator: ", ") },
                            set: { model.setMappingArray(key, codes: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEdit)
                    }
                }
            }
        }
    }

    private var keyboardEditor: some View {
        GroupBox("Keyboard shortcuts") {
            ForEach(shortcutActions, id: \.0) { action, label in
                let shortcut = model.shortcut(action)
                HStack {
                    Text(label).frame(width: 190, alignment: .leading)
                    KeyCaptureField(
                        value: shortcut.map { KeyCaptureTextField.display(code: $0["code"] as? String ?? "", modifiers: ($0["modifiers"] as? NSNumber)?.intValue ?? 0) } ?? "",
                        onCapture: { code, modifiers in model.setShortcut(action, code: code, modifiers: modifiers) }
                    )
                    .frame(height: 24)
                    .disabled(!model.canEdit)
                    Button("Clear") { model.setShortcut(action, code: nil) }.disabled(!model.canEdit || shortcut == nil)
                }
            }
        }
    }

    private var controllerShortcutEditor: some View {
        GroupBox("Home/PS + button shortcuts") {
            ForEach(controllerShortcutButtons, id: \.0) { button, label in
                HStack {
                    Text("Home/PS + \(label)").frame(width: 170, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.controllerAction(button) },
                        set: { model.setControllerAction(button, action: $0) }
                    )) {
                        Text("Unbound").tag("")
                        ForEach(shortcutActions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().disabled(!model.canEdit)
                }
            }
        }
    }

    private var customizationEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Button remapping") {
                ForEach(controllerShortcutButtons, id: \.0) { source, label in
                    HStack {
                        Text(label).frame(width: 120, alignment: .leading)
                        Picker("", selection: Binding<Int?>(
                            get: { model.customizationTarget(source) },
                            set: { model.setCustomizationTarget(source, target: $0) }
                        )) {
                            Text("Unchanged").tag(Optional<Int>.none)
                            ForEach(controllerShortcutButtons.compactMap { Int($0.0) == Int(source) ? nil : (Int($0.0)!, $0.1) }, id: \.0) {
                                Text($0.1).tag(Optional($0.0))
                            }
                        }
                        .labelsHidden().disabled(!model.canEdit)
                    }
                }
            }
            GroupBox("Controller response") {
                customizationSlider("Vibration intensity", key: "vibrationIntensity", fallback: 100)
            }
        }
    }

    private func numericRow(_ label: String, key: String, range: ClosedRange<Double>, fallback: Double) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { model.mouseNumber(key, default: fallback) }, set: { model.setMouseNumber(key, value: $0) }), in: range)
                .disabled(!model.canEdit)
            Text("\(Int(model.mouseNumber(key, default: fallback)))").frame(width: 42)
        }
    }

    private func customizationSlider(_ label: String, key: String, fallback: Double) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { model.customizationNumber(key, default: fallback) }, set: { model.setCustomizationNumber(key, value: $0) }), in: 0...100, step: 10)
                .disabled(!model.canEdit)
            Text("\(Int(model.customizationNumber(key, default: fallback)))%").frame(width: 44)
        }
    }
}
