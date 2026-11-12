import Foundation

/// Reads a compose file into `ComposeFile`. Lenient by design: keys it does not know, and values it cannot read,
/// become `ComposeWarning`s. It only throws when the text is not YAML, is not a compose file at all, or a
/// `${VAR:?message}` variable has no value.
public enum ComposeParser {
    /// Parses `yaml`, replacing `${…}` references from `variables` first.
    public static func parse(_ yaml: String, variables: [String: String] = [:]) throws -> ComposeFile {
        let raw = try ComposeValue.parse(yaml: yaml)
        var unset = Set<String>()
        let tree = try raw.mapScalars {
            try ComposeInterpolation.interpolate($0, variables: variables, unset: &unset)
        }
        var decoder = ComposeDecoder()
        var file = try decoder.file(tree)
        file.warnings = decoder.warnings
        file.unsetVariables = unset.sorted()
        return file
    }

    /// Every variable the file refers to, in order of first appearance, with the default the file gives (if any).
    /// Works on files `parse` rejects for a missing required variable, so the preview can ask for the value.
    public static func variableReferences(in yaml: String) throws -> [ComposeInterpolation.Reference] {
        var result: [ComposeInterpolation.Reference] = []
        for scalar in try ComposeValue.parse(yaml: yaml).scalars {
            ComposeInterpolation.collect(scalar, into: &result)
        }
        return result
    }
}

/// Walks the YAML tree and collects warnings on the way. One instance per parse.
struct ComposeDecoder {
    var warnings: [ComposeWarning] = []

    mutating func warn(
        _ scope: ComposeWarning.Scope, _ key: String, _ message: String,
        severity: ComposeWarning.Severity = .unsupported
    ) {
        let warning = ComposeWarning(scope: scope, key: key, message: message, severity: severity)
        if !warnings.contains(warning) { warnings.append(warning) }
    }

    /// A supported key whose value has the wrong shape.
    mutating func unreadable(_ scope: ComposeWarning.Scope, _ key: String) {
        warn(scope, key, "This value could not be read and is ignored.")
    }

    // MARK: Top level

    private static let topLevelMessages: [String: String] = [
        "secrets": "Secrets are not supported. Services that use them start without the secret files.",
        "configs": "Configs are not supported. Services that use them start without the config files.",
        "include":
            "`include` is not followed: services, volumes and networks from the included files are missing. "
            + "Import those files separately.",
    ]

    mutating func file(_ tree: ComposeValue) throws -> ComposeFile {
        guard let root = tree.mapValue else {
            throw ComposeError.invalidStructure(
                "This does not look like a compose file: it has no `services:` section.")
        }
        var reader = ComposeMapReader(root)
        var file = ComposeFile()
        _ = reader.take("version")  // obsolete, ignored by Docker Compose too
        file.name = reader.take("name")?.string
        guard let services = reader.take("services")?.mapValue, !services.isEmpty else {
            throw ComposeError.invalidStructure(
                "This does not look like a compose file: it has no `services:` section.")
        }
        for entry in services {
            guard let body = entry.value.mapValue else {
                throw ComposeError.invalidStructure(
                    "Service “\(entry.key)” is empty or not a mapping; it needs at least `image:` or `build:`.")
            }
            file.services.append(service(name: entry.key, body: body))
        }
        for entry in reader.take("volumes")?.mapValue ?? [] { file.volumes.append(volume(entry)) }
        for entry in reader.take("networks")?.mapValue ?? [] { file.networks.append(network(entry)) }
        for key in reader.unhandledKeys {
            warn(.file, key, Self.topLevelMessages[key] ?? "Top-level `\(key)` is not supported and is ignored.")
        }
        return file
    }

    private mutating func volume(_ entry: ComposeValue.Entry) -> ComposeVolume {
        var volume = ComposeVolume(key: entry.key)
        guard let body = entry.value.mapValue else { return volume }  // `data:` with no body is the common form
        var reader = ComposeMapReader(body)
        let scope = ComposeWarning.Scope.volume(entry.key)
        volume.name = reader.take("name")?.string
        volume.isExternal = external(reader.take("external"), name: &volume.name)
        volume.labels = reader.take("labels")?.stringMap ?? [:]
        if let driver = reader.take("driver")?.string, driver != "local" {
            warn(scope, "driver", "Volume driver “\(driver)” is not available; a normal local volume is created.")
        }
        for key in reader.unhandledKeys {
            warn(scope, key, "Volume option `\(key)` is not supported and is ignored.")
        }
        return volume
    }

    private mutating func network(_ entry: ComposeValue.Entry) -> ComposeNetwork {
        var network = ComposeNetwork(key: entry.key)
        guard let body = entry.value.mapValue else { return network }
        var reader = ComposeMapReader(body)
        let scope = ComposeWarning.Scope.network(entry.key)
        network.name = reader.take("name")?.string
        network.isExternal = external(reader.take("external"), name: &network.name)
        network.labels = reader.take("labels")?.stringMap ?? [:]
        if let driver = reader.take("driver")?.string, driver != "bridge" {
            warn(scope, "driver", "Network driver “\(driver)” is not available; a normal network is created.")
        }
        if let ipam = reader.take("ipam")?.mapValue {
            var ipamReader = ComposeMapReader(ipam)
            for config in ipamReader.take("config")?.listValue ?? [] {
                guard let subnet = config.mapValue?.first(where: { $0.key == "subnet" })?.value.string else {
                    continue
                }
                if subnet.contains(":") {
                    network.subnetV6 = network.subnetV6 ?? subnet
                } else {
                    network.subnet = network.subnet ?? subnet
                }
            }
        }
        if reader.take("internal")?.bool == true {
            warn(
                scope, "internal",
                "The network is created as a normal network, not an internal (host-only) one.")
        }
        for key in reader.unhandledKeys {
            warn(scope, key, "Network option `\(key)` is not supported and is ignored.")
        }
        return network
    }

    /// `external: true`, or the legacy `external: {name: x}` form (which also sets the name).
    private func external(_ value: ComposeValue?, name: inout String?) -> Bool {
        guard let value else { return false }
        if let flag = value.bool { return flag }
        if let legacy = value.mapValue {
            if let legacyName = legacy.first(where: { $0.key == "name" })?.value.string { name = name ?? legacyName }
            return true
        }
        return false
    }
}
