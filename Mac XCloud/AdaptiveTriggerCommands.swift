import SwiftUI
import Combine

@MainActor
final class TriggerLibraryMenuModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    @Published private(set) var items: [Item] = []
    private var subscription: AnyCancellable?

    init(store: InputPresetStore) {
        subscription = store.$customTriggerPresets
            .map { $0.map { Item(id: $0.id, name: $0.name) } }
            .removeDuplicates()
            .sink { [weak self] in self?.items = $0 }
    }
}

struct AdaptiveTriggerCommands: Commands {
    let service: ControllerFeatureService
    let store: InputPresetStore
    @StateObject private var library: TriggerLibraryMenuModel

    init(service: ControllerFeatureService, store: InputPresetStore) {
        self.service = service
        self.store = store
        _library = StateObject(wrappedValue: TriggerLibraryMenuModel(store: store))
    }

    var body: some Commands {
        CommandMenu("Left Trigger") { modes(for: .left) }
        CommandMenu("Right Trigger") { modes(for: .right) }
    }

    @ViewBuilder
    private func modes(for side: AdaptiveTriggerSide) -> some View {
        ForEach(AdaptiveTriggerPreset.allCases, id: \.self) { preset in
            Button(preset.htmlName) { select(.builtIn(preset), side: side) }
        }
        if !library.items.isEmpty {
            Divider()
            Text("Saved custom presets")
            ForEach(library.items) { item in
                Button(item.name) { select(.custom(item.id), side: side) }
            }
        }
    }

    private func select(_ selection: AdaptiveTriggerSelection, side: AdaptiveTriggerSide) {
        service.updateSettings {
            $0.adaptiveTriggers.select(selection, for: side, library: store.customTriggerPresets)
        }
    }
}
