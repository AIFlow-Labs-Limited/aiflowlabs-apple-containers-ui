import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Default CPUs/memory for containers, the builder and machines → `config.toml` `[container]`, `[build]`, `[machine]`.
struct ResourcesSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var savedNeedsRestart = false

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    var body: some View {
        Form {
            resourceSection(
                "Containers", section: "container", note: "Applies to new containers without --cpus/--memory.")
            resourceSection("Builder", section: "build", note: "BuildKit builder VM. Restart the builder to apply.")
            resourceSection("Machines", section: "machine", note: "Default for new container machines.")
            Section {
                HStack {
                    if savedNeedsRestart {
                        Label("Restart the engine to apply", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.statusWarning)
                        Button("Restart engine") {
                            Task {
                                await model.stopEngine(); await model.startEngine(); savedNeedsRestart = false
                            }
                        }
                    }
                    Spacer()
                    Button("Revert") { text = original }.disabled(text == original)
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text == original || saving)
                }
            }
            if let error = model.system.lastError {
                ErrorBanner(error, dismiss: { model.system.clearError() })
            }
        }
        .formStyle(.grouped)
        .disabled(!loaded)
        .task { await load() }
    }

    private func resourceSection(_ title: String, section: String, note: String) -> some View {
        Section {
            LabeledContent("CPUs") {
                HStack {
                    Stepper(value: cpuBinding(section), in: 1...max(1, hostCPUs)) {
                        Text(cpuValue(section).map(String.init) ?? "Default").monospacedDigit()
                    }
                    Button("Default") { set(section, "cpus", nil) }
                        .buttonStyle(.borderless)
                        .disabled(cpuValue(section) == nil)
                }
            }
            LabeledContent("Memory") {
                HStack {
                    Stepper(value: memoryBinding(section), in: 1...max(1, hostMemoryGB)) {
                        Text(memoryValue(section).map { "\($0) GB" } ?? "Default").monospacedDigit()
                    }
                    Button("Default") { set(section, "memory", nil) }
                        .buttonStyle(.borderless)
                        .disabled(memoryValue(section) == nil)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: TOML plumbing

    private func cpuValue(_ section: String) -> Int? {
        TOMLEditor.value("cpus", section: section, in: text).flatMap(Int.init)
    }

    private func memoryValue(_ section: String) -> Int? {
        guard let raw = TOMLEditor.stringValue("memory", section: section, in: text),
            let size = MemorySize(parsing: raw)
        else { return nil }
        return Int(size.bytes >> 30)
    }

    private func cpuBinding(_ section: String) -> Binding<Int> {
        Binding(get: { cpuValue(section) ?? 4 }, set: { set(section, "cpus", String($0)) })
    }

    private func memoryBinding(_ section: String) -> Binding<Int> {
        Binding(get: { memoryValue(section) ?? 4 }, set: { set(section, "memory", "\"\($0)g\"") })
    }

    private func set(_ section: String, _ key: String, _ value: String?) {
        text = TOMLEditor.setting(key, to: value, section: section, in: text)
    }

    private func load() async {
        await model.system.loadConfigTOML()
        text = model.system.configTOML
        original = text
        loaded = true
    }

    private func save() async {
        saving = true
        if await model.system.saveConfigTOML(text) {
            original = text
            savedNeedsRestart = true
            model.toasts.success("Saved config.toml")
        }
        saving = false
    }
}
