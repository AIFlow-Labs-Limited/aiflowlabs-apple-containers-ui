import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// "New machine" sheet built on `MachineForm`; the preview is `MachineSpec.cliArguments`, exactly what runs.
struct CreateMachineSheet: View {
    let localImages: [String]
    let create: (MachineSpec) -> Void

    private static let customTag = "__custom__"
    private let host = HostResources.current
    @State private var form: MachineForm
    @State private var imageChoice = MachineImageOption.verified.reference

    init(localImages: [String], existingNames: [String] = [], create: @escaping (MachineSpec) -> Void) {
        self.localImages = localImages
        self.create = create
        var form = MachineForm(existingNames: existingNames)
        // Don't propose a name that's taken: dev, dev-2, dev-3…
        if form.nameError != nil,
            let free = (2...99).lazy.map({ "dev-\($0)" }).first(where: { n in
                !existingNames.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
            })
        {
            form.name = free
        }
        _form = State(initialValue: form)
    }
    @State private var showAdvanced = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New container machine").font(.title2.bold())
            Form {
                Section {
                    TextField("Name", text: $form.name)
                        .accessibilityHint("Letters, digits, dash and underscore. No dots.")
                    FieldError(message: form.name.isEmpty ? nil : form.nameError)
                    imagePicker
                }
                Section("Resources") {
                    Stepper(value: $form.cpus, in: 1...host.cpus) {
                        LabeledContent("CPUs", value: "\(form.cpus) of \(host.cpus)")
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Memory", value: "\(form.memoryGB) GB of \(host.memoryGB) GB")
                        Slider(value: memoryBinding, in: 1...Double(host.memoryGB), step: 1)
                            .accessibilityLabel("Memory")
                            .accessibilityValue("\(form.memoryGB) gigabytes")
                        Text(
                            "Default is half your Mac's memory (\(host.machineDefaultMemoryGB) GB). Memory is only used as the machine needs it."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Home folder") {
                    Picker("Home folder", selection: $form.homeMount) {
                        ForEach(HomeMountMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(form.homeMount.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Set as default machine", isOn: $form.setDefault)
                    Toggle("Boot now", isOn: $form.bootNow)
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced }
                }
            }
            .formStyle(.grouped)
            CommandPreview(command: form.previewCommand())
            InfoCard(
                title: "A machine can read and change your home folder", symbol: "exclamationmark.shield",
                tint: .statusWarning
            ) {
                Text(
                    "It also gets your SSH agent, all Linux capabilities and passwordless sudo. Only use images you trust."
                )
            }
            HStack {
                Text("Creation streams into the Activity window.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(form.spec); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 600, height: 720)
    }

    private var memoryBinding: Binding<Double> {
        Binding(get: { Double(form.memoryGB) }, set: { form.memoryGB = Int($0.rounded()) })
    }

    @ViewBuilder
    private var imagePicker: some View {
        Picker("Image", selection: $imageChoice) {
            ForEach(MachineImageOption.curated) { Text($0.title).tag($0.reference) }
            Divider()
            Text("Custom image…").tag(Self.customTag)
        }
        .onChange(of: imageChoice) { _, choice in
            if choice != Self.customTag { form.image = choice } else if isCurated(form.image) { form.image = "" }
        }
        if imageChoice == Self.customTag {
            HStack {
                TextField("Image reference", text: $form.image, prompt: Text("registry/name:tag"))
                    .accessibilityLabel("Custom image reference")
                Menu("On this Mac") {
                    if localImages.isEmpty { Text("No local images") }
                    ForEach(localImages, id: \.self) { ref in Button(ref) { form.image = ref } }
                }
                .fixedSize()
                .help("Pick an image that's already on this Mac")
            }
        }
        if let option = MachineImageOption.curated.first(where: { $0.reference == form.imageReference }) {
            Label(option.note, systemImage: option.support == .verified ? "checkmark.seal" : "info.circle")
                .font(.caption)
                .foregroundStyle(option.support == .verified ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        } else if form.imageIsKnownBroken {
            brokenImageNotice
        } else if let error = form.imageError, !form.imageReference.isEmpty {
            FieldError(message: error)
        } else if !form.imageReference.isEmpty {
            Text(
                "Unverified image: it needs /sbin/init, /bin/sh and getent. If it doesn't boot, check the machine's Logs tab."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Blocks Docker Hub's alpine with the reason and a one-click switch to the verified image.
    private var brokenImageNotice: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            FieldError(message: form.imageError)
            Text(
                "Blocked: \(MachineImageOption.knownBrokenPatterns.joined(separator: ", ")). "
                    + "Apple's test image \(MachineImageOption.verified.reference) is the same distribution with a working init."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Use \(MachineImageOption.verified.reference)") {
                imageChoice = MachineImageOption.verified.reference
                form.image = MachineImageOption.verified.reference
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var advanced: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("You log in with your Mac user name; this CLI version has no option to change it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Nested virtualization", isOn: $form.virtualization)
            if form.virtualization {
                HStack {
                    TextField("Kernel", text: $form.kernelPath, prompt: Text("/path/to/vmlinux"))
                    Button("Choose…") { chooseKernel() }
                }
                FieldError(message: form.kernelError)
            }
            Text("Needs an M3 or later Mac and a kernel built with CONFIG_KVM=y.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.xs)
    }

    private func isCurated(_ ref: String) -> Bool { MachineImageOption.curated.contains { $0.reference == ref } }

    private func chooseKernel() {
        if let url = FilePanels.openFile(title: "Choose a Linux kernel built with CONFIG_KVM=y") {
            form.kernelPath = url.path(percentEncoded: false)
        }
    }
}

#Preview("Create machine") {
    CreateMachineSheet(
        localImages: ["ghcr.io/linuxcontainers/alpine:3.20", "docker.io/library/postgres:16-alpine"],
        existingNames: ["dev"]
    ) { _ in }
}
