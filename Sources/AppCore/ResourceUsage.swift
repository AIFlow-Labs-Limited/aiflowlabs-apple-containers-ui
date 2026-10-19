import Foundation
import ContainerKit

/// Image reference normalization. The CLI reports local builds as `name:tag` in `image ls` but containers created
/// from them as `docker.io/library/name:tag`, so "in use" matching compares canonical forms.
public enum ImageReferenceName {
    /// `alpine` → `docker.io/library/alpine:latest`, `ghcr.io/x/y` → `ghcr.io/x/y:latest`. Digest refs keep the digest.
    public static func canonical(_ reference: String) -> String {
        var ref = reference.trimmingCharacters(in: .whitespaces)
        var digest = ""
        if let at = ref.firstIndex(of: "@") {
            digest = String(ref[at...])
            ref = String(ref[..<at])
        }
        let parts = ref.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let hasRegistry = parts.count == 2 && (parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost")
        if !hasRegistry {
            ref = ref.contains("/") ? "docker.io/\(ref)" : "docker.io/library/\(ref)"
        }
        let hasTag = ref.lastIndex(of: ":").map { !ref[$0...].contains("/") } ?? false
        if !hasTag && digest.isEmpty { ref += ":latest" }
        return ref + digest
    }

    /// Registry host of `reference` (`docker.io` when none is given).
    public static func registry(of reference: String) -> String {
        let canonical = canonical(reference)
        return String(canonical.split(separator: "/").first ?? "docker.io")
    }

    /// Whether two references name the same image.
    public static func same(_ a: String, _ b: String) -> Bool { a == b || canonical(a) == canonical(b) }
}

/// Container ↔ resource relationships for the Images / Volumes / Networks tables. Pure, so tests can feed fixtures.
public enum ResourceUsage {
    /// Containers whose image reference matches `image` (canonical comparison).
    public static func containers(using image: Image, in containers: [Container]) -> [Container] {
        let target = ImageReferenceName.canonical(image.reference)
        return containers.filter { ImageReferenceName.canonical($0.imageReference) == target }
    }

    /// Containers mounting `volume` (mounts whose type is `.volume(name:)`).
    public static func containers(mounting volume: Volume, in containers: [Container]) -> [Container] {
        containers.filter { $0.configuration.mounts.contains { $0.type.volumeName == volume.name } }
    }

    /// Containers attached to `network` — by runtime status first, falling back to the configured attachments
    /// for stopped containers.
    public static func containers(attachedTo network: Network, in containers: [Container]) -> [Container] {
        containers.filter { c in
            if let status = c.status, !status.networks.isEmpty {
                return status.networks.contains { $0.network == network.name }
            }
            return c.configuration.networks.contains { $0.network == network.name }
        }
    }

    /// Whether the image has no tag (dangling / `<none>`).
    public static func isUntagged(_ image: Image) -> Bool {
        image.tag == nil || image.reference.hasSuffix(":<none>") || image.reference.isEmpty
    }
}

/// Masks likely secrets in `KEY=VALUE` environment entries shown in inspectors.
/// Forwarding shim over `EnvironmentVariable` (the single masker); prefer that type in new code.
public enum EnvironmentMasking {
    /// Whether the variable name suggests a secret value.
    public static func isSecret(_ key: String) -> Bool { EnvironmentVariable.isSensitive(key: key) }

    /// `(key, value, isSecret)` for an env entry; a bare `KEY` has an empty value.
    public static func split(_ entry: String) -> (key: String, value: String, secret: Bool) {
        let v = EnvironmentVariable(parsing: entry)
        guard let value = v.value else { return (v.key, "", false) }
        return (v.key, value, v.isSensitive)
    }

    /// Display form: secrets become `KEY=••••••` (credential URLs keep everything but the password).
    public static func masked(_ entry: String) -> String {
        let v = EnvironmentVariable(parsing: entry)
        guard let value = v.value, v.isSensitive, !value.isEmpty else { return entry }
        return "\(v.key)=\(EnvironmentVariable.urlCredentialRange(in: value) != nil ? EnvironmentVariable.maskedValue(value) : "••••••")"
    }
}

/// Shortens a Dockerfile history `created_by` line for display.
public enum LayerHistoryText {
    public static func shorten(_ createdBy: String, limit: Int = 140) -> String {
        var s = createdBy.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/bin/sh -c #(nop) ", "/bin/sh -c ", "|"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if prefix == "|" { s = String(s.drop { $0.isNumber }).trimmingCharacters(in: .whitespaces) }
        }
        if s.hasPrefix("RUN /bin/sh -c ") { s = "RUN " + s.dropFirst("RUN /bin/sh -c ".count) }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " # buildkit", with: "")
        return s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }
}
