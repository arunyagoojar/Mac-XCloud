import SwiftUI

/// Inline editors deliberately do not run macros while Settings owns controller input.
struct ShortcutMacroEditor: View {
    @ObservedObject var service: ControllerFeatureService
    let installDefaults: () -> Void
    @State private var macroDraft: MacroEditorDraft?
    @State private var shortcutDraft: ShortcutEditorDraft?
    @State private var deletingMacro: ControllerMacro?
    @State private var deletingShortcut: ControllerShortcut?

    private var isEditing: Bool { macroDraft != nil || shortcutDraft != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create and save a macro, then assign it to one controller button or a chord in a shortcut. Save the shortcut and return focus to the gameplay window to use it. Native actions and game-button output are blocked while Settings owns input; there is no Settings Run preview.")
                .foregroundStyle(.secondary)
            Text("Changes save automatically to controller settings and the active input preset. Physical buttons may still reach the game, so choose a chord that will not interfere with gameplay. Macros have no loops or turbo: at most 16 steps and 2,000 ms including delays and haptics. Haptics require a supported controller.")
                .font(.caption).foregroundStyle(.secondary)
            shortcutList
            if let draft = shortcutDraft {
                ShortcutDraftForm(service: service, initial: draft) { shortcutDraft = nil }
                    .id(draft.id)
            }
            macroList
            if let draft = macroDraft {
                MacroDraftForm(service: service, initial: draft) { macroDraft = nil }
                    .id(draft.id)
            }
        }
        .alert("Delete macro?", isPresented: Binding(
            get: { deletingMacro != nil },
            set: { if !$0 { deletingMacro = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingMacro = nil }
            Button("Delete", role: .destructive) { deleteMacro() }
        } message: {
            Text("This deletes \(deletingMacro?.name ?? "the macro"). Any shortcuts or touchpad mappings that refer to it will be disabled and their actions cleared.")
        }
        .alert("Delete shortcut?", isPresented: Binding(
            get: { deletingShortcut != nil },
            set: { if !$0 { deletingShortcut = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingShortcut = nil }
            Button("Delete", role: .destructive) {
                guard let id = deletingShortcut?.id else { return }
                service.updateSettings { $0.shortcuts.shortcuts.removeAll { $0.id == id } }
                deletingShortcut = nil
            }
        } message: {
            Text("Delete \(deletingShortcut?.name ?? "this shortcut")? Its macro, if any, will be kept.")
        }
    }

    private var shortcutList: some View {
        SettingsGroup("Saved Shortcuts") {
            if service.settings.shortcuts.shortcuts.isEmpty {
                Text("No shortcuts yet. Create one to assign a macro or native action.")
                    .foregroundStyle(.secondary).settingsRow()
            }
            ForEach(service.settings.shortcuts.shortcuts) { shortcut in
                SettingsRow(shortcut.name, note: shortcutSummary(shortcut)) {
                    HStack(spacing: 8) {
                        Text(shortcut.isEnabled ? "On" : "Off").foregroundStyle(.secondary)
                        Button("Edit") { shortcutDraft = ShortcutEditorDraft(shortcut) }
                        Menu {
                            Button("Duplicate") { shortcutDraft = ShortcutEditorDraft(shortcut, duplicate: true) }
                            Button("Delete", role: .destructive) { deletingShortcut = shortcut }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 24)
                        .accessibilityLabel("More actions for \(shortcut.name)")
                    }.disabled(isEditing)
                }
                Divider()
            }
            SettingsRow("Hold L3 + R3 to open Settings", note: "Adds a default only if that chord and activation are not already assigned. Existing shortcuts are kept.") {
                Button("Add Default", action: installDefaults).disabled(isEditing)
            }
            Divider()
            HStack {
                Spacer()
                Button("New Shortcut") { shortcutDraft = ShortcutEditorDraft() }.disabled(isEditing)
            }.settingsRow()
        }
    }

    private var macroList: some View {
        SettingsGroup("Saved Macros") {
            if service.settings.macros.isEmpty {
                Text("No macros yet. Add button presses and releases, waits, haptics or native actions.")
                    .foregroundStyle(.secondary).settingsRow()
            }
            ForEach(service.settings.macros) { macro in
                SettingsRow(macro.name, note: "\(macro.steps.count) steps · \(macro.totalDurationMilliseconds) ms") {
                    HStack(spacing: 8) {
                        Button("Edit") { macroDraft = MacroEditorDraft(macro) }
                        Menu {
                            Button("Assign Shortcut") {
                                shortcutDraft = ShortcutEditorDraft(name: macro.name, action: .macro(id: macro.id))
                            }
                            Button("Duplicate") { macroDraft = MacroEditorDraft(macro, duplicate: true) }
                            Button("Delete", role: .destructive) { deletingMacro = macro }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 24)
                        .accessibilityLabel("More actions for \(macro.name)")
                    }.disabled(isEditing)
                }
                Divider()
            }
            HStack {
                Button("Double A Sample") { macroDraft = .doubleA }.disabled(isEditing)
                Spacer()
                Button("New Macro") { macroDraft = MacroEditorDraft() }.disabled(isEditing)
            }.settingsRow()
        }
    }

    private func shortcutSummary(_ shortcut: ControllerShortcut) -> String {
        let chord = ControllerControl.allCases.filter { shortcut.controls.contains($0) }
            .map(\.editorLabel).joined(separator: " + ")
        let activation: String
        switch shortcut.activation {
        case .press: activation = "Press"
        case .release: activation = "Release"
        case .hold(let seconds): activation = "Hold \(seconds) s"
        case .doublePress(let interval): activation = "Double press within \(interval) s"
        }
        return "\(activation) · \(chord.isEmpty ? "No buttons" : chord) → \(shortcut.action.editorLabel(macros: service.settings.macros))"
    }

    private func deleteMacro() {
        guard let id = deletingMacro?.id else { return }
        service.cancelMacro(id: id)
        service.updateSettings { settings in
            settings.macros.removeAll { $0.id == id }
            for index in settings.shortcuts.shortcuts.indices where settings.shortcuts.shortcuts[index].action == .macro(id: id) {
                settings.shortcuts.shortcuts[index].action = .none
                settings.shortcuts.shortcuts[index].isEnabled = false
            }
            for index in settings.touchpad.mappings.indices where settings.touchpad.mappings[index].action == .macro(id: id) {
                settings.touchpad.mappings[index].action = .none
                settings.touchpad.mappings[index].isEnabled = false
            }
        }
        deletingMacro = nil
    }
}

private enum EditorValidationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private struct MacroEditorDraft: Identifiable {
    var id = UUID()
    var existingID: UUID?
    var name = ""
    var steps: [MacroStepDraft] = []

    init() {}

    init(_ macro: ControllerMacro, duplicate: Bool = false) {
        id = duplicate ? UUID() : macro.id
        existingID = duplicate ? nil : macro.id
        name = macro.name + (duplicate ? " Copy" : "")
        steps = macro.steps.map { MacroStepDraft($0) }
    }

    static var doubleA: Self {
        var draft = Self()
        draft.name = "Double A"
        draft.steps = [
            MacroStepDraft(ControllerMacroStep(delayMilliseconds: 0, action: .button(control: .buttonA, isPressed: true))),
            MacroStepDraft(ControllerMacroStep(delayMilliseconds: 70, action: .button(control: .buttonA, isPressed: false))),
            MacroStepDraft(ControllerMacroStep(delayMilliseconds: 110, action: .button(control: .buttonA, isPressed: true))),
            MacroStepDraft(ControllerMacroStep(delayMilliseconds: 70, action: .button(control: .buttonA, isPressed: false)))
        ]
        return draft
    }

    func validated() throws -> ControllerMacro {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorValidationError.message("Enter a macro name.") }
        guard !steps.isEmpty else { throw EditorValidationError.message("Add at least one step.") }
        return try ControllerMacro(id: id, name: trimmed, steps: steps.map { try $0.validated() })
    }
}

private struct MacroStepDraft: Identifiable {
    enum Kind: String, CaseIterable {
        case press = "Button press", release = "Button release", wait = "Wait", haptic = "Haptic", native = "Native action"
    }
    var id = UUID()
    var kind = Kind.press
    var delay = "0"
    var control = ControllerControl.buttonA
    var intensity = "0.5"
    var sharpness = "0.5"
    var duration = "100"
    var action = ControllerNativeAction.toggleStats

    init() {}

    init(_ step: ControllerMacroStep) {
        delay = String(step.delayMilliseconds)
        switch step.action {
        case .button(let control, let isPressed):
            kind = isPressed ? .press : .release
            self.control = control
        case .haptic(let intensity, let sharpness, let duration):
            kind = .haptic
            self.intensity = String(intensity)
            self.sharpness = String(sharpness)
            self.duration = String(duration)
        case .nativeAction(let action):
            kind = action == .none ? .wait : .native
            self.action = action
        }
    }

    func validated() throws -> ControllerMacroStep {
        guard let delay = Int(delay.trimmingCharacters(in: .whitespacesAndNewlines)), (0...2_000).contains(delay) else {
            throw EditorValidationError.message("Each delay must be a whole number from 0 to 2,000 ms.")
        }
        let output: ControllerMacroAction
        switch kind {
        case .press, .release: output = .button(control: control, isPressed: kind == .press)
        case .wait: output = .nativeAction(.none) // Preserve the existing serialized schema.
        case .native: output = .nativeAction(action)
        case .haptic:
            guard let intensity = Float(intensity.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let sharpness = Float(sharpness.trimmingCharacters(in: .whitespacesAndNewlines)),
                  intensity.isFinite, sharpness.isFinite,
                  (0...1).contains(intensity), (0...1).contains(sharpness) else {
                throw EditorValidationError.message("Haptic intensity and sharpness must be finite numbers from 0 to 1 (use a decimal point).")
            }
            guard let duration = Int(duration.trimmingCharacters(in: .whitespacesAndNewlines)), (0...2_000).contains(duration) else {
                throw EditorValidationError.message("Haptic duration must be a whole number from 0 to 2,000 ms.")
            }
            output = .haptic(intensity: intensity, sharpness: sharpness, durationMilliseconds: duration)
        }
        return ControllerMacroStep(delayMilliseconds: delay, action: output)
    }
}

private struct MacroDraftForm: View {
    @ObservedObject var service: ControllerFeatureService
    @State private var draft: MacroEditorDraft
    @State private var error: String?
    let close: () -> Void

    init(service: ControllerFeatureService, initial: MacroEditorDraft, close: @escaping () -> Void) {
        self.service = service
        _draft = State(initialValue: initial)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(draft.existingID == nil ? "New Macro" : "Edit Macro") {
                SettingsRow("Name") { TextField("Macro name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 240) }
                Divider()
                SettingsRow("Limits", note: "Each delay runs before its action. Wait steps only delay. Include a release after each button press; any remaining virtual buttons are cleared when the macro ends.") {
                    Text(budgetLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach($draft.steps) { $step in
                MacroStepForm(step: $step, number: (draft.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1,
                              canMoveUp: draft.steps.first?.id != step.id,
                              canMoveDown: draft.steps.last?.id != step.id,
                              move: { moveStep(step.id, by: $0) },
                              remove: { draft.steps.removeAll { $0.id == step.id } })
            }
            SettingsGroup {
                HStack {
                    Button("Add Step") { draft.steps.append(MacroStepDraft()) }
                        .disabled(draft.steps.count >= ControllerMacro.maximumStepCount)
                    Spacer()
                    Button("Cancel", action: close)
                    Button("Save Macro", action: save).buttonStyle(.borderedProminent)
                }.settingsRow()
                if let error { Text(error).foregroundStyle(.red).font(.caption).settingsRow().accessibilityLabel("Validation error: \(error)") }
                Text("\(draft.steps.count) of 16 steps. Saving validates the complete draft before changing your saved macro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var budgetLabel: String {
        guard let macro = try? draft.validated() else { return "\(draft.steps.count)/16 steps · Check draft" }
        return "\(macro.steps.count)/16 · \(macro.totalDurationMilliseconds)/2,000 ms"
    }

    private func moveStep(_ id: UUID, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(index + offset) else { return }
        draft.steps.swapAt(index, index + offset)
    }

    private func save() {
        do {
            let macro = try draft.validated()
            if let existingID = draft.existingID, !service.settings.macros.contains(where: { $0.id == existingID }) {
                throw EditorValidationError.message("This macro is no longer in the active preset. Cancel and create a new macro.")
            }
            service.cancelMacro(id: macro.id)
            service.updateSettings { settings in
                if let index = settings.macros.firstIndex(where: { $0.id == macro.id }) { settings.macros[index] = macro }
                else { settings.macros.append(macro) }
            }
            close()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MacroStepForm: View {
    @Binding var step: MacroStepDraft
    let number: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        SettingsGroup("Step \(number)") {
            SettingsRow("Action") {
                Picker("Action", selection: $step.kind) {
                    ForEach(MacroStepDraft.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.settingsPicker()
            }
            Divider()
            SettingsRow(step.kind == .wait ? "Wait (ms)" : "Delay before action (ms)") {
                numberField("Delay in milliseconds", text: $step.delay)
            }
            switch step.kind {
            case .press, .release:
                SettingsRow("Controller button") {
                    Picker("Controller button", selection: $step.control) {
                        ForEach(ControllerControl.allCases, id: \.self) { Text($0.editorLabel).tag($0) }
                    }.settingsPicker()
                }
            case .wait: EmptyView()
            case .native:
                SettingsRow("Native action") {
                    EditorActionPicker(action: $step.action, macros: [], allowsMacros: false)
                }
            case .haptic:
                SettingsRow("Intensity (0–1)") { numberField("Intensity", text: $step.intensity) }
                SettingsRow("Sharpness (0–1)") { numberField("Sharpness", text: $step.sharpness) }
                SettingsRow("Duration (ms)") { numberField("Haptic duration in milliseconds", text: $step.duration) }
            }
            Divider()
            HStack {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(!canMoveUp).accessibilityLabel("Move step \(number) up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(!canMoveDown).accessibilityLabel("Move step \(number) down")
                Spacer()
                Button("Remove Step", action: remove)
            }.settingsRow()
        }
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text).textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing).frame(width: 100).accessibilityLabel(label)
    }
}

private struct ShortcutEditorDraft: Identifiable {
    enum Activation: String, CaseIterable {
        case press = "Press", release = "Release", hold = "Hold", doublePress = "Double press"
    }
    var id = UUID()
    var existingID: UUID?
    var name: String
    var controls: Set<ControllerControl> = []
    var activation = Activation.press
    var holdSeconds = "0.65"
    var doublePressSeconds = "0.3"
    var action: ControllerNativeAction
    var isEnabled = true

    init(name: String = "", action: ControllerNativeAction = .toggleSettings) {
        self.name = name
        self.action = action
    }

    init(_ shortcut: ControllerShortcut, duplicate: Bool = false) {
        id = duplicate ? UUID() : shortcut.id
        existingID = duplicate ? nil : shortcut.id
        name = shortcut.name + (duplicate ? " Copy" : "")
        controls = shortcut.controls
        action = shortcut.action
        // Avoid firing an extra identical mapping until a duplicate is configured.
        isEnabled = duplicate ? false : shortcut.isEnabled
        switch shortcut.activation {
        case .press: activation = .press
        case .release: activation = .release
        case .hold(let seconds): activation = .hold; holdSeconds = String(seconds)
        case .doublePress(let interval): activation = .doublePress; doublePressSeconds = String(interval)
        }
    }

    func validated(macros: [ControllerMacro]) throws -> ControllerShortcut {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorValidationError.message("Enter a shortcut name.") }
        let trigger: ShortcutActivation
        switch activation {
        case .press: trigger = .press
        case .release: trigger = .release
        case .hold, .doublePress:
            let text = activation == .hold ? holdSeconds : doublePressSeconds
            guard let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw EditorValidationError.message("Enter a timing value in seconds using a decimal point.")
            }
            trigger = activation == .hold ? .hold(seconds: seconds) : .doublePress(maximumInterval: seconds)
        }
        if case .macro(let id) = action, !macros.contains(where: { $0.id == id }) {
            throw EditorValidationError.message("The selected macro is missing. Choose a saved macro or another action.")
        }
        let shortcut = ControllerShortcut(id: id, name: trimmed, controls: controls, activation: trigger, action: action, isEnabled: isEnabled)
        try shortcut.validate()
        return shortcut
    }
}

private struct ShortcutDraftForm: View {
    @ObservedObject var service: ControllerFeatureService
    @State private var draft: ShortcutEditorDraft
    @State private var error: String?
    let close: () -> Void

    init(service: ControllerFeatureService, initial: ShortcutEditorDraft, close: @escaping () -> Void) {
        self.service = service
        _draft = State(initialValue: initial)
        self.close = close
    }

    var body: some View {
        SettingsGroup(draft.existingID == nil ? "New Shortcut" : "Edit Shortcut") {
            SettingsRow("Name") { TextField("Shortcut name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 240) }
            Divider()
            SettingsRow("Enabled") { Toggle("Enabled", isOn: $draft.isEnabled).labelsHidden().toggleStyle(.switch) }
            Divider()
            Text("Select one button, or several for a chord. All selected controls must be pressed together. Release fires when any chord button is released; double press requires releasing the chord between presses. Triggers count as pressed above halfway.")
                .font(.caption).foregroundStyle(.secondary).settingsRow()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(ControllerControl.allCases, id: \.self) { control in
                    Toggle(control.editorLabel, isOn: Binding(
                        get: { draft.controls.contains(control) },
                        set: { selected in
                            if selected { draft.controls.insert(control) } else { draft.controls.remove(control) }
                        }
                    )).toggleStyle(.checkbox)
                }
            }.padding(.vertical, 8)
            Divider()
            SettingsRow("Activation") {
                Picker("Activation", selection: $draft.activation) {
                    ForEach(ShortcutEditorDraft.Activation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.settingsPicker()
            }
            if draft.activation == .hold {
                SettingsRow("Hold duration (seconds)", note: "0.05–60 seconds") {
                    TextField("Hold duration", text: $draft.holdSeconds).textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            if draft.activation == .doublePress {
                SettingsRow("Maximum press interval (seconds)", note: "0.05–60 seconds") {
                    TextField("Double press interval", text: $draft.doublePressSeconds).textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            Divider()
            SettingsRow("Action", note: "Saved macros appear below native actions.") {
                EditorActionPicker(action: $draft.action, macros: service.settings.macros, allowsMacros: true)
            }
            Divider()
            if let error { Text(error).foregroundStyle(.red).font(.caption).settingsRow().accessibilityLabel("Validation error: \(error)") }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Save Shortcut", action: save).buttonStyle(.borderedProminent)
            }.settingsRow()
        }
    }

    private func save() {
        do {
            let shortcut = try draft.validated(macros: service.settings.macros)
            if let existingID = draft.existingID, !service.settings.shortcuts.shortcuts.contains(where: { $0.id == existingID }) {
                throw EditorValidationError.message("This shortcut is no longer in the active preset. Cancel and create a new shortcut.")
            }
            service.updateSettings { settings in
                if let index = settings.shortcuts.shortcuts.firstIndex(where: { $0.id == shortcut.id }) { settings.shortcuts.shortcuts[index] = shortcut }
                else { settings.shortcuts.shortcuts.append(shortcut) }
            }
            close()
        } catch { self.error = error.localizedDescription }
    }
}

private struct EditorActionPicker: View {
    @Binding var action: ControllerNativeAction
    let macros: [ControllerMacro]
    let allowsMacros: Bool
    private let nativeActions: [ControllerNativeAction] = [.none, .toggleSettings, .toggleFullscreen, .screenshot, .toggleStats, .volumeUp, .volumeDown, .mute]

    var body: some View {
        Picker("Action", selection: $action) {
            ForEach(nativeActions, id: \.self) { Text($0.editorLabel(macros: [])).tag($0) }
            // Keep legacy custom actions intact without offering unvalidated script identifiers.
            if case .custom = action { Text(action.editorLabel(macros: [])).tag(action) }
            if allowsMacros {
                ForEach(macros) { macro in Text("Macro: \(macro.name)").tag(ControllerNativeAction.macro(id: macro.id)) }
            }
            if case .macro(let id) = action, !allowsMacros || !macros.contains(where: { $0.id == id }) {
                Text(allowsMacros ? "Missing macro — choose another" : "Nested macro — choose another").tag(action)
            }
        }.settingsPicker()
    }
}

private extension ControllerControl {
    var editorLabel: String {
        switch self {
        case .buttonA: return "A / Cross"
        case .buttonB: return "B / Circle"
        case .buttonX: return "X / Square"
        case .buttonY: return "Y / Triangle"
        case .menu: return "Menu / Options"
        case .options: return "View / Share"
        case .home: return "Home / PS"
        case .leftShoulder: return "LB / L1"
        case .rightShoulder: return "RB / R1"
        case .leftStickButton: return "L3"
        case .rightStickButton: return "R3"
        case .dpadUp: return "D-pad Up"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .dpadRight: return "D-pad Right"
        case .touchpadButton: return "Touchpad Click"
        case .leftTrigger: return "LT / L2"
        case .rightTrigger: return "RT / R2"
        }
    }
}

private extension ControllerNativeAction {
    func editorLabel(macros: [ControllerMacro]) -> String {
        switch self {
        case .none: return "None"
        case .toggleSettings: return "Open Settings"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .screenshot: return "Screenshot"
        case .toggleStats: return "Toggle Stats"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Toggle Mute"
        case .custom(let identifier): return "Custom: \(identifier)"
        case .macro(let id): return macros.first(where: { $0.id == id }).map { "Macro: \($0.name)" } ?? "Missing macro"
        }
    }
}
