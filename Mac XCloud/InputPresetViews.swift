import SwiftUI

/// Saved profiles: which one is in use, switching, and per-profile actions.
struct InputPresetManagerView: View {
    @ObservedObject var store: InputPresetStore
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var deleting: InputPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(footer: "When a game starts for the first time, it gets its own copy of your current settings. Changes you make while playing are saved to that game.") {
                SettingsToggleRow(label: "Remember settings for each game", isOn: $store.autoGameProfiles)
                Divider()
                SettingsRow("Now using", note: store.currentGameID.isEmpty ? nil
                            : "For \(store.currentGameTitle.isEmpty ? "this game" : store.currentGameTitle)") {
                    Text(store.activePreset.name).foregroundStyle(.secondary)
                }
            }
            SettingsGroup("Profiles") {
                ForEach(Array(store.presets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { Divider() }
                    row(preset)
                }
                Divider()
                HStack(spacing: 8) {
                    Button("Import…", action: store.importPresetFile)
                    Spacer()
                    Button("New Profile…") { newName = ""; creating = true }
                        .disabled(store.isBusy)
                }
                .controlSize(.small)
                .settingsRow()
            }
            if let message = store.operationMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .alert("Rename Profile", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Rename") {
                guard let id = renameID else { return }
                renameID = nil
                store.renamePreset(id: id, name: renameText)
            }
        }
        .alert("New Profile", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { let name = newName; Task { await store.createPreset(named: name) } }
        } message: {
            Text("The new profile starts from your current settings.")
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let id = deleting?.id else { return }
                deleting = nil
                Task { await store.deletePreset(id: id) }
            }
        } message: {
            Text("Games that used this profile return to Default.")
        }
    }

    private func row(_ preset: InputPreset) -> some View {
        let active = store.activePresetID == preset.id
        return HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.5))
                .font(.system(size: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).lineLimit(1)
                Text(preset.isDefault ? "Used when a game has no profile" : "Updated \(preset.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !active {
                Button("Use") { Task { await store.applyPreset(id: preset.id) } }
                    .controlSize(.small)
                    .disabled(store.isBusy)
            }
            Menu {
                Button("Save Current Settings to Profile") { Task { await store.updatePreset(id: preset.id) } }
                if !preset.isDefault {
                    Button("Rename…") { renameID = preset.id; renameText = preset.name }
                }
                Button("Duplicate") { store.duplicatePreset(id: preset.id) }
                Button("Export…") { store.exportPresetFile(id: preset.id) }
                if !preset.isDefault {
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = preset }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(preset.name)")
        }
        .settingsRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preset.name)\(active ? ", in use" : "")")
    }
}

/// Where profiles live on disk.
struct ProfileFilesView: View {
    @ObservedObject var store: InputPresetStore

    var body: some View {
        SettingsGroup(footer: "Profiles are plain JSON files you can back up or move to another Mac.") {
            SettingsRow("Profile folder", note: store.storageStatus.detail) {
                Button("Show in Finder", action: store.revealStorage)
                    .controlSize(.small)
                    .disabled(store.storageStatus.directoryURL == nil)
            }
        }
    }
}
