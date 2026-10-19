import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// "Load image…": `container k8s load-image --name CLUSTER [--platform P] REF`, streamed via TaskCenter.
struct LoadImageSheet: View {
    let cluster: String
    let localImages: [String]
    let load: (String, Platform?) -> Void

    private enum PlatformChoice: String, CaseIterable, Identifiable {
        case native = "Native (arm64)", amd64 = "linux/amd64"
        var id: String { rawValue }
        var platform: Platform? { self == .amd64 ? .amd64 : nil }
    }

    @State private var reference = ""
    @State private var platform = PlatformChoice.native

    var body: some View {
        FormSheet(title: "Load an image into “\(cluster)”", actionTitle: "Load",
                  canSubmit: !reference.trimmingCharacters(in: .whitespaces).isEmpty,
                  submit: { load(reference.trimmingCharacters(in: .whitespaces), platform.platform) }) {
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
                ForEach(PlatformChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            CommandPreview(command: command)
            Text("Then use it in a pod with imagePullPolicy: Never.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var command: String {
        var args = ["k8s", "load-image", "--name", cluster]
        if let p = platform.platform { args += ["--platform", p.slug] }
        args.append(reference.isEmpty ? "IMAGE" : reference)
        return ContainerKit.CommandLine(executable: "container", arguments: args).display
    }
}

#Preview("Load image") {
    LoadImageSheet(cluster: "k8s-dev", localImages: ["acdemo-api:dev", "docker.io/library/redis:7"]) { _, _ in }
}
