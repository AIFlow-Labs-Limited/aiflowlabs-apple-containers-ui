import SwiftUI
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

@main
struct ContainerDesktopApp: App {
    var body: some Scene {
        WindowGroup("Container Desktop") {
            PlaceholderView()
        }
    }
}

/// Replaced by the real shell (see docs/ARCHITECTURE.md). Proves the package links end to end.
struct PlaceholderView: View {
    @State private var summary = "Loading…"

    var body: some View {
        VStack(spacing: 12) {
            Text("Container Desktop").font(.largeTitle.bold())
            Text(summary).monospaced()
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            let backend = MockBackend()
            do {
                let containers = try await backend.listContainers(includeStopped: true)
                let images = try await backend.listImages()
                summary = "\(await backend.backendDescription): \(containers.count) containers, \(images.count) images"
            } catch {
                summary = error.localizedDescription
            }
        }
    }
}
