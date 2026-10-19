import AppCore
import ContainerKit
import Foundation

/// Editable state of the Run sheet. Rows hold raw text so half-typed values never get lost; `spec` turns
/// it into a `RunSpec` (the single source of truth for the CLI arguments and the command preview).
/// Codable so the last-used values per image can be restored.
struct RunFormValues: Codable, Equatable {
    struct PortRow: Codable, Equatable, Identifiable {
        var id = UUID()
        var host = ""
        var container = ""
        var proto = "tcp"
    }

    enum VolumeKind: String, Codable, CaseIterable, Identifiable {
        case bind, volume, anonymous
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bind: return "Folder"
            case .volume: return "Volume"
            case .anonymous: return "Anonymous"
            }
        }
    }

    struct VolumeRow: Codable, Equatable, Identifiable {
        var id = UUID()
        var kind: VolumeKind = .bind
        var source = ""
        var target = ""
        var readOnly = false
    }

    struct KeyValueRow: Codable, Equatable, Identifiable {
        var id = UUID()
        var key = ""
        var value = ""
    }

    enum PlatformChoice: String, Codable, CaseIterable, Identifiable {
        case automatic, arm64, amd64
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .arm64: return "arm64 (native)"
            case .amd64: return "amd64 via Rosetta"
            }
        }
    }

    var image = ""
    var name = ""
    var command = ""
    var entrypoint = ""
    var workingDirectory = ""
    var user = ""
    var ports: [PortRow] = []
    var volumes: [VolumeRow] = []
    var environment: [KeyValueRow] = []
    var customResources = false
    var cpus = 4
    var memoryMB: Double = 1024
    var platform: PlatformChoice = .automatic
    var network = ""  // "" = default
    var aliases = ""  // comma separated
    var macAddress = ""
    var useInit = false
    var readOnly = false
    var ssh = false
    var removeOnExit = false
    var labels: [KeyValueRow] = []
    var capAdd = ""
    var capDrop = ""
    var shmSize = ""
    var ulimits = ""
    var extraArguments = ""

    init() {}

    /// Prefills from an existing spec (image → Run, "Run similar", deep link).
    init(spec: RunSpec) {
        image = spec.image
        name = spec.name ?? ""
        command = ShellWords.join(spec.command)
        entrypoint = spec.entrypoint ?? ""
        workingDirectory = spec.workingDirectory ?? ""
        user = spec.user ?? ""
        ports = spec.ports.map { p in
            PortRow(
                host: (p.hostAddress.map { "\($0):" } ?? "") + String(p.hostPort), container: String(p.containerPort),
                proto: p.proto)
        }
        volumes = spec.mounts.map { m in
            switch m.kind {
            case .bind(let path): return VolumeRow(kind: .bind, source: path, target: m.target, readOnly: m.readOnly)
            case .volume(let name):
                return VolumeRow(kind: .volume, source: name, target: m.target, readOnly: m.readOnly)
            case .anonymous: return VolumeRow(kind: .anonymous, target: m.target, readOnly: m.readOnly)
            }
        }
        environment = EnvironmentVariable.parse(spec.environment).map {
            KeyValueRow(key: $0.key, value: $0.value ?? "")
        }
        if spec.cpus != nil || spec.memory != nil {
            customResources = true
            cpus = spec.cpus ?? 4
            memoryMB = Double((spec.memory?.bytes ?? (1 << 30)) >> 20)
        }
        platform = spec.platform.map { $0.architecture == "amd64" ? .amd64 : .arm64 } ?? .automatic
        network = spec.network ?? ""
        aliases = spec.networkAliases.joined(separator: ", ")
        macAddress = spec.macAddress ?? ""
        useInit = spec.useInit
        readOnly = spec.readOnly
        ssh = spec.ssh
        removeOnExit = spec.removeOnExit
        labels = spec.labels.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
        capAdd = spec.capAdd.joined(separator: ", ")
        capDrop = spec.capDrop.joined(separator: ", ")
        shmSize = spec.shmSize?.cliArgument ?? ""
        ulimits = spec.ulimits.joined(separator: ", ")
        extraArguments = ShellWords.join(spec.extraArguments + spec.tmpfs.flatMap { ["--tmpfs", $0] })
    }

    // MARK: Spec

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Ports whose text does not parse as numbers (reported as issues, skipped in the spec).
    var malformedPorts: [String] {
        ports.compactMap { row in
            guard !(row.host.isEmpty && row.container.isEmpty) else { return nil }
            return Self.portMapping(row) == nil ? "\(row.host):\(row.container)" : nil
        }
    }

    static func portMapping(_ row: PortRow) -> RunSpec.PortMapping? {
        let host = row.host.trimmingCharacters(in: .whitespaces)
        var address: String?
        var hostPortText = host
        if let colon = host.lastIndex(of: ":") {
            address = String(host[..<colon])
            hostPortText = String(host[host.index(after: colon)...])
        }
        guard let containerPort = Int(row.container.trimmingCharacters(in: .whitespaces)) else { return nil }
        let hostPort = hostPortText.isEmpty ? containerPort : Int(hostPortText)
        guard let hostPort else { return nil }
        return RunSpec.PortMapping(
            hostAddress: address.flatMap(trimmed), hostPort: hostPort, containerPort: containerPort, proto: row.proto)
    }

    var spec: RunSpec {
        var s = RunSpec(image: image.trimmingCharacters(in: .whitespaces))
        s.name = Self.trimmed(name)
        s.command = ShellWords.split(command)
        s.entrypoint = Self.trimmed(entrypoint)
        s.workingDirectory = Self.trimmed(workingDirectory)
        s.user = Self.trimmed(user)
        s.removeOnExit = removeOnExit
        s.ports = ports.compactMap(Self.portMapping)
        s.mounts = volumes.compactMap { row in
            let target = row.target.trimmingCharacters(in: .whitespaces)
            let source = row.source.trimmingCharacters(in: .whitespaces)
            switch row.kind {
            case .bind:
                return source.isEmpty && target.isEmpty
                    ? nil
                    : .init(kind: .bind(hostPath: Self.expandingTilde(source)), target: target, readOnly: row.readOnly)
            case .volume:
                return source.isEmpty && target.isEmpty
                    ? nil : .init(kind: .volume(name: source), target: target, readOnly: row.readOnly)
            case .anonymous:
                return target.isEmpty ? nil : .init(kind: .anonymous, target: target, readOnly: row.readOnly)
            }
        }
        s.environment = environment.compactMap { row in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : "\(key)=\(row.value)"
        }
        if customResources {
            s.cpus = cpus
            s.memory = MemorySize(bytes: Int64(memoryMB) << 20)
        }
        switch platform {
        case .automatic: break
        case .arm64: s.platform = .arm64
        case .amd64: s.platform = .amd64
        }
        s.network = Self.trimmed(network)
        s.networkAliases = Self.list(aliases)
        s.macAddress = Self.trimmed(macAddress)
        s.useInit = useInit
        s.readOnly = readOnly
        s.ssh = ssh
        s.labels = Dictionary(
            labels.compactMap { row in
                let key = row.key.trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, row.value)
            }, uniquingKeysWith: { $1 })
        s.capAdd = Self.list(capAdd)
        s.capDrop = Self.list(capDrop)
        s.shmSize = Self.trimmed(shmSize).flatMap(MemorySize.init(parsing:))
        s.ulimits = Self.list(ulimits)
        s.extraArguments = ShellWords.split(extraArguments)
        return s
    }

    /// `~` / `~/x` → the user's home folder (the CLI does not expand it; the field suggests `~/project`).
    static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    /// Everything that blocks Run, as user-facing sentences.
    var issues: [String] {
        // Image and host-folder checks (`.invalidImage`, `.relativeMountSource`) live in `RunSpec.issues`.
        var result = spec.issues.map(\.description)
        result += malformedPorts.map { "Port mapping “\($0)” must be numbers, e.g. 8080 → 80." }
        if let shm = Self.trimmed(shmSize), MemorySize(parsing: shm) == nil {
            result.append("Shared memory size “\(shm)” is not a size like 64m.")
        }
        if volumes.contains(where: {
            $0.kind != .anonymous && !$0.target.isEmpty && $0.source.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            result.append(
                volumes.contains { $0.kind == .bind && $0.source.isEmpty }
                    ? "Choose a host folder for every folder mount." : "Name every volume.")
        }
        return result
    }

    // MARK: Last-used values per image

    /// How many images keep remembered settings (least recently used are forgotten).
    static let lastUsedLimit = 20
    private static let lastUsedPrefix = "containers.run.lastUsed."
    private static let lastUsedIndexKey = "containers.run.lastUsedIndex"

    private static func key(for image: String) -> String { lastUsedPrefix + image }

    static func lastUsed(for image: String, defaults: UserDefaults = .standard) -> RunFormValues? {
        guard !image.isEmpty, let data = defaults.data(forKey: key(for: image)) else { return nil }
        return try? JSONDecoder().decode(RunFormValues.self, from: data)
    }

    /// What gets persisted: no name (names must be unique) and no secret values — sensitive environment entries keep
    /// their key with an empty value, so the user re-enters it instead of it sitting in a plist in plain text.
    var persistableCopy: RunFormValues {
        var copy = self
        copy.name = ""
        copy.environment = environment.map { row in
            var row = row
            if EnvironmentVariable.isSensitive(key: row.key.trimmingCharacters(in: .whitespaces), value: row.value) {
                row.value = ""
            }
            return row
        }
        return copy
    }

    /// Saves `persistableCopy` for this image and keeps only the `lastUsedLimit` most recently used images.
    func saveAsLastUsed(defaults: UserDefaults = .standard) {
        let copy = persistableCopy
        guard !copy.image.isEmpty, let data = try? JSONEncoder().encode(copy) else { return }
        defaults.set(data, forKey: Self.key(for: copy.image))
        var index = defaults.stringArray(forKey: Self.lastUsedIndexKey) ?? []
        index.removeAll { $0 == copy.image }
        index.insert(copy.image, at: 0)
        // Entries saved before the index existed are adopted (oldest) so they get evicted too.
        let known = Set(index)
        let legacy = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.lastUsedPrefix) }
            .map { String($0.dropFirst(Self.lastUsedPrefix.count)) }
            .filter { !known.contains($0) }
            .sorted()
        index += legacy
        while index.count > Self.lastUsedLimit {
            defaults.removeObject(forKey: Self.key(for: index.removeLast()))
        }
        defaults.set(index, forKey: Self.lastUsedIndexKey)
    }
}
