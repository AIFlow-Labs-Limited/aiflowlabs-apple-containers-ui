import ContainerKit
import Foundation

// `depends_on` conditions: the waits the app performs itself, because the runtime has no health checks.
extension ComposePlanBuilder {
    /// Plans the waits `service` needs before it starts: one step per dependency that has to be healthy or
    /// finished. Called right before the service's own `run` step, so the dependency's `run` step is already
    /// in the plan. A dependency several services wait for is waited for once, before the first of them.
    mutating func planWaits(for service: ComposeService) {
        for dependency in service.dependsOn {
            guard let other = file.service(named: dependency.service), isEnabled(other) else { continue }
            let container = containerName(for: other)
            switch dependency.condition {
            case ComposeDependency.healthy:
                guard case .check(let check) = other.healthcheck else {
                    problem(
                        "“\(service.name)” waits for “\(other.name)” to be healthy, but “\(other.name)” has no "
                            + "health check. Add a `healthcheck:` with a `test:` to “\(other.name)”, or change the "
                            + "condition to `service_started`.", service: service.name)
                    continue
                }
                appendWait(id: "healthy:\(container)", .waitHealthy(container: container, check: check), other)
            case ComposeDependency.completedSuccessfully:
                appendWait(id: "completed:\(container)", .waitCompleted(container: container), other)
                note(
                    .service(service.name), "depends_on.\(other.name).condition",
                    "“\(service.name)” starts once “\(other.name)” has stopped. The runtime does not report exit "
                        + "codes (checked on CLI 1.5.0), so the app cannot tell whether “\(other.name)” succeeded: "
                        + "any exit counts as completed.")
                if other.restart.isEnforced {
                    note(
                        .service(other.name), "restart",
                        "“\(other.name)” has a restart policy and another service waits for it to finish. The app "
                            + "may start it again after it exits.")
                }
            default:
                break
            }
        }
    }

    private mutating func appendWait(id: String, _ action: ComposeStep.Action, _ dependency: ComposeService) {
        guard plannedWaits.insert(id).inserted else { return }
        plan.steps.append(ComposeStep(id: id, action: action, service: dependency.name))
    }

    /// "db to be healthy", "migrate to finish" — what `service` waits for, for the preview's service list.
    func waitDescriptions(for service: ComposeService) -> [String] {
        service.dependsOn.compactMap { dependency in
            guard let other = file.service(named: dependency.service), isEnabled(other) else { return nil }
            switch dependency.condition {
            case ComposeDependency.healthy:
                guard case .check = other.healthcheck else { return nil }
                return "\(containerName(for: other)) to be healthy"
            case ComposeDependency.completedSuccessfully:
                return "\(containerName(for: other)) to finish"
            default:
                return nil
            }
        }
    }

    /// Says, per service with a health check, when the app runs it. Called once all services are planned.
    mutating func describeHealthchecks(_ selected: [ComposeService]) {
        for service in selected {
            guard case .check = service.healthcheck else { continue }
            let waiting = selected.filter { other in
                other.dependsOn.contains { $0.service == service.name && $0.condition == ComposeDependency.healthy }
            }
            if waiting.isEmpty {
                note(
                    .service(service.name), "healthcheck",
                    "No service waits for this health check (`depends_on` with `condition: service_healthy`), so "
                        + "it is not run. The runtime has no health checks of its own.")
            } else {
                let names = waiting.map { "“\($0.name)”" }.joined(separator: ", ")
                note(
                    .service(service.name), "healthcheck",
                    "Container Desktop runs this health check inside the container during the import, until it "
                        + "passes, and only then starts \(names). It is not run afterwards: nothing watches the "
                        + "container's health once the project is up.")
            }
        }
    }
}
