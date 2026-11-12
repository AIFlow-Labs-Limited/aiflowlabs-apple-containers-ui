import Foundation

/// A semantic version (`1.10.0`, `v0.2.0`, `1.8.0-beta.1`) that compares numerically, so `1.10.0 > 1.9.0`.
///
/// Parsing is lenient about what release tags look like in practice: a leading `v` is ignored, a missing minor
/// or patch counts as zero (`1.7` is `1.7.0`), and build metadata after `+` is dropped. Anything else that is
/// not a version (`latest`, `1.2.3.4`, an empty string) does not parse.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Incompatible-change counter.
    public let major: Int
    /// Feature counter.
    public let minor: Int
    /// Fix counter.
    public let patch: Int
    /// The part after `-` (`beta.1`), or `nil` for a stable release.
    public let prerelease: String?

    /// A stable version from its three numbers.
    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses a version or release tag; `nil` when the text is not a version.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var prerelease: String?
        if let dash = rest.firstIndex(of: "-") {
            let suffix = rest[rest.index(after: dash)...]
            guard !suffix.isEmpty else { return nil }
            prerelease = String(suffix)
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `Int("+1")` parses, so insist on digits only.
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    /// True for `1.8.0-beta.1` and friends. Pre-releases are never offered as updates.
    public var isPrerelease: Bool { prerelease != nil }

    /// `1.7.1`, or `1.8.0-beta.1` (never with a leading `v`).
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false  // a release is newer than its own pre-releases
        case (_, nil): return true
        case (let left?, let right?): return prereleasePrecedes(left, right)
        }
    }

    /// SemVer §11: compare dot-separated identifiers; numeric ones numerically and below alphanumeric ones;
    /// when all shared identifiers are equal the shorter list is older.
    private static func prereleasePrecedes(_ left: String, _ right: String) -> Bool {
        let a = left.split(separator: "."), b = right.split(separator: ".")
        for (x, y) in zip(a, b) where x != y {
            switch (Int(x), Int(y)) {
            case (let m?, let n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.count < b.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
