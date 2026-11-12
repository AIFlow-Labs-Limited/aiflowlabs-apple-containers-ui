import AppCore
import DesignSystem
import ServiceManagement
import SwiftUI

/// Settings › General: the switch for the background helper and what macOS says about it.
struct BackgroundSupervisionRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Toggle("Keep enforcing when Container Desktop is closed", isOn: $settings.keepEnforcingWhenClosed)
            .disabled(!canToggle)
        HStack(alignment: .firstTextBaseline) {
            Text(Self.statusText(settings.backgroundSupervision, error: settings.backgroundSupervisionError))
                .font(.caption)
                .foregroundStyle(isWarning ? AnyShapeStyle(.statusWarning) : AnyShapeStyle(.secondary))
            if settings.backgroundSupervision == .requiresApproval {
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        }
    }

    private var canToggle: Bool {
        if case .unavailable = model.settings.backgroundSupervision { return false }
        return true
    }

    private var isWarning: Bool {
        model.settings.backgroundSupervisionError != nil || model.settings.backgroundSupervision == .requiresApproval
    }

    /// The honest state of the helper, in one paragraph.
    static func statusText(_ status: BackgroundSupervisionStatus, error: String?) -> String {
        if let error {
            let outcome = status.isRegistered ? "The helper is still registered." : "The helper is not registered."
            return "macOS refused the change: \(error) \(outcome)"
        }
        switch status {
        case .disabled:
            return "Off: restart policies are enforced only while Container Desktop is running. Switching this on "
                + "registers a small background helper that starts at login and takes over the restarts. It "
                + "appears under System Settings › General › Login Items."
        case .enabled:
            return "On: a background helper enforces restart policies, also after you quit Container Desktop and "
                + "after you log in. It waits for the container system and does not start it. Stops you make in "
                + "the app are respected; its restarts are in the system log, not in Activity."
        case .requiresApproval:
            return "Waiting for approval: allow Container Desktop under System Settings › General › Login Items. "
                + "Until then restart policies are enforced only while the app is running."
        case .unavailable(let reason):
            return reason
        }
    }
}
