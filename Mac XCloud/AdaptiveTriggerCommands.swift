import SwiftUI

struct AdaptiveTriggerCommands: Commands {
    let service: ControllerFeatureService

    init(service: ControllerFeatureService) {
        self.service = service
    }

    var body: some Commands {
        CommandMenu("Left Trigger") { modes(for: .left) }
        CommandMenu("Right Trigger") { modes(for: .right) }
    }

    @ViewBuilder
    private func modes(for side: AdaptiveTriggerSide) -> some View {
        ForEach(AdaptiveTriggerPreset.recommendedCatalog, id: \.self) { preset in
            Button(preset.htmlName) { select(preset, side: side) }
        }
    }

    private func select(_ selection: AdaptiveTriggerPreset, side: AdaptiveTriggerSide) {
        service.updateSettings {
            $0.adaptiveTriggers.select(selection, for: side)
        }
    }
}
