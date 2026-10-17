import Foundation

/// Everything the "Run a new container" sheet can set. Maps 1:1 onto `container run` flags.
public struct RunSpec: Hashable, Sendable {
    public var image: String
    public var name: String?
    public var command: [String] = []
    public var entrypoint: String?
    public var detach: Bool = true
    public var removeOnExit: Bool = false
    public var interactive: Bool = false
    public var tty: Bool = false
    public var environment: [String] = []          // KEY=VALUE or KEY (inherit)
    public var envFiles: [String] = []
    public var ports: [PortMapping] = []
    public var mounts: [MountSpec] = []
    public var tmpfs: [String] = []                // "/path[:size=64M,mode=1777]"
    public var workingDirectory: String?
    public var user: String?
    public var cpus: Int?
    public var memory: MemorySize?
    public var platform: Platform?
    public var network: String?                    // nil = default
    public var networkAliases: [String] = []
    public var macAddress: String?
    public var dnsDomain: String?
    public var labels: [String: String] = [:]
    public var useInit: Bool = false
    public var readOnly: Bool = false
    public var rosetta: Bool = false
    public var ssh: Bool = false
    public var virtualization: Bool = false
    public var capAdd: [String] = []
    public var capDrop: [String] = []
    public var shmSize: MemorySize?
    public var ulimits: [String] = []              // "nofile=65536:131072"
    public var kernel: String?
    public var extraArguments: [String] = []       // escape hatch for flags the UI does not model

    public init(image: String) { self.image = image }

    public struct PortMapping: Hashable, Sendable {
        public var hostAddress: String?
        public var hostPort: Int
        public var containerPort: Int
        public var proto: String = "tcp"
        public init(hostAddress: String? = nil, hostPort: Int, containerPort: Int, proto: String = "tcp") {
            self.hostAddress = hostAddress; self.hostPort = hostPort; self.containerPort = containerPort; self.proto = proto
        }
        /// `[host-ip:]host-port:container-port[/protocol]`
        public var cliArgument: String {
            let host = hostAddress.map { "\($0):" } ?? ""
            return "\(host)\(hostPort):\(containerPort)/\(proto)"
        }
    }

    public struct MountSpec: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case bind(hostPath: String), volume(name: String), anonymous }
        public var kind: Kind
        public var target: String
        public var readOnly: Bool = false
        public init(kind: Kind, target: String, readOnly: Bool = false) { self.kind = kind; self.target = target; self.readOnly = readOnly }
        /// `--volume` argument.
        public var cliArgument: String {
            let ro = readOnly ? ":ro" : ""
            switch kind {
            case .bind(let p): return "\(p):\(target)\(ro)"
            case .volume(let n): return "\(n):\(target)\(ro)"
            case .anonymous: return target
            }
        }
    }

    /// Argument list after `container run`. Single source of truth for the CLI backend and for the
    /// "copy as command" feature in the UI.
    public var cliArguments: [String] {
        var a: [String] = []
        if detach { a.append("-d") }
        if removeOnExit { a.append("--rm") }
        if interactive { a.append("-i") }
        if tty { a.append("-t") }
        if let name { a += ["--name", name] }
        if let entrypoint { a += ["--entrypoint", entrypoint] }
        for e in environment { a += ["-e", e] }
        for f in envFiles { a += ["--env-file", f] }
        for p in ports { a += ["-p", p.cliArgument] }
        for m in mounts { a += ["-v", m.cliArgument] }
        for t in tmpfs { a += ["--tmpfs", t] }
        if let workingDirectory { a += ["-w", workingDirectory] }
        if let user { a += ["-u", user] }
        if let cpus { a += ["-c", String(cpus)] }
        if let memory { a += ["-m", memory.cliArgument] }
        if let platform { a += ["--platform", platform.slug] }
        if network != nil || macAddress != nil || !networkAliases.isEmpty {
            var spec = network ?? "default"
            if let macAddress { spec += ",mac=\(macAddress)" }
            for alias in networkAliases { spec += ",alias=\(alias)" }
            a += ["--network", spec]
        }
        if let dnsDomain { a += ["--dns-domain", dnsDomain] }
        for (k, v) in labels.sorted(by: { $0.key < $1.key }) { a += ["-l", "\(k)=\(v)"] }
        if useInit { a.append("--init") }
        if readOnly { a.append("--read-only") }
        if rosetta { a.append("--rosetta") }
        if ssh { a.append("--ssh") }
        if virtualization { a.append("--virtualization") }
        for c in capAdd { a += ["--cap-add", c] }
        for c in capDrop { a += ["--cap-drop", c] }
        if let shmSize { a += ["--shm-size", shmSize.cliArgument] }
        for u in ulimits { a += ["--ulimit", u] }
        if let kernel { a += ["--kernel", kernel] }
        a += extraArguments
        a.append(image)
        a += command
        return a
    }
}

