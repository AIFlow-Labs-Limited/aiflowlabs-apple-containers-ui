import AppCore
import AppKit
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Ports tab: published ports (Open / Copy) and published Unix sockets.
struct ContainerPortsTab: View {
    let container: Container
    let actions: ContainerActions

    private var ports: [Container.PublishedPort] { container.configuration.publishedPorts }
    private var sockets: [Container.PublishedSocket] { container.configuration.publishedSockets }

    var body: some View {
        if ports.isEmpty && sockets.isEmpty {
            EmptyStateView(
                symbol: "point.3.connected.trianglepath.dotted", title: "No published ports",
                message: "Publish ports with -p when running a container (Run sheet → Ports).",
                actionTitle: "Run Similar With Ports…"
            ) { actions.runSimilar(container) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !ports.isEmpty {
                    Table(ports.map(PortRow.init)) {
                        TableColumn("Host") { r in
                            Text("\(r.port.hostAddress):\(String(r.port.hostPort))").font(.monoCaption)
                        }
                        .width(min: 120, ideal: 160)
                        TableColumn("Container") { r in
                            Text("\(String(r.port.containerPort))/\(r.port.proto)").font(.monoCaption)
                        }
                        .width(min: 90, ideal: 110)
                        TableColumn("Range") { r in
                            Text((r.port.count ?? 1) > 1 ? "×\(r.port.count ?? 1)" : "single").foregroundStyle(
                                .secondary)
                        }
                        .width(60)
                        TableColumn("URL") { r in
                            Text(r.port.hostURL?.absoluteString ?? emDash).font(.monoCaption).foregroundStyle(
                                .secondary)
                        }
                        .width(min: 140, ideal: 200)
                        TableColumn("") { r in
                            HStack(spacing: Spacing.s) {
                                Button("Open", systemImage: "safari") { actions.openInBrowser(r.port) }
                                    .disabled(r.port.proto != "tcp")
                                CopyButton(r.port.hostURL?.absoluteString ?? r.port.display, label: "Copy URL")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .width(110)
                    }
                    .alternatingRowBackgrounds(.disabled)
                    .accessibilityLabel("Published ports")
                }
                if !sockets.isEmpty {
                    InspectorSection("Published sockets") {
                        KeyValueGrid(sockets.map { ($0.containerPath, $0.hostPath) })
                    }
                    .padding(.horizontal, Spacing.l)
                }
            }
        }
    }

    private struct PortRow: Identifiable {
        let port: Container.PublishedPort
        var id: String { port.display }
    }
}

#Preview("Ports") {
    @Previewable @State var ui = ContainersUIState()
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let c = Container(
        id: "api",
        configuration: .init(
            id: "api",
            image: ImageReference(
                reference: "api", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
            creationDate: .now, initProcess: .init(executable: "uvicorn"),
            publishedPorts: [
                .init(hostPort: 18081, containerPort: 8080), .init(hostPort: 5353, containerPort: 53, proto: "udp"),
            ],
            publishedSockets: [.init(hostPath: "/tmp/api.sock", containerPath: "/run/api.sock")]))
    ContainerPortsTab(container: c, actions: ContainerActions(model: model, ui: ui))
        .frame(width: 800, height: 300)
}
