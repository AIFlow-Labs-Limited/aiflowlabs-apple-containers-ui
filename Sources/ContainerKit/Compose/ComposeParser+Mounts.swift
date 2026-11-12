import Foundation

// Ports and volumes: the two service keys with a short string syntax and a long mapping syntax.
extension ComposeDecoder {
    // MARK: Ports

    mutating func ports(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [ComposePort] {
        guard let items = value.listValue else {
            unreadable(scope, "ports")
            return []
        }
        var result: [ComposePort] = []
        for item in items {
            if let text = item.string {
                if let parsed = Self.shortPort(text) {
                    result += parsed
                } else {
                    warn(scope, "ports", "Port mapping “\(text)” could not be read and is ignored.")
                }
            } else if let entries = item.mapValue {
                var reader = ComposeMapReader(entries)
                guard let target = reader.take("target")?.int, Self.validPort(target) else {
                    warn(scope, "ports", "A port entry without a valid `target` is ignored.")
                    continue
                }
                let proto = reader.take("protocol")?.string?.lowercased() ?? "tcp"
                guard proto == "tcp" || proto == "udp" else {
                    warn(scope, "ports", "Protocol “\(proto)” cannot be published; port \(target) is ignored.")
                    continue
                }
                let published = reader.take("published")
                if let published, published.int.map(Self.validPort) != true {
                    // A host range (`"8000-8010"`) in the long form: Docker picks one free port from it.
                    warn(
                        scope, "ports",
                        "Published port “\(published.string ?? "?")” for \(target) could not be read; "
                            + "the entry is ignored.")
                    continue
                }
                result.append(
                    ComposePort(
                        hostAddress: reader.take("host_ip")?.string, published: published?.int, target: target,
                        proto: proto))
                _ = reader.take("mode")
                _ = reader.take("name")
                _ = reader.take("app_protocol")
            } else {
                warn(scope, "ports", "A port entry could not be read and is ignored.")
            }
        }
        return result
    }

    static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }

