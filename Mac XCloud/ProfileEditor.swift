//
//  ProfileEditor.swift
//  Mac XCloud
//
//  Native editors for Better xCloud's IndexedDB profile stores.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Profile types

enum ProfileKind: String, CaseIterable, Identifiable, Hashable {
    case controllerShortcuts = "controller-shortcuts"
    case controllerCustomization = "controller-customization"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controllerShortcuts: "Controller Shortcut Profiles"
        case .controllerCustomization: "Controller Remapping Profiles"
        }
    }

    var subtitle: String {
        switch self {
        case .controllerShortcuts: "Assign Home/PS + button shortcuts."
        case .controllerCustomization: "Remap buttons and stick axes, disable controls, and tune deadzones, trigger ranges, and rumble."
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

    private var intendedPresetID: UUID? { browser?.inputPresets.activePresetID }

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
        case .controllerShortcuts:
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
        let presetID = intendedPresetID
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
                browser?.inputPresets.noteBetterXCloudInputChanged(for: presetID)
            } catch {
                message = "Could not create profile: \(error.localizedDescription)"
            }
        }
    }

    func save() {
        guard let id = selectedID, id > 0 else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Profile name cannot be empty"; return }
        let presetID = intendedPresetID
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
                browser?.inputPresets.noteBetterXCloudInputChanged(for: presetID)
            } catch {
                message = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    func deleteSelected() {
        guard let id = selectedID, id > 0 else { return }
        let presetID = intendedPresetID
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
                browser?.inputPresets.noteBetterXCloudInputChanged(for: presetID)
            } catch {
                message = "Could not delete: \(error.localizedDescription)"
            }
        }
    }

    func makeActive() {
        guard let id = selectedID else { return }
        let presetID = intendedPresetID
        Task {
            do {
                _ = try await browser?.callAsyncJS(
                    "return await BxCBridge.selectProfile(kind, id);",
                    arguments: ["kind": kind.rawValue, "id": id]
                )
                activeID = id
                message = "Active profile changed"
                browser?.inputPresets.noteBetterXCloudInputChanged(for: presetID)
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
        guard let value = mapping[source] else { return nil }
        if let enabled = value as? Bool, !enabled { return -1 }
        return (value as? NSNumber)?.intValue
    }

    func setCustomizationTarget(_ source: String, target: Int?) {
        var mapping = draftData["mapping"] as? [String: Any] ?? [:]
        if target == -1 { mapping[source] = false }
        else if let target { mapping[source] = target }
        else { mapping.removeValue(forKey: source) }
        draftData["mapping"] = mapping
        objectWillChange.send()
    }

    func customizationRange(_ key: String) -> [Double] {
        let settings = draftData["settings"] as? [String: Any] ?? [:]
        let raw = settings[key] as? [Any] ?? []
        guard raw.count >= 2,
              let lower = raw[0] as? NSNumber,
              let upper = raw[1] as? NSNumber else { return [0, 100] }
        return [lower.doubleValue, upper.doubleValue]
    }

    func setCustomizationRange(_ key: String, lower: Double? = nil, upper: Double? = nil) {
        var settings = draftData["settings"] as? [String: Any] ?? [:]
        var value = customizationRange(key)
        if let lower { value[0] = min(max(lower, 0), value[1]) }
        if let upper { value[1] = max(min(upper, 100), value[0]) }
        settings[key] = value.map { Int($0.rounded()) }
        draftData["settings"] = settings
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
        ("bx.settings.show", "Show Settings"),
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

    // Matches Better xCloud's ControllerCustomizationsManagerDialog.BUTTONS_ORDER.
    private let customizationControls: [(String, String)] = [
        ("0","A"),("1","B"),("2","X"),("3","Y"),("12","D-pad Up"),("15","D-pad Right"),
        ("13","D-pad Down"),("14","D-pad Left"),("4","LB"),("5","RB"),("6","LT"),("7","RT"),
        ("10","L3"),("11","R3"),("104","Left Stick Axes"),("204","Right Stick Axes"),
        ("8","View"),("9","Menu"),("17","Share")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
                Divider()
                editor
            }
        }
        .navigationTitle(model.kind.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.load() }
    }

    @ViewBuilder
    private var editor: some View {
        if model.selectedID == nil {
            VStack(spacing: 8) {
                Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary)
                Text("No Profile Selected").font(.headline)
                Text("Choose a profile from the sidebar.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            GroupBox("Button and axis remapping") {
                ForEach(customizationControls, id: \.0) { source, label in
                    HStack {
                        Text(label).frame(width: 140, alignment: .leading)
                        Picker("", selection: Binding<Int?>(
                            get: { model.customizationTarget(source) },
                            set: { model.setCustomizationTarget(source, target: $0) }
                        )) {
                            Text("Unchanged").tag(Optional<Int>.none)
                            Text("Disabled").tag(Optional(-1))
                            let sourceIsAxis = source == "104" || source == "204"
                            ForEach(customizationControls.compactMap { item -> (Int, String)? in
                                let itemIsAxis = item.0 == "104" || item.0 == "204"
                                guard sourceIsAxis == itemIsAxis, item.0 != source, let id = Int(item.0) else { return nil }
                                return (id, item.1)
                            }, id: \.0) {
                                Text($0.1).tag(Optional($0.0))
                            }
                        }
                        .labelsHidden().disabled(!model.canEdit)
                    }
                }
            }
            GroupBox("Controller response") {
                customizationSlider("Vibration intensity", key: "vibrationIntensity", fallback: 100)
                customizationRangeRow("Left trigger range", key: "leftTriggerRange")
                customizationRangeRow("Right trigger range", key: "rightTriggerRange")
                customizationRangeRow("Left stick deadzone", key: "leftStickDeadzone")
                customizationRangeRow("Right stick deadzone", key: "rightStickDeadzone")
            }
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

    private func customizationRangeRow(_ label: String, key: String) -> some View {
        let range = model.customizationRange(key)
        return HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Text("Min")
            Slider(value: Binding(
                get: { model.customizationRange(key)[0] },
                set: { model.setCustomizationRange(key, lower: $0) }
            ), in: 0...100, step: 1)
            .disabled(!model.canEdit)
            Text("\(Int(range[0]))").frame(width: 30)
            Text("Max")
            Slider(value: Binding(
                get: { model.customizationRange(key)[1] },
                set: { model.setCustomizationRange(key, upper: $0) }
            ), in: 0...100, step: 1)
            .disabled(!model.canEdit)
            Text("\(Int(range[1]))").frame(width: 30)
        }
    }
}
