import ContainerKit
import Foundation

// How the services of a plan reach each other by name, and the per-service row of the preview.
extension ComposePlanBuilder {
    /// Names other containers can use for `containerName`, as far as CLI 1.5.0 is known to resolve them.
    func hostnames(for containerName: String) -> [String] {
        guard options.networking == .sharedDefault, let domain = environment.dnsDomain else { return [] }
        return containerName.contains(".") ? [containerName] : [containerName, "\(containerName).\(domain)"]
    }

    mutating func describeNaming() {
        let example = plan.containerNames.first ?? "db"
        switch (options.networking, environment.dnsDomain) {
        case (.asDeclared, _):
            plan.namingSummary =
                "Containers join the networks from the file. On CLI 1.5.0, name lookup only works on the built-in "
                + "`default` network (apple/container#1809), so on these networks services reach each other by IP "
                + "address only; names such as “\(example)” do not resolve."
            note(.file, "names", plan.namingSummary)
        case (.sharedDefault, .some(let domain)):
            plan.namingSummary =
                "All containers join the built-in `default` network. The engine's DNS domain is “\(domain)”, so "
                + "each container is reachable from the others by its container name: “\(example)” or "
                + "“\(example).\(domain)”."
        case (.sharedDefault, nil):
            if let domain = environment.unregisteredDNSDomain {
                plan.namingSummary =
                    "The engine's DNS domain is set to “\(domain)”, but that domain is not registered "
                    + "(`container system dns list` does not show it), so containers cannot find each other by name: "
                    + "“\(example)” will not resolve. Enable DNS names under Settings → Network, or connect by IP address."
            } else if environment.isLoaded {
                plan.namingSummary =
                    "No DNS domain is configured, so containers cannot find each other by name: “\(example)” will not "
                    + "resolve. Set one up under Settings → Network, or connect by IP address."
            } else {
                plan.namingSummary =
                    "The engine is not running, so its DNS setup could not be checked. Container names only resolve "
                    + "when a DNS domain is configured (Settings → Network)."
            }
            note(.file, "names", plan.namingSummary)
        }
        guard options.naming == .projectPrefixed else { return }
        let renamed = file.services.filter { isEnabled($0) && containerName(for: $0) != $0.name }
        if let first = renamed.first {
            note(
                .file, "names",
                "Containers are named after the project (“\(containerName(for: first))”), so the service names the "
                    + "file uses for its own connections (“\(first.name)”) do not resolve. Use the container names "
                    + "in your configuration, or switch naming to “Service names”.")
        }
    }

    func summary(_ service: ComposeService) -> ComposeServiceSummary {
        let name = containerName(for: service)
        var healthcheck: ComposeHealthcheck?
        if case .check(let check) = service.healthcheck { healthcheck = check }
        return ComposeServiceSummary(
            name: service.name, containerName: name, image: imageName(for: service), isBuilt: service.build != nil,
            isEnabled: isEnabled(service), profiles: service.profiles,
            ports: service.ports.map {
                let host = $0.hostAddress.map { "\($0):" } ?? ""
                return "\(host)\($0.published ?? $0.target)→\($0.target)\($0.proto == "tcp" ? "" : "/\($0.proto)")"
            },
            hostnames: hostnames(for: name), healthcheck: healthcheck, restart: service.restart,
            waitsFor: isEnabled(service) ? waitDescriptions(for: service) : [])
    }
}
