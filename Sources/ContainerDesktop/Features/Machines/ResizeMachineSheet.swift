import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// "Resize…": `container machine set -n NAME cpus=N memory=Mg`. The new size applies on the next boot,
/// so after saving we explain that and offer to stop a running machine.
struct ResizeMachineSheet: View {
    let machine: Machine
    let save: (Int, Int) async -> Bool
    let stop: () async -> Void

    private let host = HostResources.current
    @State private var cpus: Int
    @State private var memoryGB: Int
    @State private var phase = Phase.editing
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case editing, saving, saved }

    init(machine: Machine, save: @escaping (Int, Int) async -> Bool, stop: @escaping () async -> Void) {
        self.machine = machine
        self.save = save
        self.stop = stop
        let host = HostResources.current
        _cpus = State(initialValue: min(max(1, machine.cpus), host.cpus))
        _memoryGB = State(initialValue: min(max(1, Int(machine.memory >> 30)), host.memoryGB))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Resize “\(machine.name)”").font(.title2.bold())
            if phase == .saved { savedView } else { editor }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Form {
                Stepper(value: $cpus, in: 1...host.cpus) {
                    LabeledContent("CPUs", value: "\(cpus) (now \(machine.cpus))")
                }
                VStack(alignment: .leading) {
                    LabeledContent("Memory", value: "\(memoryGB) GB (now \(ByteCount.format(machine.memory)))")
                    Slider(value: Binding(get: { Double(memoryGB) }, set: { memoryGB = Int($0.rounded()) }),
                           in: 1...Double(host.memoryGB), step: 1)
                        .accessibilityLabel("Memory")
                        .accessibilityValue("\(memoryGB) gigabytes")
                }
                CommandPreview(command: MachineResize.previewCommand(
                    name: machine.name, settings: MachineResize.settings(cpus: cpus, memoryGB: memoryGB)))
            }
            .formStyle(.grouped)
            Text("The new size applies the next time the machine boots.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    phase = .saving
                    Task {
                        if await save(cpus, memoryGB) { phase = .saved } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(phase == .saving || (cpus == machine.cpus && Int64(memoryGB) << 30 == machine.memory))
            }
        }
    }

    private var savedView: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            InfoCard(title: "Saved — applies on next boot", symbol: "arrow.clockwise.circle") {
                Text(machine.isRunning
                     ? "“\(machine.name)” keeps its current size until it restarts. Stop it now and it boots with \(cpus) CPUs and \(memoryGB) GB the next time you open a terminal."
                     : "“\(machine.name)” boots with \(cpus) CPUs and \(memoryGB) GB the next time you open a terminal.")
            }
            HStack {
                Spacer()
                if machine.isRunning {
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Stop Now") { Task { await stop(); dismiss() } }
                        .keyboardShortcut(.defaultAction)
                        .help("Stops \(machine.name); terminal sessions end. Files are kept.")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

#Preview("Resize machine") {
    ResizeMachineSheet(machine: Machine(id: "dev", status: .running, cpus: 4, memory: 8 << 30, diskSize: 1 << 30, isDefault: true),
                       save: { _, _ in true }, stop: {})
}
