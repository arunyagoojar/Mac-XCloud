import SwiftUI

struct AdaptiveTriggerPresetManager: View {
    @ObservedObject var service: ControllerFeatureService
    @ObservedObject var store: InputPresetStore
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var parameters = AdaptiveTriggerCustomParameters.default
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isLoadingSelection = false

    var body: some View {
        GroupBox("Custom adaptive-trigger presets") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Saved preset", selection: $selectedID) {
                        Text("New Preset").tag(Optional<UUID>.none)
                        ForEach(store.customTriggerPresets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Load") { loadSelected() }.disabled(selectedID == nil)
                    Button("New") { selectedID = nil; name = ""; parameters = .default }
                    Button("Duplicate") {
                        if let selectedID, let newID = store.duplicateTriggerPreset(id: selectedID) {
                            self.selectedID = newID
                            loadSelected()
                        }
                    }.disabled(selectedID == nil)
                }
                TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                Picker("Effect", selection: $parameters.mode) {
                    ForEach(AdaptiveTriggerEffectMode.allCases, id: \.self) { Text(effectName($0)).tag($0) }
                }
                slider("Start position", value: $parameters.startPosition)
                slider("End position", value: $parameters.endPosition)
                slider("Start strength", value: $parameters.startStrength)
                slider("End strength", value: $parameters.endStrength)
                slider("Amplitude", value: $parameters.amplitude)
                slider("Frequency", value: $parameters.frequency)
                HStack {
                    Button("Apply Left") { service.updateSettings { $0.adaptiveTriggers.leftUsesCustom = true; $0.adaptiveTriggers.leftCustom = parameters.clamped } }
                    Button("Apply Right") { service.updateSettings { $0.adaptiveTriggers.rightUsesCustom = true; $0.adaptiveTriggers.rightCustom = parameters.clamped } }
                    Button("Preview") { preview() }
                    Button("Stop") { service.stopTriggerPreview() }
                    Spacer()
                    Button("Save / Rename") { save() }
                    Button("Delete", role: .destructive) {
                        if let selectedID { store.deleteTriggerPreset(id: selectedID); self.selectedID = nil; name = ""; parameters = .default }
                    }.disabled(selectedID == nil)
                }
            }
        }
        .onChange(of: name) { _, _ in scheduleAutosave() }
        .onChange(of: parameters) { _, _ in scheduleAutosave() }
        .onDisappear {
            autosaveTask?.cancel()
            service.stopTriggerPreview()
        }
    }

    private func slider(_ label: String, value: Binding<Float>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 42)
        }
    }

    private func effectName(_ mode: AdaptiveTriggerEffectMode) -> String {
        switch mode {
        case .off: "Off"
        case .feedback: "Feedback"
        case .weapon: "Weapon"
        case .vibration: "Vibration"
        case .slopeFeedback: "Slope Feedback"
        }
    }

    private func preview() {
        service.previewAdaptiveTrigger(parameters)
    }

    private func loadSelected() {
        guard let selectedID, let preset = store.customTriggerPresets.first(where: { $0.id == selectedID }) else { return }
        autosaveTask?.cancel()
        isLoadingSelection = true
        name = preset.name
        parameters = preset.parameters
        isLoadingSelection = false
    }

    private func scheduleAutosave() {
        guard !isLoadingSelection, let selectedID else { return }
        autosaveTask?.cancel()
        let currentName = name
        let currentParameters = parameters
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, self.selectedID == selectedID,
                  let existing = store.customTriggerPresets.first(where: { $0.id == selectedID }) else { return }
            var updated = existing
            updated.name = currentName
            updated.parameters = currentParameters
            store.saveTriggerPreset(updated)
        }
    }
    private func save() {
        if let selectedID,
           let existing = store.customTriggerPresets.first(where: { $0.id == selectedID }) {
            var updated = existing
            updated.name = name
            updated.parameters = parameters
            store.saveTriggerPreset(updated)
        } else if let id = store.createTriggerPreset(named: name, parameters: parameters) {
            selectedID = id
            loadSelected()
        }
    }
}
