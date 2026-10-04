import SwiftUI

/// The Controller menu: quick motion actions and trigger effects.
struct ControllerCommands: Commands {
    let browser: BrowserModel

    var body: some Commands {
        CommandMenu("Controller") {
            Button("Recenter Steering") { browser.controllerFeatures.recenterSteering() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Calibrate Gyro") { browser.controllerFeatures.calibrateGyro() }
            Divider()
            Menu("Left Trigger Effect") { effects(for: .left) }
            Menu("Right Trigger Effect") { effects(for: .right) }
            Divider()
            Button("Controller Settings…") { browser.openSettingsWindow(route: .pane(.controller)) }
        }
    }

    @ViewBuilder
    private func effects(for side: AdaptiveTriggerSide) -> some View {
        ForEach(AdaptiveTriggerPreset.recommendedCatalog, id: \.self) { preset in
            Button(preset.htmlName) {
                browser.controllerFeatures.updateSettings { $0.adaptiveTriggers.select(preset, for: side) }
            }
        }
    }
}
