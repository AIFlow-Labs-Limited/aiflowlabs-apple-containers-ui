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
                        Text(cpuValue(section).map(String.init) ?? defaultLabel(engineCPUs(section).map(String.init)))
                            .monospacedDigit()
                    }
                    Button("Default") { set(section, "cpus", nil) }
                        .buttonStyle(.borderless)
                        .disabled(cpuValue(section) == nil)
                }
            }
            LabeledContent("Memory") {
                HStack {
                    Stepper(value: memoryBinding(section), in: 1...max(1, hostMemoryGB)) {
                        Text(
                            memoryValue(section).map { "\($0) GB" }
                                ?? defaultLabel(engineMemoryGB(section).map { "\($0) GB" })
                        )
                        .monospacedDigit()
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

    // The engine's current values (`system property ls`) for keys config.toml leaves unset, so "Default" says what
    // it means and the stepper moves from it: it used to start at a hard-coded 4 (4 GB) whatever the default was.

    private func defaultLabel(_ value: String?) -> String { value.map { "Default (\($0))" } ?? "Default" }

    private func engineCPUs(_ section: String) -> Int? {
        let p = model.system.properties
        switch section {
        case "container": return p?.container?.cpus
        case "build": return p?.build?.cpus
        case "machine": return p?.machine?.cpus
        default: return nil
        }
    }

    private func engineMemoryGB(_ section: String) -> Int? {
        let p = model.system.properties
        let raw: String? =
            switch section {
            case "container": p?.container?.memory
            case "build": p?.build?.memory
            case "machine": p?.machine?.memory
            default: nil
            }
        guard let raw, let size = MemorySize(parsing: raw), size.bytes >= 1 << 30 else { return nil }
        return Int(size.bytes >> 30)
    }

    private func cpuBinding(_ section: String) -> Binding<Int> {
        Binding(
            get: { cpuValue(section) ?? engineCPUs(section) ?? 4 }, set: { set(section, "cpus", String($0)) })
    }

    private func memoryBinding(_ section: String) -> Binding<Int> {
        Binding(
            get: { memoryValue(section) ?? engineMemoryGB(section) ?? 4 },
            set: { set(section, "memory", "\"\($0)g\"") })
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
