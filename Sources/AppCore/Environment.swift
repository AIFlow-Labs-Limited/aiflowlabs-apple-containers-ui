import SwiftUI
import ContainerKit

public extension EnvironmentValues {
    /// The app model. Prefer `@Environment(AppModel.self)` in views (non-optional); this key exists for code that
    /// must tolerate a missing model (previews of leaf components).
    @Entry var appModel: AppModel? = nil
    /// The active backend (same instance as `appModel.backend`).
    @Entry var backend: (any ContainerBackend)? = nil
}

public extension View {
    /// Injects `model` under every key the app uses: `AppModel.self`, `\.appModel`, `\.backend`.
    func appModelEnvironment(_ model: AppModel) -> some View {
        self.environment(model)
            .environment(\.appModel, model)
            .environment(\.backend, model.backend)
    }
}
