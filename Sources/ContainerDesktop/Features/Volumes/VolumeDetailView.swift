import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Volume inspector: key facts, "Used by" deep links, reveal / copy actions.
struct VolumeDetailView: View {
    let volume: Volume
    let usedBy: [Container]
    let delete: () -> Void

    private var journal: String { volume.configuration.options["journal"] ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(volume.name).font(.title3.bold()).textSelection(.enabled).lineLimit(2)
                    if volume.isAnonymous { TagBadge("anonymous") }
                }
                HStack {
                    Button("Reveal in Finder", systemImage: "folder") { FilePanels.reveal([volume.configuration.source]) }
                    Button("Copy -v flag", systemImage: "doc.on.doc") { copyToPasteboard(VolumeRow.mountFlag(volume.name)) }
                        .help(VolumeRow.mountFlag(volume.name))
                    Spacer()
                    Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
                        .disabled(!usedBy.isEmpty)
                        .help(usedBy.isEmpty ? "Delete this volume" : "Mounted by \(usedBy.map(\.id).joined(separator: ", "))")
                }
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
                InspectorSection("Volume") {
                    KeyValueGrid([
                        ("Driver", volume.configuration.driver),
                        ("Format", volume.configuration.format),
                        ("Max size", ByteCount.format(volume.configuration.sizeInBytes)),
                        ("Journal", journal),
                        ("Created", RelativeDate.absolute(volume.configuration.creationDate)),
                        ("Backing file", volume.configuration.source),
                    ])
                }
                if !volume.configuration.labels.isEmpty {
                    InspectorSection("Labels") {
                        KeyValueGrid(volume.configuration.labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                    }
                }
                InspectorSection("Used by") {
                    if usedBy.isEmpty {
                        Text("No container mounts this volume.").foregroundStyle(.secondary)
                    } else {
                        ContainerLinks(containers: usedBy)
                    }
                }
                Text("Max size is the cap of a sparse disk image; the file on disk only grows with the data written.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.l)
        }
    }
}

/// Create volume: validated name, optional size, ext4 journal mode (+ size), labels.
struct CreateVolumeSheet: View {
    enum Journal: String, CaseIterable, Identifiable {
        case `default`, ordered, writeback, journal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .default: return "Default"
            case .ordered: return "Ordered"
            case .writeback: return "Writeback (fastest, least safe)"
            case .journal: return "Journal (safest, slowest)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    let didCreate: (String) -> Void
    @State private var name = ""
    @State private var size = ""
    @State private var journal = Journal.default
    @State private var journalSize = ""
    @State private var labels: [String] = []

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameProblem: String? {
        if let p = ResourceValidator.resourceName(trimmedName) { return p }
        return model.volumes.items.contains { $0.name == trimmedName } ? "A volume with that name exists." : nil
    }
    private var sizeValue: MemorySize? { MemorySize(parsing: size) }
    private var sizeProblem: String? { !size.isEmpty && sizeValue == nil ? "Use a size like 10g or 512m." : nil }
    private var journalSizeProblem: String? {
        !journalSize.isEmpty && MemorySize(parsing: journalSize) == nil ? "Use a size like 64m." : nil
    }
    private var journalArgument: String? {
        guard journal != .default else { return nil }
        guard let js = MemorySize(parsing: journalSize), !journalSize.isEmpty else { return journal.rawValue }
        return "\(journal.rawValue):\(js.cliArgument)"
    }
    private var canSubmit: Bool {
        nameProblem == nil && sizeProblem == nil && journalSizeProblem == nil
            && StringRowsEditor.allValid(labels) { ResourceValidator.keyValue($0) }
    }

    var body: some View {
        FormSheet(title: "Create volume", actionTitle: "Create", canSubmit: canSubmit, submit: submit) {
            TextField("Name", text: $name, prompt: Text("pgdata"))
            if !name.isEmpty, let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.statusError) }
            TextField("Max size", text: $size, prompt: Text("default (512g)"))
            if let sizeProblem { Text(sizeProblem).font(.caption).foregroundStyle(.statusError) }
            Picker("Journal mode", selection: $journal) {
                ForEach(Journal.allCases) { Text($0.title).tag($0) }
            }
            if journal != .default {
                TextField("Journal size", text: $journalSize, prompt: Text("optional, e.g. 64m"))
                if let journalSizeProblem { Text(journalSizeProblem).font(.caption).foregroundStyle(.statusError) }
            }
            LabeledContent("Labels") {
                StringRowsEditor("Label", rows: $labels, placeholder: "key=value", addTitle: "Add label") {
                    ResourceValidator.keyValue($0)
                }
            }
            Text("Size is the maximum of a sparse ext4 disk image; it only uses what is written.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func submit() {
        let name = trimmedName
        let size = sizeValue
        let journal = journalArgument
        let labels = ResourceValidator.labels(from: labels)
        Task {
            if await model.volumes.create(name: name, size: size, journal: journal, labels: labels) {
                model.toasts.success("Created volume \(name)")
                didCreate(name)
            }
        }
    }
}

#Preview("Create volume") {
    CreateVolumeSheet { _ in }.appModelEnvironment(ResourcePreview.model())
}
