import Foundation

/// The one network operation update checks need, injected so tests answer with canned responses.
public protocol HTTPFetching: Sendable {
    /// Performs a GET and returns the body with the HTTP status code. Throws when there is no response at all
    /// (offline, DNS failure, timeout).
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

/// `HTTPFetching` over an ephemeral `URLSession`: no cookies, no cache, no credentials, no identifiers. The only
/// headers sent are `Accept` and a fixed `User-Agent` (GitHub rejects requests without one).
public struct URLSessionHTTPFetcher: HTTPFetching {
    /// Creates the fetcher.
    public init() {}

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ContainerDesktop", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// A product whose GitHub releases the app watches.
public enum ReleaseFeed: String, Sendable, CaseIterable {
    /// Container Desktop itself.
    case app
    /// Apple's `container` runtime.
    case runtime

    /// `owner/name` on GitHub.
    public var repository: String {
        switch self {
        case .app: return "AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui"
        case .runtime: return "apple/container"
        }
    }

    /// GitHub REST endpoint for the latest stable release (drafts and pre-releases are excluded by GitHub).
    public var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// The web page that always shows the latest release.
    public var latestReleasePage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    /// The Homebrew command that upgrades this product.
    public var brewUpgradeCommand: String {
        switch self {
        case .app: return "brew upgrade --cask container-desktop"
        case .runtime: return "brew upgrade container"
        }
    }

    /// The Homebrew command that installs Apple's runtime.
    public static let brewInstallRuntimeCommand = "brew install container"
}

/// A published release, reduced to what the app shows.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    /// Normalised version (`1.7.1`, no leading `v`).
    public let version: String
    /// The release's web page (always on github.com).
    public let pageURL: URL
    /// When it was published, if GitHub said.
    public let publishedAt: Date?

    /// Memberwise initialiser.
    public init(version: String, pageURL: URL, publishedAt: Date? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }

    /// `version` parsed for comparison.
    public var semanticVersion: SemanticVersion? { SemanticVersion(version) }

    /// Whether this release is a stable version newer than `installed`. False when either side is not a
    /// version (a `dev` build is never told to update) or this release is a pre-release.
    public func isNewer(than installed: String?) -> Bool {
        guard let latest = semanticVersion, !latest.isPrerelease,
            let installed, let current = SemanticVersion(installed)
        else { return false }
        return latest > current
    }
}

/// Why a check produced no answer. Never shown as an error banner; the Updates pane says "Could not check".
public enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// No response (offline, DNS, timeout).
    case offline
    /// GitHub's anonymous rate limit (HTTP 403 or 429).
    case rateLimited
    /// The repository has no published stable release (HTTP 404).
    case noRelease
    /// Any other HTTP status.
    case unexpectedStatus(Int)
    /// The body was not the JSON GitHub documents, or its tag is not a version.
    case malformed

    /// One short clause for the caption under "Could not check".
    public var explanation: String {
        switch self {
        case .offline: return "github.com could not be reached."
        case .rateLimited: return "GitHub is limiting requests from this network. Try again in an hour."
        case .noRelease: return "No release has been published yet."
        case .unexpectedStatus(let code): return "GitHub answered with HTTP \(code)."
        case .malformed: return "GitHub's answer could not be read."
        }
    }
}

/// Fetches and decodes the latest release of a feed.
public enum ReleaseLookup {
    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case draft, prerelease
        }
    }

    /// Asks GitHub for the feed's latest stable release.
    public static func latest(
        _ feed: ReleaseFeed, using http: any HTTPFetching
    ) async -> Result<
        ReleaseInfo, UpdateCheckFailure
    > {
        let response: (data: Data, status: Int)
        do { response = try await http.get(feed.latestReleaseAPI) } catch { return .failure(.offline) }
        switch response.status {
        case 200: break
        case 403, 429: return .failure(.rateLimited)
        case 404: return .failure(.noRelease)
        default: return .failure(.unexpectedStatus(response.status))
        }
        return parse(response.data, feed: feed)
    }

    /// Decodes a `releases/latest` body. Drafts, pre-releases and tags that are not versions are refused.
    public static func parse(_ data: Data, feed: ReleaseFeed) -> Result<ReleaseInfo, UpdateCheckFailure> {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let version = SemanticVersion(payload.tagName)
        else { return .failure(.malformed) }
        if payload.draft == true || payload.prerelease == true || version.isPrerelease {
            return .failure(.noRelease)
        }
        let published = payload.publishedAt.flatMap { try? Date($0, strategy: .iso8601) }
        return .success(
            ReleaseInfo(
                version: version.description, pageURL: trustedPage(payload.htmlURL, feed: feed),
                publishedAt: published))
    }

    /// The release page from the response, but only when it is an https github.com URL inside the feed's
    /// repository; otherwise the feed's fixed "latest release" page. The app opens this URL in the browser, so a
    /// tampered response must not be able to send the user elsewhere.
    static func trustedPage(_ text: String?, feed: ReleaseFeed) -> URL {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host() == "github.com",
            url.path().hasPrefix("/\(feed.repository)/releases/")
        else { return feed.latestReleasePage }
        return url
    }
}