    /// `[HOST_IP:][HOST_PORT:]CONTAINER_PORT[/PROTOCOL]`, each port optionally a range (`8000-8002`). An IPv6 host
    /// address is bracketed (`[::1]:8080:80`). Returns one entry per port, or `nil` when the text is malformed.
    static func shortPort(_ text: String) -> [ComposePort]? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var proto = "tcp"
        if let slash = rest.lastIndex(of: "/") {
            proto = rest[rest.index(after: slash)...].lowercased()
            rest = String(rest[..<slash])
        }
        guard proto == "tcp" || proto == "udp" else { return nil }
        var hostAddress: String?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            hostAddress = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
            guard rest.hasPrefix(":") else { return nil }
            rest.removeFirst()
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var hostPart: String?
        let containerPart: String
        switch (parts.count, hostAddress == nil) {
        case (1, _): containerPart = parts[0]
        case (2, _): (hostPart, containerPart) = (parts[0], parts[1])
        case (3, true): (hostAddress, hostPart, containerPart) = (parts[0], parts[1], parts[2])
        default: return nil
        }
        if hostAddress?.isEmpty == true { hostAddress = nil }
        if hostPart?.isEmpty == true { hostPart = nil }
        guard let targets = portRange(containerPart) else { return nil }
        var published: [Int?] = Array(repeating: nil, count: targets.count)
        if let hostPart {
            guard let hosts = portRange(hostPart), hosts.count == targets.count else { return nil }
            published = hosts.map { $0 }
        }
        return zip(published, targets).map {
            ComposePort(hostAddress: hostAddress, published: $0, target: $1, proto: proto)
        }
    }

    /// `80` → `[80]`, `8000-8002` → `[8000, 8001, 8002]`; `nil` when not a port or a (small) ascending range.
    private static func portRange(_ text: String) -> [Int]? {
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        switch bounds.count {
        case 1:
            guard let port = bounds[0], validPort(port) else { return nil }
            return [port]
        case 2:
            guard let low = bounds[0], let high = bounds[1], validPort(low), validPort(high), low <= high,
                high - low < 1_000
            else { return nil }
            return Array(low...high)
        default: return nil
        }
    }

    // MARK: Volumes

    /// Short-syntax access modes that change nothing on this runtime (SELinux labels, Docker Desktop caching).
    private static let ignoredMountModes: Set<String> = ["rw", "z", "Z", "cached", "delegated", "consistent"]

    mutating func mounts(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [ComposeMount] {
        guard let items = value.listValue else {
            unreadable(scope, "volumes")
            return []
        }
        var result: [ComposeMount] = []
        for item in items {
            if let text = item.string {
                if let mount = shortMount(text, scope: scope) { result.append(mount) }
            } else if let entries = item.mapValue {
                if let mount = longMount(entries, scope: scope) { result.append(mount) }
            } else {
                warn(scope, "volumes", "A volume entry could not be read and is ignored.")
            }
        }
        return result
    }

    /// Compose's rule: a source that starts with `.`, `/` or `~` is a host path, anything else a volume name.
    static func isHostPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }

    /// `TARGET`, `SOURCE:TARGET` or `SOURCE:TARGET:MODE[,MODE]`.
    private mutating func shortMount(_ text: String, scope: ComposeWarning.Scope) -> ComposeMount? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), !parts.contains(where: \.isEmpty) else {
            warn(scope, "volumes", "Volume “\(text)” could not be read and is ignored.")
            return nil
        }
        if parts.count == 1 { return ComposeMount(source: .anonymous, target: parts[0]) }
        var mount = ComposeMount(
            source: Self.isHostPath(parts[0]) ? .bind(parts[0]) : .volume(parts[0]), target: parts[1])
        if parts.count == 3 {
            for mode in parts[2].split(separator: ",").map(String.init) {
                if mode == "ro" {
                    mount.readOnly = true
                } else if !Self.ignoredMountModes.contains(mode) {
                    warn(scope, "volumes", "Mount option “\(mode)” on “\(text)” is not supported and is ignored.")
                }
            }
        }
        return mount
    }

    private mutating func longMount(_ entries: [ComposeValue.Entry], scope: ComposeWarning.Scope) -> ComposeMount? {
        var reader = ComposeMapReader(entries)
        guard let target = reader.take("target")?.string else {
            warn(scope, "volumes", "A volume entry without a `target` is ignored.")
            return nil
        }
        let source = reader.take("source")?.string
        let type = reader.take("type")?.string ?? (source.map { Self.isHostPath($0) ? "bind" : "volume" } ?? "volume")
        let readOnly = reader.take("read_only")?.bool ?? false
        let tmpfsSize = reader.take("tmpfs")?.mapValue?.first { $0.key == "size" }?.value.string
        _ = reader.take("bind")  // create_host_path / propagation / selinux: nothing to map
        _ = reader.take("volume")  // nocopy / subpath
        _ = reader.take("consistency")
        for key in reader.unhandledKeys {
            warn(scope, "volumes.\(key)", "Volume option `\(key)` on “\(target)” is not supported and is ignored.")
        }
        switch type {
        case "bind":
            guard let source else {
                warn(scope, "volumes", "The bind mount at “\(target)” has no `source` and is ignored.")
                return nil
            }
            return ComposeMount(source: .bind(source), target: target, readOnly: readOnly)
        case "volume":
            return ComposeMount(source: source.map { .volume($0) } ?? .anonymous, target: target, readOnly: readOnly)
        case "tmpfs":
            return ComposeMount(source: .tmpfs(size: tmpfsSize.flatMap { MemorySize(parsing: $0) }), target: target)
        default:
            warn(scope, "volumes", "Mount type “\(type)” at “\(target)” is not supported and is ignored.")
            return nil
        }
    }
}
