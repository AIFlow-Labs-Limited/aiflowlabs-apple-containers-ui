import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// "Scale…": a replica stepper with the exact `kubectl scale` command it runs.
struct ScaleDeploymentSheet: View {
    let deployment: KubeDeployment
    /// The command for a replica count.
    let command: (Int) -> String
    let scale: (Int) -> Void

    static let maximumReplicas = 50

    @State private var replicas: Int

    init(deployment: KubeDeployment, command: @escaping (Int) -> String, scale: @escaping (Int) -> Void) {
        self.deployment = deployment
        self.command = command
        self.scale = scale
        _replicas = State(initialValue: min(deployment.desiredReplicas, Self.maximumReplicas))
    }

    var body: some View {
        FormSheet(
            title: "Scale “\(deployment.name)”", actionTitle: "Scale",
            canSubmit: replicas != deployment.desiredReplicas,
            submit: { scale(replicas) }
        ) {
            Stepper(value: $replicas, in: 0...Self.maximumReplicas) {
                LabeledContent("Replicas", value: "\(replicas) (now \(deployment.desiredReplicas))")
            }
            .accessibilityValue("\(replicas) replicas")
            if replicas == 0 {
                Text("0 replicas stops every pod of this deployment. The deployment itself stays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Namespace", value: deployment.namespace)
            CommandPreview(command: command(replicas))
        }
    }
}

#Preview("Scale deployment") {
    ScaleDeploymentSheet(
        deployment: KubeDeployment(
            metadata: KubeMetadata(name: "web", namespace: "shop"), spec: .init(replicas: 2),
            status: .init(replicas: 2, readyReplicas: 2, updatedReplicas: 2, availableReplicas: 2)),
        command: {
            KubectlAction.scaleDeployment(namespace: "shop", name: "web", replicas: $0)
                .displayCommand(in: KubectlTarget(cluster: "dev", node: "dev"))
        }, scale: { _ in })
}
