import Foundation

/// Most-recently-used strings persisted in `UserDefaults` (pull references, build context folders…).
/// Value type: create one where needed with the same key to share the list.
public struct RecentValues: Sendable {
    public let key: String
    public let limit: Int
    private let suiteName: String?

    /// `suiteName` selects a `UserDefaults` suite (tests); `nil` uses `.standard`.
    public init(key: String, limit: Int = 12, suiteName: String? = nil) {
        self.key = key
        self.limit = limit
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Newest first.
    public var values: [String] { defaults.stringArray(forKey: key) ?? [] }

    /// Moves `value` to the front (deduplicated, trimmed to `limit`).
    public func add(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        var list = values.filter { $0 != v }
        list.insert(v, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: key)
    }

    public func remove(_ value: String) { defaults.set(values.filter { $0 != value }, forKey: key) }

    public func clear() { defaults.removeObject(forKey: key) }

    /// Shared keys.
    public static let pulledImages = RecentValues(key: "recent.pulledImages")
    public static let buildContexts = RecentValues(key: "recent.buildContexts")
    public static let buildTags = RecentValues(key: "recent.buildTags")
}
