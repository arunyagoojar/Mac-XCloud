import SwiftUI

struct PingTestControl: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isPingingRegions {
                ProgressView().controlSize(.small)
                Text(model.pingStatusText ?? "Testing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let best = model.bestRegionResult {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("The best server for you is \(best.displayName)")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(best.averageMs) ms · lowest latency")
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