/// `container build` parameters.
public struct BuildSpec: Hashable, Sendable {
    public var contextDirectory: String
    public var dockerfile: String?
    public var tag: String
    public var platforms: [Platform] = []
    public var buildArgs: [String] = []            // KEY=VALUE
    public var target: String?
    public var noCache: Bool = false
    public var pull: Bool = false
    public var labels: [String] = []
    public var secrets: [String] = []              // id=KEY,env=ENV or id=KEY,src=path
    public var forwardSSH: Bool = false
    public var cpus: Int?
    public var memory: MemorySize?
    public var output: String?                     // type=oci,dest=…

    public init(contextDirectory: String, tag: String) { self.contextDirectory = contextDirectory; self.tag = tag }

    public var cliArguments: [String] {
        var a: [String] = ["-t", tag, "--progress", "plain"]
        if let dockerfile { a += ["-f", dockerfile] }
        for p in platforms { a += ["--platform", p.slug] }
        for b in buildArgs { a += ["--build-arg", b] }
        if let target { a += ["--target", target] }
        if noCache { a.append("--no-cache") }
        if pull { a.append("--pull") }
        for l in labels { a += ["-l", l] }
        for s in secrets { a += ["--secret", s] }
        if forwardSSH { a += ["--ssh", "default"] }
        if let cpus { a += ["-c", String(cpus)] }
        if let memory { a += ["-m", memory.cliArgument] }
        if let output { a += ["-o", output] }
        a.append(contextDirectory)
        return a
    }
}

/// `container machine create` parameters.
public struct MachineSpec: Hashable, Sendable {
    public var image: String
    public var name: String
    public var cpus: Int?
    public var memory: MemorySize?
    public var homeMount: String?                  // rw | ro | none
    public var setDefault: Bool = false
    public var noBoot: Bool = false
    public var virtualization: Bool = false
    public var kernel: String?
    public var user: String?
    public var platform: Platform?

    public init(image: String, name: String) { self.image = image; self.name = name }

    public var cliArguments: [String] {
        var a: [String] = ["--name", name]
        if let cpus { a += ["--cpus", String(cpus)] }
        if let memory { a += ["--memory", memory.cliArgument] }
        if let homeMount { a += ["--home-mount", homeMount] }
        if setDefault { a.append("--set-default") }
        if noBoot { a.append("--no-boot") }
        if virtualization { a.append("--virtualization") }
        if let kernel { a += ["--kernel", kernel] }
        if let user { a += ["--user", user] }
        if let platform { a += ["--platform", platform.slug] }
        a.append(image)
        return a
    }
}

/// `container k8s create` parameters.
public struct ClusterSpec: Hashable, Sendable {
    public var name: String = "k8s-dev"
    public var cpus: Int?
    public var memory: MemorySize?
    public var nodeImage: String?
    public var cniManifest: String?
    public var removeOnStop: Bool = false
    public var workers: Int?                       // not in 1.5.0; backend omits if unsupported

    public init(name: String = "k8s-dev") { self.name = name }

    public var cliArguments: [String] {
        var a: [String] = ["--name", name]
        if let cpus { a += ["-c", String(cpus)] }
        if let memory { a += ["-m", memory.cliArgument] }
        if let nodeImage { a += ["--node-image", nodeImage] }
        if let cniManifest { a += ["--cni", cniManifest] }
        if removeOnStop { a.append("--rm") }
        if let workers, workers > 0 { a += ["--workers", String(workers)] }
        return a
    }
}

/// An executable + arguments the UI can hand to an embedded terminal (SwiftTerm) or copy to the clipboard.
public struct CommandLine: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
    }

    /// Shell-quoted one-liner for display / copy.
    public var display: String {
        ([executable] + arguments).map { arg in
            arg.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"$`\\"))) == nil
                ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

/// What an embedded terminal should attach to.
public enum TerminalTarget: Hashable, Sendable {
    case container(id: String, command: [String])   // `container exec -it <id> <command>`
    case machine(name: String)                       // `container machine run -n <name>`
    case shell                                       // plain login shell with `container` on PATH
}
