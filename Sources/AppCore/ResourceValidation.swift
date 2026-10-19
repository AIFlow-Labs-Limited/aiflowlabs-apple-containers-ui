import Foundation

/// Input validation for resource sheets (images, volumes, networks, builds). Pure functions so they are testable
/// without UI. Each returns `nil` when valid, or a short human-readable problem.
public enum ResourceValidator {
    /// Volume / network names: start with a letter or digit, then letters, digits, `_`, `.`, `-` (max 63).
    public static func resourceName(_ name: String) -> String? {
        let s = name.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Enter a name." }
        if s.count > 63 { return "Use at most 63 characters." }
        guard s.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.\-]*/) != nil else {
            return "Use letters, digits, “_”, “.” or “-”, starting with a letter or digit."
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
        if components.count > 1, let first = components.first, first.contains(".") || first.contains(":") || first == "localhost" {
            guard first.wholeMatch(of: /[A-Za-z0-9.\-]+(:[0-9]+)?/) != nil else { return "Invalid registry host “\(first)”." }
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

    /// `192.168.70.0/24`.
    public static func ipv4CIDR(_ cidr: String) -> String? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return "Use CIDR notation, e.g. 192.168.70.0/24."
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ o in
            !o.isEmpty && o.count <= 3 && o.allSatisfy(\.isNumber) && (Int(o) ?? 256) <= 255
        }) else { return "“\(parts[0])” is not an IPv4 address." }
        return nil
    }

    /// `fd00:1234::/64`.
    public static func ipv6CIDR(_ cidr: String) -> String? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...128).contains(prefix) else {
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
        guard let eq = s.firstIndex(of: "=") else { return allowBareKey ? nil : "Use KEY=VALUE." }
        return s[..<eq].isEmpty ? "The key before “=” is empty." : nil
    }

    /// Build secret: `id=NAME[,env=VAR]` or `id=NAME,src=PATH`.
    public static func buildSecret(_ entry: String) -> String? {
        let s = entry.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        var fields: [String: String] = [:]
        for part in s.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { return "“\(part)” must be key=value." }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let id = fields["id"], !id.isEmpty else { return "A secret needs id=NAME." }
        if fields["env"] != nil && fields["src"] != nil { return "Use either env= or src=, not both." }
        let unknown = Set(fields.keys).subtracting(["id", "env", "src", "type"])
        return unknown.isEmpty ? nil : "Unknown field “\(unknown.sorted()[0])”."
    }

    /// Parses `KEY=VALUE` lines into a dictionary (invalid / empty lines ignored).
    public static func labels(from rows: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let s = row.trimmingCharacters(in: .whitespaces)
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            result[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return result
    }
}
