import Foundation

/// What the installed CLI's Kubernetes plugin can do, read from its own `--help` output rather than from a
/// version table (the plugin was renamed and reshaped between container 1.5 and 1.7; see `docs/COMPATIBILITY.md`).
///
/// Backends report it through `KubernetesOperations.kubernetesCapabilities()`; forms and views use it to pick the
/// command word for previews and to disable options the CLI does not have.
public struct KubernetesCapabilities: Hashable, Sendable {
    /// The plugin's subcommand: `k8s` (container 1.5.0, 1.6.0) or `cluster` (1.6.1 and later).
    public var commandWord: String
    /// `create --workers <n>` exists (1.6.0 and later).
    public var supportsWorkers: Bool
    /// `create --workers count=<n>,cpus=<n>,memory=<size>` (repeatable groups) exists (1.7 and later).
    public var supportsWorkerGroups: Bool
    /// `create --shared-image-store` exists (1.7 and later).
    public var supportsSharedImageStore: Bool
    /// The `load-image` subcommand exists (removed in 1.7).
    public var supportsLoadImage: Bool
    /// `load-image --node <name>` exists (1.6.x).
    public var supportsLoadImageNodes: Bool
    /// `list --format json` exists (1.7 and later); older plugins print the per-node table only.
    public var listsJSON: Bool
    /// `list --nodes` exists (1.7 and later), printing the per-node table that older plugins print by default.
    public var listsNodes: Bool
    /// The name `create` uses when `--name` is left out (`k8s-dev`, later `cluster-dev`).
    public var defaultClusterName: String

    /// Creates a capability set. Everything optional defaults to "not supported".
    public init(
        commandWord: String, supportsWorkers: Bool = false, supportsWorkerGroups: Bool = false,
        supportsSharedImageStore: Bool = false, supportsLoadImage: Bool = false, supportsLoadImageNodes: Bool = false,
        listsJSON: Bool = false, listsNodes: Bool = false, defaultClusterName: String? = nil
    ) {
        self.commandWord = commandWord
        self.supportsWorkers = supportsWorkers
        self.supportsWorkerGroups = supportsWorkerGroups
        self.supportsSharedImageStore = supportsSharedImageStore
        self.supportsLoadImage = supportsLoadImage
        self.supportsLoadImageNodes = supportsLoadImageNodes
        self.listsJSON = listsJSON
        self.listsNodes = listsNodes
        self.defaultClusterName = defaultClusterName ?? Self.fallbackClusterName(commandWord)
    }

    /// The plugin subcommands this app knows, newest first (the order they are probed in).
    public static let commandWords = ["cluster", "k8s"]

    /// `container k8s` as shipped with 1.5.0: single node, `load-image`, table-only listing. Also what a backend
    /// that cannot say more is assumed to be.
    public static let legacy = KubernetesCapabilities(commandWord: "k8s", supportsLoadImage: true)

    /// `container cluster` as shipped with 1.7.1: worker groups, shared image store, JSON listing, no `load-image`.
    public static let modern = KubernetesCapabilities(
        commandWord: "cluster", supportsWorkers: true, supportsWorkerGroups: true, supportsSharedImageStore: true,
        listsJSON: true, listsNodes: true)

    /// `container <word>` as it appears in command previews and copyable commands.
    public var displayCommand: String { "container \(commandWord)" }

    /// One-line reason shown next to the disabled worker controls, `nil` when workers can be created.
    public var workersUnavailableReason: String? {
        supportsWorkers
            ? nil
            : "Single node only: this container CLI's `\(commandWord) create` has no --workers option (added in 1.6)."
    }

    /// One-line reason shown next to the disabled per-group sizing, `nil` when groups can be sized.
    public var workerGroupsUnavailableReason: String? {
        supportsWorkerGroups
            ? nil
            : "Workers get the default size: this container CLI takes a worker count only (sized groups need 1.7)."
    }

    /// One-line reason shown next to the disabled shared-image-store toggle, `nil` when it is available.
    public var sharedImageStoreUnavailableReason: String? {
        supportsSharedImageStore
            ? nil
            : "Not available: this container CLI's `\(commandWord) create` has no --shared-image-store (added in 1.7)."
    }

