import SwiftUI
import AppKit
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Mounts tab: bind / volume / tmpfs mounts with Reveal in Finder (binds) and Open volume (deep link).
struct ContainerMountsTab: View {
    let container: Container
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let id: Int
        let mount: Container.Mount
    }

    private var rows: [Row] { container.configuration.mounts.enumerated().map { Row(id: $0.offset, mount: $0.element) } }

    var body: some View {
        if rows.isEmpty {
            EmptyStateView(symbol: "externaldrive", title: "No mounts",
                           message: "This container has no bind mounts, volumes or tmpfs mounts.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("Type") { row in TagBadge(row.mount.type.kind, tint: tint(row.mount.type)) }
                    .width(70)
                TableColumn("Source") { row in
                    Text(source(row.mount)).font(.monoCaption).lineLimit(1).truncationMode(.middle)
                        .help(row.mount.source).textSelection(.enabled)
                }
                .width(min: 160, ideal: 320)
                TableColumn("Destination") { row in Text(row.mount.destination).font(.monoCaption).textSelection(.enabled) }
                    .width(min: 100, ideal: 180)
                TableColumn("Mode") { row in Text(row.mount.isReadOnly ? "RO" : "RW").foregroundStyle(row.mount.isReadOnly ? .orange : .secondary) }
                    .width(44)
                TableColumn("") { row in actionButton(row.mount) }
                    .width(130)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityLabel("Mounts")
        }
    }

    private func source(_ mount: Container.Mount) -> String {
        if case .volume(let name, _) = mount.type { return name }
        if case .tmpfs = mount.type { return "tmpfs" }
        return (mount.source as NSString).abbreviatingWithTildeInPath
    }

    private func tint(_ type: Container.MountType) -> Color {
        switch type {
        case .bind: return .accentColor
        case .volume: return .statusRunning
        case .tmpfs: return .statusWarning
        case .other: return .secondary
        }
    }

    @ViewBuilder
    private func actionButton(_ mount: Container.Mount) -> some View {
        switch mount.type {
        case .bind:
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: mount.source)])
            }
            .buttonStyle(.borderless).controlSize(.small)
        case .volume(let name, _):
            Button("Open Volume", systemImage: "arrow.right.circle") { model.navigation.open(.volumes, select: name) }
                .buttonStyle(.borderless).controlSize(.small)
        default:
            EmptyView()
        }
    }
}

#Preview("Mounts") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let c = Container(id: "web", configuration: .init(
        id: "web", image: ImageReference(reference: "nginx", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
        creationDate: .now, initProcess: .init(executable: "nginx"),
        mounts: [.init(destination: "/usr/share/nginx/html", source: "/Users/me/site", options: ["ro"], type: .bind),
                 .init(destination: "/data", source: "/vol/data.img", type: .volume(name: "data", format: "ext4")),
                 .init(destination: "/tmp", source: "", type: .tmpfs(options: [:]))]))
    ContainerMountsTab(container: c)
        .appModelEnvironment(model)
        .frame(width: 900, height: 300)
}
