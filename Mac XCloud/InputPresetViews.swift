import SwiftUI

struct InputPresetManagerView: View {
    @ObservedObject var store: InputPresetStore
    @State private var newName = ""
    @State private var renameID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Each preset captures native controller settings and the selected Better xCloud mouse, keyboard, shortcut, and controller-remapping profiles. It is never tied to a game.")
                .foregroundStyle(.secondary)

            storageCard

            SettingsGroup("Save & Create Profiles") {
                SettingsRow("Active profile", note: store.activePreset.name) {
                    Button("Save Current Profile") { Task { await store.updatePreset(id: store.activePresetID) } }
                        .disabled(store.isBusy)
                }
                Divider()
                SettingsRow("Default preset", note: "Default can be updated but cannot be renamed or deleted.") {
                    Button("Save Current as Default") { Task { await store.saveCurrentAsDefault() } }
                        .disabled(store.isBusy)
                }
                Divider()
                SettingsRow("New preset name") {
                    TextField("Preset name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                HStack {
                    Spacer()
                    Button("Create New Profile") {
                        let name = newName
                        newName = ""
                        Task { await store.createPreset(named: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                }.settingsRow()
            }

            SettingsGroup("Input Presets") {
                ForEach(Array(store.presets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        SettingsSymbol(name: preset.isDefault ? "lock.fill" : "slider.horizontal.3",
                                       color: preset.isDefault ? .gray : .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).fontWeight(store.activePresetID == preset.id ? .semibold : .regular)
                            Text(preset.isDefault ? "Protected name · update with Save Current as Default" : "Native controller + Better xCloud input profiles")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if store.activePresetID == preset.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Active preset")
                        }
                        Button("Select") { Task { await store.applyPreset(id: preset.id) } }
                            .disabled(store.activePresetID == preset.id || store.isBusy)
                        if !preset.isDefault {
                            Menu {
                                Button("Update from Current Settings") { Task { await store.updatePreset(id: preset.id) } }
                                Button("Rename…") { renameID = preset.id; renameText = preset.name }
                                Button("Duplicate") { store.duplicatePreset(id: preset.id) }
                                Divider()
                                Button("Delete", role: .destructive) { Task { await store.deletePreset(id: preset.id) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("Actions for \(preset.name)")
                        }
                    }
                    .settingsRow()
                }
            }

            if let message = store.operationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Rename Preset", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") {
                guard let id = renameID else { return }
                renameID = nil
                store.renamePreset(id: id, name: renameText)
            }
        }
    }

    private var storageCard: some View {
        SettingsGroup("Local Storage") {
            SettingsRow("Stored on this Mac", note: store.storageStatus.detail) {
                SettingsSymbol(name: "externaldrive.fill", color: .gray)
            }
            Divider()
            HStack {
                Spacer()
                Button("Reload", action: store.reloadFromDisk)
                Button("Show Local Folder", action: store.revealStorage)
                    .disabled(store.storageStatus.directoryURL == nil)
            }.settingsRow()
        }
    }
}
