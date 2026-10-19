import Foundation

/// An image as reported by `container image ls --format json` / `container image inspect`.
public struct Image: Codable, Identifiable, Hashable, Sendable {
    /// Index digest hex (no `sha256:` prefix).
    public var id: String
    public var configuration: Configuration
    public var variants: [Variant]

    public init(id: String, configuration: Configuration, variants: [Variant]) {
        self.id = id
        self.configuration = configuration
        self.variants = variants
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        configuration = try c.decode(Configuration.self, forKey: .configuration)
        variants = (try? c.decodeIfPresent(LossyArray<Variant>.self, forKey: .variants))?.elements ?? []
    }

    // MARK: Derived

    /// Full reference, e.g. `docker.io/library/python:alpine`.
    public var reference: String { configuration.name }
    /// `python` / `library/python` without registry and tag.
    public var repository: String {
        var ref = reference
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") { ref = String(ref[..<colon]) }
        if ref.hasPrefix("docker.io/library/") { ref = String(ref.dropFirst("docker.io/library/".count)) }
        else if ref.hasPrefix("docker.io/") { ref = String(ref.dropFirst("docker.io/".count)) }
        return ref
    }
    public var tag: String? {
        guard let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") else { return nil }
        return String(reference[reference.index(after: colon)...])
    }
    public var platforms: [Platform] { variants.map(\.platform) }
    public var isMultiArch: Bool { variants.count > 1 }
    /// Sum of all variant sizes (compressed).
    public var totalSize: Int64 { variants.reduce(0) { $0 + $1.size } }
    public var created: Date { variants.compactMap(\.config?.created).max() ?? configuration.creationDate }
    public var shortID: String { String(id.prefix(12)) }

    public struct Configuration: Codable, Hashable, Sendable {
        public var name: String
        public var creationDate: Date
        public var descriptor: Descriptor

        public init(name: String, creationDate: Date, descriptor: Descriptor) {
            self.name = name
            self.creationDate = creationDate
            self.descriptor = descriptor
        }

        /// `name` and `descriptor` are required; an unreadable date falls back to the epoch.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            creationDate = LenientDecoding.date(c, .creationDate)
            descriptor = try c.decode(Descriptor.self, forKey: .descriptor)
        }
    }

    public struct Variant: Codable, Hashable, Sendable {
        public var platform: Platform
        public var digest: String
        public var size: Int64
        public var config: OCIConfig?

        public init(platform: Platform, digest: String, size: Int64, config: OCIConfig? = nil) {
            self.platform = platform
            self.digest = digest
            self.size = size
            self.config = config
        }
    }

    /// OCI image config (`variants[].config`).
    public struct OCIConfig: Codable, Hashable, Sendable {
        public var architecture: String?
        public var os: String?
        public var created: Date?
        public var author: String?
        public var config: RuntimeConfig?
        public var rootfs: RootFS?
        public var history: [History]?

        public struct RuntimeConfig: Codable, Hashable, Sendable {
            public var cmd: [String]?
            public var entrypoint: [String]?
            public var env: [String]?
            public var workingDir: String?
            public var user: String?
            public var labels: [String: String]?
            public var exposedPorts: [String: JSONValue]?
            public var volumes: [String: JSONValue]?

            enum CodingKeys: String, CodingKey {
                case cmd = "Cmd", entrypoint = "Entrypoint", env = "Env", workingDir = "WorkingDir"
                case user = "User", labels = "Labels", exposedPorts = "ExposedPorts", volumes = "Volumes"
            }

            public var exposedPortList: [String] { exposedPorts.map { Array($0.keys).sorted() } ?? [] }
        }

        public struct RootFS: Codable, Hashable, Sendable {
            public var type: String
            public var diffIDs: [String]
            enum CodingKeys: String, CodingKey { case type, diffIDs = "diff_ids" }
        }

        public struct History: Codable, Hashable, Sendable {
            public var created: Date?
            public var createdBy: String?
            public var comment: String?
            public var emptyLayer: Bool?
            enum CodingKeys: String, CodingKey {
                case created, createdBy = "created_by", comment, emptyLayer = "empty_layer"
            }
        }
    }
}
