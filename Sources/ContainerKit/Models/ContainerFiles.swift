import Foundation

/// One entry of a directory inside a container (the Files tab).
public struct ContainerFileEntry: Hashable, Sendable, Identifiable {
    /// File type, from the `S_IFMT` bits of the mode (or the first character of an `ls -l` line).
    public enum Kind: String, Hashable, Sendable {
        case file, directory, symlink, characterDevice, blockDevice, fifo, socket, unknown
    }

    /// Name within its directory (never contains `/`; may contain spaces, newlines or any other byte).
    public var name: String
    /// What the entry is. A symbolic link is `.symlink` whatever it points to.
    public var kind: Kind
    /// Size in bytes as reported by the container (`0` for device nodes listed by `ls`).
    public var size: Int64
    /// Permission bits including setuid/setgid/sticky (`mode & 0o7777`).
    public var permissions: UInt16
    /// Numeric owner, when the listing method reports it.
    public var uid: Int?
    /// Numeric group, when the listing method reports it.
    public var gid: Int?
    /// Owner name resolved inside the container (`nil` when unknown or only the id is known).
    public var owner: String?
    /// Group name resolved inside the container.
    public var group: String?
    /// Last modification time (`nil` when the listing method could not report one).
    public var modified: Date?
    /// Target of a symbolic link, verbatim.
    public var linkTarget: String?
    /// `true` when a symbolic link resolves to a directory (so it can be opened like a folder).
    public var linkPointsToDirectory: Bool

    /// Creates an entry.
    public init(
        name: String, kind: Kind, size: Int64 = 0, permissions: UInt16 = 0o644, uid: Int? = nil, gid: Int? = nil,
        owner: String? = nil, group: String? = nil, modified: Date? = nil, linkTarget: String? = nil,
        linkPointsToDirectory: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.uid = uid
        self.gid = gid
        self.owner = owner
        self.group = group
        self.modified = modified
        self.linkTarget = linkTarget
        self.linkPointsToDirectory = linkPointsToDirectory
    }

    /// The name identifies an entry within one directory.
    public var id: String { name }

    /// A directory, or a symbolic link that resolves to one.
    public var isBrowsable: Bool { kind == .directory || (kind == .symlink && linkPointsToDirectory) }

    /// Dot-file (hidden unless "Show Hidden Files" is on).
    public var isHidden: Bool { name.hasPrefix(".") }

    /// `drwxr-xr-x` form, including `s`/`S`/`t`/`T` for setuid, setgid and sticky.
    public var modeString: String {
        let type: Character
        switch kind {
        case .file: type = "-"
        case .directory: type = "d"
        case .symlink: type = "l"
        case .characterDevice: type = "c"
        case .blockDevice: type = "b"
        case .fifo: type = "p"
        case .socket: type = "s"
        case .unknown: type = "?"
        }
        func triple(_ shift: UInt16, special: UInt16, _ set: Character, _ unset: Character) -> String {
            let bits = permissions >> shift
            let execute = bits & 1 != 0
            let last: Character =
                permissions & special != 0 ? (execute ? set : unset) : (execute ? "x" : "-")
            return (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + String(last)
        }
        return String(type) + triple(6, special: 0o4000, "s", "S") + triple(3, special: 0o2000, "s", "S")
            + triple(0, special: 0o1000, "t", "T")
    }

    /// Octal permissions as `chmod` takes them (`755`, `4755`).
    public var octalMode: String { String(permissions, radix: 8) }

    /// `root:root`, falling back to numeric ids (`1000:1000`); empty when nothing is known.
    public var ownerDescription: String {
        let user = owner ?? uid.map(String.init)
        let groupName = group ?? gid.map(String.init)
        switch (user, groupName) {
        case (let u?, let g?): return "\(u):\(g)"
        case (let u?, nil): return u
        case (nil, let g?): return ":\(g)"
        case (nil, nil): return ""
        }
    }
}

/// The contents of one directory inside a container.
public struct ContainerDirectoryListing: Hashable, Sendable {
    /// How the entries were obtained (best first).
    public enum Method: String, Hashable, Sendable {
        /// `stat -c` records framed by a per-call nonce: exact for every file name.
        case stat
        /// `ls -lAn --full-time`.
        case lsFullTime
        /// `ls -lAn` (dates have minute or year precision).
        case lsLong
        /// `ls -la`.
        case lsBasic
    }

