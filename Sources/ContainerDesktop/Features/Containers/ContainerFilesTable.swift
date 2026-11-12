import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// The Files outline: one row per entry, sub-folders expand inline and load on demand.
struct ContainerFilesTable: View {
    @Bindable var files: ContainerFilesModel
    let actions: ContainerFileActions

    var body: some View {
        let rows = files.rows
        Table(of: ContainerFilesModel.Row.self, selection: $files.selection) {
            TableColumn("Name") { row in FileNameCell(row: row, files: files) }
                .width(min: 220, ideal: 380)
            TableColumn("Size") { row in
                Text(size(row)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 92, max: 120)
            TableColumn("Modified") { row in
                Text(row.entry?.modified.map(RelativeDate.absolute) ?? "").foregroundStyle(.secondary)
                    .help(row.entry?.modified.map { RelativeDate.format($0) } ?? "")
            }
            .width(min: 110, ideal: 150)
            TableColumn("Mode") { row in
                Text(row.entry?.modeString ?? "").font(.monoCaption).foregroundStyle(.secondary)
                    .help(row.entry.map { "chmod \($0.octalMode)" } ?? "")
            }
            .width(min: 84, ideal: 92, max: 110)
            TableColumn("Owner") { row in
                Text(row.entry?.ownerDescription ?? "").font(.monoCaption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 110)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .dropDestination(for: URL.self) { urls in actions.upload(urls, into: actions.dropFolder(for: row)) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenuItems(rows: ids.compactMap { id in rows.first { $0.id == id } }, files: files, actions: actions)
        } primaryAction: { ids in
            if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) { actions.open(row) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.upload(urls, into: files.path)
            return true
        }
        .onKeyPress(.space) {
            guard files.selection.count == 1, let row = rows.first(where: { files.selection.contains($0.id) }),
                row.entry?.kind == .file
            else { return .ignored }
            actions.open(row)
            return .handled
        }
        .onDeleteCommand { actions.requestDelete(selectedPaths(rows)) }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Empty folder", systemImage: "folder",
                    description: Text(
                        files.showHidden
                            ? "Drop files here to upload them." : "No visible files. Hidden files are not shown."))
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Files in \(files.path)")
    }

    private func selectedPaths(_ rows: [ContainerFilesModel.Row]) -> [String] {
        rows.filter { files.selection.contains($0.id) && $0.entry != nil }.map(\.path)
    }

    private func size(_ row: ContainerFilesModel.Row) -> String {
        guard let entry = row.entry else { return "" }
        return entry.kind == .file ? ByteCount.format(entry.size) : emDash
    }
}

/// Indented name with a disclosure chevron for folders, a type icon, link target and mount badge. Placeholder
/// rows (loading, error, truncated, empty) render here too.
private struct FileNameCell: View {
    let row: ContainerFilesModel.Row
    let files: ContainerFilesModel

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            switch row.content {
            case .entry(let entry): entryLabel(entry)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            case .failure(let error):
                SwiftUI.Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.statusError)
                Text(error.errorDescription ?? "Could not read this folder.")
                    .foregroundStyle(.secondary).lineLimit(1)
                    .help(error.maskedFailedCommand ?? "")
                Button("Retry") { Task { await files.load(row.path) } }
                    .buttonStyle(.borderless).controlSize(.small)
            case .truncated(let shown):
                SwiftUI.Image(systemName: "ellipsis").foregroundStyle(.secondary)
                Text("Showing the first \(shown) entries. Type a path to open a sub-folder directly.")
                    .foregroundStyle(.secondary).lineLimit(1)
            case .empty:
                Text("Empty").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func entryLabel(_ entry: ContainerFileEntry) -> some View {
        if entry.isBrowsable {
            let isExpanded = files.expanded.contains(row.path)
            Button {
                Task { await files.toggleExpanded(row.path) }
            } label: {
                SwiftUI.Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isExpanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
        SwiftUI.Image(systemName: symbol(entry))
            .foregroundStyle(entry.isBrowsable ? Color.accentColor : Color.secondary)
            .frame(width: 18)
            .accessibilityLabel(kindLabel(entry))
        Text(displayName(entry.name)).lineLimit(1).truncationMode(.middle)
            .help(row.path)
        if let target = entry.linkTarget {
            Text("→ \(displayName(target))").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if let mount = row.mount {
            TagBadge(mount.type.kind, tint: .statusRunning)
                .help("Mounted from \(mountSource(mount)); its contents live outside the container")
        }
    }

    /// Control characters would break the single-line cell; show them as `␤`-style pictures.
    private func displayName(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return name }
        var view = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let picture = scalar.value < 0x20 ? Unicode.Scalar(0x2400 + scalar.value) : nil
            view.append(scalar.value == 0x7F ? "\u{2421}" : (picture ?? scalar))
        }
        return String(view)
    }

    private func mountSource(_ mount: Container.Mount) -> String {
        if case .volume(let name, _) = mount.type { return "volume “\(name)”" }
        if case .tmpfs = mount.type { return "tmpfs" }
        return mount.source
    }

    private func symbol(_ entry: ContainerFileEntry) -> String {
        if row.mount != nil { return "externaldrive.fill" }
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return entry.linkPointsToDirectory ? "folder.badge.gearshape" : "link"
        case .file: return entry.permissions & 0o111 != 0 ? "terminal" : "doc"
        case .characterDevice, .blockDevice: return "internaldrive"
        case .fifo: return "arrow.left.arrow.right"
        case .socket: return "powerplug"
        case .unknown: return "questionmark.square"
        }
    }

    private func kindLabel(_ entry: ContainerFileEntry) -> String {
        if row.mount != nil { return "Mount point" }
        switch entry.kind {
        case .directory: return "Folder"
        case .symlink: return "Symbolic link"
        case .file: return entry.permissions & 0o111 != 0 ? "Executable" : "File"
        case .characterDevice, .blockDevice: return "Device"
        case .fifo: return "Named pipe"
        case .socket: return "Socket"
        case .unknown: return "Unknown"
        }
    }
}

/// Context menu for the selected rows (or, with nothing selected, for the current folder).
private struct FileMenuItems: View {
    let rows: [ContainerFilesModel.Row]
    let files: ContainerFilesModel
    let actions: ContainerFileActions

    var body: some View {
        let entries = rows.filter { $0.entry != nil }
        let paths = entries.map(\.path)
        if let row = entries.first, entries.count == 1, let entry = row.entry {
            if entry.isBrowsable {
                Button("Open", systemImage: "folder") { actions.open(row) }
                Button("Upload Here…", systemImage: "square.and.arrow.down") { actions.chooseUploads(into: row.path) }
                Button("New Folder Inside…", systemImage: "folder.badge.plus") {
                    actions.dialogs.namePrompt = .newFolder(in: row.path)
                }
            } else if entry.kind == .file {
                Button("Preview", systemImage: "eye") { actions.open(row) }
            }
            Button("Save to Mac…", systemImage: "square.and.arrow.up") { actions.save(paths) }
            Divider()
            Button("Copy Path") { actions.copyPaths(paths) }
            Button("Rename…", systemImage: "pencil") { actions.dialogs.namePrompt = .rename(path: row.path) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { actions.requestDelete(paths) }
        } else if !entries.isEmpty {
            Button("Save \(entries.count) Items to Mac…", systemImage: "square.and.arrow.up") { actions.save(paths) }
            Button("Copy Paths") { actions.copyPaths(paths) }
            Divider()
            Button("Delete \(entries.count) Items…", systemImage: "trash", role: .destructive) {
                actions.requestDelete(paths)
            }
        } else {
            Button("Upload Here…", systemImage: "square.and.arrow.down") { actions.chooseUploads(into: files.path) }
            Button("New Folder…", systemImage: "folder.badge.plus") {
                actions.dialogs.namePrompt = .newFolder(in: files.path)
            }
            Button("Copy Path") { actions.copyPaths([files.path]) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
        }
    }
}
