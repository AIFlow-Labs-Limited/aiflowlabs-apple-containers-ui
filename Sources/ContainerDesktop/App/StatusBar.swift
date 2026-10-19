import AppCore
import DesignSystem
import SwiftUI

/// Bottom bar: engine state + version, running count, total CPU/RAM, disk used/reclaimable, "Clean up…".
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private var memoryHelp: String {
        let system = model.containers.systemMemoryBytes
        let base = "Memory used by your running containers"
        guard system > 0 else { return base }
        return base + " (system containers such as the builder use \(ByteCount.format(system)) more)"
    }

    var body: some View {
        HStack(spacing: Spacing.l) {
            HStack(spacing: Spacing.xs) {
                StatusDot(model.engine.color, label: nil)
                Text("Engine \(model.engine.label.lowercased())")
                if let version = model.engine.version {
                    Text("v\(version)").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            if model.engine.isRunning {
                Divider().frame(height: 12)
                Label("\(model.containers.runningCount) running", systemImage: "shippingbox")
                Label("CPU \(Percent.format(model.containers.totalCPUPercent))", systemImage: "cpu")
                    .monospacedDigit()
                    .help("Total CPU of your running containers (100% = one core)")
                Label("RAM \(ByteCount.format(model.containers.totalMemoryBytes))", systemImage: "memorychip")
                    .monospacedDigit()
                    .help(memoryHelp)
            }

            Spacer(minLength: Spacing.s)

            if model.engine.isRunning, let df = model.system.diskUsage {
                Label(
                    "Disk \(ByteCount.format(df.totalBytes)) · \(ByteCount.format(df.reclaimableBytes)) reclaimable",
                    systemImage: "internaldrive"
                )
                .monospacedDigit()
                Button("Clean up…") { model.navigation.isCleanupOpen = true }
                    .controlSize(.small)
                    .help("Remove stopped containers, unused images, volumes and networks")
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal, Spacing.m)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
