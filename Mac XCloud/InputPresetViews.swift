import SwiftUI

struct InputPresetManagerView: View {
    @ObservedObject var store: InputPresetStore
    @State private var newName = ""
    @State private var renameID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Input Presets")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Each preset captures native controller settings and the selected Better xCloud mouse, keyboard, shortcut, and controller-remapping profiles. It is never tied to a game.")
                .foregroundStyle(.secondary)

            storageCard

            HStack {
                Button("Save Current as Default") { Task { await store.saveCurrentAsDefault() } }
                    .disabled(store.isBusy)
                Text("Default can be updated but cannot be renamed or deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                TextField("Preset name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("Capture Current Settings") {
                    let name = newName
                    newName = ""
                    Task { await store.createPreset(named: name) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
            }

            ForEach(store.presets) { preset in
                HStack(spacing: 10) {
                    Image(systemName: preset.isDefault ? "lock.fill" : "slider.horizontal.3")
                        .foregroundStyle(preset.isDefault ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).fontWeight(store.activePresetID == preset.id ? .semibold : .regular)
                        Text(preset.isDefault ? "Protected name · update with Save Current as Default" : "Native controller + Better xCloud input profiles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.activePresetID == preset.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
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
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
        HStack {
            Image(systemName: "externaldrive.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Stored in this Mac").font(.headline)
                Text(store.storageStatus.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Reload", action: store.reloadFromDisk)
            Button("Show Local Folder", action: store.revealStorage)
                .disabled(store.storageStatus.directoryURL == nil)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
