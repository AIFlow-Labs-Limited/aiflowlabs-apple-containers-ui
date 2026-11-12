import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// "Load image…": `container <k8s|cluster> load-image --name CLUSTER [--platform P] REF`, streamed via TaskCenter.
/// Only presented when the installed CLI has `load-image` (container 1.7 dropped it for the shared image store).
struct LoadImageSheet: View {
    let cluster: String
    let localImages: [String]
    /// What the installed CLI's Kubernetes plugin supports; picks the command word for the preview.
    var capabilities: KubernetesCapabilities = .legacy
    let load: (String, Platform?) -> Void

    /// `load-image` takes one platform; native or Rosetta are the useful choices.
    private static let choices: [PlatformChoice] = [.native, .amd64]

    @State private var reference = ""
    @State private var platform = PlatformChoice.native

    var body: some View {
        FormSheet(
            title: "Load an image into “\(cluster)”", actionTitle: "Load",
            canSubmit: !reference.trimmingCharacters(in: .whitespaces).isEmpty,
            submit: { load(reference.trimmingCharacters(in: .whitespaces), platform.single) }
        ) {
            if localImages.isEmpty {
                TextField("Image", text: $reference, prompt: Text("my-svc:v1"))
                Text("No images on this Mac yet — build or pull one first.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Image", selection: $reference) {
                    Text("Choose…").tag("")
                    ForEach(localImages, id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("Platform", selection: $platform) {
                ForEach(Self.choices) { Text($0.title).tag($0) }
            }
            CommandPreview(
                command: LoadImageCommand.preview(
                    cluster: cluster, reference: reference, platform: platform.single, capabilities: capabilities))
            Text("Then use it in a pod with imagePullPolicy: Never.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview("Load image") {
    LoadImageSheet(cluster: "k8s-dev", localImages: ["acdemo-api:dev", "docker.io/library/redis:7"]) { _, _ in }
}
