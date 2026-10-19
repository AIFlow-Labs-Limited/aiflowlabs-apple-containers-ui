import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Resources: CPUs stepper (1…host CPUs), memory slider (256 MB…host RAM) with presets, platform.
struct RunResourcesSection: View {
    @Binding var form: RunFormValues
    let hostCPUs: Int
    let hostMemoryMB: Double

    private var presets: [Double] { [512, 1024, 2048, 4096, 8192, 16384].filter { $0 <= hostMemoryMB } }

    var body: some View {
        Section("Resources") {
            Toggle("Custom CPU and memory limits", isOn: $form.customResources)
            if form.customResources {
                Stepper(value: $form.cpus, in: 1...max(1, hostCPUs)) {
                    LabeledContent("CPUs", value: "\(form.cpus) of \(hostCPUs)")
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    LabeledContent("Memory", value: ByteCount.format(Int64(form.memoryMB) << 20))
                    Slider(value: $form.memoryMB, in: 256...max(512, hostMemoryMB), step: 256) {
                        Text("Memory")
                    } minimumValueLabel: {
                        Text("256 MB").font(.caption2)
                    } maximumValueLabel: {
                        Text(ByteCount.format(Int64(hostMemoryMB) << 20)).font(.caption2)
                    }
                    .labelsHidden()
                    HStack(spacing: Spacing.xs) {
                        ForEach(presets, id: \.self) { mb in
                            Button(MemorySize(bytes: Int64(mb) << 20).cliArgument.uppercased()) { form.memoryMB = mb }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(form.memoryMB == mb ? .accentColor : nil)
                        }
                    }
                }
            }
            Picker("Platform", selection: $form.platform) {
                ForEach(RunFormValues.PlatformChoice.allCases) { Text($0.title).tag($0) }
            }
            if form.platform == .amd64 {
                Label("x86-64 images run under Rosetta and are slower than native arm64.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Network: default or a custom network, aliases, MAC address.
struct RunNetworkSection: View {
    @Binding var form: RunFormValues
    let networks: [String]

    var body: some View {
        Section("Network") {
            Picker("Network", selection: $form.network) {
                Text("default").tag("")
                ForEach(networks.filter { $0 != "default" }, id: \.self) { Text($0).tag($0) }
                if !form.network.isEmpty, !networks.contains(form.network) { Text(form.network).tag(form.network) }
            }
            TextField("Aliases", text: $form.aliases, prompt: Text("api, backend"))
            TextField("MAC address", text: $form.macAddress, prompt: Text("Automatic"))
        }
    }
}

/// Advanced: init, read-only, SSH agent, --rm, capabilities, shm, ulimits, extra args (labels are a sibling section).
struct RunAdvancedSection: View {
    @Binding var form: RunFormValues
    @Binding var expanded: Bool

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Toggle("Run an init process (--init)", isOn: $form.useInit)
                    Toggle("Read-only root filesystem", isOn: $form.readOnly)
                    Toggle("Forward SSH agent", isOn: $form.ssh)
                    Toggle("Remove when stopped (--rm)", isOn: $form.removeOnExit)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s)
                    {
                        row("Entrypoint", $form.entrypoint, "Image default")
                        row("Working dir", $form.workingDirectory, "Image default")
                        row("User", $form.user, "uid[:gid] or name")
                        row("Add capabilities", $form.capAdd, "NET_ADMIN, SYS_PTRACE")
                        row("Drop capabilities", $form.capDrop, "ALL")
                        row("Shared memory", $form.shmSize, "64m")
                        row("Ulimits", $form.ulimits, "nofile=65536:65536")
                        row("Extra arguments", $form.extraArguments, "--dns 1.1.1.1")
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.top, Spacing.s)
            }
        }
    }

    private func row(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(label, text: text, prompt: Text(prompt))
                .font(.monoBody)
                .labelsHidden()
        }
    }
}
