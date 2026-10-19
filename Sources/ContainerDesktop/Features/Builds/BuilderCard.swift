import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// BuildKit builder status with Start (sized) / Stop / Reset.
struct BuilderCard: View {
    @Environment(AppModel.self) private var model
    @State private var showStartOptions = false
    @State private var confirmReset = false
    @State private var cpus = 2
    @State private var memoryGB = 2
    @State private var working = false

    private var store: BuildsStore { model.builds }
    private var builder: Container? { store.builder }
    private var hostCPUs: Int { model.system.status?.host?.cpus ?? ProcessInfo.processInfo.activeProcessorCount }

    private var statusText: String {
        guard let builder else { return "Not created" }
        return builder.isRunning ? "Running" : builder.state.displayName == "Exited" ? "Stopped" : builder.state.displayName
    }
    private var statusColor: Color {
        guard let builder else { return .statusStopped }
        return builder.isRunning ? .statusRunning : builder.state.statusColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "hammer.circle.fill").font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Builder").font(.headline)
                        HStack(spacing: Spacing.xs) {
                            StatusDot(statusColor)
                            Text(statusText).font(.callout)
                            if working { ProgressView().controlSize(.mini) }
                        }
                    }
                }
                Text(builder?.imageReference ?? "Created automatically on the first build, or start it now.")
                    .font(.monoCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(builder?.imageReference ?? "")
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Builder \(statusText)")
            MetricTile(title: "CPUs", value: builder.map { "\($0.configuration.resources.cpus)" } ?? emDash)
                .frame(width: 100)
            MetricTile(title: "Memory", value: builder.map { ByteCount.format($0.configuration.resources.memoryInBytes) } ?? emDash)
                .frame(width: 120)
            MetricTile(title: "IP", value: builder?.primaryIPv4 ?? emDash)
                .frame(width: 150)
            VStack(alignment: .leading, spacing: Spacing.s) {
                if store.builderRunning {
                    Button("Stop", systemImage: "stop.fill") { act { await store.stopBuilder() } }
                        .help("Stop the builder (keeps its cache)")
                } else {
                    Button("Start…", systemImage: "play.fill") { showStartOptions = true }
                        .buttonStyle(.borderedProminent)
                        .popover(isPresented: $showStartOptions, arrowEdge: .bottom) { startOptions }
                }
                Button("Reset…", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
                    .disabled(builder == nil)
                    .help("Stop and delete the builder, clearing the layer cache")
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 110, alignment: .leading)
            .disabled(working)
        }
        .padding(Spacing.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.large))
        .confirmDestructive(title: "Reset the builder?",
                            message: "Stops and deletes the BuildKit builder container “\(builder?.id ?? "buildkit")”. "
                                + "This clears the build layer cache; the next build starts from scratch. Images are kept.",
                            actionTitle: "Reset", isPresented: $confirmReset) {
            act {
                if store.builderRunning { await store.stopBuilder() }
                await store.resetBuilder()
            }
        }
        .onAppear(perform: loadDefaults)
    }

    private var startOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Start builder").font(.headline)
            Stepper("CPUs: \(cpus)", value: $cpus, in: 1...max(1, hostCPUs))
            Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: 1...64)
            Text("Sizing applies when the builder container is created; reset it to change an existing one.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
            HStack {
                Spacer()
                Button("Start") {
                    showStartOptions = false
                    let (c, m) = (cpus, MemorySize(bytes: Int64(memoryGB) << 30))
                    act { await store.startBuilder(cpus: c, memory: m) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await work()
            working = false
        }
    }

    private func loadDefaults() {
        if let c = builder?.configuration.resources.cpus ?? model.system.properties?.build?.cpus { cpus = c }
        if let bytes = builder?.configuration.resources.memoryInBytes { memoryGB = max(1, Int(bytes >> 30)) }
        else if let m = model.system.properties?.build?.memory.flatMap(MemorySize.init(parsing:)) { memoryGB = max(1, Int(m.bytes >> 30)) }
    }
}

#Preview("Builder card") {
    BuilderCard().appModelEnvironment(ResourcePreview.model()).padding().frame(width: 900)
}