    /// Why a container cannot be browsed at all.
    public enum UnavailableReason: String, Hashable, Sendable {
        /// The image has no `sh` (distroless, scratch).
        case noShell
        /// There is a shell but neither a usable `stat` nor `ls`.
        case noListingTool
    }

    /// Absolute, normalized directory path.
    public var path: String
    /// Entries in the order the container reported them (the UI sorts).
    public var entries: [ContainerFileEntry]
    /// `true` when the directory holds more entries than the requested limit.
    public var isTruncated: Bool
    /// Listing method that produced `entries` (`nil` when `unavailable` is set).
    public var method: Method?
    /// Set when the image has no shell or listing tool; `entries` is then empty. Not an error.
    public var unavailable: UnavailableReason?

    /// Creates a listing.
    public init(
        path: String, entries: [ContainerFileEntry] = [], isTruncated: Bool = false, method: Method? = .stat,
        unavailable: UnavailableReason? = nil
    ) {
        self.path = path
        self.entries = entries
        self.isTruncated = isTruncated
        self.method = method
        self.unavailable = unavailable
    }
}

/// Pure helpers for absolute POSIX paths inside a container.
public enum ContainerPath {
    /// Directories whose removal breaks practically every image; `deletionRefusal` rejects them.
    public static let protectedDirectories: Set<String> = [
        "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64", "/libx32", "/opt", "/proc", "/root",
        "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/usr/bin", "/usr/lib", "/usr/lib64", "/usr/libexec",
        "/usr/local", "/usr/sbin", "/usr/share", "/var", "/var/lib", "/var/log", "/var/run",
    ]

    /// Collapses `//`, `.` and `..` and removes a trailing slash. A relative `path` is resolved against `base`
    /// (itself absolute). `..` never climbs above `/`.
    public static func normalize(_ path: String, relativeTo base: String = "/") -> String {
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Parent directory of a normalized path (`/` is its own parent).
    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// Last component of a normalized path (empty for `/`).
    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `directory` + `/` + `name`.
    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// `/`, `/var`, `/var/log` for `/var/log` (path bar crumbs).
    public static func ancestors(of path: String) -> [String] {
        var result = ["/"]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append(current)
        }
        return result
    }

    /// `true` when `path` is `ancestor` itself or lies below it.
    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        ancestor == "/" || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// `nil` when `name` can be used for a new file or folder; otherwise a user-facing reason.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name == "." || name == ".." { return "“\(name)” is not a valid name." }
        if name.contains("/") { return "A name cannot contain “/”." }
        if name.contains("\0") { return "A name cannot contain a NUL character." }
        if name.utf8.count > 255 { return "A name can be at most 255 bytes long." }
        return nil
    }

    /// Why `path` must not be deleted, or `nil` when deleting it is allowed. Refuses `/`, the standard system
    /// directories, anything that is not a normalized absolute path, and (given `mountPoints`) mounted volumes
    /// and their ancestors, whose contents live outside the container.
    public static func deletionRefusal(_ path: String, mountPoints: [String] = []) -> String? {
        guard path.hasPrefix("/"), normalize(path) == path, !path.contains("\0") else {
            return "“\(path)” is not an absolute, normalized path."
        }
        if path == "/" { return "The root directory cannot be deleted." }
        if protectedDirectories.contains(path) {
            return "“\(path)” is a system directory. Deleting it would break the container."
        }
        for mount in mountPoints.map({ normalize($0) }) where mount != "/" && isSameOrInside(mount, path) {
            return mount == path
                ? "“\(path)” is a mount point. Delete its contents individually, or remove the mount."
                : "“\(path)” contains the mount point “\(mount)”, whose data lives outside the container."
        }
        return nil
    }
}