    private static func fallbackClusterName(_ word: String) -> String { word == "k8s" ? "k8s-dev" : "cluster-dev" }
}

// MARK: - Detection from help text

extension KubernetesCapabilities {
    /// Builds the capability set from the plugin's ArgumentParser help screens.
    /// - Parameters:
    ///   - commandWord: the subcommand whose `--help` succeeded (`cluster` or `k8s`).
    ///   - pluginHelp: `container <word> --help` (the SUBCOMMANDS list).
    ///   - createHelp: `container <word> create --help`.
    ///   - listHelp: `container <word> list --help`.
    ///   - loadImageHelp: `container <word> load-image --help`, when that subcommand exists.
    public static func detect(
        commandWord: String, pluginHelp: String, createHelp: String, listHelp: String, loadImageHelp: String? = nil
    ) -> KubernetesCapabilities {
        let hasLoadImage = subcommands(in: pluginHelp).contains("load-image")
        let workers = hasOption("--workers", in: createHelp)
        return KubernetesCapabilities(
            commandWord: commandWord,
            supportsWorkers: workers,
            // 1.6 documents "--workers <workers>  Number of worker nodes"; 1.7 adds the `count=<n>,…` group form.
            supportsWorkerGroups: workers && createHelp.contains("count=<"),
            supportsSharedImageStore: hasOption("--shared-image-store", in: createHelp),
            supportsLoadImage: hasLoadImage,
            supportsLoadImageNodes: hasLoadImage && hasOption("--node", in: loadImageHelp ?? ""),
            listsJSON: hasOption("--format", in: listHelp),
            listsNodes: hasOption("--nodes", in: listHelp),
            defaultClusterName: defaultName(in: createHelp))
    }

    /// Names (and aliases) listed under `SUBCOMMANDS:` in an ArgumentParser help screen.
    static func subcommands(in help: String) -> Set<String> {
        var names: Set<String> = []
        var inSection = false
        for line in help.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Section titles (`OPTIONS:`, `SUBCOMMANDS:`, `USAGE: …`) are the only lines that start in column 0.
            if !line.hasPrefix(" ") {
                inSection = trimmed.hasPrefix("SUBCOMMANDS:")
                continue
            }
            // Entries are indented by exactly two spaces; wrapped descriptions are indented much further.
            guard inSection, line.hasPrefix("  "), !line.hasPrefix("   ") else { continue }
            let label = trimmed.split(separator: /\s{2,}/, maxSplits: 1).first.map(String.init) ?? trimmed
            for name in label.split(separator: ",") {
                let name = name.trimmingCharacters(in: .whitespaces)
                // The section ends with a two-space-indented sentence ("See 'cluster help <subcommand>' for
                // detailed help."), which is not a command name.
                if !name.isEmpty, !name.contains(" ") { names.insert(name) }
            }
        }
        return names
    }

    /// Whether `help` documents the long option `name` (as a whole word, so `--node` does not match `--nodes`
    /// or `--node-image`).
    static func hasOption(_ name: String, in help: String) -> Bool {
        var searchStart = help.startIndex
        while let range = help.range(of: name, range: searchStart..<help.endIndex) {
            let before = range.lowerBound == help.startIndex ? nil : help[help.index(before: range.lowerBound)]
            let after = range.upperBound == help.endIndex ? nil : help[range.upperBound]
            let startsWord = before.map { !($0.isLetter || $0.isNumber || $0 == "-") } ?? true
            let endsWord = after.map { !($0.isLetter || $0.isNumber || $0 == "-") } ?? true
            if startsWord && endsWord { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// The `--name` default from `create --help` (`Cluster name (default: cluster-dev)`).
    static func defaultName(in createHelp: String) -> String? {
        guard let option = createHelp.range(of: "--name <name>", options: .backwards) else { return nil }
        let tail = createHelp[option.upperBound...].prefix(200)
        guard let match = tail.firstMatch(of: /\(default:\s*([A-Za-z0-9][A-Za-z0-9_.-]*)\)/) else { return nil }
        return String(match.1)
    }
}
