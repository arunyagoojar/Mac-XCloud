import SwiftUI

struct PingTestControl: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isPingingRegions {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let best = model.bestRegionResult {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(best.name) · \(best.averageMs) ms")
                        .font(.system(size: 12, weight: .medium))
                    Text("best of \(best.samples) samples")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Run test")
                    .font(.system(size: 13, weight: .medium))
            }
            if model.bestRegionResult != nil, !model.isPingingRegions {
                Button("Use Best") { model.useBestRegion() }
                    .buttonStyle(.borderedProminent)
            }
            Button(model.isPingingRegions ? "Stop" : "Test") {
                model.isPingingRegions ? model.stopRegionPing() : model.testRegions()
            }
            .buttonStyle(.bordered)
        }
    }
}
