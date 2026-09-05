import SwiftUI
import Combine

/// Selection and its draft change together. Only explicit edit bindings schedule a save.
@MainActor
final class AdaptiveTriggerPresetEditor: ObservableObject {
    struct Draft: Equatable {
        var selectedID: UUID?
        var name = ""
        var parameters = AdaptiveTriggerCustomParameters.default
    }

    @Published private(set) var draft = Draft()
    private var autosaveTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    deinit { autosaveTask?.cancel() }

    func cancelAutosave() {
        generation &+= 1
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    func flushDraft(store: InputPresetStore) {
        cancelAutosave()
        guard let id = draft.selectedID,
              var existing = store.customTriggerPresets.first(where: { $0.id == id }),
              existing.name != draft.name || existing.parameters.clamped != draft.parameters else { return }
        existing.name = draft.name
        existing.parameters = draft.parameters
        store.saveTriggerPreset(existing)
    }

    func select(_ id: UUID?, store: InputPresetStore) {
        if id != draft.selectedID { flushDraft(store: store) }
        cancelAutosave()
        if let id, let preset = store.customTriggerPresets.first(where: { $0.id == id }) {
            draft = Draft(selectedID: id, name: preset.name, parameters: preset.parameters.clamped)
        } else {
            draft = Draft()
        }
    }

    func editName(_ name: String, store: InputPresetStore) {
        guard name != draft.name else { return }
        draft.name = name
        scheduleAutosave(store: store)
    }

    func editParameters(_ edit: (inout AdaptiveTriggerCustomParameters) -> Void, store: InputPresetStore) {
        var parameters = draft.parameters
        edit(&parameters)
        parameters = parameters.clamped
        guard parameters != draft.parameters else { return }
        draft.parameters = parameters
        scheduleAutosave(store: store)
    }

    private func scheduleAutosave(store: InputPresetStore) {
        cancelAutosave()
        guard let id = draft.selectedID else { return }
        let captured = draft
        let token = generation
        autosaveTask = Task { @MainActor [weak self, weak store] in
            do { try await Task.sleep(nanoseconds: 600_000_000) }
            catch { return }
            guard let self, let store, !Task.isCancelled,
                  self.generation == token, self.draft.selectedID == id,
                  var existing = store.customTriggerPresets.first(where: { $0.id == id }) else { return }
            existing.name = captured.name
            existing.parameters = captured.parameters
            store.saveTriggerPreset(existing)
            // Reflect a normalized/uniquified name without scheduling another save.
            if let saved = store.customTriggerPresets.first(where: { $0.id == id }) {
                self.draft = Draft(selectedID: id, name: saved.name, parameters: saved.parameters.clamped)
            }
            self.autosaveTask = nil
        }
    }

    func save(store: InputPresetStore) {
        cancelAutosave()
        if let id = draft.selectedID {
            guard var existing = store.customTriggerPresets.first(where: { $0.id == id }) else { return }
            existing.name = draft.name
            existing.parameters = draft.parameters
            store.saveTriggerPreset(existing)
            select(id, store: store)
        } else {
            saveAs(store: store)
        }
    }

    func saveAs(store: InputPresetStore, duplicate: Bool = false) {
        cancelAutosave()
        // Copy the current draft, including edits still inside the debounce window.
        let name = duplicate ? draft.name + " Copy" : draft.name
        if let id = store.createTriggerPreset(named: name, parameters: draft.parameters) {
            select(id, store: store)
        }
    }

    func delete(store: InputPresetStore) {
        cancelAutosave()
        guard let id = draft.selectedID else { return }
        store.deleteTriggerPreset(id: id)
        if !store.customTriggerPresets.contains(where: { $0.id == id }) {
            select(nil, store: store)
        }
    }
}

struct AdaptiveTriggerPresetManager: View {
    @ObservedObject var service: ControllerFeatureService
    @ObservedObject var store: InputPresetStore
    @StateObject private var editor = AdaptiveTriggerPresetEditor()

