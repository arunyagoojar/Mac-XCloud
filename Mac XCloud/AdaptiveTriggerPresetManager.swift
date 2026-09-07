import SwiftUI

struct AdaptiveTriggerPresetSelector: View {
    let title: String
    let side: AdaptiveTriggerSide
    @ObservedObject var service: ControllerFeatureService

    var body: some View {
        Picker(title, selection: Binding(
            get: { side == .left ? service.settings.adaptiveTriggers.leftPreset : service.settings.adaptiveTriggers.rightPreset },
            set: { selection in
                service.updateSettings {
                    $0.adaptiveTriggers.select(selection, for: side)
                }
            }
        )) {
            ForEach(AdaptiveTriggerPreset.recommendedCatalog, id: \.self) { preset in
                Text(preset.htmlName).tag(preset)
            }
            let current = side == .left ? service.settings.adaptiveTriggers.leftPreset : service.settings.adaptiveTriggers.rightPreset
            if !AdaptiveTriggerPreset.recommendedCatalog.contains(current) {
                Text("Previous: " + current.htmlName).tag(current)
            }
        }.settingsPicker()
        .help("Select a curated immersive preset for the adaptive trigger. These utilize native DualSense hardware modes.")
    }
}
