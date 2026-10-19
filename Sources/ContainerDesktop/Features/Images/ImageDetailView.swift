import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Image inspector: Overview · Variants · Config · Layers.
struct ImageDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", variants = "Variants", config = "Config", layers = "Layers"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let image: ContainerKit.Image
    let usedBy: [Container]
    let run: () -> Void
    @State private var tab = Tab.overview
    @State private var variantIndex = 0

    private var variant: ContainerKit.Image.Variant? {
        image.variants.indices.contains(variantIndex) ? image.variants[variantIndex] : image.variants.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], Spacing.l)
                .padding(.bottom, Spacing.s)
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.s)
            if (tab == .config || tab == .layers) && image.variants.count > 1 {
                Picker("Variant", selection: $variantIndex) {
                    ForEach(image.variants.indices, id: \.self) { i in Text(image.variants[i].platform.slug).tag(i) }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.s)
            }
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .overview: overview
                    case .variants: variants
                    case .config: ImageConfigSection(config: variant?.config)
                    case .layers: ImageLayersSection(config: variant?.config)
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: image.reference) { variantIndex = 0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(image.reference).font(.title3.bold()).textSelection(.enabled).lineLimit(2)
            HStack {
                PlatformBadges(image: image)
                Spacer()
                Button("Run…", systemImage: "play.fill", action: run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open the run sheet in Containers")
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            InspectorSection("Overview") {
                KeyValueGrid([
                    ("Reference", image.reference),
                    ("Index digest", image.configuration.descriptor.digest),
                    ("Media type", image.configuration.descriptor.mediaType),
                    ("Created", RelativeDate.absolute(image.created)),
                    ("Total size", ByteCount.format(image.totalSize)),
                    ("Platforms", image.platforms.map(\.slug).joined(separator: ", ")),
                    ("Registry", ImageReferenceName.registry(of: image.reference)),
                ])
            }
            InspectorSection("Used by") {
                if usedBy.isEmpty {
                    Text("No containers use this image.").foregroundStyle(.secondary)
                } else {
                    ContainerLinks(containers: usedBy)
                }
            }
        }
    }

    private var variants: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(Array(image.variants.enumerated()), id: \.offset) { _, v in
                InspectorSection(v.platform.slug) {
                    KeyValueGrid([
                        ("Digest", v.digest),
                        ("Size", ByteCount.format(v.size)),
                        ("OS / arch", "\(v.config?.os ?? v.platform.os) / \(v.config?.architecture ?? v.platform.architecture)"
                            + (v.platform.variant.map { " (\($0))" } ?? "")),
                        ("Created", v.config?.created.map(RelativeDate.absolute) ?? ""),
                    ])
                }
            }
            if image.variants.isEmpty { Text("No variant information.").foregroundStyle(.secondary) }
        }
    }
}

/// Deep links to containers in the Containers section.
struct ContainerLinks: View {
    @Environment(AppModel.self) private var model
    let containers: [Container]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(containers, id: \.id) { c in
                Button {
                    model.navigation.open(.containers, select: c.id)
                } label: {
                    HStack(spacing: Spacing.s) {
                        StatusDot(c.state.statusColor, label: c.state.displayName)
                        Text(c.id).fontWeight(.medium)
                        Text(c.state.displayName).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Show \(c.id) in Containers")
                .accessibilityLabel("Show container \(c.id), \(c.state.displayName)")
            }
        }
    }
}

#Preview("Image detail") {
    let model = ResourcePreview.model()
    let backend = MockPreviewImage.first
    ImageDetailView(image: backend, usedBy: [], run: {})
        .appModelEnvironment(model)
        .frame(width: 420, height: 600)
}

/// A fixture image for previews.
@MainActor
enum MockPreviewImage {
    static var first: ContainerKit.Image {
        let desc = Descriptor(digest: "sha256:" + String(repeating: "ab", count: 32), mediaType: "application/vnd.oci.image.index.v1+json", size: 500)
        return ContainerKit.Image(id: String(repeating: "ab", count: 32), configuration: .init(name: "docker.io/library/alpine:3.22",
                                  creationDate: .now, descriptor: desc),
                                  variants: [.init(platform: .arm64, digest: desc.digest, size: 4_000_000),
                                             .init(platform: .amd64, digest: desc.digest, size: 4_100_000)])
    }
}