    var body: some View {
        SettingsGroup("Custom Adaptive-Trigger Presets") {
            SettingsRow("Saved preset") {
                Picker("Saved preset", selection: Binding(
                    get: { editor.draft.selectedID },
                    set: { editor.select($0, store: store) }
                )) {
                    Text("New Preset").tag(Optional<UUID>.none)
                    ForEach(store.customTriggerPresets) { Text($0.name).tag(Optional($0.id)) }
                }.settingsPicker()
            }
            HStack {
                Spacer()
                Button("New") { editor.select(nil, store: store) }
                Button("Duplicate") { editor.saveAs(store: store, duplicate: true) }
                    .disabled(editor.draft.selectedID == nil)
            }.settingsRow()
            Divider()
            SettingsRow("Preset name", note: "Name and effect edits autosave to this library entry. Apply again to update a trigger's snapshot.") {
                TextField("Preset name", text: Binding(
                    get: { editor.draft.name },
                    set: { editor.editName($0, store: store) }
                )).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Divider()
            SettingsRow("Effect") {
                Picker("Effect", selection: parameter(\.mode)) {
                    ForEach(AdaptiveTriggerEffectMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.settingsPicker()
            }
            Text(editor.draft.parameters.mode.explanation)
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            TriggerEffectCurve(parameters: editor.draft.parameters)
                .padding(.vertical, 8)
            effectControls
            Divider()
            HStack {
                Button("Apply Left") { apply(to: .left) }
                Button("Apply Right") { apply(to: .right) }
                Spacer()
                Button("Preview") { service.previewAdaptiveTrigger(editor.draft.parameters) }
                Button("Stop") { service.stopTriggerPreview() }
            }.settingsRow()
            Divider()
            HStack {
                Spacer()
                Button(editor.draft.selectedID == nil ? "Save" : "Save / Rename") { editor.save(store: store) }
                Button("Save As New") { editor.saveAs(store: store) }
                Button("Delete", role: .destructive) { editor.delete(store: store) }
                    .disabled(editor.draft.selectedID == nil)
            }.settingsRow()
            Text("Library changes do not change applied triggers or saved input-preset snapshots. Switching entries saves pending edits to their original entry. Use Save to keep edits immediately.")
                .font(.caption).foregroundStyle(.secondary).settingsRow()
            if let message = store.operationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).settingsRow()
            }
        }
        .onReceive(store.$customTriggerPresets.map { $0.map(\.id) }.removeDuplicates()) { ids in
            if let id = editor.draft.selectedID, !ids.contains(id) {
                editor.select(nil, store: store)
            }
        }
        .onDisappear {
            editor.flushDraft(store: store)
            service.stopTriggerPreview()
        }
    }

    @ViewBuilder
    private var effectControls: some View {
        let mode = editor.draft.parameters.mode
        if mode != .off {
            Divider()
            slider("Start position", value: parameter(\.startPosition), range: mode.hasEndPosition ? 0...0.99 : 0...1)
        }
        if mode.hasEndPosition {
            Divider()
            slider("End position", value: parameter(\.endPosition), range: (editor.draft.parameters.startPosition + 0.01)...1)
        }
        if mode == .feedback || mode == .weapon || mode == .slopeFeedback || mode == .resistanceCurve {
            Divider()
            slider(mode == .slopeFeedback ? "Start strength" : "Resistance", value: parameter(\.startStrength))
        }
        if mode == .slopeFeedback || mode == .resistanceCurve || mode == .vibrationRamp {
            Divider()
            slider("End strength" , value: parameter(\.endStrength))
                .opacity(mode == .slopeFeedback || mode == .resistanceCurve ? 1 : 0)
                .accessibilityHidden(mode == .vibrationRamp)
        }
        if mode == .vibration || mode == .vibrationRamp {
            Divider()
            slider(mode == .vibrationRamp ? "Peak amplitude" : "Amplitude", value: parameter(\.amplitude))
            Divider()
            slider("Speed (relative)", value: parameter(\.frequency))
            Text("Speed is a normalized 0–1 control from slowest to fastest, not a value in Hz.")
                .font(.caption).foregroundStyle(.secondary).settingsRow()
        }
    }

    private func parameter<Value>(_ keyPath: WritableKeyPath<AdaptiveTriggerCustomParameters, Value>) -> Binding<Value> {
        Binding(get: { editor.draft.parameters[keyPath: keyPath] }, set: { value in
            editor.editParameters({ $0[keyPath: keyPath] = value }, store: store)
        })
    }

    private func slider(_ label: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1) -> some View {
        SettingsRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range).frame(width: 168).accessibilityLabel(label)
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }

    private func apply(to side: AdaptiveTriggerSide) {
        let draft = editor.draft
        let savedID = store.customTriggerPresets.first {
            $0.id == draft.selectedID && $0.parameters.clamped == draft.parameters.clamped
        }?.id
        service.updateSettings {
            $0.adaptiveTriggers.applySnapshot(draft.parameters, for: side, presetID: savedID)
        }
    }
}

/// Shared typed catalog for both Settings selectors. Observe the library directly
/// so a rename/create/delete refreshes options without requiring a controller event.
struct AdaptiveTriggerPresetSelector: View {
    let title: String
    let side: AdaptiveTriggerSide
    @ObservedObject var service: ControllerFeatureService
    @ObservedObject var store: InputPresetStore

    var body: some View {
        Picker(title, selection: Binding(
            get: { service.settings.adaptiveTriggers.selection(for: side, library: store.customTriggerPresets) },
            set: { selection in
                service.updateSettings {
                    $0.adaptiveTriggers.select(selection, for: side, library: store.customTriggerPresets)
                }
            }
        )) {
            ForEach(AdaptiveTriggerCategory.allCases) { category in
                Section(category.rawValue) {
                    ForEach(AdaptiveTriggerPreset.catalog(in: category), id: \.self) { preset in
                        Text(preset.htmlName).tag(AdaptiveTriggerSelection.builtIn(preset))
                    }
                }
            }
            if !store.customTriggerPresets.isEmpty {
                Section("Custom Presets") {
                    ForEach(store.customTriggerPresets) { preset in
                        Text(preset.name).tag(AdaptiveTriggerSelection.custom(preset.id))
                    }
                }
            }
            if service.settings.adaptiveTriggers.selection(for: side, library: store.customTriggerPresets) == .currentCustomSnapshot {
                Text("Current Custom Snapshot").tag(AdaptiveTriggerSelection.currentCustomSnapshot)
            }
        }.settingsPicker()
    }
}
