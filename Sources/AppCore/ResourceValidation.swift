import Foundation

/// Input validation for resource sheets (images, volumes, networks, builds). Pure functions so they are testable
/// without UI. Each returns `nil` when valid, or a short human-readable problem.
public enum ResourceValidator {
    /// Volume / network / container names: start with a letter or digit, then letters, digits, `_`, `.`
    /// (when `allowDots`), `-`. `maxLength` `nil` = unlimited. The app's single name rule.
    public static func resourceName(_ name: String, maxLength: Int? = 63, allowDots: Bool = true) -> String? {
        let s = name.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Enter a name." }
        if let maxLength, s.count > maxLength { return "Use at most \(maxLength) characters." }
        let ok = allowDots ? s.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\-]*/) != nil
                           : s.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_\-]*/) != nil
        guard ok else {
            return allowDots ? "Use letters, digits, “_”, “.” or “-”, starting with a letter or digit."
                             : "Use letters, digits, “_” or “-”, starting with a letter or digit."
        }
        return nil
    }

    /// `[registry[:port]/]repo[/more][:tag][@digest]`, OCI distribution grammar (lowercase repository).
    public static func imageReference(_ reference: String) -> String? {
        let s = reference.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Enter an image reference." }
        if s.contains(where: \.isWhitespace) { return "References cannot contain spaces." }
        var rest = Substring(s)
        if let at = rest.firstIndex(of: "@") {
            let digest = rest[rest.index(after: at)...]
            guard digest.wholeMatch(of: /[a-z0-9]+:[a-f0-9]{32,}/) != nil else { return "The digest must look like sha256:<hex>." }
            rest = rest[..<at]
        }
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            let tag = rest[rest.index(after: colon)...]
            if let problem = Self.tag(String(tag)) { return problem }
            rest = rest[..<colon]
        }
        var components = rest.split(separator: "/", omittingEmptySubsequences: false)
        if components.count > 1, let first = components.first, ImageReferenceName.isRegistryHost(first) {
            guard first.wholeMatch(of: /[A-Za-z0-9.\-]+(:[0-9]+)?/) != nil
                || first.wholeMatch(of: /\[[0-9A-Fa-f:.]+\](:[0-9]+)?/) != nil else { return "Invalid registry host “\(first)”." }
            components.removeFirst()
        }
        if components.isEmpty { return "Missing repository name." }
        for c in components {
            guard c.wholeMatch(of: /[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*/) != nil else {
                return c.isEmpty ? "Repository path has an empty component." : "“\(c)” must be lowercase letters, digits, “.”, “_” or “-”."
            }
        }
        return nil
    }

    /// Docker tag grammar: `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}`.
    public static func tag(_ tag: String) -> String? {
        if tag.isEmpty { return "The tag after “:” is empty." }
        guard tag.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127}/) != nil else {
            return "Tags use letters, digits, “_”, “.” or “-” (max 128)."
        }
        return nil
    }

    /// Prefix lengths accepted for a container network (a /31 or /32 leaves no room for containers).
    public static let ipv4PrefixRange: ClosedRange<Int> = 8...30
    /// The runtime's default network; user subnets overlapping it break routing.
    public static let defaultNetworkSubnet = "192.168.64.0/24"

    /// `192.168.70.0/24`: dotted quad, prefix /8–/30, no host bits set.
    public static func ipv4CIDR(_ cidr: String) -> String? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber),
              let prefix = Int(parts[1]) else {
            return "Use CIDR notation, e.g. 192.168.70.0/24."
        }
        guard let address = parseIPv4(parts[0]) else { return "“\(parts[0])” is not an IPv4 address." }
        guard ipv4PrefixRange.contains(prefix) else {
            return "Use a prefix between /\(ipv4PrefixRange.lowerBound) and /\(ipv4PrefixRange.upperBound)."
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        if address & ~mask != 0 {
            return "Host bits are set; the network address is \(formatIPv4(address & mask))/\(prefix)."
        }
        return nil
    }

    /// Non-blocking warning for a valid IPv4 CIDR that overlaps the default network or one of `existing`.
    public static func ipv4CIDRWarning(_ cidr: String, existing: [String] = []) -> String? {
        guard ipv4CIDR(cidr) == nil, let range = ipv4Range(cidr) else { return nil }
        for other in [defaultNetworkSubnet] + existing {
            guard let o = ipv4Range(other) else { continue }
            if range.lowerBound <= o.upperBound && o.lowerBound <= range.upperBound {
                return other == defaultNetworkSubnet
                    ? "Overlaps the default network \(defaultNetworkSubnet); containers may become unreachable."
                    : "Overlaps the existing subnet \(other)."
            }
        }
        return nil
    }

    static func parseIPv4<S: StringProtocol>(_ text: S) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for o in octets {
            guard !o.isEmpty, o.count <= 3, o.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt32(o), n <= 255 else { return nil }
            value = value << 8 | n
        }
        return value
    }

    static func formatIPv4(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)" }

    static func ipv4Range(_ cidr: String) -> ClosedRange<UInt32>? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let address = parseIPv4(parts[0]), let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return (address & mask)...(address | ~mask)
    }

    /// `fd00:1234::/64`.
    public static func ipv6CIDR(_ cidr: String) -> String? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let prefix = Int(parts[1]),
              (0...128).contains(prefix) else {
            return "Use CIDR notation, e.g. fd00:1::/64."
        }
        let address = String(parts[0])
        var storage = in6_addr()
        guard inet_pton(AF_INET6, address, &storage) == 1 else { return "“\(address)” is not an IPv6 address." }
        return nil
    }

    /// `KEY=VALUE` (build args, labels). `allowBareKey` accepts `KEY` (value inherited).
    public static func keyValue(_ entry: String, allowBareKey: Bool = false) -> String? {
        let s = entry.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let v = EnvironmentVariable(parsing: s)
        guard v.value != nil else { return allowBareKey ? nil : "Use KEY=VALUE." }
        return v.key.trimmingCharacters(in: .whitespaces).isEmpty ? "The key before “=” is empty." : nil
    }

    /// Hint for the build sheet: the accepted shape, how `src=` resolves, and what `env=` actually reads.
    public static let buildSecretHint =
        "Start with id=NAME, then env=VAR or src=PATH. Relative src= paths resolve against the build context (~ works). "
        + "env= reads Container Desktop's own environment, which doesn't include your shell profile when opened from Finder."

    /// Build secret as the CLI accepts it: `id=NAME[,env=VAR]` or `id=NAME,src=PATH` — `id=` first, no `type=`.
    public static func buildSecret(_ entry: String) -> String? {
        let s = entry.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        var fields: [(String, String)] = []
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "=") else { return "“\(part)” must be key=value." }
            fields.append((String(part[..<eq]), String(part[part.index(after: eq)...])))
        }
        guard let first = fields.first, first.0 == "id" else {
            return fields.contains { $0.0 == "id" } ? "Put id=NAME first." : "A secret needs id=NAME."
        }
        if first.1.isEmpty { return "A secret needs id=NAME." }
        let keys = fields.map(\.0)
        if keys.contains("type") { return "type= is not supported; use env= or src=." }
        if let unknown = keys.dropFirst().first(where: { !["env", "src"].contains($0) }) {
            return unknown == "id" ? "Use id= only once." : "Unknown field “\(unknown)”."
        }
        if keys.contains("env") && keys.contains("src") { return "Use either env= or src=, not both." }
        if keys.filter({ $0 != "id" }).count > 1 { return "Use one env= or src=." }
        if let empty = fields.dropFirst().first(where: { $0.1.isEmpty }) { return "\(empty.0)= needs a value." }
        return nil
    }

    /// Rewrites `src=` for the CLI: `~` expands to the home directory and relative paths resolve against
    /// `contextDirectory` (the CLI would otherwise resolve them against its own working directory, `/` for a
    /// Finder-launched app). Other entries are returned unchanged.
    public static func resolvedBuildSecret(_ entry: String, contextDirectory: String,
                                           home: String = NSHomeDirectory()) -> String {
        let s = entry.trimmingCharacters(in: .whitespaces)
        return s.split(separator: ",", omittingEmptySubsequences: false).map { part -> String in
            guard part.hasPrefix("src=") else { return String(part) }
            return "src=" + resolvedPath(String(part.dropFirst(4)), relativeTo: contextDirectory, home: home)
        }.joined(separator: ",")
    }

    /// `~` / `~/x` → home-based absolute path; relative → under `base`; absolute unchanged.
    public static func resolvedPath(_ path: String, relativeTo base: String?, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") || base == nil { return path }
        return ((base! as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Parses `KEY=VALUE` lines into a dictionary (invalid / empty lines ignored; keys and values trimmed).
    public static func labels(from rows: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let v = EnvironmentVariable(parsing: row.trimmingCharacters(in: .whitespaces))
            let key = v.key.trimmingCharacters(in: .whitespaces)
            guard let value = v.value, !key.isEmpty else { continue }
            result[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
