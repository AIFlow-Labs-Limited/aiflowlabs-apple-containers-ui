import Foundation

/// OCI platform (`{"architecture":"arm64","os":"linux"}`).
public struct Platform: Codable, Hashable, Sendable {
    public var architecture: String
    public var os: String
    public var variant: String?

    public init(architecture: String, os: String = "linux", variant: String? = nil) {
        self.architecture = architecture
        self.os = os
        self.variant = variant
    }

    /// `linux/arm64` form used by `--platform`.
    public var slug: String { variant.map { "\(os)/\(architecture)/\($0)" } ?? "\(os)/\(architecture)" }
    public static let arm64 = Platform(architecture: "arm64")
    public static let amd64 = Platform(architecture: "amd64")
}

/// OCI content descriptor.
public struct Descriptor: Codable, Hashable, Sendable {
    public var digest: String
    public var mediaType: String
    public var size: Int64
    public var annotations: [String: String]?

    public init(digest: String, mediaType: String, size: Int64, annotations: [String: String]? = nil) {
        self.digest = digest
        self.mediaType = mediaType
        self.size = size
        self.annotations = annotations
    }

    /// First 12 hex chars after `sha256:`.
    public var shortDigest: String { String(digest.split(separator: ":").last?.prefix(12) ?? "") }
}

/// `{"descriptor": …, "reference": "docker.io/library/python:alpine"}`.
public struct ImageReference: Codable, Hashable, Sendable {
    public var reference: String
    public var descriptor: Descriptor

    public init(reference: String, descriptor: Descriptor) {
        self.reference = reference
        self.descriptor = descriptor
    }
}

/// Labels the runtime attaches to its own resources.
public enum ResourceLabel {
    public static let role = "com.apple.container.resource.role"
    public static let plugin = "com.apple.container.plugin"
    public static let anonymousVolume = "com.apple.container.resource.anonymous"
    public enum Role {
        public static let builder = "builder"
        public static let builtin = "builtin"
    }
}

/// Label this app attaches to resources it creates (compose-style grouping).
public enum AppLabel {
    public static let project = "io.aiflowlabs.containerdesktop.project"
}

/// Memory size strings as accepted by the CLI (`512m`, `4g`, `2048mb`). Binary units.
public struct MemorySize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var bytes: Int64

    public init(bytes: Int64) { self.bytes = bytes }

    /// Parses `1g`, `1gb`, `1gib`, `2048mb`, `512m`, `.5g`, bare bytes. Case-insensitive.
    /// Returns `nil` for zero, negative, non-finite or out-of-range (≥ 2⁶³ bytes) sizes.
    public init?(parsing text: String) {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard digits.allSatisfy(\.isASCII), let value = Double(digits) else { return nil }
        let unit = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb", "kib": multiplier = 1024
        case "m", "mb", "mib": multiplier = 1_048_576
        case "g", "gb", "gib": multiplier = 1_073_741_824
        case "t", "tb", "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        let product = (value * multiplier).rounded()
        // Double(Int64.max) rounds up to 2^63, so `<` keeps the conversion below in range.
        guard product.isFinite, product >= 1, product < Double(Int64.max) else { return nil }
        bytes = Int64(product)
    }

    /// Argument for memory flags (`-m`, `--memory`, `--shm-size`, `memory=`): the CLI works in 1 MiB steps,
    /// so the size is rounded to the nearest whole MiB (at least 1) and written as `NG` or `NM`.
    public var cliArgument: String {
        let mebibytes = max(1, (bytes + (1 << 19)) >> 20)
        return mebibytes % 1024 == 0 ? "\(mebibytes / 1024)G" : "\(mebibytes)M"
    }

    /// Exact size in bytes with no suffix, for flags that take bytes (`volume create -s`).
    public var cliArgumentBytes: String { String(bytes) }

    public var description: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
